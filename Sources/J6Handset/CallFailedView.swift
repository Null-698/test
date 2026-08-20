import SwiftUI

struct CallFailedView: View {
    let number: String
    let onCancel: () -> Void
    let onCallBack: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(
                    red: 0.145,
                    green: 0.145,
                    blue: 0.150
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    VStack(spacing: 5) {
                        Text("Call failed")
                            .font(
                                .system(
                                    size: 23,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(
                                .white.opacity(0.56)
                            )

                        Text(
                            number.isEmpty
                                ? "Unknown"
                                : number
                        )
                        .font(
                            .system(
                                size: 39,
                                weight: .semibold
                            )
                        )
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    }
                    .padding(
                        .top,
                        max(
                            proxy.safeAreaInsets.top + 82,
                            126
                        )
                    )
                    .padding(.horizontal, 28)

                    Spacer()

                    HStack {
                        failedAction(
                            title: "Cancel",
                            systemImage: "xmark",
                            fill: Color(
                                red: 0.62,
                                green: 0.62,
                                blue: 0.63
                            ),
                            action: onCancel
                        )

                        Spacer()

                        failedAction(
                            title: "Call Back",
                            systemImage: "phone.fill",
                            fill:
                                Color(
                                    uiColor:
                                        .systemGreen
                                ),
                            action: onCallBack
                        )
                    }
                    .padding(.horizontal, 43)
                    .padding(
                        .bottom,
                        max(
                            proxy.safeAreaInsets.bottom + 50,
                            68
                        )
                    )
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func failedAction(
        title: String,
        systemImage: String,
        fill: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(
                        .system(
                            size: 30,
                            weight: .medium
                        )
                    )
                    .foregroundStyle(.white)
                    .frame(width: 82, height: 82)
                    .background(fill, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(
                                Color.white.opacity(0.55),
                                lineWidth: 0.8
                            )
                    }
            }
            .buttonStyle(FailedCallPressStyle())

            Text(title)
                .font(
                    .system(
                        size: 16,
                        weight: .regular
                    )
                )
                .foregroundStyle(.white)
        }
    }
}

private struct FailedCallPressStyle: ButtonStyle {
    func makeBody(
        configuration: Configuration
    ) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? 0.94
                    : 1
            )
            .opacity(
                configuration.isPressed
                    ? 0.82
                    : 1
            )
            .animation(
                .easeOut(duration: 0.09),
                value: configuration.isPressed
            )
    }
}
