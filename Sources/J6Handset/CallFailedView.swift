import SwiftUI

struct CallFailedView: View {
    let number: String
    let onCancel: () -> Void
    let onCallBack: () -> Void

    var body: some View {
        ZStack {
            CallFailedBackdrop()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "phone.down.fill")
                    .font(
                        .system(
                            size: 30,
                            weight: .semibold
                        )
                    )
                    .frame(
                        width: 84,
                        height: 84
                    )
                    .glassEffect(
                        .regular,
                        in: .circle
                    )

                VStack(spacing: 7) {
                    Text("Call ended")
                        .font(
                            .system(
                                size: 30,
                                weight: .bold,
                                design: .rounded
                            )
                        )

                    Text(
                        number.isEmpty
                            ? "Unknown number"
                            : number
                    )
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                }

                Spacer()

                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        Button {
                            onCallBack()
                        } label: {
                            Label(
                                "Call Again",
                                systemImage:
                                    "phone.fill"
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
                        .buttonStyle(
                            .glassProminent
                        )
                        .tint(.green)
                        .foregroundStyle(.white)

                        Button("Dismiss") {
                            onCancel()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                .padding(16)
                .glassEffect(
                    .regular,
                    in: .rect(
                        cornerRadius: 30
                    )
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 44)
            }
            .foregroundStyle(.primary)
        }
        .ignoresSafeArea()
    }
}

private struct CallFailedBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            RadialGradient(
                colors: [
                    Color.red.opacity(
                        colorScheme == .dark ? 0.20 : 0.10
                    ),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 480
            )

            RadialGradient(
                colors: [
                    AppTheme.tint.opacity(
                        colorScheme == .dark ? 0.14 : 0.07
                    ),
                    .clear
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
        }
    }
}
