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
            ZStack {
                DialerBackdrop()

                VStack(spacing: 0) {
                    header
                        .padding(.top, 14)

                    Spacer(minLength: 18)

                    numberCard
                        .padding(.horizontal, 24)

                    Spacer(minLength: 26)

                    GlassEffectContainer(spacing: 12) {
                        keypad
                    }

                    Spacer(minLength: 22)

                    callRow

                    Spacer(minLength: 18)
                }
                .padding(.bottom, 12)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: ble.dialNumber) {
            _, number in
            resolveName(number)
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Keypad")
                    .font(
                        .system(
                            size: 34,
                            weight: .bold,
                            design: .rounded
                        )
                    )

                Text(
                    ble.isConnected
                        ? "J6 connected"
                        : "J6 disconnected"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 7) {
                Circle()
                    .fill(
                        ble.isConnected
                            ? Color.green
                            : Color.secondary.opacity(0.35)
                    )
                    .frame(width: 8, height: 8)

                Image(
                    systemName:
                        "iphone.radiowaves.left.and.right"
                )
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .glassEffect(
                .regular,
                in: .capsule
            )
        }
        .padding(.horizontal, 22)
    }

    private var numberCard: some View {
        VStack(spacing: 7) {
            if ble.dialNumber.isEmpty {
                Text("Enter a number")
                    .font(
                        .system(
                            size: 28,
                            weight: .medium,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.secondary)
            } else {
                Text(displayDialNumber)
                    .font(
                        .system(
                            size: 32,
                            weight: .semibold,
                            design: .rounded
                        )
                    )
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.48)
                    .contentTransition(.numericText())

                if !resolvedName.isEmpty {
                    Text(resolvedName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Cellular call")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .padding(.horizontal, 18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 26)
        )
    }

    private var keypad: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { column in
                        let key =
                            keys[row * 3 + column]

                        keypadButton(
                            digit: key.0,
                            letters: key.1
                        )
                    }
                }
            }
        }
    }

    private func keypadButton(
        digit: String,
        letters: String
    ) -> some View {
        Button {
            appendDigit(digit)
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
                            : 0.78
                    )
            }
            .frame(width: 78, height: 78)
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .simultaneousGesture(
            LongPressGesture(
                minimumDuration: 0.43
            )
            .onEnded { _ in
                guard digit == "0" else {
                    return
                }

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

    private var callRow: some View {
        HStack(spacing: 20) {
            if !ble.dialNumber.isEmpty {
                Button {
                    guard !ble.dialNumber.isEmpty else {
                        return
                    }

                    ble.dialNumber.removeLast()
                    haptic(.light)
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 52, height: 52)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .transition(
                    .opacity.combined(
                        with: .scale
                    )
                )
            } else {
                Color.clear
                    .frame(width: 52, height: 52)
            }

            Button {
                dialOrRedial()
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 25, weight: .bold))
                    .frame(width: 70, height: 70)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.green)
            .disabled(!ble.isConnected)
            .opacity(ble.isConnected ? 1 : 0.45)

            Color.clear
                .frame(width: 52, height: 52)
        }
        .animation(
            .snappy(duration: 0.18),
            value: ble.dialNumber.isEmpty
        )
    }

    private var displayDialNumber: String {
        let basic =
            contacts.basicMetadata(
                for: ble.dialNumber
            )

        return basic.formattedNumber.isEmpty
            ? ble.dialNumber
            : basic.formattedNumber
    }

    private func dialOrRedial() {
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

        callKit.startOutgoing(
            number: ble.dialNumber
        )
    }

    private func appendDigit(
        _ digit: String
    ) {
        guard ble.dialNumber.count < 32 else {
            return
        }

        ble.dialNumber.append(digit)
        haptic(.light)
    }

    private func resolveName(
        _ number: String
    ) {
        lookupTask?.cancel()
        resolvedName = ""

        guard number
            .filter({ $0.isNumber })
            .count >= 6
        else {
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
                await contacts.resolve(
                    number: number
                )

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
        _ style:
            UIImpactFeedbackGenerator.FeedbackStyle
    ) {
        UIImpactFeedbackGenerator(
            style: style
        )
        .impactOccurred()
    }
}

private struct DialerBackdrop: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.11),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )

            RadialGradient(
                colors: [
                    Color.green.opacity(0.06),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 20,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }
}
