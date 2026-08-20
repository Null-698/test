import AVFAudio
import AVKit
import SwiftUI
import UIKit

struct InAppCallView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var callKit: CallKitCoordinator

    let onMinimize: () -> Void

    @State private var showingKeypad = false
    @State private var showingMore = false
    @State private var enteredDigits = ""

    private let keypadKeys: [(String, String)] = [
        ("1", ""),
        ("2", "ABC"),
        ("3", "DEF"),
        ("4", "GHI"),
        ("5", "JKL"),
        ("6", "MNO"),
        ("7", "PQRS"),
        ("8", "TUV"),
        ("9", "WXYZ"),
        ("*", ""),
        ("0", "+"),
        ("#", "")
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                callBackground

                if showingKeypad &&
                   ble.uiCallState == "ACTIVE" {
                    inCallKeypad(proxy: proxy)
                        .transition(.opacity)
                } else {
                    callFace(proxy: proxy)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea(edges: .all)
        }
        .preferredColorScheme(.dark)
        .animation(
            .easeInOut(duration: 0.18),
            value: showingKeypad
        )
        .confirmationDialog(
            "Call Options",
            isPresented: $showingMore,
            titleVisibility: .hidden
        ) {
            Button("Minimize Call") {
                onMinimize()
            }

            if ble.uiCallState == "ACTIVE" {
                Button(
                    callKit.isMuted
                        ? "Unmute"
                        : "Mute"
                ) {
                    callKit.setMuted(
                        !callKit.isMuted
                    )
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: ble.uiCallState) {
            _, newState in

            if newState != "ACTIVE" {
                showingKeypad = false
                enteredDigits = ""
            }
        }
    }

    // MARK: - Main active/ringing face

    private func callFace(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            identityHeader
                .padding(.top, max(
                    proxy.safeAreaInsets.top + 34,
                    72
                ))
                .padding(.horizontal, 24)

            Spacer()

            if ble.uiCallState == "RINGING" {
                incomingButtons
                    .padding(
                        .bottom,
                        max(
                            proxy.safeAreaInsets.bottom + 44,
                            58
                        )
                    )
            } else {
                sixControlGrid
                    .padding(
                        .bottom,
                        max(
                            proxy.safeAreaInsets.bottom + 26,
                            38
                        )
                    )
            }
        }
    }

    private var identityHeader: some View {
        VStack(spacing: 6) {
            if ble.uiCallState == "ACTIVE" {
                TimelineView(
                    .periodic(
                        from: .now,
                        by: 1
                    )
                ) { context in
                    Text(durationText(now: context.date))
                        .font(
                            .system(
                                size: 16,
                                weight: .regular
                            )
                        )
                        .foregroundStyle(
                            .white.opacity(0.70)
                        )
                        .monospacedDigit()
                }
            } else {
                Text(stateText)
                    .font(
                        .system(
                            size: 16,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.70)
                    )
            }

            Text(primaryIdentity)
                .font(
                    .system(
                        size:
                            callKit.displayCallerName.isEmpty
                                ? 28
                                : 31,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.64)
                .multilineTextAlignment(.center)

            if !secondaryIdentity.isEmpty {
                Text(secondaryIdentity)
                    .font(
                        .system(
                            size: 16,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(
                        .white.opacity(0.72)
                    )
                    .lineLimit(1)
            }
        }
    }

    private var sixControlGrid: some View {
        VStack(spacing: 22) {
            HStack(spacing: 34) {
                routeControl

                phoneControl(
                    title: "FaceTime",
                    systemImage: "video.fill",
                    enabled: false,
                    selected: false
                ) { }

                phoneControl(
                    title:
                        callKit.isMuted
                            ? "Unmute"
                            : "Mute",
                    systemImage:
                        callKit.isMuted
                            ? "mic.slash.fill"
                            : "mic.slash",
                    selected: callKit.isMuted
                ) {
                    callKit.setMuted(
                        !callKit.isMuted
                    )
                }
            }

            HStack(spacing: 34) {
                phoneControl(
                    title: "More",
                    systemImage: "ellipsis"
                ) {
                    showingMore = true
                }

                VStack(spacing: 8) {
                    Button {
                        callKit.endCurrentCall()
                    } label: {
                        Image(
                            systemName:
                                "phone.down.fill"
                        )
                        .font(
                            .system(
                                size: 26,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(
                            Color(
                                red: 0.80,
                                green: 0.015,
                                blue: 0.015
                            ),
                            in: Circle()
                        )
                    }
                    .buttonStyle(CallPressStyle())

                    Text("End")
                        .font(
                            .system(
                                size: 13,
                                weight: .regular
                            )
                        )
                        .foregroundStyle(.white)
                }
                .frame(width: 82)

                phoneControl(
                    title: "Keypad",
                    systemImage:
                        "circle.grid.3x3.fill"
                ) {
                    guard ble.uiCallState == "ACTIVE"
                    else {
                        return
                    }

                    enteredDigits = ""
                    showingKeypad = true
                    impact()
                }
            }
        }
    }

    private var routeControl: some View {
        VStack(spacing: 8) {
            ZStack {
                callGlassCircle

                Image(
                    systemName:
                        "speaker.wave.3.fill"
                )
                .font(
                    .system(
                        size: 24,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.white)

                // Keep Apple's actual route picker as the hit target while
                // matching the Phone screenshot's Speaker glyph.
                NativeRoutePicker()
                    .frame(width: 72, height: 72)
                    .opacity(0.015)
            }

            Text("Speaker")
                .font(
                    .system(
                        size: 13,
                        weight: .regular
                    )
                )
                .foregroundStyle(.white)
        }
        .frame(width: 82)
        .accessibilityLabel("Audio route")
    }

    private func phoneControl(
        title: String,
        systemImage: String,
        enabled: Bool = true,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                ZStack {
                    if selected {
                        Circle()
                            .fill(Color.white)
                            .frame(
                                width: 72,
                                height: 72
                            )
                    } else {
                        callGlassCircle
                    }

                    Image(
                        systemName: systemImage
                    )
                    .font(
                        .system(
                            size: 24,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(
                        selected
                            ? Color.black
                            : Color.white
                    )
                }
                .frame(width: 72, height: 72)
            }
            .buttonStyle(CallPressStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.25)

            Text(title)
                .font(
                    .system(
                        size: 13,
                        weight: .regular
                    )
                )
                .foregroundStyle(
                    .white.opacity(
                        enabled ? 1 : 0.58
                    )
                )
        }
        .frame(width: 82)
    }

    @ViewBuilder
    private var callGlassCircle: some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(.clear)
                .frame(width: 72, height: 72)
                .glassEffect(
                    .clear.interactive(),
                    in: .circle
                )
                .overlay {
                    Circle()
                        .stroke(
                            Color.white.opacity(0.16),
                            lineWidth: 0.7
                        )
                }
        } else {
            Circle()
                .fill(
                    Color.white.opacity(0.075)
                )
                .frame(width: 72, height: 72)
                .overlay {
                    Circle()
                        .stroke(
                            Color.white.opacity(0.16),
                            lineWidth: 0.7
                        )
                }
        }
    }

    // MARK: - Incoming

    private var incomingButtons: some View {
        HStack {
            largeCallAction(
                title: "Decline",
                systemImage: "xmark",
                fill: Color(
                    red: 0.62,
                    green: 0.62,
                    blue: 0.64
                )
            ) {
                callKit.endCurrentCall()
            }

            Spacer()

            largeCallAction(
                title: "Accept",
                systemImage: "phone.fill",
                fill: Color(uiColor: .systemGreen)
            ) {
                callKit.answerCurrentCall()
            }
        }
        .padding(.horizontal, 54)
    }

    private func largeCallAction(
        title: String,
        systemImage: String,
        fill: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(
                        .system(
                            size: 29,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(fill, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                Color.white.opacity(0.52),
                                lineWidth: 0.8
                            )
                    }
            }
            .buttonStyle(CallPressStyle())

            Text(title)
                .font(
                    .system(
                        size: 16,
                        weight: .regular
                    )
                )
                .foregroundStyle(.white)
        }
    }

    // MARK: - In-call DTMF

    private func inCallKeypad(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 5) {
                Text(
                    enteredDigits.isEmpty
                        ? primaryIdentity
                        : enteredDigits
                )
                .font(
                    .system(
                        size:
                            enteredDigits.isEmpty
                                ? 26
                                : 34,
                        weight: .regular
                    )
                )
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.60)

                Text(
                    enteredDigits.isEmpty
                        ? "Keypad"
                        : primaryIdentity
                )
                .font(
                    .system(
                        size: 15,
                        weight: .regular
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.64)
                )
                .lineLimit(1)
            }
            .padding(
                .top,
                max(
                    proxy.safeAreaInsets.top + 46,
                    82
                )
            )

            Spacer()

            VStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 22) {
                        ForEach(
                            0..<3,
                            id: \.self
                        ) { column in
                            let key =
                                keypadKeys[
                                    row * 3
                                    + column
                                ]

                            dtmfButton(
                                digit: key.0,
                                letters: key.1
                            )
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 38) {
                Button {
                    showingKeypad = false
                    enteredDigits = ""
                } label: {
                    Text("Hide")
                        .font(
                            .system(
                                size: 16,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.white)
                        .frame(
                            width: 76,
                            height: 54
                        )
                }
                .buttonStyle(CallCapsuleStyle())

                Button {
                    callKit.endCurrentCall()
                } label: {
                    Image(
                        systemName:
                            "phone.down.fill"
                    )
                    .font(
                        .system(
                            size: 25,
                            weight: .semibold
                        )
                    )
                    .foregroundStyle(.white)
                    .frame(width: 70, height: 70)
                    .background(
                        Color.red,
                        in: Circle()
                    )
                }
                .buttonStyle(CallPressStyle())
            }
            .padding(
                .bottom,
                max(
                    proxy.safeAreaInsets.bottom + 28,
                    42
                )
            )
        }
    }

    private func dtmfButton(
        digit: String,
        letters: String
    ) -> some View {
        Button {
            sendDtmf(digit)
        } label: {
            VStack(spacing: -2) {
                Text(digit)
                    .font(
                        .system(
                            size: 34,
                            weight: .regular
                        )
                    )
                    .monospacedDigit()

                Text(letters)
                    .font(
                        .system(
                            size: 10,
                            weight: .semibold
                        )
                    )
                    .tracking(2.0)
                    .frame(height: 12)
                    .opacity(
                        letters.isEmpty ? 0 : 1
                    )
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(
                Color.white.opacity(0.10),
                in: Circle()
            )
            .overlay {
                Circle()
                    .stroke(
                        Color.white.opacity(0.15),
                        lineWidth: 0.7
                    )
            }
        }
        .buttonStyle(CallPressStyle())
    }

    private func sendDtmf(_ digit: String) {
        guard ble.uiCallState == "ACTIVE" else {
            return
        }

        if ble.sendDtmf(digit) {
            enteredDigits.append(digit)

            if enteredDigits.count > 24 {
                enteredDigits.removeFirst(
                    enteredDigits.count - 24
                )
            }

            impact()
        } else {
            UINotificationFeedbackGenerator()
                .notificationOccurred(.error)
        }
    }

    // MARK: - Display

    private var primaryIdentity: String {
        if !callKit.displayCallerName.isEmpty {
            return callKit.displayCallerName
        }

        if !callKit.displayPhoneNumber.isEmpty {
            return callKit.displayPhoneNumber
        }

        if !ble.uiCallerID.isEmpty {
            return ble.uiCallerID
        }

        if !ble.dialNumber.isEmpty {
            return ble.dialNumber
        }

        return "Unknown Caller"
    }

    private var secondaryIdentity: String {
        guard !callKit.displayCallerName.isEmpty
        else {
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
            return "calling…"
        case "HOLDING":
            return "On Hold"
        case "DISCONNECTING":
            return "ending…"
        default:
            return ble.uiCallState.capitalized
        }
    }

    private func durationText(now: Date) -> String {
        guard let start = callKit.connectedAt
        else {
            return "00:00"
        }

        let total = max(
            0,
            Int(now.timeIntervalSince(start))
        )

        if total >= 3600 {
            return String(
                format:
                    "%d:%02d:%02d",
                total / 3600,
                (total / 60) % 60,
                total % 60
            )
        }

        return String(
            format: "%02d:%02d",
            total / 60,
            total % 60
        )
    }

    private var callBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(
                        red: 0.020,
                        green: 0.22,
                        blue: 0.27
                    ),
                    Color(
                        red: 0.015,
                        green: 0.34,
                        blue: 0.30
                    ),
                    Color(
                        red: 0.015,
                        green: 0.24,
                        blue: 0.36
                    )
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(
                        red: 0.06,
                        green: 0.62,
                        blue: 0.43
                    ).opacity(0.35),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 560
            )

            RadialGradient(
                colors: [
                    Color(
                        red: 0.02,
                        green: 0.39,
                        blue: 0.70
                    ).opacity(0.28),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 520
            )

            Rectangle()
                .fill(
                    Color.black.opacity(0.14)
                )
        }
    }

    private func impact() {
        UIImpactFeedbackGenerator(
            style: .light
        ).impactOccurred()
    }
}

// MARK: - Native audio route picker

private struct NativeRoutePicker: UIViewRepresentable {
    func makeUIView(
        context: Context
    ) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.activeTintColor = .white
        view.tintColor = .white
        return view
    }

    func updateUIView(
        _ uiView: AVRoutePickerView,
        context: Context
    ) { }
}

// MARK: - Button styles

private struct CallPressStyle: ButtonStyle {
    func makeBody(
        configuration: Configuration
    ) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? 0.94
                    : 1
            )
            .opacity(
                configuration.isPressed
                    ? 0.80
                    : 1
            )
            .animation(
                .easeOut(duration: 0.09),
                value: configuration.isPressed
            )
    }
}

private struct CallCapsuleStyle: ButtonStyle {
    func makeBody(
        configuration: Configuration
    ) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(
                        .clear.interactive(),
                        in: .capsule
                    )
            } else {
                configuration.label
                    .background(
                        Color.white.opacity(0.10),
                        in: Capsule()
                    )
            }
        }
        .scaleEffect(
            configuration.isPressed
                ? 0.96
                : 1
        )
    }
}
