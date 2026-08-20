import AVKit
import SwiftUI
import UIKit

struct InAppCallView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var callKit: CallKitCoordinator

    let onMinimize: () -> Void

    @State private var showingKeypad = false
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
                CallBackdrop()

                if showingKeypad &&
                   ble.uiCallState == "ACTIVE" {
                    keypadScreen(proxy: proxy)
                        .transition(.opacity)
                } else {
                    mainScreen(proxy: proxy)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .animation(
            .easeInOut(duration: 0.18),
            value: showingKeypad
        )
        .onChange(of: ble.uiCallState) {
            _, state in

            if state != "ACTIVE" {
                showingKeypad = false
                enteredDigits = ""
            }
        }
    }

    private func mainScreen(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 18)
                .padding(
                    .top,
                    max(
                        proxy.safeAreaInsets.top + 8,
                        18
                    )
                )

            Spacer(minLength: 28)

            identityBlock
                .padding(.horizontal, 24)

            Spacer()

            if ble.uiCallState == "RINGING" {
                incomingActions
                    .padding(
                        .bottom,
                        max(
                            proxy.safeAreaInsets.bottom + 42,
                            58
                        )
                    )
            } else {
                activeActions
                    .padding(
                        .horizontal,
                        22
                    )
                    .padding(
                        .bottom,
                        max(
                            proxy.safeAreaInsets.bottom + 24,
                            38
                        )
                    )
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                onMinimize()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Minimize call")

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(
                        ble.uiCallState == "ACTIVE"
                            ? Color.green
                            : Color.orange
                    )
                    .frame(width: 7, height: 7)

                Text(statusChipText)
                    .font(
                        .system(
                            size: 13,
                            weight: .semibold
                        )
                    )
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .glassEffect(
                .regular,
                in: .capsule
            )
        }
        .foregroundStyle(.white)
    }

    private var identityBlock: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        Color.white.opacity(0.08)
                    )
                    .frame(
                        width: 118,
                        height: 118
                    )

                Circle()
                    .stroke(
                        Color.white.opacity(0.18),
                        lineWidth: 1
                    )
                    .frame(
                        width: 118,
                        height: 118
                    )

                Image(
                    systemName:
                        "person.fill"
                )
                .font(
                    .system(
                        size: 46,
                        weight: .medium
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.90)
                )
            }
            .glassEffect(
                .regular,
                in: .circle
            )

            VStack(spacing: 6) {
                Text(primaryIdentity)
                    .font(
                        .system(
                            size: 34,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.58)

                if !secondaryIdentity.isEmpty {
                    Text(secondaryIdentity)
                        .font(.system(size: 16))
                        .foregroundStyle(
                            .white.opacity(0.66)
                        )
                        .lineLimit(1)
                }

                if ble.uiCallState == "ACTIVE" {
                    TimelineView(
                        .periodic(
                            from: .now,
                            by: 1
                        )
                    ) { context in
                        Text(
                            durationText(
                                now: context.date
                            )
                        )
                        .font(
                            .system(
                                size: 16,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(
                            .white.opacity(0.72)
                        )
                        .monospacedDigit()
                    }
                } else {
                    Text(stateText)
                        .font(
                            .system(
                                size: 16,
                                weight: .medium
                            )
                        )
                        .foregroundStyle(
                            .white.opacity(0.72)
                        )
                }
            }
        }
    }

    private var activeActions: some View {
        GlassEffectContainer(spacing: 14) {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    glassAction(
                        title:
                            callKit.isMuted
                                ? "Unmute"
                                : "Mute",
                        symbol:
                            callKit.isMuted
                                ? "mic.slash.fill"
                                : "mic.fill",
                        selected:
                            callKit.isMuted
                    ) {
                        callKit.setMuted(
                            !callKit.isMuted
                        )
                    }

                    audioRouteAction

                    glassAction(
                        title: "Keypad",
                        symbol:
                            "circle.grid.3x3.fill"
                    ) {
                        guard
                            ble.uiCallState ==
                                "ACTIVE"
                        else {
                            return
                        }

                        enteredDigits = ""
                        showingKeypad = true
                        impact()
                    }
                }

                Button {
                    callKit.endCurrentCall()
                } label: {
                    Label(
                        "End Call",
                        systemImage:
                            "phone.down.fill"
                    )
                    .font(
                        .system(
                            size: 17,
                            weight: .semibold
                        )
                    )
                    .frame(
                        maxWidth: .infinity
                    )
                    .frame(height: 58)
                }
                .buttonStyle(.glassProminent)
                .tint(.red)
            }
        }
        .padding(16)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 30)
        )
    }

    private func glassAction(
        title: String,
        symbol: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Group {
                if selected {
                    Button(action: action) {
                        Image(systemName: symbol)
                            .font(
                                .system(
                                    size: 22,
                                    weight: .semibold
                                )
                            )
                            .frame(
                                width: 64,
                                height: 64
                            )
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(.white)
                    .foregroundStyle(.black)
                } else {
                    Button(action: action) {
                        Image(systemName: symbol)
                            .font(
                                .system(
                                    size: 22,
                                    weight: .semibold
                                )
                            )
                            .frame(
                                width: 64,
                                height: 64
                            )
                    }
                    .buttonStyle(.glass(.clear))
                    .buttonBorderShape(.circle)
                    .foregroundStyle(.white)
                }
            }

            Text(title)
                .font(
                    .system(
                        size: 12.5,
                        weight: .medium
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.82)
                )
        }
        .frame(maxWidth: .infinity)
    }

    private var audioRouteAction: some View {
        VStack(spacing: 8) {
            ZStack {
                Button { } label: {
                    Image(
                        systemName:
                            "speaker.wave.2.fill"
                    )
                    .font(
                        .system(
                            size: 22,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: 64,
                        height: 64
                    )
                }
                .buttonStyle(.glass(.clear))
                .buttonBorderShape(.circle)
                .foregroundStyle(.white)
                .allowsHitTesting(false)

                NativeRoutePicker()
                    .frame(
                        width: 64,
                        height: 64
                    )
                    .opacity(0.02)
            }

            Text("Audio")
                .font(
                    .system(
                        size: 12.5,
                        weight: .medium
                    )
                )
                .foregroundStyle(
                    .white.opacity(0.82)
                )
        }
        .frame(maxWidth: .infinity)
    }

    private var incomingActions: some View {
        HStack(spacing: 36) {
            VStack(spacing: 10) {
                Button {
                    callKit.endCurrentCall()
                } label: {
                    Image(systemName: "xmark")
                        .font(
                            .system(
                                size: 28,
                                weight: .semibold
                            )
                        )
                        .frame(
                            width: 78,
                            height: 78
                        )
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(
                    Color.white.opacity(0.16)
                )

                Text("Decline")
                    .font(.subheadline)
            }

            VStack(spacing: 10) {
                Button {
                    callKit.answerCurrentCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(
                            .system(
                                size: 27,
                                weight: .semibold
                            )
                        )
                        .frame(
                            width: 78,
                            height: 78
                        )
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.green)

                Text("Answer")
                    .font(.subheadline)
            }
        }
        .foregroundStyle(.white)
    }

    private func keypadScreen(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingKeypad = false
                    enteredDigits = ""
                } label: {
                    Image(
                        systemName:
                            "chevron.down"
                    )
                    .font(
                        .system(
                            size: 16,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: 42,
                        height: 42
                    )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(
                .top,
                max(
                    proxy.safeAreaInsets.top + 8,
                    18
                )
            )

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
                                ? 27
                                : 34,
                        weight: .semibold,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

                Text("DTMF keypad")
                    .font(.subheadline)
                    .foregroundStyle(
                        .white.opacity(0.62)
                    )
            }
            .foregroundStyle(.white)
            .padding(.top, 24)

            Spacer()

            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(
                        0..<4,
                        id: \.self
                    ) { row in
                        HStack(spacing: 16) {
                            ForEach(
                                0..<3,
                                id: \.self
                            ) { column in
                                let key =
                                    keypadKeys[
                                        row * 3
                                        + column
                                    ]

                                dtmfKey(
                                    digit: key.0,
                                    letters:
                                        key.1
                                )
                            }
                        }
                    }
                }
            }

            Spacer()

            Button {
                callKit.endCurrentCall()
            } label: {
                Label(
                    "End Call",
                    systemImage:
                        "phone.down.fill"
                )
                .font(
                    .system(
                        size: 17,
                        weight: .semibold
                    )
                )
                .frame(width: 180)
                .frame(height: 56)
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .padding(
                .bottom,
                max(
                    proxy.safeAreaInsets.bottom + 26,
                    38
                )
            )
        }
    }

    private func dtmfKey(
        digit: String,
        letters: String
    ) -> some View {
        Button {
            sendDtmf(digit)
        } label: {
            VStack(spacing: -1) {
                Text(digit)
                    .font(
                        .system(
                            size: 31,
                            weight: .medium,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()

                Text(letters)
                    .font(
                        .system(
                            size: 9.5,
                            weight: .semibold
                        )
                    )
                    .tracking(1.8)
                    .frame(height: 11)
                    .opacity(
                        letters.isEmpty
                            ? 0
                            : 0.76
                    )
            }
            .frame(
                width: 76,
                height: 76
            )
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .foregroundStyle(.white)
    }

    private func sendDtmf(
        _ digit: String
    ) {
        guard
            ble.uiCallState == "ACTIVE"
        else {
            return
        }

        if callKit.playDtmf(digit) {
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
        guard
            !callKit.displayCallerName.isEmpty
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
            return "Incoming call"
        case "CONNECTING",
             "DIALING":
            return "Calling…"
        case "HOLDING":
            return "On hold"
        case "DISCONNECTING":
            return "Ending…"
        default:
            return ble.uiCallState.capitalized
        }
    }

    private var statusChipText: String {
        switch ble.uiCallState {
        case "ACTIVE":
            return "Connected"
        case "RINGING":
            return "Incoming"
        case "CONNECTING",
             "DIALING":
            return "Calling"
        default:
            return "Call"
        }
    }

    private func durationText(
        now: Date
    ) -> String {
        guard
            let start =
                callKit.connectedAt
        else {
            return "00:00"
        }

        let total =
            max(
                0,
                Int(
                    now.timeIntervalSince(
                        start
                    )
                )
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
            format:
                "%02d:%02d",
            total / 60,
            total % 60
        )
    }

    private func impact() {
        UIImpactFeedbackGenerator(
            style: .light
        )
        .impactOccurred()
    }
}

private struct CallBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(
                        red: 0.045,
                        green: 0.075,
                        blue: 0.13
                    ),
                    Color(
                        red: 0.035,
                        green: 0.19,
                        blue: 0.22
                    ),
                    Color(
                        red: 0.025,
                        green: 0.10,
                        blue: 0.18
                    )
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.green.opacity(0.22),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 560
            )

            RadialGradient(
                colors: [
                    Color.blue.opacity(0.20),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 480
            )
        }
        .ignoresSafeArea()
    }
}

private struct NativeRoutePicker: UIViewRepresentable {
    func makeUIView(
        context: Context
    ) -> AVRoutePickerView {
        let view =
            AVRoutePickerView()

        view.prioritizesVideoDevices =
            false
        view.activeTintColor =
            .white
        view.tintColor =
            .white

        return view
    }

    func updateUIView(
        _ uiView: AVRoutePickerView,
        context: Context
    ) { }
}
