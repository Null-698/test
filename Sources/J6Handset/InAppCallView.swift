import AVKit
import SwiftUI
import UIKit

struct InAppCallView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var relay: RelayController
    @EnvironmentObject private var callKit: CallKitCoordinator

    let onMinimize: () -> Void

    @State private var activeSince: Date?
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
                callBackground

                if showingKeypad && ble.uiCallState == "ACTIVE" {
                    inCallKeypad(proxy: proxy)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.98)),
                                removal: .opacity
                            )
                        )
                } else {
                    mainCallScreen(proxy: proxy)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .animation(.easeInOut(duration: 0.20), value: showingKeypad)
        .onAppear {
            updateActiveStart()
        }
        .onChange(of: ble.uiCallState) { _, newState in
            updateActiveStart()

            if newState != "ACTIVE" {
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
            topBar
                .padding(.horizontal, 18)
                .padding(.top, max(8, proxy.safeAreaInsets.top + 4))

            Spacer(minLength: 20)

            identityArea
                .padding(.horizontal, 24)

            Spacer(minLength: 26)

            controlsArea
                .padding(.horizontal, 24)
                .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 10))
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(CallGlassButtonStyle())
            .accessibilityLabel("Minimize call")

            Spacer()

            if callKit.systemCallPresent {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("System CallKit call active")
            }
        }
    }

    private var identityArea: some View {
        VStack(spacing: 18) {
            callerAvatar

            VStack(spacing: 6) {
                Text(primaryDisplayText)
                    .font(
                        .system(
                            size: 36,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.55)

                if !secondaryDisplayText.isEmpty {
                    Text(secondaryDisplayText)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                if ble.uiCallState == "ACTIVE" {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(durationText(now: context.date))
                            .font(
                                .system(
                                    size: 16,
                                    weight: .regular,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(.white.opacity(0.80))
                            .monospacedDigit()
                    }
                } else {
                    Text(stateLine)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.white.opacity(0.80))
                }
            }
        }
    }

    @ViewBuilder
    private var controlsArea: some View {
        if ble.uiCallState == "RINGING" {
            incomingControls
        } else {
            activeControls
        }
    }

    private var incomingControls: some View {
        HStack(spacing: 74) {
            callAction(
                title: "Decline",
                systemImage: "phone.down.fill",
                tint: .red,
                prominent: true
            ) {
                callKit.endCurrentCall()
            }

            callAction(
                title: "Accept",
                systemImage: "phone.fill",
                tint: .green,
                prominent: true
            ) {
                callKit.answerCurrentCall()
            }
        }
    }

    private var activeControls: some View {
        VStack(spacing: 30) {
            Group {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 18) {
                        HStack(spacing: 24) {
                            muteControl
                            keypadControl
                            routePickerControl
                        }
                    }
                } else {
                    HStack(spacing: 24) {
                        muteControl
                        keypadControl
                        routePickerControl
                    }
                }
            }

            Button {
                callKit.endCurrentCall()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
            }
            .buttonStyle(EndCallButtonStyle())
            .accessibilityLabel("End call")
        }
    }

    private var muteControl: some View {
        callAction(
            title: callKit.isMuted ? "Unmute" : "Mute",
            systemImage:
                callKit.isMuted
                    ? "mic.slash.fill"
                    : "mic.fill",
            selected: callKit.isMuted
        ) {
            callKit.setMuted(!callKit.isMuted)
        }
    }

    private var keypadControl: some View {
        callAction(
            title: "Keypad",
            systemImage: "circle.grid.3x3.fill"
        ) {
            guard ble.uiCallState == "ACTIVE" else {
                return
            }
            enteredDigits = ""
            showingKeypad = true
            UIImpactFeedbackGenerator(
                style: .light
            ).impactOccurred()
        }
    }

    private var routePickerControl: some View {
        VStack(spacing: 9) {
            ZStack {
                if #available(iOS 26.0, *) {
                    Circle()
                        .fill(.clear)
                        .frame(width: 72, height: 72)
                        .glassEffect(
                            .regular.interactive(),
                            in: .circle
                        )
                } else {
                    Circle()
                        .fill(.thinMaterial)
                        .frame(width: 72, height: 72)
                }

                NativeRoutePicker()
                    .frame(width: 72, height: 72)
            }

            Text("Audio")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: 88)
    }

    // MARK: - In-call keypad

    private func inCallKeypad(
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingKeypad = false
                    enteredDigits = ""
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(CallGlassButtonStyle())

                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, max(8, proxy.safeAreaInsets.top + 4))

            Spacer(minLength: 12)

            VStack(spacing: 5) {
                Text(
                    enteredDigits.isEmpty
                        ? primaryDisplayText
                        : enteredDigits
                )
                .font(
                    .system(
                        size: enteredDigits.isEmpty ? 25 : 34,
                        weight: .regular,
                        design: .rounded
                    )
                )
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

                Text(
                    enteredDigits.isEmpty
                        ? "Keypad"
                        : primaryDisplayText
                )
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            }
            .frame(height: 72)

            Spacer(minLength: 12)

            Group {
                if #available(iOS 26.0, *) {
                    GlassEffectContainer(spacing: 14) {
                        dtmfGrid
                    }
                } else {
                    dtmfGrid
                }
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 26)

            Spacer(minLength: 20)

            HStack(spacing: 34) {
                Button {
                    showingKeypad = false
                    enteredDigits = ""
                } label: {
                    Text("Hide")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 52)
                }
                .buttonStyle(CallGlassCapsuleButtonStyle())

                Button {
                    callKit.endCurrentCall()
                } label: {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                }
                .buttonStyle(EndCallButtonStyle())
            }
            .padding(.bottom, max(24, proxy.safeAreaInsets.bottom + 10))
        }
    }

    private var dtmfGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 20),
                count: 3
            ),
            spacing: 16
        ) {
            ForEach(
                Array(keypadKeys.enumerated()),
                id: \.offset
            ) { _, key in
                Button {
                    sendDtmf(key.0)
                } label: {
                    VStack(spacing: 1) {
                        Text(key.0)
                            .font(
                                .system(
                                    size: 30,
                                    weight: .regular,
                                    design: .rounded
                                )
                            )
                            .monospacedDigit()

                        Text(key.1)
                            .font(
                                .system(
                                    size: 9,
                                    weight: .semibold
                                )
                            )
                            .tracking(1.6)
                            .frame(height: 10)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                }
                .buttonStyle(DtmfGlassButtonStyle())
                .accessibilityLabel("DTMF \(key.0)")
            }
        }
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

            UIImpactFeedbackGenerator(
                style: .light
            ).impactOccurred()
        } else {
            UINotificationFeedbackGenerator()
                .notificationOccurred(.error)
        }
    }

    // MARK: - Reusable controls / display

    private func callAction(
        title: String,
        systemImage: String,
        tint: Color? = nil,
        prominent: Bool = false,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 9) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        selected ? Color.black : Color.white
                    )
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(
                CallControlButtonStyle(
                    tint:
                        selected
                            ? Color.white
                            : tint,
                    prominent: prominent
                )
            )

            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: 88)
    }

    @ViewBuilder
    private var callerAvatar: some View {
        if let data = callKit.contactThumbnailImageData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 132, height: 132)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        Color.white.opacity(0.16),
                        lineWidth: 0.8
                    )
                )
                .shadow(
                    color: .black.opacity(0.24),
                    radius: 24,
                    y: 10
                )
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 124))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    @ViewBuilder
    private var callBackground: some View {
        if let data = callKit.contactThumbnailImageData,
           let image = UIImage(data: data) {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.45)
                    .blur(radius: 54)
                    .saturation(0.82)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.42),
                        Color.black.opacity(0.76)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(
                            red: 0.16,
                            green: 0.19,
                            blue: 0.25
                        ),
                        Color(
                            red: 0.055,
                            green: 0.065,
                            blue: 0.095
                        ),
                        .black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        Color.white.opacity(0.11),
                        .clear
                    ],
                    center: .top,
                    startRadius: 24,
                    endRadius: 460
                )
                .ignoresSafeArea()
            }
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

    private var stateLine: String {
        switch ble.uiCallState {
        case "RINGING":
            return "Incoming Call"
        case "CONNECTING", "DIALING":
            return "calling…"
        case "ACTIVE":
            return durationText(now: Date())
        case "HOLDING":
            return "On Hold"
        case "DISCONNECTING":
            return "ending…"
        default:
            return ble.uiCallState.capitalized
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

// MARK: - Styles

private struct CallGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(
                        .regular.interactive(),
                        in: .circle
                    )
            } else {
                configuration.label
                    .background(.thinMaterial, in: Circle())
            }
        }
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .animation(
            .easeOut(duration: 0.12),
            value: configuration.isPressed
        )
    }
}

private struct CallGlassCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(
                        .regular.interactive(),
                        in: .capsule
                    )
            } else {
                configuration.label
                    .background(
                        .thinMaterial,
                        in: Capsule()
                    )
            }
        }
        .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct CallControlButtonStyle: ButtonStyle {
    let tint: Color?
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(
                        tint.map {
                            .regular
                                .tint($0)
                                .interactive()
                        }
                        ?? .regular.interactive(),
                        in: .circle
                    )
            } else {
                configuration.label
                    .background(
                        tint?.opacity(
                            prominent ? 0.96 : 0.86
                        )
                        ?? Color.white.opacity(0.16),
                        in: Circle()
                    )
            }
        }
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .animation(
            .easeOut(duration: 0.12),
            value: configuration.isPressed
        )
    }
}

private struct DtmfGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .glassEffect(
                        .regular.interactive(),
                        in: .circle
                    )
            } else {
                configuration.label
                    .background(
                        Color.white.opacity(0.16),
                        in: Circle()
                    )
            }
        }
        .scaleEffect(configuration.isPressed ? 0.92 : 1)
        .animation(
            .easeOut(duration: 0.10),
            value: configuration.isPressed
        )
    }
}

private struct EndCallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                configuration.label
                    .background(Color.red, in: Circle())
                    .glassEffect(
                        .regular
                            .tint(.red)
                            .interactive(),
                        in: .circle
                    )
            } else {
                configuration.label
                    .background(Color.red, in: Circle())
            }
        }
        .scaleEffect(configuration.isPressed ? 0.94 : 1)
        .animation(
            .easeOut(duration: 0.10),
            value: configuration.isPressed
        )
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
