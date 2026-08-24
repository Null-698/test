import SwiftUI
import UIKit

struct InAppCallView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var relay: RelayController
    @Environment(\.colorScheme) private var colorScheme

    let onMinimize: () -> Void

    @State private var showingKeypad = false
    @State private var showingAudioRoutes = false
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
                } else {
                    mainScreen(proxy: proxy)
                }

                if showingAudioRoutes {
                    audioRouteOverlay(proxy: proxy)
                        .transition(
                            .opacity.combined(
                                with: .move(edge: .bottom)
                            )
                        )
                        .zIndex(10)
                }
            }
            .ignoresSafeArea()
        }
        .animation(
            .easeOut(duration: 0.18),
            value: showingAudioRoutes
        )
        .onChange(of: ble.uiCallState) { _, state in
            if state != "ACTIVE" {
                showingKeypad = false
                showingAudioRoutes = false
                enteredDigits = ""
            }
        }
        .onChange(of: relay.hasExternalAudioRoute) { _, hasExternalRoute in
            if !hasExternalRoute {
                showingAudioRoutes = false
            }
        }
        .onAppear {
            relay.refreshAudioRoutes()
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

            Spacer(minLength: 24)

            identityBlock
                .frame(maxWidth: 420)
                .padding(.horizontal, 24)

            Spacer(minLength: 24)

            if ble.uiCallState == "RINGING" {
                incomingActions
                    .frame(maxWidth: 360)
                    .padding(.horizontal, 20)
                    .padding(
                        .bottom,
                        max(
                            proxy.safeAreaInsets.bottom + 42,
                            58
                        )
                    )
            } else {
                activeActions
                    .frame(maxWidth: 430)
                    .padding(.horizontal, 20)
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
            .buttonStyle(
                CallButtonStyle(
                    fill: AppTheme.controlFill,
                    cornerRadius: 21
                )
            )
            .foregroundStyle(.primary)
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
            .background(
                Capsule()
                    .fill(AppTheme.controlFill)
            )
            .overlay {
                Capsule()
                    .stroke(
                        AppTheme.separator,
                        lineWidth: 1
                    )
            }
        }
        .foregroundStyle(.primary)
    }

    private var identityBlock: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.controlFill)

                Circle()
                    .stroke(
                        AppTheme.separator,
                        lineWidth: 1
                    )

                Image(systemName: "person.fill")
                    .font(
                        .system(
                            size: 40,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.primary)
            }
            .frame(width: 104, height: 104)
            .shadow(
                color: .black.opacity(0.20),
                radius: 18,
                y: 10
            )

            VStack(spacing: 6) {
                Text(primaryIdentity)
                    .font(
                        .system(
                            size: 32,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.58)

                if !secondaryIdentity.isEmpty {
                    Text(secondaryIdentity)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activeActions: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                callControl(
                    title: "Mute",
                    symbol: callKit.isMuted
                        ? "mic.slash.fill"
                        : "mic.fill",
                    isSelected: callKit.isMuted,
                    accessibilityValue: callKit.isMuted
                        ? "On"
                        : "Off"
                ) {
                    callKit.setMuted(!callKit.isMuted)
                }

                audioRouteControl

                callControl(
                    title: "Keypad",
                    symbol: "circle.grid.3x3.fill",
                    isEnabled: ble.uiCallState == "ACTIVE"
                ) {
                    enteredDigits = ""
                    showingKeypad = true
                }
            }

            Button {
                callKit.endCurrentCall()
            } label: {
                Label(
                    "End Call",
                    systemImage: "phone.down.fill"
                )
                .font(
                    .system(
                        size: 17,
                        weight: .semibold
                    )
                )
                .frame(maxWidth: .infinity)
                .frame(height: 58)
            }
            .buttonStyle(
                CallButtonStyle(
                    fill: .red,
                    cornerRadius: 18,
                    pressedScale: 0.98
                )
            )
            .foregroundStyle(.white)
        }
        .padding(16)
        .background(
            RoundedRectangle(
                cornerRadius: 30,
                style: .continuous
            )
            .fill(
                AppTheme.panelBackground.opacity(
                    colorScheme == .dark ? 0.82 : 0.94
                )
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: 30,
                style: .continuous
            )
            .stroke(
                AppTheme.separator,
                lineWidth: 1
            )
        }
    }

    private func callControl(
        title: String,
        symbol: String,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        accessibilityValue: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(
                        .system(
                            size: 22,
                            weight: .semibold
                        )
                    )
                    .frame(width: 66, height: 66)
            }
            .buttonStyle(
                CallButtonStyle(
                    fill: isSelected
                        ? AppTheme.selectedControlFill
                        : AppTheme.controlFill,
                    cornerRadius: 33
                )
            )
            .foregroundStyle(
                isSelected
                    ? AppTheme.selectedControlForeground
                    : Color.primary
            )
            .disabled(!isEnabled)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue ?? "")

            Text(title)
                .font(
                    .system(
                        size: 12.5,
                        weight: .medium
                    )
                )
                .foregroundStyle(.secondary)
                .opacity(isEnabled ? 1 : 0.45)
        }
        .frame(maxWidth: .infinity)
    }

    private var audioRouteControl: some View {
        callControl(
            title: "Audio",
            symbol: "speaker.wave.2.fill",
            isSelected: relay.selectedAudioRoute == .speaker,
            isEnabled: !relay.isAudioRouteSwitching,
            accessibilityValue: relay.selectedAudioRoute.title
        ) {
            relay.refreshAudioRoutes()
            if relay.hasExternalAudioRoute {
                showingAudioRoutes = true
            } else {
                relay.toggleBuiltInAudioRoute()
            }
        }
    }

    private var incomingActions: some View {
        HStack(spacing: 28) {
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
                        .frame(width: 78, height: 78)
                }
                .buttonStyle(
                    CallButtonStyle(
                        fill: AppTheme.controlFill,
                        cornerRadius: 39
                    )
                )

                Text("Decline")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)

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
                        .frame(width: 78, height: 78)
                }
                .buttonStyle(
                    CallButtonStyle(
                        fill: .green,
                        cornerRadius: 39
                    )
                )
                .foregroundStyle(.white)

                Text("Answer")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 34)
        .foregroundStyle(.primary)
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
                    Image(systemName: "chevron.down")
                        .font(
                            .system(
                                size: 16,
                                weight: .semibold
                            )
                        )
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(
                    CallButtonStyle(
                        fill: AppTheme.controlFill,
                        cornerRadius: 21
                    )
                )
                .foregroundStyle(.primary)

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
                        size: enteredDigits.isEmpty
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
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.top, 24)

            Spacer()

            VStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 16) {
                        ForEach(0..<3, id: \.self) { column in
                            let key = keypadKeys[
                                row * 3 + column
                            ]

                            dtmfKey(
                                digit: key.0,
                                letters: key.1
                            )
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
                    systemImage: "phone.down.fill"
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
            .buttonStyle(
                CallButtonStyle(
                    fill: .red,
                    cornerRadius: 18,
                    pressedScale: 0.98
                )
            )
            .foregroundStyle(.white)
            .padding(
                .bottom,
                max(
                    proxy.safeAreaInsets.bottom + 26,
                    38
                )
            )
        }
        .foregroundStyle(.primary)
    }

    private func dtmfKey(
        digit: String,
        letters: String
    ) -> some View {
        Button {
            sendDtmf(digit)
        } label: {
            InCallDialPadKeyFace(
                digit: digit,
                letters: letters,
                diameter: 76
            )
        }
        .buttonStyle(
            CallButtonStyle(
                fill: AppTheme.controlFill,
                cornerRadius: 38
            )
        )
        .foregroundStyle(.primary)
        .accessibilityLabel(
            letters.isEmpty
                ? digit
                : "\(digit), \(letters)"
        )
    }

    private func audioRouteOverlay(
        proxy: GeometryProxy
    ) -> some View {
        ZStack(alignment: .bottom) {
            Button {
                showingAudioRoutes = false
            } label: {
                Color.black.opacity(0.48)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close audio routes")

            VStack(spacing: 14) {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 36, height: 5)

                HStack {
                    Text("Audio Route")
                        .font(.title3.weight(.semibold))

                    Spacer()

                    Button {
                        showingAudioRoutes = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(
                                .system(
                                    size: 14,
                                    weight: .bold
                                )
                            )
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(
                        CallButtonStyle(
                            fill: AppTheme.controlFill,
                            cornerRadius: 17
                        )
                    )
                    .accessibilityLabel("Close")
                }

                VStack(spacing: 8) {
                    ForEach(relay.availableAudioRoutes) { route in
                        Button {
                            relay.selectAudioRoute(route)
                            showingAudioRoutes = false
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: route.callScreenSymbol)
                                    .font(
                                        .system(
                                            size: 18,
                                            weight: .semibold
                                        )
                                    )
                                    .frame(width: 28)

                                Text(route.title)
                                    .font(.body.weight(.medium))

                                Spacer()

                                if relay.selectedAudioRoute == route {
                                    Image(systemName: "checkmark")
                                        .font(
                                            .system(
                                                size: 15,
                                                weight: .bold
                                            )
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(
                            CallButtonStyle(
                                fill: relay.selectedAudioRoute == route
                                    ? Color(uiColor: .systemFill)
                                    : AppTheme.controlFill,
                                cornerRadius: 15,
                                pressedScale: 0.985
                            )
                        )
                        .foregroundStyle(
                            relay.selectedAudioRoute == route
                                ? AppTheme.tint
                                : Color.primary
                        )
                        .disabled(relay.isAudioRouteSwitching)
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(18)
            .background(
                RoundedRectangle(
                    cornerRadius: 28,
                    style: .continuous
                )
                .fill(
                    Color(uiColor: .systemBackground)
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 28,
                    style: .continuous
                )
                .stroke(
                    AppTheme.separator,
                    lineWidth: 1
                )
            }
            .shadow(
                color: .black.opacity(
                    colorScheme == .dark ? 0.42 : 0.16
                ),
                radius: 26,
                y: 12
            )
            .padding(.horizontal, 18)
            .padding(
                .bottom,
                max(
                    proxy.safeAreaInsets.bottom + 18,
                    28
                )
            )
        }
    }

    private func sendDtmf(
        _ digit: String
    ) {
        guard ble.uiCallState == "ACTIVE" else {
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
        case "HOLDING":
            return "On Hold"
        default:
            return "Call"
        }
    }

    private func durationText(
        now: Date
    ) -> String {
        guard let start = callKit.connectedAt else {
            return "00:00"
        }

        let total = max(
            0,
            Int(
                now.timeIntervalSince(
                    start
                )
            )
        )

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

    private func impact() {
        UIImpactFeedbackGenerator(
            style: .light
        )
        .impactOccurred()
    }
}

private struct CallButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let fill: Color
    let cornerRadius: CGFloat
    var pressedScale: CGFloat = 0.94

    func makeBody(
        configuration: Configuration
    ) -> some View {
        configuration.label
            .background(
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .fill(
                    configuration.isPressed
                        ? fill.opacity(0.72)
                        : fill
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .stroke(
                    AppTheme.separator.opacity(
                        configuration.isPressed ? 1 : 0.75
                    ),
                    lineWidth: 1
                )
            }
            .scaleEffect(
                configuration.isPressed
                    ? pressedScale
                    : 1
            )
            .opacity(isEnabled ? 1 : 0.38)
            .animation(
                .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
    }
}

private struct InCallDialPadKeyFace: View {
    let digit: String
    let letters: String
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if letters.isEmpty {
                primaryGlyph
                    .position(
                        x: diameter / 2,
                        y: diameter / 2
                    )
            } else {
                primaryGlyph
                    .position(
                        x: diameter / 2,
                        y: diameter / 2 - 7.5
                    )

                Text(letters)
                    .font(
                        .system(
                            size: 9.5,
                            weight: .semibold
                        )
                    )
                    .tracking(1.65)
                    .lineLimit(1)
                    .fixedSize()
                    .position(
                        x: diameter / 2,
                        y: diameter / 2 + 17.5
                    )
            }
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var primaryGlyph: some View {
        if digit == "*" {
            Image(systemName: "asterisk")
                .font(.system(size: 28, weight: .medium))
        } else if digit == "#" {
            Image(systemName: "number")
                .font(.system(size: 27, weight: .medium))
        } else {
            Text(digit)
                .font(
                    .system(
                        size: 31,
                        weight: .medium,
                        design: .rounded
                    )
                )
                .monospacedDigit()
                .fixedSize()
        }
    }
}

private extension CallAudioRouteChoice {
    var callScreenSymbol: String {
        switch self {
        case .receiver:
            return "iphone"
        case .speaker:
            return "speaker.wave.2.fill"
        case .bluetooth:
            return "airpodspro"
        }
    }
}

private struct CallBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            RadialGradient(
                colors: [
                    Color.green.opacity(
                        colorScheme == .dark ? 0.22 : 0.10
                    ),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 560
            )

            RadialGradient(
                colors: [
                    AppTheme.tint.opacity(
                        colorScheme == .dark ? 0.20 : 0.09
                    ),
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
