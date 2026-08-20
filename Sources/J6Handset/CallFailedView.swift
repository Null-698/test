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
                    .foregroundStyle(
                        .white.opacity(0.65)
                    )
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
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}

private struct CallFailedBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(
                        red: 0.055,
                        green: 0.065,
                        blue: 0.11
                    ),
                    Color(
                        red: 0.11,
                        green: 0.055,
                        blue: 0.08
                    )
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color.red.opacity(0.16),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 480
            )
        }
    }
}
