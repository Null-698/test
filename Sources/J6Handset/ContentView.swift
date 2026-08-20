import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver

    @State private var selectedTab: RootTab = .keypad
    @State private var callScreenMinimized = false

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(
                    "Keypad",
                    systemImage: "circle.grid.3x3.fill",
                    value: RootTab.keypad
                ) {
                    keypadScreen
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
            .tint(.primary)

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
        .onChange(of: ble.uiCallState) {
            oldState,
            newState in

            if isCallPresentationState(newState) &&
               !isCallPresentationState(oldState) {
                callScreenMinimized = false
            }

            if newState == "IDLE" ||
               newState == "DISCONNECTED" {
                callScreenMinimized = false
            }
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
                        ? "J6 connected"
                        : "J6 disconnected"
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
            title: "J6 Connection",
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

            Text(ble.bluetoothStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            SettingsRow(
                title: "Audio peer",
                value: ble.audioPeerStatus
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
                .disabled(
                    ble.isScanning ||
                    ble.isConnected
                )

                if ble.isConnected {
                    Button("Disconnect") {
                        ble.disconnect()
                    }
                    .buttonStyle(.glass)
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

            TextField(
                "J6 Wi-Fi IP",
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
                value: relay.status
            )

            DisclosureGroup("Diagnostics") {
                VStack(spacing: 12) {
                    SettingsRow(
                        title: "Auto restarts",
                        value: "\(relay.audioRestartCount)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Mic → J6",
                        value: "\(relay.sentFrames)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "J6 → iPhone",
                        value: "\(relay.receivedFrames)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Mic / caller RMS",
                        value:
                            "\(relay.micRMS) / \(relay.remoteRMS)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Jitter q / target",
                        value:
                            "\(relay.jitterBuffered) / \(relay.jitterTarget)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Network jitter",
                        value:
                            String(
                                format:
                                    "%.1f ms",
                                relay.jitterMS
                            ),
                        monospaced: true
                    )

                    SettingsRow(
                        title: "PLC / late / stale",
                        value:
                            "\(relay.plcFrames) / \(relay.lateFrames) / \(relay.latencyDrops)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Clock -/+ samples",
                        value:
                            "\(relay.clockShortens) / \(relay.clockStretches)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Wire bad / resets",
                        value:
                            "\(relay.badWirePackets) / \(relay.streamResets)",
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Audio route",
                        value: relay.audioRoute
                    )

                    SettingsRow(
                        title: "iOS I/O buffer",
                        value:
                            String(
                                format:
                                    "%.1f ms",
                                relay.ioBufferMS
                            ),
                        monospaced: true
                    )

                    SettingsRow(
                        title: "Input / output",
                        value:
                            String(
                                format:
                                    "%.1f / %.1f ms",
                                relay.inputLatencyMS,
                                relay.outputLatencyMS
                            ),
                        monospaced: true
                    )
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
}

private enum RootTab: Hashable {
    case keypad
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

private struct SettingsBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}
