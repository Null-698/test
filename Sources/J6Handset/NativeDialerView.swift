import SwiftUI
import UIKit

struct NativeDialerView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver
    @Environment(\.colorScheme) private var colorScheme

    @State private var resolvedName = ""
    @State private var lookupTask: Task<Void, Never>?
    @AppStorage("LastDialedNumber") private var lastDialedNumber = ""

    // Geometry measured from the supplied real iOS 26 Phone screenshots
    // (1320x2868 @3x -> 440x956 pt). Used only to size elements, never to
    // pin absolute on-screen positions, so layout stays centered on every
    // device size/aspect ratio instead of just the reference device.
    private let referenceWidth: CGFloat = 440
    private let referenceHeight: CGFloat = 956
    private let referenceRowStep: CGFloat = 108
    private let referenceColumnStep: CGFloat = 112
    private let referenceKeyDiameter: CGFloat = 88.5

    private let keys: [(String, String)] = [
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
            let scale = keypadScale(for: proxy.size)

            VStack(spacing: 0) {
                numberDisplay(scale: scale)
                    .frame(height: 92 * scale)
                    .padding(.top, topInset(proxy))
                    .padding(.horizontal, 24)

                Spacer(minLength: 4)

                keypad(scale: scale)

                Spacer(minLength: 4)

                actionRow(scale: scale)
                    .padding(.bottom, bottomInset(proxy))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: ble.dialNumber) { _, number in
            resolveName(number)
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    // MARK: - Adaptive geometry

    /// Scales keypad element sizes to the available space using BOTH width
    /// and height, so short devices (e.g. SE) and tall devices (e.g. Pro
    /// Max) both end up correctly centered instead of only matching the
    /// single reference screen width.
    private func keypadScale(for size: CGSize) -> CGFloat {
        let widthScale = size.width / referenceWidth
        let heightScale = size.height / referenceHeight
        return min(max(min(widthScale, heightScale), 0.80), 1.08)
    }

    private func topInset(_ proxy: GeometryProxy) -> CGFloat {
        max(proxy.safeAreaInsets.top, 12) + 16
    }

    private func bottomInset(_ proxy: GeometryProxy) -> CGFloat {
        max(proxy.safeAreaInsets.bottom, 12) + 18
    }

    // MARK: - Number display

    private func numberDisplay(scale: CGFloat) -> some View {
        VStack(spacing: 4 * scale) {
            Text(ble.dialNumber.isEmpty ? " " : displayDialNumber)
                .font(.system(size: 32 * scale, weight: .regular))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.50)
                .contentTransition(.numericText())

            Group {
                if ble.dialNumber.isEmpty {
                    Text(" ")
                } else if !resolvedName.isEmpty {
                    Text(resolvedName)
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text("Add Number")
                        .foregroundStyle(Color.accentColor)
                        .opacity(0.88)
                }
            }
            .font(.system(size: 15 * scale, weight: .regular))
            .lineLimit(1)
        }
        // Keeping the container always laid out (with a blank placeholder
        // instead of conditionally inserting the whole view) is what stops
        // the number/keypad from visibly jumping the moment you dial the
        // first digit.
        .animation(.easeInOut(duration: 0.15), value: ble.dialNumber.isEmpty)
    }

    // MARK: - Keypad

    private func keypad(scale: CGFloat) -> some View {
        let gap = (referenceColumnStep - referenceKeyDiameter) * scale
        let rowGap = (referenceRowStep - referenceKeyDiameter) * scale

        return VStack(spacing: rowGap) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        let key = keys[row * 3 + column]
                        keypadButton(
                            digit: key.0,
                            letters: key.1,
                            scale: scale
                        )
                    }
                }
            }
        }
        // Grid centers itself horizontally and vertically via the parent
        // VStack + Spacers, so it never needs a hardcoded on-screen point.
        .frame(maxWidth: .infinity)
    }

    private func keypadButton(
        digit: String,
        letters: String,
        scale: CGFloat
    ) -> some View {
        let button = Button {
            appendDigit(digit)
        } label: {
            VStack(spacing: -3 * scale) {
                Text(digit)
                    .font(.system(size: 36 * scale, weight: .regular))
                    .monospacedDigit()

                Text(letters)
                    .font(.system(size: 10.5 * scale, weight: .semibold))
                    .tracking(2.25 * scale)
                    .frame(height: 13 * scale)
                    .opacity(letters.isEmpty ? 0 : 1)
            }
            .foregroundStyle(.primary)
            .frame(
                width: referenceKeyDiameter * scale,
                height: referenceKeyDiameter * scale
            )
            .background(keyFill, in: Circle())
            .overlay {
                Circle().stroke(keyStroke, lineWidth: 0.55)
            }
            .shadow(
                color: colorScheme == .light
                    ? Color.black.opacity(0.055)
                    : .clear,
                radius: 13 * scale,
                y: 7 * scale
            )
            .contentShape(Circle())
        }
        .buttonStyle(PhoneKeyPressStyle())
        .accessibilityLabel(letters.isEmpty ? digit : "\(digit), \(letters)")

        // Only the "0" key needs to distinguish a long press (insert "+").
        // Attaching that recognizer to every key was what made ordinary
        // taps on 1-9/*/# feel delayed, since the system had to wait to
        // rule out a long press before committing each tap.
        if digit == "0" {
            return AnyView(
                button.simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.43)
                        .onEnded { _ in
                            if ble.dialNumber.last == "0" {
                                ble.dialNumber.removeLast()
                            }
                            ble.dialNumber.append("+")
                            haptic(.medium)
                        }
                )
            )
        }

        return AnyView(button)
    }

    // MARK: - Action row (call / delete)

    private func actionRow(scale: CGFloat) -> some View {
        // A fixed-width slot on each side keeps the call button perfectly
        // centered whether or not the delete button is currently visible,
        // instead of the delete button appearing and nudging things off
        // center.
        let sideWidth = referenceColumnStep * scale

        return HStack(spacing: 0) {
            Color.clear.frame(width: sideWidth, height: sideWidth)

            Spacer(minLength: 0)

            callButton(scale: scale)

            Spacer(minLength: 0)

            Group {
                if !ble.dialNumber.isEmpty {
                    deleteButton(scale: scale)
                        .transition(.opacity.combined(with: .scale))
                } else {
                    Color.clear
                }
            }
            .frame(width: sideWidth, height: sideWidth)
        }
        .animation(.snappy(duration: 0.18), value: ble.dialNumber.isEmpty)
        .padding(.horizontal, 24)
    }

    private func callButton(scale: CGFloat) -> some View {
        Button {
            if ble.dialNumber.isEmpty {
                guard !lastDialedNumber.isEmpty else {
                    haptic(.light)
                    return
                }
                ble.dialNumber = lastDialedNumber
                haptic(.light)
                return
            }

            lastDialedNumber = ble.dialNumber
            haptic(.medium)
            callKit.startOutgoing(number: ble.dialNumber)
        } label: {
            Image(systemName: "phone.fill")
                .font(.system(size: 28 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 86 * scale, height: 86 * scale)
                .background(Color(uiColor: .systemGreen), in: Circle())
                .overlay {
                    Circle().stroke(
                        Color.white.opacity(colorScheme == .dark ? 0.36 : 0.18),
                        lineWidth: 0.8
                    )
                }
        }
        .buttonStyle(PhoneKeyPressStyle())
        .disabled(!ble.isConnected)
        .opacity(ble.isConnected ? 1 : 0.42)
        .accessibilityLabel("Call")
    }

    private func deleteButton(scale: CGFloat) -> some View {
        Button {
            guard !ble.dialNumber.isEmpty else { return }
            ble.dialNumber.removeLast()
            haptic(.light)
        } label: {
            Image(systemName: "delete.left.fill")
                .font(.system(size: 25 * scale, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 64 * scale, height: 64 * scale)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }

    // MARK: - Styling

    private var keyFill: Color {
        if colorScheme == .dark {
            return Color(red: 0.070, green: 0.070, blue: 0.073)
        }
        return Color(red: 0.988, green: 0.988, blue: 0.990)
    }

    private var keyStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.white.opacity(0.90)
    }

    private var displayDialNumber: String {
        let basic = contacts.basicMetadata(for: ble.dialNumber)
        return basic.formattedNumber.isEmpty
            ? ble.dialNumber
            : basic.formattedNumber
    }

    // MARK: - Actions

    private func appendDigit(_ digit: String) {
        guard ble.dialNumber.count < 32 else { return }
        ble.dialNumber.append(digit)
        haptic(.light)
    }

    private func resolveName(_ number: String) {
        lookupTask?.cancel()
        resolvedName = ""

        guard number.filter({ $0.isNumber }).count >= 6 else {
            return
        }

        lookupTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let metadata = await contacts.resolve(number: number)
            guard !Task.isCancelled, ble.dialNumber == number else {
                return
            }

            resolvedName = metadata.displayName ?? ""
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

private struct PhoneKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.955 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
