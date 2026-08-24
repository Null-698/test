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
        GeometryReader { _ in
            ZStack {
                DialerBackdrop()

                VStack(spacing: 0) {
                    Spacer(minLength: 22)

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
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                connectionIndicator
            }
            .padding(.horizontal, 22)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .sheet(
            isPresented: Binding(
                get: { ble.isUssdSheetPresented },
                set: { presented in
                    if !presented {
                        ble.dismissUssdSheet()
                    }
                }
            )
        ) {
            UssdResultSheet(ble: ble)
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

    private var connectionIndicator: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(
                    ble.isConnected
                        ? Color.green
                        : Color.secondary.opacity(0.35)
                )
                .frame(width: 8, height: 8)

            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .glassEffect(
            .regular,
            in: .capsule
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ble.isConnected
                ? "Connected"
                : "Disconnected"
        )
    }

    private var numberCard: some View {
        VStack(spacing: 7) {
            if !ble.dialNumber.isEmpty {
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
                    Text(isLikelyUssd(ble.dialNumber) ? "USSD" : "Cellular call")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
        .contextMenu {
            if !ble.dialNumber.isEmpty {
                Button {
                    UIPasteboard.general.string = ble.dialNumber
                    haptic(.light)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            Button {
                pasteDialNumber()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        }
        .accessibilityHint("Touch and hold to copy or paste a phone number")
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
            DialPadKeyFace(
                digit: digit,
                letters: letters,
                diameter: 78
            )
        }
        .buttonStyle(.glass(.clear))
        .buttonBorderShape(.circle)
        .foregroundStyle(.primary)
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
                .foregroundStyle(.primary)
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
            .foregroundStyle(.white)
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
        if isLikelyUssd(ble.dialNumber) {
            return ble.dialNumber
        }

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

        let numberToDial = ble.dialNumber
        lastDialedNumber = numberToDial
        haptic(.medium)

        if isLikelyUssd(numberToDial) {
            if ble.sendUssd(numberToDial) {
                ble.dialNumber = ""
                resolvedName = ""
            }
            return
        }

        callKit.startOutgoing(
            number: numberToDial
        )

        // prepareOutgoingUI() moves the BLE presentation state to DIALING
        // synchronously when the request is accepted. Only clear the field
        // after that successful transition, not if CallKit rejected a second
        // outgoing request while another call is already present.
        if ble.uiCallState == "DIALING" ||
           ble.uiCallState == "CONNECTING" {
            ble.dialNumber = ""
            resolvedName = ""
        }
    }

    private func pasteDialNumber() {
        guard let clipboard = UIPasteboard.general.string else {
            haptic(.light)
            return
        }

        var normalized = ""
        for character in clipboard {
            if character.isNumber ||
               character == "*" ||
               character == "#" ||
               (character == "+" && normalized.isEmpty) {
                normalized.append(character)
            }

            if normalized.count >= 32 {
                break
            }
        }

        guard !normalized.isEmpty else {
            UINotificationFeedbackGenerator()
                .notificationOccurred(.error)
            return
        }

        ble.dialNumber = normalized
        haptic(.medium)
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

        guard !isLikelyUssd(number) else {
            return
        }

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

    private func isLikelyUssd(_ value: String) -> Bool {
        let code = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard code.count >= 2,
              code.first == "*" || code.first == "#",
              code.last == "#" else {
            return false
        }
        return code.allSatisfy {
            $0.isNumber || $0 == "*" || $0 == "#" || $0 == "+"
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

private struct UssdResultSheet: View {
    @ObservedObject var ble: BLECallController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        if ble.ussdPending {
                            ProgressView()
                        } else {
                            Image(
                                systemName: ble.ussdSucceeded
                                    ? "checkmark.circle.fill"
                                    : "exclamationmark.circle.fill"
                            )
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(
                                ble.ussdSucceeded ? Color.green : Color.orange
                            )
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(ble.ussdPending ? "USSD request" : "USSD response")
                                .font(.headline)
                            Text(ble.ussdRequest)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if ble.ussdPending {
                        Text("Waiting for the mobile network…")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(ble.ussdResponse)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !ble.ussdResponse.isEmpty {
                            Button {
                                UIPasteboard.general.string = ble.ussdResponse
                                UIImpactFeedbackGenerator(style: .light)
                                    .impactOccurred()
                            } label: {
                                Label("Copy Response", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(22)
            }
            .navigationTitle("USSD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        ble.dismissUssdSheet()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DialPadKeyFace: View {
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

private struct DialerBackdrop: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
    }
}
