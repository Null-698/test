import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver
    @EnvironmentObject private var sms: SMSController

    @ObservedObject private var systemCallRequests =
        SystemCallRequestCenter.shared

    @State private var selectedTab: RootTab = .keypad
    @State private var callScreenMinimized = false
    @State private var selectedContact: CellularContactSelection?
    @State private var pendingContactAction: CellularContactAction?
    @State private var contactComposeRequest: ContactComposeRequest?

    var body: some View {
        ZStack {
            TabView(
                selection: $selectedTab
            ) {
                Tab(
                    "Keypad",
                    systemImage: "circle.grid.3x3.fill",
                    value: RootTab.keypad
                ) {
                    keypadScreen
                }

                Tab(
                    "Recents",
                    systemImage: "clock.fill",
                    value: RootTab.recents
                ) {
                    NavigationStack {
                        RecentsView()
                            .safeAreaInset(
                                edge: .top,
                                spacing: 10
                            ) {
                                if hasVisibleCall &&
                                   callScreenMinimized {
                                    SystemCallStrip()
                                        .padding(.horizontal, 16)
                                        .onTapGesture {
                                            callScreenMinimized = false
                                        }
                                }
                            }
                    }
                }

                Tab(
                    "Contacts",
                    systemImage: "person.crop.circle.fill",
                    value: RootTab.contacts
                ) {
                    NavigationStack {
                        CellularContactsListView { selection in
                            selectedContact = selection
                        }
                        .sheet(
                            item: $selectedContact,
                            onDismiss: performPendingContactAction
                        ) { selection in
                            NavigationStack {
                                CellularContactDetailView(
                                    selection: selection
                                ) { action in
                                    pendingContactAction = action
                                }
                            }
                            .presentationDetents([.medium, .large])
                        }
                        .safeAreaInset(
                            edge: .top,
                            spacing: 10
                        ) {
                            if hasVisibleCall &&
                               callScreenMinimized {
                                SystemCallStrip()
                                    .padding(.horizontal, 16)
                                    .onTapGesture {
                                        callScreenMinimized = false
                                    }
                            }
                        }
                    }
                }

                Tab(
                    "Messages",
                    systemImage: sms.unreadCount > 0 ? "message.badge.fill" : "message.fill",
                    value: RootTab.messages
                ) {
                    NavigationStack {
                        SMSInboxView()
                    }
                }

                Tab(
                    "Settings",
                    systemImage: "gearshape.fill",
                    value: RootTab.settings
                ) {
                    settingsScreen
                }
            }
            .tabBarMinimizeBehavior(.never)
            .tint(AppTheme.tint)

            if hasVisibleCall &&
               !callScreenMinimized {
                InAppCallView {
                    callScreenMinimized = true
                }
                .transition(
                    .opacity.combined(
                        with: .scale(scale: 0.985)
                    )
                )
                .zIndex(20)
            }

            if let failed =
                callKit.failedOutgoingNumber {
                CallFailedView(
                    number: formatted(failed),
                    onCancel: {
                        callKit.dismissFailedOutgoingCall()
                    },
                    onCallBack: {
                        let retry = failed
                        callKit.dismissFailedOutgoingCall()
                        callKit.startOutgoing(number: retry)
                    }
                )
                .transition(.opacity)
                .zIndex(30)
            }
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: callScreenMinimized
        )
        .animation(
            .easeInOut(duration: 0.18),
            value: callKit.failedOutgoingNumber
        )
        .sheet(item: $contactComposeRequest) { request in
            SMSComposeView(
                initialRecipient: request.recipient
            )
            .environmentObject(sms)
            .environmentObject(ble)
            .environmentObject(contacts)
        }
        .onChange(of: ble.uiCallState) {
            oldState,
            newState in

            if isCallPresentationState(newState) &&
               !isCallPresentationState(oldState) {
                callScreenMinimized = false
                dismissContactsFlow()
            }

            if newState == "IDLE" ||
               newState == "DISCONNECTED" {
                callScreenMinimized = false
            }
        }
        .onAppear {
            sms.setApplicationActive(scenePhase == .active)
            sms.requestNotificationPermissionIfNeeded()
            if sms.requestedThreadKey != nil ||
               sms.requestedComposeRecipient != nil {
                selectedTab = .messages
            }
            handlePendingSystemCall()
        }
        .onChange(of: scenePhase) { _, newPhase in
            sms.setApplicationActive(newPhase == .active)
        }
        .onContinueUserActivity(
            SystemCallActivity.modernType
        ) { userActivity in
            _ = systemCallRequests.receive(userActivity)
        }
        .onContinueUserActivity(
            SystemCallActivity.legacyAudioType
        ) { userActivity in
            _ = systemCallRequests.receive(userActivity)
        }
        .onOpenURL { url in
            _ = systemCallRequests.receive(url)
        }
        .onChange(of: systemCallRequests.pendingRequest) {
            _, _ in
            handlePendingSystemCall()
        }
        .onChange(of: sms.requestedThreadKey) { _, threadKey in
            if threadKey != nil {
                selectedTab = .messages
            }
        }
        .onChange(of: sms.requestedComposeRecipient) { _, recipient in
            if recipient != nil {
                selectedTab = .messages
            }
        }
        .fileExporter(
            isPresented: $relay.debugExportRequested,
            document: DebugLogDocument(text: relay.debugExportText),
            contentType: .plainText,
            defaultFilename: relay.debugExportFilename
        ) { result in
            relay.debugExportCompleted(result)
        }
    }

    private var keypadScreen: some View {
        NavigationStack {
            NativeDialerView()
                .safeAreaInset(
                    edge: .top,
                    spacing: 10
                ) {
                    if hasVisibleCall &&
                       callScreenMinimized {
                        SystemCallStrip()
                            .padding(.horizontal, 16)
                            .onTapGesture {
                                callScreenMinimized = false
                            }
                    }
                }
        }
    }

    private var settingsScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    settingsHeader
                    contactsCard
                    bluetoothCard
                    audioCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .background {
                SettingsBackdrop()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(
                edge: .top,
                spacing: 10
            ) {
                if hasVisibleCall &&
                   callScreenMinimized {
                    SystemCallStrip()
                        .padding(.horizontal, 16)
                        .onTapGesture {
                            callScreenMinimized = false
                        }
                }
            }
            .onAppear {
                contacts.requestAccessIfNeeded()
                relay.refreshLocalIP()

                if ble.isConnected {
                    ble.configureAudioPeer(
                        ip: relay.localIP
                    )
                }
            }
        }
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .glassEffect(
                    .regular,
                    in: .rect(cornerRadius: 14)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("Cellular Relay")
                    .font(.headline)

                Text(
                    ble.isConnected
                        ? "Relay connected"
                        : "Relay disconnected"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(
                    ble.isConnected
                        ? Color.green
                        : Color.secondary.opacity(0.35)
                )
                .frame(width: 10, height: 10)
        }
        .padding(16)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 24)
        )
    }

    private var contactsCard: some View {
        SettingsCard(
            title: "Contacts",
            subtitle: "Caller identification",
            symbol: "person.crop.circle"
        ) {
            SettingsRow(
                title: "Access",
                value: contacts.authorizationText
            )

            Divider()

            Text(contacts.lastLookupStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !contacts.canReadContacts {
                Button("Allow Contacts Access") {
                    contacts.requestAccessIfNeeded()
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .tint(AppTheme.tint)
            }

            if callKit.contactMatched {
                Divider()

                SettingsRow(
                    title: "Matched caller",
                    value:
                        callKit.displayCallerName.isEmpty
                            ? "Contact"
                            : callKit.displayCallerName
                )
            }

            Text(
                "Contacts are optional. Calls still work if access is denied."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bluetoothCard: some View {
        SettingsCard(
            title: "Relay Connection",
            subtitle: "Bluetooth control channel",
            symbol: "antenna.radiowaves.left.and.right"
        ) {
            SettingsRow(
                title: "Connection",
                value:
                    ble.isConnected
                        ? "Connected"
                        : "Disconnected"
            )

            Divider()

            Text(relayDisplayText(ble.bluetoothStatus))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsRow(
                title: "Audio peer",
                value: relayDisplayText(ble.audioPeerStatus)
            )

            HStack(spacing: 12) {
                Button(
                    ble.isScanning
                        ? "Scanning…"
                        : "Scan / Reconnect"
                ) {
                    ble.scan()
                }
                .buttonStyle(.glassProminent)
                .tint(AppTheme.tint)
                .disabled(
                    ble.isScanning ||
                    ble.isConnected
                )

                if ble.isConnected {
                    Button("Disconnect") {
                        ble.disconnect()
                    }
                    .buttonStyle(.glass)
                    .tint(AppTheme.tint)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Last state packet")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    ble.lastWireState.isEmpty
                        ? "—"
                        : ble.lastWireState
                )
                .font(
                    .system(
                        .caption,
                        design: .monospaced
                    )
                )
                .textSelection(.enabled)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
            }
        }
    }

    private var audioCard: some View {
        SettingsCard(
            title: "Call Audio",
            subtitle: "Wi-Fi relay and diagnostics",
            symbol: "waveform"
        ) {
            SettingsRow(
                title: "This iPhone",
                value: relay.localIP,
                monospaced: true
            )

            Button("Refresh / Send iPhone IP") {
                relay.refreshLocalIP()
                ble.configureAudioPeer(
                    ip: relay.localIP
                )
            }
            .buttonStyle(.glass)
            .tint(AppTheme.tint)

            TextField(
                "Relay Wi-Fi IP",
                text: $relay.j6IP
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.numbersAndPunctuation)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .glassEffect(
                .regular,
                in: .rect(cornerRadius: 15)
            )
            .tint(AppTheme.tint)

            Divider()

            SettingsRow(
                title: "Audio",
                value:
                    relay.isRunning
                        ? "Active"
                        : "Stopped"
            )

            SettingsRow(
                title: "Mic stream",
                value:
                    relay.micStreamingReady
                        ? "Verified"
                        : "Waiting"
            )

            SettingsRow(
                title: "Status",
                value: relayDisplayText(relay.status)
            )

            DisclosureGroup("Advanced diagnostics") {
                VStack(spacing: 12) {
                    SettingsRow(
                        title: "Renderer",
                        value: "Stage 2 direct 48k v19.11 Native Call Controls"
                    )

                    SettingsRow(
                        title: "Auto restarts",
                        value: "\(relay.audioRestartCount)",
                        monospaced: true
                    )

                    RelayDiagnosticsRows(
                        diagnostics: relay.diagnostics
                    )

                    Divider()

                    Toggle(
                        "Diagnostic logging",
                        isOn: Binding(
                            get: { relay.diagnosticLoggingEnabled },
                            set: { relay.setDiagnosticLoggingEnabled($0) }
                        )
                    )
                    .tint(AppTheme.tint)

                    SettingsRow(
                        title: "Debug log",
                        value: relay.debugLogStatus
                    )

                    Button("Export Debug Log") {
                        relay.exportDebugLogNow()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(AppTheme.tint)
                    .disabled(!relay.diagnosticLoggingEnabled)

                    Text(
                        relay.diagnosticLoggingEnabled
                            ? "Diagnostic file logging is enabled. Export Debug Log creates a snapshot you can save to Downloads."
                            : "Diagnostic file logging is off. No diagnostic file is created or written until you explicitly enable it."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                }
                .padding(.top, 12)
            }

            Text(
                "Call audio switches automatically from real cellular ringback to full duplex when the GSM call becomes active."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var hasVisibleCall: Bool {
        ble.uiCallState == "RINGING" ||
        hasOngoingCall
    }

    private func isCallPresentationState(
        _ state: String
    ) -> Bool {
        switch state {
        case "RINGING",
             "NEW",
             "CONNECTING",
             "SELECT_PHONE_ACCOUNT",
             "DIALING",
             "ACTIVE",
             "HOLDING",
             "DISCONNECTING":
            return true
        default:
            return false
        }
    }

    private var hasOngoingCall: Bool {
        switch ble.uiCallState {
        case "NEW",
             "CONNECTING",
             "SELECT_PHONE_ACCOUNT",
             "DIALING",
             "ACTIVE",
             "HOLDING",
             "DISCONNECTING":
            return true
        default:
            return false
        }
    }

    private func formatted(
        _ number: String
    ) -> String {
        let basic =
            contacts.basicMetadata(for: number)

        return basic.formattedNumber.isEmpty
            ? number
            : basic.formattedNumber
    }

    private func relayDisplayText(_ value: String) -> String {
        value.replacingOccurrences(
            of: "J6",
            with: "Relay",
            options: [.caseInsensitive]
        )
    }

    private func handlePendingSystemCall() {
        guard let request = systemCallRequests.pendingRequest,
              let number = systemCallRequests.consume(request)
        else {
            return
        }

        selectedTab = .keypad
        callScreenMinimized = false
        callKit.startOutgoing(number: number)
    }

    private func dismissContactsFlow() {
        selectedContact = nil
        pendingContactAction = nil
        contactComposeRequest = nil
    }

    private func performPendingContactAction() {
        guard let action = pendingContactAction else {
            return
        }
        pendingContactAction = nil

        switch action {
        case .call(let rawNumber):
            let number = contacts.normalizedHandle(
                for: rawNumber
            )
            guard !number.isEmpty else {
                return
            }

            callScreenMinimized = false
            callKit.startOutgoing(number: number)

        case .message(let rawNumber):
            let normalized = contacts.normalizedHandle(
                for: rawNumber
            )
            let recipient = normalized.isEmpty
                ? rawNumber.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                : normalized
            guard !recipient.isEmpty else {
                return
            }

            contactComposeRequest = ContactComposeRequest(
                recipient: recipient
            )
        }
    }
}

private struct ContactComposeRequest: Identifiable {
    let id = UUID()
    let recipient: String
}

private enum RootTab: Hashable {
    case keypad
    case recents
    case messages
    case contacts
    case settings
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .glassEffect(
                        .regular,
                        in: .rect(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 26)
        )
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(
                    monospaced
                        ? .system(.body, design: .monospaced)
                        : .body
                )
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

private struct RelayDiagnosticsRows: View {
    @ObservedObject var diagnostics: RelayDiagnostics

    var body: some View {
        let stats = diagnostics.snapshot

        Group {
            SettingsRow(
                title: "Uplink frames",
                value: "\(stats.sentFrames)",
                monospaced: true
            )

            SettingsRow(
                title: "Downlink frames",
                value: "\(stats.receivedFrames)",
                monospaced: true
            )

            SettingsRow(
                title: "Mic / caller RMS",
                value: "\(stats.micRMS) / \(stats.remoteRMS)",
                monospaced: true
            )

            SettingsRow(
                title: "Direct FIFO / start",
                value: "\(stats.directBuffered) / \(stats.directStartFrames)",
                monospaced: true
            )

            SettingsRow(
                title: "Seq gaps / late / overflow",
                value: "\(stats.sequenceGaps) / \(stats.lateFrames) / \(stats.latencyDrops)",
                monospaced: true
            )

            SettingsRow(
                title: "Renderer underruns",
                value: "\(stats.rendererUnderruns)",
                monospaced: true
            )

            SettingsRow(
                title: "Fixed rebuffers",
                value: "\(stats.rebufferEvents)",
                monospaced: true
            )

            SettingsRow(
                title: "Max packet gap",
                value: String(
                    format: "%.1f ms",
                    stats.maxPacketGapMS
                ),
                monospaced: true
            )

            SettingsRow(
                title: "Rate conversion",
                value: stats.audioRoute.contains("Bluetooth")
                    ? "Route-dependent"
                    : "Direct 48 kHz",
                monospaced: true
            )

            SettingsRow(
                title: "Wire bad / resets",
                value: "\(stats.badWirePackets) / \(stats.streamResets)",
                monospaced: true
            )

            SettingsRow(
                title: "Audio route",
                value: stats.audioRoute
            )

            SettingsRow(
                title: "iOS I/O buffer",
                value: String(
                    format: "%.1f ms",
                    stats.ioBufferMS
                ),
                monospaced: true
            )

            SettingsRow(
                title: "Input / output",
                value: String(
                    format: "%.1f / %.1f ms",
                    stats.inputLatencyMS,
                    stats.outputLatencyMS
                ),
                monospaced: true
            )
        }
    }
}

private struct SettingsBackdrop: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}
