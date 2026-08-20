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

    // Geometry measured from the supplied real iOS 26 Phone screenshots.
    private let referenceWidth: CGFloat = 440
    private let referenceFirstKeyY: CGFloat = 311
    private let referenceRowStep: CGFloat = 108
    private let referenceColumnStep: CGFloat = 112
    private let referenceKeyDiameter: CGFloat = 88.5
    private let referenceCallY: CGFloat = 748.5

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
            let scale = min(
                max(proxy.size.width / referenceWidth, 0.82),
                1.08
            )

            ZStack(alignment: .topLeading) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                if !ble.dialNumber.isEmpty {
                    numberArea(scale: scale)
                        .frame(
                            width: min(proxy.size.width - 36, 370 * scale),
                            height: 82 * scale
                        )
                        .position(
                            x: proxy.size.width / 2,
                            y: 210 * scale
                        )
                }

                keypad(scale: scale)
                    .position(
                        x: proxy.size.width / 2,
                        y:
                            (referenceFirstKeyY
                             + referenceRowStep * 1.5)
                            * scale
                    )

                callButton(scale: scale)
                    .position(
                        x: proxy.size.width / 2,
                        y: referenceCallY * scale
                    )

                if !ble.dialNumber.isEmpty {
                    deleteButton(scale: scale)
                        .position(
                            x:
                                proxy.size.width / 2
                                + referenceColumnStep * scale,
                            y: referenceCallY * scale
                        )
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(
                .snappy(duration: 0.18),
                value: ble.dialNumber.isEmpty
            )
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: ble.dialNumber) { _, number in
            resolveName(number)
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    private func numberArea(scale: CGFloat) -> some View {
        VStack(spacing: 4 * scale) {
            Text(displayDialNumber)
                .font(
                    .system(
                        size: 32 * scale,
                        weight: .regular
                    )
                )
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.50)
                .contentTransition(.numericText())

            if !resolvedName.isEmpty {
                Text(resolvedName)
                    .font(
                        .system(
                            size: 15 * scale,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else {
                Text("Add Number")
                    .font(
                        .system(
                            size: 15 * scale,
                            weight: .regular
                        )
                    )
                    .foregroundStyle(Color.accentColor)
                    .opacity(0.88)
            }
        }
    }

    private func keypad(scale: CGFloat) -> some View {
        let gap =
            (referenceColumnStep - referenceKeyDiameter)
            * scale
        let rowGap =
            (referenceRowStep - referenceKeyDiameter)
            * scale

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
    }

    private func keypadButton(
        digit: String,
        letters: String,
        scale: CGFloat
    ) -> some View {
        Button {
            appendDigit(digit)
        } label: {
            VStack(spacing: -3 * scale) {
                Text(digit)
                    .font(
                        .system(
                            size: 36 * scale,
                            weight: .regular
                        )
                    )
                    .monospacedDigit()

                Text(letters)
                    .font(
                        .system(
                            size: 10.5 * scale,
                            weight: .semibold
                        )
                    )
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
                Circle()
                    .stroke(
                        keyStroke,
                        lineWidth: 0.55
                    )
            }
            .shadow(
                color:
                    colorScheme == .light
                        ? Color.black.opacity(0.055)
                        : .clear,
                radius: 13 * scale,
                y: 7 * scale
            )
            .contentShape(Circle())
        }
        .buttonStyle(PhoneKeyPressStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.43)
                .onEnded { _ in
                    guard digit == "0" else { return }

                    if ble.dialNumber.last == "0" {
                        ble.dialNumber.removeLast()
                    }

                    ble.dialNumber.append("+")
                    haptic(.medium)
                }
        )
        .accessibilityLabel(
            letters.isEmpty
                ? digit
                : "\(digit), \(letters)"
        )
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
                .font(
                    .system(
                        size: 28 * scale,
                        weight: .semibold
                    )
                )
                .foregroundStyle(.white)
                .frame(
                    width: 86 * scale,
                    height: 86 * scale
                )
                .background(
                    Color(uiColor: .systemGreen),
                    in: Circle()
                )
                .overlay {
                    Circle()
                        .stroke(
                            Color.white.opacity(
                                colorScheme == .dark ? 0.36 : 0.18
                            ),
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
                .font(
                    .system(
                        size: 25 * scale,
                        weight: .regular
                    )
                )
                .foregroundStyle(.primary)
                .frame(
                    width: 64 * scale,
                    height: 64 * scale
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete")
    }

    private var keyFill: Color {
        if colorScheme == .dark {
            return Color(
                red: 0.070,
                green: 0.070,
                blue: 0.073
            )
        }

        return Color(
            red: 0.988,
            green: 0.988,
            blue: 0.990
        )
    }

    private var keyStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.white.opacity(0.90)
    }

    private var displayDialNumber: String {
        let basic = contacts.basicMetadata(
            for: ble.dialNumber
        )

        return basic.formattedNumber.isEmpty
            ? ble.dialNumber
            : basic.formattedNumber
    }

    private func appendDigit(_ digit: String) {
        guard ble.dialNumber.count < 32 else {
            return
        }

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
            try? await Task.sleep(
                for: .milliseconds(180)
            )

            guard !Task.isCancelled else {
                return
            }

            let metadata =
                await contacts.resolve(number: number)

            guard !Task.isCancelled,
                  ble.dialNumber == number
            else {
                return
            }

            resolvedName =
                metadata.displayName ?? ""
        }
    }

    private func haptic(
        _ style: UIImpactFeedbackGenerator.FeedbackStyle
    ) {
        UIImpactFeedbackGenerator(
            style: style
        ).impactOccurred()
    }
}

private struct PhoneKeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? 0.955
                    : 1
            )
            .opacity(
                configuration.isPressed
                    ? 0.72
                    : 1
            )
            .animation(
                .easeOut(duration: 0.09),
                value: configuration.isPressed
            )
    }
}
