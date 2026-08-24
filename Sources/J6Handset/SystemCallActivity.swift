import Foundation
import Combine
import Intents

@MainActor
final class SystemCallRequestCenter: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let number: String
    }

    static let shared = SystemCallRequestCenter()

    @Published private(set) var pendingRequest: Request?

    private var lastReceivedNumber = ""
    private var lastReceivedAt = Date.distantPast
    private var lastSourceIdentifier: String?
    private var receivedSourceIdentifiers: [String: Date] = [:]

    private let fallbackDuplicateWindow: TimeInterval = 8
    private let sourceIdentifierRetention: TimeInterval = 15

    private init() {}

    func receive(_ userActivity: NSUserActivity) -> Bool {
        guard let number = SystemCallActivity.phoneNumber(
            from: userActivity
        ) else {
            return false
        }

        enqueue(
            number,
            sourceIdentifier: SystemCallActivity.requestIdentifier(
                from: userActivity
            )
        )
        return true
    }

    func receive(_ url: URL) -> Bool {
        guard let number = SystemCallActivity.phoneNumber(
            from: url
        ) else {
            return false
        }

        enqueue(number)
        return true
    }

    func enqueue(
        _ number: String,
        sourceIdentifier: String? = nil
    ) {
        let now = Date()

        receivedSourceIdentifiers =
            receivedSourceIdentifiers.filter {
                now.timeIntervalSince($0.value) < sourceIdentifierRetention
            }

        if let sourceIdentifier,
           receivedSourceIdentifiers[sourceIdentifier] != nil {
            return
        }

        // URL handoffs and older intent paths may not expose an interaction
        // identifier. Keep a bounded number/time fallback for only those cases;
        // distinct identified Phone intents remain valid immediate retries.
        let needsFallbackDedupe =
            sourceIdentifier == nil || lastSourceIdentifier == nil
        if needsFallbackDedupe,
           number == lastReceivedNumber,
           now.timeIntervalSince(lastReceivedAt) < fallbackDuplicateWindow {
            return
        }

        if let sourceIdentifier {
            receivedSourceIdentifiers[sourceIdentifier] = now
        }

        lastReceivedNumber = number
        lastReceivedAt = now
        lastSourceIdentifier = sourceIdentifier
        pendingRequest = Request(number: number)
    }

    func consume(_ request: Request) -> String? {
        guard pendingRequest?.id == request.id else {
            return nil
        }

        pendingRequest = nil
        return request.number
    }
}

enum SystemCallActivity {
    static let modernType = "INStartCallIntent"
    static let legacyAudioType = "INStartAudioCallIntent"

    static func phoneNumber(
        from userActivity: NSUserActivity
    ) -> String? {
        if let interaction = userActivity.interaction {
            if let intent = interaction.intent as? INStartCallIntent {
                if let number = firstNumber(in: intent.contacts) {
                    return sanitized(number)
                }

                if let number = firstNumber(
                    in: intent.callRecordToCallBack?.participants
                ) {
                    return sanitized(number)
                }
            }

            // Phone/Recents can still resume an app with the deprecated
            // INStartAudioCallIntent activity on current iOS releases. Avoid
            // referencing that deprecated Swift type directly; it exposes the
            // same INPerson contacts payload through Objective-C.
            let intent = interaction.intent
            if String(describing: type(of: intent))
                .contains(legacyAudioType),
               let contacts = intent.value(forKey: "contacts") as? [INPerson],
               let number = firstNumber(in: contacts) {
                return sanitized(number)
            }
        }

        return numberFromUserInfo(userActivity.userInfo)
    }

    static func requestIdentifier(
        from userActivity: NSUserActivity
    ) -> String? {
        guard let rawIdentifier = userActivity.interaction?.identifier
        else {
            return nil
        }

        let identifier = rawIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else { return nil }

        return userActivity.activityType + "|" + identifier
    }

    static func phoneNumber(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "tel" else {
            return nil
        }

        let resource = String(
            url.absoluteString.dropFirst(4)
        )
        .trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return sanitized(resource)
    }

    private static func firstNumber(
        in people: [INPerson]?
    ) -> String? {
        people?
            .compactMap { $0.personHandle?.value }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func numberFromUserInfo(
        _ userInfo: [AnyHashable: Any]?
    ) -> String? {
        guard let userInfo else { return nil }

        let preferredKeys = [
            "phoneNumber",
            "number",
            "handle",
            "recipient"
        ]

        for key in preferredKeys {
            if let value = userInfo[key] as? String,
               let number = sanitized(value) {
                return number
            }
        }

        return nil
    }

    private static func sanitized(
        _ rawValue: String
    ) -> String? {
        var value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if value.lowercased().hasPrefix("tel:") {
            value.removeFirst(4)
        }

        value = value.removingPercentEncoding ?? value
        guard !value.isEmpty,
              value.contains(where: \.isNumber)
        else {
            return nil
        }

        return value
    }
}
