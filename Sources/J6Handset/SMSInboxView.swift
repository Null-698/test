import SwiftUI
import UIKit

struct SMSInboxView: View {
    @EnvironmentObject private var sms: SMSController
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var contacts: ContactResolver
    @Environment(\.displayScale) private var displayScale

    @State private var composeRequest: SMSComposeRequest?
    @State private var selectedThreadKey: String?
    @Namespace private var composeTransition

    private let composeTransitionID = "new-sms-compose"

    private var threads: [SMSThreadSummary] {
        var buckets: [String: [SMSController.Message]] = [:]
        var newestParticipant: [String: (timestamp: Int64, raw: String)] = [:]

        for message in sms.messages {
            let key = SMSController.threadKey(for: message.sender)
            buckets[key, default: []].append(message)

            if newestParticipant[key] == nil ||
               message.timestampMs > newestParticipant[key]!.timestamp {
                newestParticipant[key] = (message.timestampMs, message.sender)
            }
        }

        return buckets.compactMap { key, items in
            guard let latest = items.max(by: { $0.timestampMs < $1.timestampMs }) else {
                return nil
            }

            return SMSThreadSummary(
                id: key,
                participant: newestParticipant[key]?.raw ?? latest.sender,
                messages: items.sorted(by: { $0.timestampMs < $1.timestampMs }),
                latest: latest,
                unreadCount: items.reduce(into: 0) { count, message in
                    if !message.isOutgoing && !message.isRead {
                        count += 1
                    }
                }
            )
        }
        .sorted { $0.latest.timestampMs > $1.latest.timestampMs }
    }

    var body: some View {
        let displayedThreads = threads

        VStack(spacing: 0) {
            messagesHeader
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 22)

            List {
                if displayedThreads.isEmpty {
                    ContentUnavailableView(
                        "No Messages",
                        systemImage: "message"
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(displayedThreads.enumerated()), id: \.element.id) { index, thread in
                        Button {
                            selectedThreadKey = thread.id
                        } label: {
                            SMSThreadRow(thread: thread)
                                .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            if index < displayedThreads.count - 1 {
                                Rectangle()
                                    .fill(Color(uiColor: .separator))
                                    .frame(height: 1.0 / max(displayScale, 1.0))
                                    .padding(.leading, 62)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                sms.deleteThread(thread.id)
                            } label: {
                                Label("Delete", systemImage: "trash.fill")
                            }
                            .tint(.red)
                        }
                        .listRowSeparator(.hidden)
                        .listRowInsets(
                            EdgeInsets(
                                top: 0,
                                leading: 16,
                                bottom: 0,
                                trailing: 16
                            )
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $composeRequest) { request in
            SMSComposeView(initialRecipient: request.recipient)
                .environmentObject(sms)
                .environmentObject(ble)
                .environmentObject(contacts)
                .navigationTransition(
                    .zoom(
                        sourceID: composeTransitionID,
                        in: composeTransition
                    )
                )
        }
        .navigationDestination(item: $selectedThreadKey) { threadKey in
            if let thread = displayedThreads.first(where: { $0.id == threadKey }) {
                SMSConversationView(thread: thread)
                    .environmentObject(sms)
                    .environmentObject(ble)
                    .environmentObject(contacts)
            } else {
                ContentUnavailableView(
                    "Conversation unavailable",
                    systemImage: "message.badge",
                    description: Text("This conversation was deleted.")
                )
            }
        }
        .onAppear {
            sms.requestNotificationPermissionIfNeeded()
            sms.refreshNotificationStatus()
            contacts.requestAccessIfNeeded()
            openRequestedThreadIfNeeded()
            openRequestedComposerIfNeeded()
            if ble.isConnected {
                ble.syncSMS()
            }
        }
        .onChange(of: sms.requestedThreadKey) { _, _ in
            openRequestedThreadIfNeeded()
        }
        .onChange(of: sms.requestedComposeRecipient) { _, _ in
            openRequestedComposerIfNeeded()
        }
        .refreshable {
            if ble.isConnected {
                ble.syncSMS()
            }
        }
    }

    private var messagesHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Messages")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Button {
                composeRequest = SMSComposeRequest(recipient: "")
            } label: {
                Image(systemName: "square.and.pencil")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(AppTheme.tint)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44, alignment: .center)
                    .contentShape(Circle())
                    .glassEffect(.regular, in: .circle)
                    .matchedTransitionSource(
                        id: composeTransitionID,
                        in: composeTransition
                    )
            }
            .buttonStyle(.plain)
            .tint(AppTheme.tint)
            .accessibilityLabel("New SMS")
        }
        .frame(maxWidth: .infinity)
    }

    private func openRequestedThreadIfNeeded() {
        guard let key = sms.requestedThreadKey,
              threads.contains(where: { $0.id == key }) else { return }
        selectedThreadKey = key
        DispatchQueue.main.async {
            sms.consumeOpenThreadRequest(key)
        }
    }

    private func openRequestedComposerIfNeeded() {
        guard let recipient = sms.requestedComposeRecipient else { return }
        composeRequest = SMSComposeRequest(recipient: recipient)
        DispatchQueue.main.async {
            sms.consumeComposeRequest(recipient)
        }
    }
}

private struct SMSComposeRequest: Identifiable {
    let id = UUID()
    let recipient: String
}

private struct SMSThreadSummary: Identifiable {
    let id: String
    let participant: String
    let messages: [SMSController.Message]
    let latest: SMSController.Message
    let unreadCount: Int
}

private struct ParticipantPresentation: Equatable {
    let title: String
    let subtitle: String?
    let initials: String
    let thumbnailData: Data?
    let avatarCacheKey: String
}

private struct SMSThreadRow: View {
    @EnvironmentObject private var contacts: ContactResolver
    let thread: SMSThreadSummary
    @State private var presentation: ParticipantPresentation

    init(thread: SMSThreadSummary) {
        self.thread = thread
        let fallbackTitle = thread.participant.trimmingCharacters(in: .whitespacesAndNewlines)
        _presentation = State(initialValue: ParticipantPresentation(
            title: fallbackTitle,
            subtitle: nil,
            initials: Self.initials(from: fallbackTitle),
            thumbnailData: nil,
            avatarCacheKey: "thread:\(thread.id)"
        ))
    }

    var body: some View {
        HStack(spacing: 14) {
            ContactAvatarView(
                initials: presentation.initials,
                imageData: presentation.thumbnailData,
                cacheKey: presentation.avatarCacheKey
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(threadDate(thread.latest.date))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(thread.latest.body)
                    .font(thread.unreadCount > 0 ? .body.weight(.semibold) : .body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if thread.unreadCount > 0 {
                Text("\(thread.unreadCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue))
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(thread.id)|\(contacts.canReadContacts)|\(contacts.contactsRevision)") {
            await resolveContact()
        }
    }

    private var subtitleText: String? {
        if let subtitle = presentation.subtitle,
           !subtitle.isEmpty,
           subtitle != presentation.title {
            return subtitle
        }

        if thread.latest.isOutgoing {
            return deliveryLabel(thread.latest.effectiveDeliveryStatus)
        }

        return nil
    }

    private func resolveContact() async {
        let resolved = await contacts.resolve(number: thread.participant)
        presentation = ParticipantPresentation(
            title: resolved.displayName ?? resolved.formattedNumber,
            subtitle: resolved.displayName == nil ? nil : resolved.formattedNumber,
            initials: Self.initials(from: resolved.displayName ?? resolved.formattedNumber),
            thumbnailData: resolved.thumbnailImageData,
            avatarCacheKey: resolved.contactIdentifier
                ?? "thread:\(thread.id)"
        )
    }

    private func threadDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month())
        }
        return date.formatted(.dateTime.day().month().year(.twoDigits))
    }

    private func deliveryLabel(_ status: SMSController.DeliveryStatus) -> String? {
        switch status {
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        case .received: return nil
        }
    }

    fileprivate static func initials(from value: String) -> String {
        let parts = value
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            .prefix(2)
        let text = parts.compactMap { $0.first.map(String.init) }.joined()
        return text.isEmpty ? "#" : text.uppercased()
    }
}

private struct SMSConversationView: View {
    @EnvironmentObject private var sms: SMSController
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var contacts: ContactResolver

    let thread: SMSThreadSummary

    @State private var messageText = ""
    @State private var sendError: String?
    @State private var presentation: ParticipantPresentation
    @State private var composerHeight: CGFloat = 40
    @State private var composerFocused = false
    @State private var completedInitialScroll = false

    private static let bottomAnchorID = "sms-conversation-bottom"

    init(thread: SMSThreadSummary) {
        self.thread = thread
        let fallbackTitle = thread.participant.trimmingCharacters(in: .whitespacesAndNewlines)
        _presentation = State(initialValue: ParticipantPresentation(
            title: fallbackTitle,
            subtitle: nil,
            initials: SMSThreadRow.initials(from: fallbackTitle),
            thumbnailData: nil,
            avatarCacheKey: "conversation:\(thread.id)"
        ))
    }

    private var messages: [SMSController.Message] {
        sms.messages
            .filter { SMSController.threadKey(for: $0.sender) == thread.id }
            .sorted(by: { $0.timestampMs < $1.timestampMs })
    }

    var body: some View {
        let displayedMessages = messages

        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                        VStack(spacing: 8) {
                            if shouldShowDayHeader(
                                at: index,
                                in: displayedMessages
                            ) {
                                Text(dayHeader(for: message.date))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, index == 0 ? 8 : 14)
                            }

                            SMSBubbleRow(
                                message: message,
                                showStatus: shouldShowStatus(
                                    for: index,
                                    in: displayedMessages
                                ),
                                onRetry: {
                                    retry(message)
                                },
                                onDelete: {
                                    sms.deleteMessage(message.id)
                                }
                            )
                            .id(message.id)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composerBar
                    .background(Color(uiColor: .systemBackground))
            }
            .task(id: displayedMessages.last?.id) {
                await Task.yield()
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollToBottom(
                    scrollProxy,
                    animated: completedInitialScroll
                )
                completedInitialScroll = true
            }
            .task(id: composerFocused) {
                guard composerFocused else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                scrollToBottom(scrollProxy, animated: false)

                // The safe area finishes moving after focus changes. Re-anchor
                // once more when the keyboard animation has settled.
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                scrollToBottom(scrollProxy, animated: false)
            }
            .onChange(of: composerHeight) { _, _ in
                guard composerFocused else { return }
                scrollToBottom(scrollProxy, animated: false)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(presentation.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = presentation.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .onAppear {
            sms.setActiveThread(thread.id)
        }
        .onDisappear {
            sms.setActiveThread(nil)
        }
        .task(id: "\(thread.id)|\(contacts.canReadContacts)|\(contacts.contactsRevision)") {
            await resolveContact()
            sms.markThreadRead(participantKeys: [thread.id])
        }
        .onChange(of: displayedMessages.count) { _, _ in
            sms.markThreadRead(participantKeys: [thread.id])
        }
    }

    private var composerBar: some View {
        VStack(spacing: 0) {
            if let sendError {
                Text(sendError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 5)
            }

            GlassEffectContainer(spacing: 5) {
                HStack(alignment: .center, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        GrowingSMSComposerTextView(
                            text: $messageText,
                            measuredHeight: $composerHeight,
                            isFocused: $composerFocused
                        )
                        .frame(height: composerHeight)

                        if messageText.isEmpty {
                            Text("Text Message • SMS")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 5)
                                .frame(height: composerHeight, alignment: .center)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        send()
                    } label: {
                        ZStack {
                            // Keep the visible control compact while giving the
                            // button the full 44x44pt iOS touch target.
                            Color.clear
                                .frame(width: 44, height: 44)

                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(canSend ? Color.white : Color.secondary)
                                .frame(width: 29, height: 29)
                                .glassEffect(
                                    .regular
                                        .tint(canSend ? Color.green : Color.clear)
                                        .interactive(),
                                    in: .circle
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send SMS")
                }
                .padding(.leading, 9)
                .padding(.trailing, 5)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 22)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var canSend: Bool {
        ble.isConnected &&
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        messageText.count <= 4_096
    }

    private func send() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID = ble.sendSMS(to: thread.participant, body: text) else {
            sendError = ble.bluetoothStatus
            return
        }

        sms.recordOutgoing(
            requestID: requestID,
            recipient: thread.participant,
            body: text
        )
        messageText = ""
        sendError = nil
    }

    private func retry(_ message: SMSController.Message) {
        guard message.isOutgoing,
              message.effectiveDeliveryStatus == .failed else { return }

        guard let requestID = ble.sendSMS(
            to: message.sender,
            body: message.body
        ) else {
            sendError = ble.bluetoothStatus
            return
        }

        sms.prepareRetry(
            messageID: message.id,
            requestID: requestID
        )
        sendError = nil
    }

    private func resolveContact() async {
        let resolved = await contacts.resolve(number: thread.participant)
        presentation = ParticipantPresentation(
            title: resolved.displayName ?? resolved.formattedNumber,
            subtitle: resolved.displayName == nil ? nil : resolved.formattedNumber,
            initials: SMSThreadRow.initials(from: resolved.displayName ?? resolved.formattedNumber),
            thumbnailData: resolved.thumbnailImageData,
            avatarCacheKey: resolved.contactIdentifier
                ?? "conversation:\(thread.id)"
        )
    }

    private func shouldShowDayHeader(
        at index: Int,
        in messages: [SMSController.Message]
    ) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(messages[index - 1].date, inSameDayAs: messages[index].date)
    }

    private func dayHeader(for date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func shouldShowStatus(
        for index: Int,
        in messages: [SMSController.Message]
    ) -> Bool {
        let message = messages[index]
        guard message.isOutgoing else { return false }
        if message.effectiveDeliveryStatus == .failed { return true }
        if index == messages.indices.last { return true }
        return messages[index + 1].isOutgoing == false
    }

    private func scrollToBottom(
        _ proxy: ScrollViewProxy,
        animated: Bool
    ) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }



}

private struct SMSBubbleRow: View {
    let message: SMSController.Message
    let showStatus: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(
            alignment: message.isOutgoing ? .trailing : .leading,
            spacing: 3
        ) {
            Text(message.body)
                .textSelection(.enabled)
                .font(.body)
                .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            message.isOutgoing
                                ? Color.blue
                                : Color(uiColor: .secondarySystemBackground)
                        )
                )

            HStack(spacing: 5) {
                Text(messageTimestamp(message.date))
                if showStatus,
                   let status = deliveryLabel(message.effectiveDeliveryStatus) {
                    Text("·")
                    Text(status)
                    if message.effectiveDeliveryStatus == .failed {
                        Text("·")
                        Button("Retry") {
                            onRetry()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 3)

            if let otp = message.otpCode, !message.isOutgoing {
                Button {
                    UIPasteboard.general.string = otp
                } label: {
                    Label("Copy code \(otp)", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.glass)
            }
        }
        .padding(message.isOutgoing ? .leading : .trailing, 48)
        .frame(
            maxWidth: .infinity,
            alignment: message.isOutgoing ? .trailing : .leading
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.body
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if let otp = message.otpCode, !message.isOutgoing {
                Button {
                    UIPasteboard.general.string = otp
                } label: {
                    Label("Copy Code", systemImage: "number.square")
                }
            }

            if message.isOutgoing,
               message.effectiveDeliveryStatus == .failed {
                Button {
                    onRetry()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func messageTimestamp(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .day()
                .month(.abbreviated)
                .hour()
                .minute()
        )
    }

    private func deliveryLabel(_ status: SMSController.DeliveryStatus) -> String? {
        switch status {
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        case .received: return nil
        }
    }
}

private struct GrowingSMSComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.layer.backgroundColor = UIColor.clear.cgColor
        textView.isOpaque = false
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.tintColor = .systemGreen
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainer.lineFragmentPadding = 0
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .interactive
        textView.contentInset = .zero
        textView.scrollIndicatorInsets = .zero
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.configureInsets(for: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        // UIKit can briefly restore its default text-view backing color during
        // trait/layout changes. Reassert transparency on every SwiftUI update
        // so the Liquid Glass shell is the only visible composer surface.
        textView.backgroundColor = .clear
        textView.layer.backgroundColor = UIColor.clear.cgColor
        textView.isOpaque = false
        context.coordinator.configureInsets(for: textView)

        if textView.text != text {
            textView.text = text
        }

        context.coordinator.measure(textView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingSMSComposerTextView

        private var measurementGeneration: UInt = 0
        private var lastRequestedHeight: CGFloat = 0
        private let minimumHeight: CGFloat = 40
        private let maximumLines: CGFloat = 6

        init(parent: GrowingSMSComposerTextView) {
            self.parent = parent
        }

        func configureInsets(for textView: UITextView) {
            let lineHeight = textView.font?.lineHeight
                ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let vertical = max(7, (minimumHeight - lineHeight) / 2)
            let desired = UIEdgeInsets(
                top: vertical,
                left: 5,
                bottom: vertical,
                right: 5
            )
            if textView.textContainerInset != desired {
                textView.textContainerInset = desired
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused {
                parent.isFocused = true
            }
            measure(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused {
                parent.isFocused = false
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text {
                parent.text = textView.text
            }

            if textView.text.isEmpty {
                textView.isScrollEnabled = false
                textView.setContentOffset(.zero, animated: false)
            }

            measure(textView)
        }

        func measure(_ textView: UITextView) {
            measurementGeneration &+= 1
            let generation = measurementGeneration

            let width = textView.bounds.width
            guard width > 1 else {
                DispatchQueue.main.async { [weak textView, weak self] in
                    guard let self, let textView,
                          self.measurementGeneration == generation else { return }
                    self.measure(textView)
                }
                return
            }

            configureInsets(for: textView)
            let lineHeight = textView.font?.lineHeight
                ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
            let insets = textView.textContainerInset.top + textView.textContainerInset.bottom
            let maximumHeight = ceil(lineHeight * maximumLines + insets)

            let naturalHeight: CGFloat
            if textView.text.isEmpty {
                naturalHeight = minimumHeight
            } else {
                textView.layoutManager.ensureLayout(for: textView.textContainer)
                naturalHeight = max(
                    minimumHeight,
                    textView.sizeThatFits(
                        CGSize(width: width, height: .greatestFiniteMagnitude)
                    ).height
                )
            }

            let clampedHeight = min(maximumHeight, naturalHeight)
            let shouldScroll = naturalHeight > maximumHeight + 0.5

            if textView.isScrollEnabled != shouldScroll {
                textView.isScrollEnabled = shouldScroll
                if !shouldScroll {
                    textView.setContentOffset(.zero, animated: false)
                }
            }

            guard abs(lastRequestedHeight - clampedHeight) > 0.5 ||
                  abs(parent.measuredHeight - clampedHeight) > 0.75 else {
                return
            }

            lastRequestedHeight = clampedHeight

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.measurementGeneration == generation else { return }

                // There is only one animated value now: the composer's measured
                // height. The ScrollView uses its native .sizeChanges bottom
                // anchor, so no competing scroll animation runs alongside it.
                withAnimation(.smooth(duration: 0.18)) {
                    self.parent.measuredHeight = clampedHeight
                }
            }
        }
    }
}

struct SMSComposeView: View {
    @EnvironmentObject private var sms: SMSController
    @EnvironmentObject private var ble: BLECallController
    @EnvironmentObject private var contacts: ContactResolver
    @Environment(\.dismiss) private var dismiss

    @State private var recipient: String
    @State private var messageText = ""
    @State private var sendError: String?
    @State private var suggestions: [ContactSMSRecipientSuggestion] = []
    @State private var selectedRecipient: ContactSMSRecipientSuggestion?
    @State private var selectedRecipientPhone: String?

    init(initialRecipient: String = "") {
        _recipient = State(initialValue: initialRecipient)
        _selectedRecipient = State(initialValue: nil)
        _selectedRecipientPhone = State(initialValue: nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("To") {
                    if let selectedRecipient {
                        HStack(spacing: 10) {
                            ContactAvatarView(
                                initials: SMSThreadRow.initials(
                                    from: selectedRecipient.displayName
                                ),
                                imageData: selectedRecipient.thumbnailImageData,
                                cacheKey: "compose:\(selectedRecipient.id)",
                                size: 30
                            )

                            Text(selectedRecipient.displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer()

                            Button {
                                clearSelectedRecipient()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(selectedRecipient.displayName)")
                        }
                        .padding(.vertical, 2)
                    } else {
                        TextField("Name or phone number", text: $recipient)
                            .textContentType(.telephoneNumber)
                            .textInputAutocapitalization(.words)
                    }

                    ForEach(suggestions) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                ContactAvatarView(
                                    initials: SMSThreadRow.initials(
                                        from: suggestion.displayName
                                    ),
                                    imageData: suggestion.thumbnailImageData,
                                    cacheKey: "compose:\(suggestion.id)",
                                    size: 36
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text(suggestion.formattedNumber)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Message") {
                    TextEditor(text: $messageText)
                        .frame(minHeight: 140)
                    HStack {
                        Spacer()
                        Text("\(messageText.count) / 4096")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let sendError {
                    Section {
                        Text(sendError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        send()
                    }
                    .disabled(
                        !recipientIsDialable ||
                        messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        messageText.count > 4_096 ||
                        !ble.isConnected
                    )
                }
            }
            .task(id: recipient) {
                await refreshSuggestions()
            }
        }
    }

    private var recipientIsDialable: Bool {
        if selectedRecipientPhone != nil {
            return true
        }

        let value = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.contains(where: { $0.isNumber }) else {
            return false
        }
        return value.allSatisfy { character in
            character.isNumber ||
            character == "+" ||
            character == "*" ||
            character == "#" ||
            character.isWhitespace ||
            "-().".contains(character)
        }
    }

    private func refreshSuggestions() async {
        if selectedRecipient != nil {
            suggestions = []
            return
        }

        let query = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            suggestions = []
            return
        }

        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled,
              recipient.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
            return
        }

        let results = await contacts.smsRecipientSuggestions(matching: query)
        guard !Task.isCancelled,
              recipient.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
            return
        }
        suggestions = results
    }

    private func select(_ suggestion: ContactSMSRecipientSuggestion) {
        selectedRecipient = suggestion
        selectedRecipientPhone = suggestion.phoneNumber
        recipient = ""
        suggestions = []
        sendError = nil
    }

    private func clearSelectedRecipient() {
        selectedRecipient = nil
        selectedRecipientPhone = nil
        recipient = ""
        suggestions = []
        sendError = nil
    }

    private func send() {
        let to = selectedRecipientPhone
            ?? recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestID = ble.sendSMS(to: to, body: text) else {
            sendError = ble.bluetoothStatus
            return
        }

        sms.recordOutgoing(
            requestID: requestID,
            recipient: to,
            body: text
        )
        dismiss()
        DispatchQueue.main.async {
            sms.requestOpenThread(for: to)
        }
    }
}
