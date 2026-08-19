import SwiftUI
import UIKit

struct NativeDialerView: View {
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver

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
                dialerBackground

                VStack(spacing: 0) {
                    Spacer(minLength: 28)

                    numberArea
                        .frame(height: 122)
                        .padding(.horizontal, 24)

                    Spacer(minLength: 10)

                    keypad
                        .frame(maxWidth: 330)
                        .padding(.horizontal, 24)

                    Spacer(minLength: 24)

                    callRow
                        .padding(.horizontal, 28)
                        .padding(.bottom, max(12, proxy.safeAreaInsets.bottom + 4))
                }
            }
        }
        .navigationTitle("Keypad")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: ble.dialNumber) { _, number in
            resolveName(number)
        }
        .onDisappear {
            lookupTask?.cancel()
        }
    }

    private var dialerBackground: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.12),
                    Color.clear
                ],
                center: .top,
                startRadius: 24,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }

    private var numberArea: some View {
        VStack(spacing: 7) {
            Spacer()

            if ble.dialNumber.isEmpty {
                Text("Enter a number")
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                Text(displayDialNumber)
                    .font(.system(size: 35, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .contentTransition(.numericText())
            }

            if !resolvedName.isEmpty {
                Text(resolvedName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else if !ble.dialNumber.isEmpty {
                Button("Add Number") { }
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                    .disabled(true)
                    .opacity(0.8)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var keypad: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 15) {
                keypadGrid
            }
        } else {
            keypadGrid
        }
    }

    private var keypadGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 20),
                count: 3
            ),
            spacing: 15
        ) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keypadButton(digit: key.0, letters: key.1)
            }
        }
    }

    @ViewBuilder
    private func keypadButton(
        digit: String,
        letters: String
    ) -> some View {
        Button {
            appendDigit(digit)
        } label: {
            VStack(spacing: -1) {
                Text(digit)
                    .font(.system(size: 31, weight: .regular, design: .rounded))
                    .monospacedDigit()

                Text(letters)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1.7)
                    .frame(height: 11)
                    .opacity(letters.isEmpty ? 0 : 0.88)
            }
            .foregroundStyle(.primary)
            .frame(width: 78, height: 78)
            .contentShape(Circle())
        }
        .buttonStyle(DialKeyButtonStyle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
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
            letters.isEmpty ? digit : "\(digit), \(letters)"
        )
    }

    private var callRow: some View {
        ZStack {
            HStack {
                Spacer()

                callButton

                Spacer()
            }

            HStack {
                Spacer()

                if !ble.dialNumber.isEmpty {
                    Button {
                        ble.dialNumber.removeLast()
                        haptic(.light)
                    } label: {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale))
                    .accessibilityLabel("Delete")
                }
            }
        }
        .frame(height: 78)
        .animation(.snappy(duration: 0.2), value: ble.dialNumber.isEmpty)
    }

    private var callButton: some View {
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
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 74, height: 74)
        }
        .buttonStyle(GreenCallButtonStyle())
        .disabled(!ble.isConnected)
        .opacity(ble.isConnected ? 1 : 0.48)
        .accessibilityLabel("Call")
    }

    private var displayDialNumber: String {
        let basic = contacts.basicMetadata(for: ble.dialNumber)
        return basic.formattedNumber.isEmpty
            ? ble.dialNumber
            : basic.formattedNumber
    }

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
            guard !Task.isCancelled,
                  ble.dialNumber == number
            else { return }
            resolvedName = metadata.displayName ?? ""
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

private struct DialKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .glassEffect(
                    .regular.interactive(),
                    in: .circle
                )
                .animation(
                    .snappy(duration: 0.16),
                    value: configuration.isPressed
                )
        } else {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .background(
                    .thinMaterial,
                    in: Circle()
                )
                .animation(
                    .easeOut(duration: 0.12),
                    value: configuration.isPressed
                )
        }
    }
}

private struct GreenCallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        if #available(iOS 26.0, *) {
            configuration.label
                .background(Color.green, in: Circle())
                .glassEffect(
                    .regular.tint(.green).interactive(),
                    in: .circle
                )
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(
                    .snappy(duration: 0.16),
                    value: configuration.isPressed
                )
        } else {
            configuration.label
                .background(Color.green, in: Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
        }
    }
}
