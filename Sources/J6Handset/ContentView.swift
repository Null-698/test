import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver

    @State private var callScreenMinimized = false

    var body: some View {
        ZStack {
            NavigationStack {
                Form {
                    if hasVisibleCall && callScreenMinimized {
                        Section {
                            Button {
                                callScreenMinimized = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName:
                                            "phone.fill"
                                    )
                                    .foregroundStyle(.green)

                                    VStack(
                                        alignment: .leading,
                                        spacing: 2
                                    ) {
                                        Text("Return to Call")
                                            .fontWeight(.semibold)

                                        Text(
                                            !callKit.displayCallerName.isEmpty
                                                ? callKit.displayCallerName
                                                : (
                                                    !callKit.displayPhoneNumber.isEmpty
                                                        ? callKit.displayPhoneNumber
                                                        : (
                                                            ble.uiCallerID.isEmpty
                                                                ? ble.uiCallState
                                                                : ble.uiCallerID
                                                        )
                                                )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if callKit.systemCallPresent {
                                        Text("System")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(
                                                Color.green.opacity(0.15)
                                            )
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }

                    callSection
                    contactsSection
                    bluetoothSection
                    audioSection
                }
                .navigationTitle("Cellular")
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

            if hasVisibleCall && !callScreenMinimized {
                InAppCallView {
                    callScreenMinimized = true
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: callScreenMinimized
        )
        .onChange(of: ble.uiCallState) {
            _,
            newState in

            // Native-first behavior:
            // CallKit owns automatic call presentation. Our custom call view
            // never forces itself over a successful system call. It remains
            // available through the "Return to Call" banner, like a
            // third-party calling app's own optional call screen.
            if newState == "RINGING" {
                callScreenMinimized =
                    callKit.callKitAvailable
            } else if isCallPresentationState(newState) {
                callScreenMinimized = true
            }

            if newState == "IDLE" ||
               newState == "DISCONNECTED" {
                callScreenMinimized = false
            }
        }
    }

    private var callSection: some View {
        Section("Cellular call") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ble.uiCallState)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if !callKit.displayCallerName.isEmpty {
                        Text(callKit.displayCallerName)
                            .font(.title3)
                            .fontWeight(.medium)

                        if !callKit.displayPhoneNumber.isEmpty {
                            Text(callKit.displayPhoneNumber)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else if !callKit.displayPhoneNumber.isEmpty {
                        Text(callKit.displayPhoneNumber)
                            .font(.title3)
                            .textSelection(.enabled)
                    } else if !ble.uiCallerID.isEmpty {
                        Text(ble.uiCallerID)
                            .font(.title3)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                Circle()
                    .fill(stateColor)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel(ble.uiCallState)
            }

            LabeledContent("System CallKit") {
                Text(callKit.status)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }

            if ble.uiCallState == "ACTIVE" {
                Toggle(
                    "Mute microphone",
                    isOn: Binding(
                        get: { callKit.isMuted },
                        set: { callKit.setMuted($0) }
                    )
                )
            }

            if ble.uiCallState == "RINGING" {
                HStack {
                    Button("Reject") {
                        callKit.endCurrentCall()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Spacer()

                    Button("Answer") {
                        callKit.answerCurrentCall()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            } else if hasOngoingCall {
                Button {
                    callKit.endCurrentCall()
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "phone.down.fill")
                        Text("Hang Up")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .accessibilityLabel("Hang up cellular call")
            }

            if !hasOngoingCall && ble.uiCallState != "RINGING" {
                HStack {
                    TextField(
                        "Phone number",
                        text: $ble.dialNumber
                    )
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)

                    Button("Dial") {
                        callKit.startOutgoing(
                            number: ble.dialNumber
                        )
                    }
                    .disabled(!ble.isConnected)
                }
            }
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

    private var stateColor: Color {
        switch ble.uiCallState {
        case "RINGING":
            return .orange
        case "ACTIVE":
            return .green
        case "DIALING", "CONNECTING":
            return .blue
        case "ERROR":
            return .red
        default:
            return .secondary
        }
    }
}
