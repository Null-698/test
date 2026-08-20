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
                systemCallBackground

                if showingKeypad &&
                   ble.uiCallState == "ACTIVE" {
                    dtmfScreen(proxy: proxy)
                        .transition(.opacity)
                } else {
                    mainCallScreen(proxy: proxy)
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
        .confirmationDialog(
            "Call Options",
            isPresented: $showingMore,
            titleVisibility: .hidden
        ) {
            Button("Minimize Call") {
                onMinimize()
            }

            Button(
                callKit.isMuted
                    ? "Unmute"
                    : "Mute"
            ) {
                callKit.setMuted(!callKit.isMuted)
            }

            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: ble.uiCallState) { _, state in
            if state != "ACTIVE" {
                showingKeypad = false
                enteredDigits = ""
            }
        }
    }

    // MARK: - Main call screen

    private func mainCallScreen(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            callIdentity
                .padding(
                    .top,
                    max(proxy.safeAreaInsets.top + 44, 82)
                )
                .padding(.horizontal, 24)

            Spacer()

            if ble.uiCallState == "RINGING" {
                incomingControls
                    .padding(
                        .bottom,
                        max(proxy.safeAreaInsets.bottom + 44, 62)
                    )
            } else {
                activeControls
                    .padding(
                        .bottom,
                        max(proxy.safeAreaInsets.bottom + 26, 42)
                    )
            }
        }
    }

    private var callIdentity: some View {
        VStack(spacing: 5) {
            if ble.uiCallState == "ACTIVE" {
                TimelineView(
                    .periodic(from: .now, by: 1)
                ) { context in
                    Text(durationText(now: context.date))
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .monospacedDigit()
                }
            } else {
                Text(stateText)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.72))
            }

            Text(primaryIdentity)
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.60)
                .multilineTextAlignment(.center)

            if !secondaryIdentity.isEmpty {
                Text(secondaryIdentity)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
        }
    }

    private var activeControls: some View {
        GlassEffectContainer(spacing: 18) {
            VStack(spacing: 22) {
                HStack(spacing: 28) {
                    audioRouteControl

                    callControl(
                        title: "FaceTime",
                        symbol: "video.fill",
                        enabled: false
                    ) { }

                    callControl(
                        title: callKit.isMuted ? "Unmute" : "Mute",
                        symbol:
                            callKit.isMuted
                                ? "mic.slash.fill"
                                : "mic.slash",
                        selected: callKit.isMuted
                    ) {
                        callKit.setMuted(!callKit.isMuted)
                    }
                }

                HStack(spacing: 28) {
                    callControl(
                        title: "More",
                        symbol: "ellipsis"
                    ) {
                        showingMore = true
                    }

                    VStack(spacing: 8) {
                        Button {
                            callKit.endCurrentCall()
                        } label: {
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 25, weight: .semibold))
                                .frame(width: 68, height: 68)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .tint(.red)
                        .accessibilityLabel("End call")

                        Text("End")
                            .callControlLabel()
                    }
                    .frame(width: 84)

                    callControl(
                        title: "Keypad",
                        symbol: "circle.grid.3x3.fill"
                    ) {
                        guard ble.uiCallState == "ACTIVE" else {
                            return
                        }
                        enteredDigits = ""
                        showingKeypad = true
                        impact()
                    }
                }
            }
        }
    }

    private var audioRouteControl: some View {
        VStack(spacing: 8) {
            ZStack {
                // This visible control uses Apple's native iOS 26 glass style.
                Button { } label: {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 68, height: 68)
                }
                .buttonStyle(.glass(.clear))
                .buttonBorderShape(.circle)
                .allowsHitTesting(false)

                // Apple's AVRoutePickerView remains the actual hit target,
                // preserving AirPods/speaker/system-route behavior.
                NativeRoutePicker()
                    .frame(width: 68, height: 68)
                    .opacity(0.02)
            }

            Text("Speaker")
                .callControlLabel()
        }
        .frame(width: 84)
    }

    private func callControl(
        title: String,
        symbol: String,
        enabled: Bool = true,
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
                                    size: 24,
                                    weight: .semibold
                                )
                            )
                            .frame(width: 68, height: 68)
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
                                    size: 24,
                                    weight: .semibold
                                )
                            )
                            .frame(width: 68, height: 68)
                    }
                    .buttonStyle(.glass(.clear))
                    .buttonBorderShape(.circle)
                    .foregroundStyle(.white)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.28)

            Text(title)
                .callControlLabel()
                .opacity(enabled ? 1 : 0.60)
        }
        .frame(width: 84)
    }

    private var incomingControls: some View {
        HStack {
            VStack(spacing: 10) {
                Button {
                    callKit.endCurrentCall()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 30, weight: .medium))
                        .frame(width: 78, height: 78)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(Color(uiColor: .systemGray))
                Text("Decline")
                    .font(.system(size: 16))
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    callKit.answerCurrentCall()
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 29, weight: .medium))
                        .frame(width: 78, height: 78)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.green)
                Text("Accept")
                    .font(.system(size: 16))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 54)
    }

    // MARK: - DTMF keypad

    private func dtmfScreen(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text(
                    enteredDigits.isEmpty
                        ? primaryIdentity
                        : enteredDigits
                )
                .font(
                    .system(
                        size: enteredDigits.isEmpty ? 27 : 34,
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
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.64))
            }
            .padding(
                .top,
                max(proxy.safeAreaInsets.top + 46, 84)
            )

            Spacer()

            VStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 22) {
                        ForEach(0..<3, id: \.self) { column in
                            let key = keypadKeys[row * 3 + column]
                            dtmfKey(
                                digit: key.0,
                                letters: key.1
                            )
                        }
                    }
                }
            }

            Spacer()

            HStack(spacing: 36) {
                Button("Hide") {
                    showingKeypad = false
                    enteredDigits = ""
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                Button {
                    callKit.endCurrentCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 66, height: 66)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(.red)
            }
            .foregroundStyle(.white)
            .padding(
                .bottom,
                max(proxy.safeAreaInsets.bottom + 28, 42)
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
            VStack(spacing: -2) {
                Text(digit)
                    .font(.system(size: 34, weight: .regular))
                    .monospacedDigit()

                Text(letters)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(2.0)
                    .frame(height: 12)
                    .opacity(letters.isEmpty ? 0 : 1)
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
    }

    private func sendDtmf(_ digit: String) {
        guard ble.uiCallState == "ACTIVE" else {
            return
        }

        // IMPORTANT: do not bypass CallKit here.
        // A CXPlayDTMFCallAction gives this custom keypad exactly the same
        // local tone semantics as Apple's native CallKit keypad.
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

    // MARK: - Identity / state

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
        guard let start = callKit.connectedAt else {
            return "00:00"
        }

        let total = max(0, Int(now.timeIntervalSince(start)))
        if total >= 3600 {
            return String(
                format: "%d:%02d:%02d",
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

    // Reference-inspired field behind Apple's actual glass controls.
    private var systemCallBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.30, blue: 0.34),
                    Color(red: 0.015, green: 0.45, blue: 0.38),
                    Color(red: 0.01, green: 0.28, blue: 0.46)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.07, green: 0.68, blue: 0.48)
                        .opacity(0.34),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 540
            )

            RadialGradient(
                colors: [
                    Color.blue.opacity(0.26),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 10,
                endRadius: 500
            )

            Color.black.opacity(0.10)
        }
    }

    private func impact() {
        UIImpactFeedbackGenerator(style: .light)
            .impactOccurred()
    }
}

private extension Text {
    func callControlLabel() -> some View {
        self
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white)
    }
}

private struct NativeRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
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
