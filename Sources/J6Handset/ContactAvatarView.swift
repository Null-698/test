import ImageIO
import SwiftUI
import UIKit

enum ContactAvatarPlaceholderStyle {
    case initials
    case system
}

private struct DecodedContactAvatar: @unchecked Sendable {
    let image: UIImage
}

private final class ContactAvatarImageCache: @unchecked Sendable {
    static let shared = ContactAvatarImageCache()

    let images: NSCache<NSString, UIImage>

    private init() {
        images = NSCache<NSString, UIImage>()
        images.countLimit = 160
        images.totalCostLimit = 12 * 1_024 * 1_024
    }
}

struct ContactAvatarView: View {
    let initials: String
    let imageData: Data?
    let cacheKey: String
    var size: CGFloat = 48
    var placeholderStyle: ContactAvatarPlaceholderStyle = .initials

    @Environment(\.displayScale) private var displayScale
    @State private var decodedImage: UIImage?

    var body: some View {
        Group {
            if let decodedImage {
                Image(uiImage: decodedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: decodeIdentifier) {
            await decodeIfNeeded()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch placeholderStyle {
        case .initials:
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.blue.opacity(0.35),
                                Color.indigo.opacity(0.65)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Text(initials)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }

        case .system:
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private var decodeIdentifier: String {
        let fingerprint = imageData?.hashValue ?? 0
        return "\(cacheKey)|\(fingerprint)|\(pixelSize)"
    }

    private var pixelSize: Int {
        max(1, Int((size * max(displayScale, 1)).rounded(.up)))
    }

    @MainActor
    private func decodeIfNeeded() async {
        guard let imageData, !imageData.isEmpty else {
            decodedImage = nil
            return
        }

        let key = decodeIdentifier as NSString
        if let cached = ContactAvatarImageCache.shared.images.object(forKey: key) {
            decodedImage = cached
            return
        }

        let targetPixelSize = pixelSize
        let scale = max(displayScale, 1)
        let decoded = await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let source = CGImageSourceCreateWithData(
                imageData as CFData,
                nil
            ),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil as DecodedContactAvatar?
            }

            return DecodedContactAvatar(
                image: UIImage(
                    cgImage: cgImage,
                    scale: scale,
                    orientation: .up
                )
            )
        }.value

        guard !Task.isCancelled, let decoded else { return }
        ContactAvatarImageCache.shared.images.setObject(
            decoded.image,
            forKey: key,
            cost: targetPixelSize * targetPixelSize * 4
        )
        decodedImage = decoded.image
    }
}
