import SwiftUI
import UIKit

struct InAppCallView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var callKit: CallKitCoordinator

    let onMinimize: () -> Void

    @State private var activeSince: Date?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.96),
                    Color.blue.opacity(0.42)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                HStack {
                    Spacer()

                    Button(action: onMinimize) {
                        Image(
                            systemName:
                                "chevron.down.circle.fill"
                        )
                        .font(.system(size: 30))
                        .symbolRenderingMode(.hierarchical)
                    }
                    .tint(.white.opacity(0.9))
                    .accessibilityLabel("Minimize call screen")
                }

                Spacer()

                callerAvatar

                VStack(spacing: 8) {
                    Text(primaryDisplayText)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)

                    if !secondaryDisplayText.isEmpty {
                        Text(secondaryDisplayText)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    Text(stateText)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))

                    if ble.uiCallState == "ACTIVE" {
                        TimelineView(.periodic(from: .now, by: 1)) {
                            context in
                            Text(
                                durationText(
                                    now: context.date
                                )
                            )
                            .font(
                                .system(
                                    .body,
                                    design: .monospaced
                                )
                            )
                            .foregroundStyle(
                                .white.opacity(0.75)
                            )
                        }
                    }
                }

                Spacer()

                controls
                    .padding(.bottom, 28)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
        .onAppear {
            updateActiveStart()
        }
        .onChange(of: ble.uiCallState) { _, _ in
            updateActiveStart()
        }
    }

    @ViewBuilder
    private var controls: some View {
        if ble.uiCallState == "RINGING" {
            HStack(spacing: 56) {
                callCircle(
                    title: "Decline",
                    systemImage: "phone.down.fill",
                    tint: .red
                ) {
                    callKit.endCurrentCall()
                }

                callCircle(
                    title: "Answer",
                    systemImage: "phone.fill",
                    tint: .green
                ) {
                    callKit.answerCurrentCall()
                }
            }
        } else {
            HStack(spacing: 42) {
                callCircle(
                    title: callKit.isMuted
                        ? "Unmute"
                        : "Mute",
                    systemImage: callKit.isMuted
                        ? "mic.slash.fill"
                        : "mic.fill",
                    tint: .white.opacity(0.18)
                ) {
                    callKit.setMuted(!callKit.isMuted)
                }

                callCircle(
                    title: "End",
                    systemImage: "phone.down.fill",
                    tint: .red
                ) {
                    callKit.endCurrentCall()
                }
            }
        }
    }

    private func callCircle(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 9) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 27, weight: .semibold))
                    .frame(width: 66, height: 66)
                    .background(tint)
                    .clipShape(Circle())
            }
            .tint(.white)

            Text(title)
                .font(.caption)
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var callerAvatar: some View {
        if let data = callKit.contactThumbnailImageData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 108, height: 108)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        Color.white.opacity(0.22),
                        lineWidth: 1
                    )
                )
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 100))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
    }

    private var primaryDisplayText: String {
        if !callKit.displayCallerName.isEmpty {
            return callKit.displayCallerName
        }

        if !callKit.displayPhoneNumber.isEmpty {
            return callKit.displayPhoneNumber
        }

        if !ble.uiCallerID.isEmpty {
            return ble.uiCallerID
        }

        return "Unknown Caller"
    }

    private var secondaryDisplayText: String {
        guard !callKit.displayCallerName.isEmpty else {
            return ""
        }

        if !callKit.displayPhoneNumber.isEmpty {
            return callKit.displayPhoneNumber
        }

        return ble.uiCallerID
    }

    private var stateText: String {
        switch ble.uiCallState {
        case "RINGING":
            return "Incoming Call"
        case "CONNECTING", "DIALING":
            return "Calling…"
        case "ACTIVE":
            return "Call"
        case "HOLDING":
            return "On hold"
        case "DISCONNECTING":
            return "Ending…"
        default:
            return ble.uiCallState
        }
    }

    private func updateActiveStart() {
        if ble.uiCallState == "ACTIVE" {
            if activeSince == nil {
                activeSince = Date()
            }
        } else if ble.uiCallState == "IDLE" ||
                  ble.uiCallState == "DISCONNECTED" {
            activeSince = nil
        }
    }

    private func durationText(now: Date) -> String {
        guard let activeSince else {
            return "00:00"
        }

        let seconds = max(
            0,
            Int(now.timeIntervalSince(activeSince))
        )
        return String(
            format: "%02d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
}
