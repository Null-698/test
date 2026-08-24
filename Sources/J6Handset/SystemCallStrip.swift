import SwiftUI

struct SystemCallStrip: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var callKit: CallKitCoordinator

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                stripContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(
                        .regular.interactive(),
                        in: .rect(cornerRadius: 22)
                    )
            } else {
                stripContent
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(
                            cornerRadius: 22,
                            style: .continuous
                        )
                    )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var stripContent: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(identity)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if ble.uiCallState == "ACTIVE" {
                Button {
                    callKit.setMuted(!callKit.isMuted)
                } label: {
                    Image(
                        systemName:
                            callKit.isMuted
                                ? "mic.slash.fill"
                                : "mic.fill"
                    )
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(CompactCallButtonStyle())
                .foregroundStyle(.primary)
                .accessibilityLabel(
                    callKit.isMuted ? "Unmute" : "Mute"
                )
            }

            Button {
                callKit.endCurrentCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(CompactEndCallButtonStyle())
            .accessibilityLabel(
                ble.uiCallState == "RINGING"
                    ? "Decline call"
                    : "End call"
            )
        }
    }

    private var identity: String {
        if !callKit.displayCallerName.isEmpty {
            return callKit.displayCallerName
        }

        if !callKit.displayPhoneNumber.isEmpty {
            return callKit.displayPhoneNumber
        }

        if !ble.uiCallerID.isEmpty {
            return ble.uiCallerID
        }

        return "Call"
    }

    private var stateText: String {
        switch ble.uiCallState {
        case "RINGING":
            return "Incoming Call"
        case "CONNECTING", "DIALING":
            return "Calling…"
        case "ACTIVE":
            return "System Call Active"
        case "HOLDING":
            return "On Hold"
        case "DISCONNECTING":
            return "Ending…"
        default:
            return ble.uiCallState.capitalized
        }
    }

    private var statusSymbol: String {
        switch ble.uiCallState {
        case "RINGING":
            return "phone.arrow.down.left.fill"
        case "ACTIVE":
            return "phone.fill"
        default:
            return "phone.arrow.up.right.fill"
        }
    }

    private var statusColor: Color {
        switch ble.uiCallState {
        case "RINGING":
            return .orange
        case "ACTIVE":
            return .green
        default:
            return .primary
        }
    }
}

private struct CompactCallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .glassEffect(
                    .regular.interactive(),
                    in: .circle
                )
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
        } else {
            configuration.label
                .background(.thinMaterial, in: Circle())
                .scaleEffect(configuration.isPressed ? 0.93 : 1)
        }
    }
}

private struct CompactEndCallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.red, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
    }
}
