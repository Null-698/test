import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver

    @State private var selectedTab: RootTab = .keypad
    @State private var callScreenMinimized = false
    @State private var searchText = ""

    var body: some View {
        ZStack {
            rootTabs

            // Our full Phone-style in-app call face controls the same real
            // CallKit/J6 call. System CallKit remains authoritative.
            if hasVisibleCall &&
               !callScreenMinimized {
                InAppCallView {
                    callScreenMinimized = true
                }
                .transition(.opacity)
                .zIndex(20)
            }

            if let failed =
                callKit.failedOutgoingNumber {
                CallFailedView(
                    number: formatted(
                        failed
                    ),
                    onCancel: {
                        callKit
                            .dismissFailedOutgoingCall()
                    },
                    onCallBack: {
                        let retry = failed
                        callKit
                            .dismissFailedOutgoingCall()
                        callKit.startOutgoing(
                            number: retry
                        )
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
            value:
                callKit.failedOutgoingNumber
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

    private var rootTabs: some View {
        TabView(selection: $selectedTab) {
            Tab(
                "Calls",
                systemImage: "clock",
                value: RootTab.calls
            ) {
                gatewayScreen
            }

            Tab(
                "Contacts",
                systemImage: "person.crop.circle",
                value: RootTab.contacts
            ) {
                contactsScreen
            }

            Tab(
                "Keypad",
                systemImage: "circle.grid.3x3",
                value: RootTab.keypad
            ) {
                dialerScreen
            }

            // Apple specifically recommends a semantic search tab.
            // On iOS 26 the system pins it separately at the trailing edge
            // and gives it the current Liquid Glass search presentation.
            Tab(
                value: RootTab.search,
                role: .search
            ) {
                searchScreen
            }
        }
        .tabBarMinimizeBehavior(.never)
    }

    private var dialerScreen: some View {
        NativeDialerView()
            .safeAreaInset(
                edge: .top,
                spacing: 8
            ) {
                if hasVisibleCall &&
                   callScreenMinimized {
                    SystemCallStrip()
                        .padding(
                            .horizontal,
                            14
                        )
                        .onTapGesture {
                            callScreenMinimized = false
                        }
                }
            }
    }

    private var gatewayScreen: some View {
        NavigationStack {
            Form {
                bluetoothSection
                audioSection
            }
            .navigationTitle("Calls")
            .safeAreaInset(
                edge: .top,
                spacing: 8
            ) {
                if hasVisibleCall &&
                   callScreenMinimized {
                    SystemCallStrip()
                        .padding(
                            .horizontal,
                            14
                        )
                        .onTapGesture {
                            callScreenMinimized = false
                        }
                }
            }
            .onAppear {
                relay.refreshLocalIP()

                if ble.isConnected {
                    ble.configureAudioPeer(
                        ip: relay.localIP
                    )
                }
            }
        }
    }

    private var contactsScreen: some View {
        NavigationStack {
            Form {
                contactsSection
            }
            .navigationTitle("Contacts")
            .onAppear {
                contacts
                    .requestAccessIfNeeded()
            }
        }
    }

    private var searchScreen: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search",
                        systemImage:
                            "magnifyingglass",
                        description: Text(
                            "Enter a phone number or contact name."
                        )
                    )
                    .listRowBackground(
                        Color.clear
                    )
                } else {
                    let basic =
                        contacts.basicMetadata(
                            for: searchText
                        )

                    Button {
                        ble.dialNumber =
                            searchText
                        selectedTab = .keypad
                    } label: {
                        VStack(
                            alignment: .leading,
                            spacing: 4
                        ) {
                            Text(searchText)
                                .foregroundStyle(
                                    .primary
                                )

                            if !basic
                                .formattedNumber
                                .isEmpty {
                                Text(
                                    basic
                                        .formattedNumber
                                )
                                .font(.footnote)
                                .foregroundStyle(
                                    .secondary
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(
                text: $searchText,
                prompt: "Search"
            )
        }
    }

    private var contactsSection: some View {
        Section("Caller ID & Contacts") {
            LabeledContent("Access") {
                Text(contacts.authorizationText)
                    .multilineTextAlignment(.trailing)
            }

            Text(contacts.lastLookupStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !contacts.canReadContacts {
                Button("Allow Contacts Access") {
                    contacts.requestAccessIfNeeded()
                }
            }

            if callKit.contactMatched {
                LabeledContent("Matched caller") {
                    Text(
                        callKit.displayCallerName.isEmpty
                            ? "Contact"
                            : callKit.displayCallerName
                    )
                }
            }

            Text(
                "Calls still work if Contacts access is denied. "
                + "CallKit receives the phone number either way."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var bluetoothSection: some View {
        Section("Bluetooth control") {
            LabeledContent("Connection") {
                Text(ble.isConnected ? "Connected" : "Disconnected")
            }

            Text(ble.bluetoothStatus)
                .font(.footnote)

            LabeledContent("Audio peer") {
                Text(ble.audioPeerStatus)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Button(
                    ble.isScanning ? "Scanning…" : "Scan / Reconnect"
                ) {
                    ble.scan()
                }
                .disabled(ble.isScanning || ble.isConnected)

                Spacer()

                if ble.isConnected {
                    Button("Disconnect") {
                        ble.disconnect()
                    }
                }
            }

            LabeledContent("Last state packet") {
                Text(ble.lastWireState)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var audioSection: some View {
        Section("Automatic call audio") {
            LabeledContent("This iPhone") {
                Text(relay.localIP)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Button("Refresh / Send iPhone IP") {
                relay.refreshLocalIP()
                ble.configureAudioPeer(ip: relay.localIP)
            }

            TextField("J6 Wi-Fi IP", text: $relay.j6IP)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)

            LabeledContent("Audio") {
                Text(relay.isRunning ? "Active" : "Stopped")
                    .fontWeight(relay.isRunning ? .semibold : .regular)
            }

            LabeledContent("Mic stream") {
                Text(relay.micStreamingReady ? "Verified" : "Waiting")
                    .fontWeight(relay.micStreamingReady ? .semibold : .regular)
            }

            LabeledContent("Auto restarts") {
                Text("\(relay.audioRestartCount)")
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Status") {
                Text(relay.status)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("Mic → J6") {
                Text("\(relay.sentFrames)")
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("J6 → iPhone") {
                Text("\(relay.receivedFrames)")
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Mic / caller RMS") {
                Text("\(relay.micRMS) / \(relay.remoteRMS)")
                    .font(.system(.body, design: .monospaced))
            }


            LabeledContent("Jitter q / target") {
                Text("\(relay.jitterBuffered) / \(relay.jitterTarget)")
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Network jitter") {
                Text(String(format: "%.1f ms", relay.jitterMS))
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("PLC / late / stale") {
                Text(
                    "\(relay.plcFrames) / \(relay.lateFrames) / \(relay.latencyDrops)"
                )
                .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Clock -/+ samples") {
                Text("\(relay.clockShortens) / \(relay.clockStretches)")
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Wire bad / stream resets") {
                Text("\(relay.badWirePackets) / \(relay.streamResets)")
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("Audio route") {
                Text(relay.audioRoute)
                    .multilineTextAlignment(.trailing)
                    .font(.footnote)
            }

            LabeledContent("iOS I/O buffer") {
                Text(String(format: "%.1f ms", relay.ioBufferMS))
                    .font(.system(.body, design: .monospaced))
            }

            LabeledContent("iOS input / output") {
                Text(
                    String(
                        format: "%.1f / %.1f ms",
                        relay.inputLatencyMS,
                        relay.outputLatencyMS
                    )
                )
                .font(.system(.body, design: .monospaced))
            }

            Text(
                "No ADB audio command is required. Outgoing DIALING uses the real cellular "
                + "downlink for ringback/busy/announcements; ACTIVE switches to full duplex automatically."
            )
            .font(.footnote)
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
            contacts.basicMetadata(
                for: number
            )

        return basic.formattedNumber.isEmpty
            ? number
            : basic.formattedNumber
    }
}

private enum RootTab: Hashable {
    case calls
    case contacts
    case keypad
    case search
}
