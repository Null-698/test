import Foundation
import UserNotifications

final class SMSController: ObservableObject {
    enum Direction: String, Codable, Sendable {
        case incoming
        case outgoing
    }

    enum DeliveryStatus: String, Codable, Sendable {
        case received
        case sending
        case sent
        case delivered
        case failed
    }

    struct Message: Identifiable, Codable, Equatable, Sendable {
        let id: String
        let timestampMs: Int64
        let sender: String
        let body: String
        var isRead: Bool
        let otpCode: String?

        // Optional for backward compatibility with older persisted sms.json.
        var direction: Direction? = nil
        var deliveryStatus: DeliveryStatus? = nil
        var requestID: String? = nil

        var date: Date {
            Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        }

        var isOutgoing: Bool {
            direction == .outgoing
        }

        var effectiveDeliveryStatus: DeliveryStatus {
            if let deliveryStatus { return deliveryStatus }
            return isOutgoing ? .sent : .received
        }
    }

    static let shared = SMSController()

    @Published private(set) var messages: [Message] = []
    @Published private(set) var notificationStatus = "Not requested"
    @Published private(set) var requestedThreadKey: String?
    @Published private(set) var requestedComposeRecipient: String?

    private var activeThreadKey: String?
    private var applicationIsActive = false

    private let storageQueue = DispatchQueue(
        label: "com.regis.j6handset.sms.storage",
        qos: .utility
    )
    private let maxMessages = 500

    private init() {
        messages = Self.loadMessages()
        refreshNotificationStatus()
    }

    var unreadCount: Int {
        messages.reduce(into: 0) { count, message in
            if !message.isOutgoing && !message.isRead { count += 1 }
        }
    }

    var latestTimestampMs: Int64 {
        messages.map(\.timestampMs).max() ?? 0
    }

    func receive(
        id: String,
        timestampMs: Int64,
        sender: String,
        body: String,
        onPersisted: @escaping () -> Void = {}
    ) {
        guard !id.isEmpty, timestampMs > 0, !body.isEmpty else { return }
        if messages.contains(where: { $0.id == id }) {
            onPersisted()
            return
        }

        let normalizedSender = sender.isEmpty ? "Unknown" : sender
        let key = Self.threadKey(for: normalizedSender)
        let isAlreadyViewingThread =
            applicationIsActive && activeThreadKey == key
        let message = Message(
            id: id,
            timestampMs: timestampMs,
            sender: normalizedSender,
            body: body,
            isRead: isAlreadyViewingThread,
            otpCode: Self.extractOTP(from: body),
            direction: .incoming,
            deliveryStatus: .received,
            requestID: nil
        )

        messages.append(message)
        sortAndTrim()
        persistAsync { success in
            if success { onPersisted() }
        }
        updateBadge()
        if !isAlreadyViewingThread {
            deliverNotification(for: message)
        }
    }

    func recordOutgoing(
        requestID: String,
        recipient: String,
        body: String
    ) {
        guard !requestID.isEmpty, !recipient.isEmpty, !body.isEmpty else { return }
        if messages.contains(where: { $0.requestID == requestID }) { return }

        let message = Message(
            id: "out-\(requestID)",
            timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
            sender: recipient,
            body: body,
            isRead: true,
            otpCode: nil,
            direction: .outgoing,
            deliveryStatus: .sending,
            requestID: requestID
        )
        messages.append(message)
        sortAndTrim()
        persistAsync()
    }

    func updateOutgoingStatus(requestID: String, status: DeliveryStatus) {
        guard let index = messages.firstIndex(where: { $0.requestID == requestID }) else {
            return
        }

        let current = messages[index].effectiveDeliveryStatus
        if statusPriority(status) < statusPriority(current) {
            return
        }

        messages[index].deliveryStatus = status
        persistAsync()
    }

    func updateOutgoingStatus(requestID: String, succeeded: Bool) {
        updateOutgoingStatus(
            requestID: requestID,
            status: succeeded ? .sent : .failed
        )
    }

    func failSendingMessages(requestIDs: Set<String>) {
        guard !requestIDs.isEmpty else { return }
        var changed = false
        for index in messages.indices {
            guard messages[index].effectiveDeliveryStatus == .sending,
                  let requestID = messages[index].requestID,
                  requestIDs.contains(requestID)
            else { continue }
            messages[index].deliveryStatus = .failed
            changed = true
        }
        if changed { persistAsync() }
    }


    func prepareRetry(messageID: String, requestID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].isOutgoing,
              !requestID.isEmpty
        else { return }

        messages[index].requestID = requestID
        messages[index].deliveryStatus = .sending
        persistAsync()
    }

    func deleteMessage(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let removed = messages.remove(at: index)
        persistAsync()
        updateBadge()
        if !removed.isOutgoing {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: ["j6-sms-\(removed.id)"]
            )
        }
    }

    func deleteThread(_ threadKey: String) {
        guard !threadKey.isEmpty else { return }
        let removedIDs = messages.compactMap { message -> String? in
            guard Self.threadKey(for: message.sender) == threadKey,
                  !message.isOutgoing else { return nil }
            return "j6-sms-\(message.id)"
        }
        let originalCount = messages.count
        messages.removeAll { Self.threadKey(for: $0.sender) == threadKey }
        guard messages.count != originalCount else { return }

        persistAsync()
        updateBadge()
        if !removedIDs.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: removedIDs
            )
        }
    }

    func setActiveThread(_ threadKey: String?) {
        activeThreadKey = threadKey
        guard applicationIsActive, let threadKey else { return }
        markThreadRead(participantKeys: [threadKey])
        removeDeliveredNotifications(forThreadKey: threadKey)
    }

    func setApplicationActive(_ isActive: Bool) {
        guard applicationIsActive != isActive else { return }
        applicationIsActive = isActive

        // A conversation can remain mounted while its scene is backgrounded.
        // Only treat it as visible after the scene becomes active again.
        guard isActive, let activeThreadKey else { return }
        markThreadRead(participantKeys: [activeThreadKey])
        removeDeliveredNotifications(forThreadKey: activeThreadKey)
    }

    func requestOpenThread(for participant: String) {
        let key = Self.threadKey(for: participant)
        guard !key.isEmpty else { return }
        requestedThreadKey = key
    }

    func consumeOpenThreadRequest(_ key: String) {
        guard requestedThreadKey == key else { return }
        requestedThreadKey = nil
    }

    func requestCompose(to recipient: String) {
        let value = recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else { return }
        requestedComposeRecipient = value
    }

    func consumeComposeRequest(_ recipient: String) {
        guard requestedComposeRecipient == recipient else { return }
        requestedComposeRecipient = nil
    }

    func markRead(_ id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
              !messages[index].isOutgoing,
              !messages[index].isRead
        else { return }

        messages[index].isRead = true
        persistAsync()
        updateBadge()
    }

    func markThreadRead(participantKeys: Set<String>) {
        guard !participantKeys.isEmpty else { return }
        var changed = false
        for index in messages.indices {
            let message = messages[index]
            guard !message.isOutgoing,
                  !message.isRead,
                  participantKeys.contains(Self.threadKey(for: message.sender))
            else { continue }
            messages[index].isRead = true
            changed = true
        }
        if changed {
            persistAsync()
            updateBadge()
        }
    }

    func markAllRead() {
        var changed = false
        for index in messages.indices
        where !messages[index].isOutgoing && !messages[index].isRead {
            messages[index].isRead = true
            changed = true
        }
        if changed {
            persistAsync()
            updateBadge()
        }
    }

    func requestNotificationPermissionIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else {
                Task { @MainActor in
                    SMSController.shared.refreshNotificationStatus()
                }
                return
            }

            center.requestAuthorization(options: [.alert, .sound, .badge]) {
                _, _ in
                Task { @MainActor in
                    SMSController.shared.refreshNotificationStatus()
                }
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                text = "Enabled"
            case .denied:
                text = "Disabled"
            case .notDetermined:
                text = "Not requested"
            @unknown default:
                text = "Unknown"
            }
            Task { @MainActor in
                SMSController.shared.notificationStatus = text
            }
        }
    }

    static func threadKey(for participant: String) -> String {
        let trimmed = participant.trimmingCharacters(in: .whitespacesAndNewlines)

        // GSM sender IDs may be alphanumeric carrier/service names, including
        // names that also contain digits. Keep the complete sender identity so
        // it remains visible and cannot collide with an unrelated short code.
        if trimmed.contains(where: \.isLetter) {
            return trimmed.lowercased()
        }

        let digits = trimmed.filter { $0.isNumber }

        guard !digits.isEmpty else {
            return trimmed.lowercased()
        }

        // Normalize local/international variants of the same mobile number
        // into one stable thread key. For full phone numbers we key by the
        // subscriber digits, while short codes keep their full value.
        if digits.count >= 9 {
            return String(digits.suffix(9))
        }

        return digits
    }

    private func statusPriority(_ status: DeliveryStatus) -> Int {
        switch status {
        case .sending: 0
        case .sent: 1
        case .failed: 2
        case .delivered: 3
        case .received: 0
        }
    }

    private func sortAndTrim() {
        messages.sort { $0.timestampMs > $1.timestampMs }
        if messages.count > maxMessages {
            messages.removeLast(messages.count - maxMessages)
        }
    }

    private func deliverNotification(for message: Message) {
        guard !message.isOutgoing else { return }

        let threadKey = Self.threadKey(for: message.sender)
        let messageSnapshot = message

        DispatchQueue.global(qos: .utility).async {
            let metadata = ContactResolver.notificationMetadata(
                for: messageSnapshot.sender
            )
            let title = metadata.displayName ?? metadata.formattedNumber

            DispatchQueue.main.async {
                // Contact lookup can take a moment. Re-check the visible thread
                // before presenting so a message received while this conversation
                // is already open never creates a redundant banner.
                let controller = SMSController.shared
                guard !(controller.applicationIsActive &&
                        controller.activeThreadKey == threadKey) else {
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = title.isEmpty ? messageSnapshot.sender : title
                content.body = messageSnapshot.body
                content.sound = .default
                content.threadIdentifier = "j6-sms-\(threadKey)"
                content.userInfo = [
                    "smsID": messageSnapshot.id,
                    "sender": messageSnapshot.sender,
                    "threadKey": threadKey
                ]

                if let otp = messageSnapshot.otpCode {
                    content.subtitle = "Verification code: \(otp)"
                    content.categoryIdentifier = J6NotificationDelegate.otpCategoryID
                    content.userInfo["otpCode"] = otp
                } else {
                    content.categoryIdentifier = J6NotificationDelegate.smsCategoryID
                }

                Task {
                    let request = UNNotificationRequest(
                        identifier: "j6-sms-\(messageSnapshot.id)",
                        content: content,
                        trigger: nil
                    )
                    do {
                        try await UNUserNotificationCenter.current().add(request)
                    } catch {
                        DiagnosticLog.active?.log(
                            "SMS",
                            "notification add_failed error=\(error.localizedDescription)"
                        )
                    }
                }
            }
        }
    }

    private func removeDeliveredNotifications(forThreadKey threadKey: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let identifiers = notifications.compactMap { notification -> String? in
                let value = notification.request.content.userInfo["threadKey"] as? String
                return value == threadKey ? notification.request.identifier : nil
            }
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: identifiers
            )
        }
    }

    private func updateBadge() {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        }
    }

    private func persistAsync(
        completion: ((Bool) -> Void)? = nil
    ) {
        let snapshot = messages
        let url = Self.storageURL
        storageQueue.async {
            let success: Bool
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
                success = true
            } catch {
                success = false
            }
            if let completion {
                DispatchQueue.main.async {
                    completion(success)
                }
            }
        }
    }

    private static var storageURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("J6Handset", isDirectory: true)
            .appendingPathComponent("sms.json")
    }

    private static func loadMessages() -> [Message] {
        let url = storageURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Message].self, from: data)
        else {
            return []
        }

        return decoded.sorted { $0.timestampMs > $1.timestampMs }
    }

    private static func extractOTP(from body: String) -> String? {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let patterns = [
            #"\b\d{4,8}\b"#,
            #"(?i)(?:otp|code|verification)[^\d]{0,10}(\d{4,8})"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            if let match = regex.firstMatch(in: body, options: [], range: range) {
                let captureRange = match.range(at: match.numberOfRanges > 1 ? 1 : 0)
                if let swiftRange = Range(captureRange, in: body) {
                    return String(body[swiftRange])
                }
            }
        }

        return nil
    }
}
