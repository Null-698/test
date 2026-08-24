import SwiftUI

struct RecentsView: View {
    @EnvironmentObject private var history: CallHistoryStore
    @EnvironmentObject private var callKit: CallKitCoordinator
    @EnvironmentObject private var contacts: ContactResolver

    @State private var filter: RecentsFilter = .all

    private var groups: [RecentCallGroup] {
        let entries = history.entries.filter { entry in
            switch filter {
            case .all:
                return true
            case .missed:
                return entry.isMissed
            case .incoming:
                return entry.direction == .incoming
            case .outgoing:
                return entry.direction == .outgoing
            }
        }

        return RecentCallGroup.make(from: entries)
    }

    var body: some View {
        let displayedGroups = groups
        let firstGroupID = displayedGroups.first?.id

        Group {
            if displayedGroups.isEmpty {
                ContentUnavailableView(
                    filter.emptyTitle,
                    systemImage: filter.emptySystemImage
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(displayedGroups) { group in
                        Button {
                            guard group.canCallBack else { return }
                            callKit.startOutgoing(number: group.latest.number)
                        } label: {
                            RecentCallRow(group: group)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(group.id == firstGroupID ? .hidden : .visible, edges: .top)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                history.delete(ids: Set(group.entries.map(\.id)))
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Recents")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(RecentsFilter.allCases) { option in
                            Label(option.title, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .tint(AppTheme.tint)
                .accessibilityLabel("Filter")
            }
        }
        .onAppear {
            contacts.requestAccessIfNeeded()
        }
    }
}

private enum RecentsFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case missed
    case incoming
    case outgoing

    var id: Self { self }

    var title: String {
        switch self {
        case .all:
            return "All Calls"
        case .missed:
            return "Missed"
        case .incoming:
            return "Incoming"
        case .outgoing:
            return "Outgoing"
        }
    }

    var systemImage: String {
        switch self {
        case .all:
            return "phone"
        case .missed:
            return "phone.down"
        case .incoming:
            return "phone.arrow.down.left"
        case .outgoing:
            return "phone.arrow.up.right"
        }
    }

    var emptyTitle: String {
        switch self {
        case .all:
            return "No Recents"
        case .missed:
            return "No Missed Calls"
        case .incoming:
            return "No Incoming Calls"
        case .outgoing:
            return "No Outgoing Calls"
        }
    }

    var emptySystemImage: String {
        switch self {
        case .all:
            return "clock"
        case .missed:
            return "phone.badge.checkmark"
        case .incoming:
            return "phone.arrow.down.left"
        case .outgoing:
            return "phone.arrow.up.right"
        }
    }


}

private struct RecentCallGroup: Identifiable {
    let entries: [CallHistoryStore.Entry]

    var id: UUID { entries[0].id }
    var latest: CallHistoryStore.Entry { entries[0] }
    var count: Int { entries.count }
    var canCallBack: Bool {
        let value = latest.number.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "Unknown"
    }

    static func make(
        from entries: [CallHistoryStore.Entry]
    ) -> [RecentCallGroup] {
        let sorted = entries.sorted { $0.endedAt > $1.endedAt }
        var groups: [RecentCallGroup] = []

        for entry in sorted {
            if entry.isMissed,
               let last = groups.last,
               last.latest.isMissed,
               sameNumber(last.latest.number, entry.number),
               abs(last.entries.last!.endedAt.timeIntervalSince(entry.endedAt)) <= 86_400 {
                groups[groups.count - 1] = RecentCallGroup(
                    entries: last.entries + [entry]
                )
            } else {
                groups.append(RecentCallGroup(entries: [entry]))
            }
        }

        return groups
    }

    private static func sameNumber(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ value: String) -> String {
        let digits = value.filter(\.isNumber)
        if !digits.isEmpty { return digits }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct RecentContactPresentation: Equatable {
    let title: String
    let formattedNumber: String
    let thumbnailData: Data?
    let avatarCacheKey: String
}

private struct RecentCallRow: View {
    @EnvironmentObject private var contacts: ContactResolver

    let group: RecentCallGroup
    @State private var presentation: RecentContactPresentation

    init(group: RecentCallGroup) {
        self.group = group
        let fallback = group.latest.number.trimmingCharacters(in: .whitespacesAndNewlines)
        _presentation = State(
            initialValue: RecentContactPresentation(
                title: fallback.isEmpty ? "Unknown" : fallback,
                formattedNumber: fallback,
                thumbnailData: nil,
                avatarCacheKey: "recent:\(group.latest.number)"
            )
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 2) {
                Text(titleText)
                    .foregroundStyle(group.latest.isMissed ? Color.red : Color.primary)
                    .lineLimit(1)

                Text(detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(dateLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
        .task(id: "\(group.latest.id.uuidString)|\(contacts.canReadContacts)|\(contacts.contactsRevision)") {
            await refreshContact()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(group.canCallBack ? "Calls this number" : "Caller number unavailable")
    }

    @ViewBuilder
    private var avatar: some View {
        ContactAvatarView(
            initials: "",
            imageData: presentation.thumbnailData,
            cacheKey: presentation.avatarCacheKey,
            size: 44,
            placeholderStyle: .system
        )
    }

    private var titleText: String {
        if group.count > 1 {
            return "\(presentation.title) (\(group.count))"
        }
        return presentation.title
    }

    private var detailText: String {
        if shouldShowNumber {
            return "\(statusText) · \(presentation.formattedNumber)"
        }
        return statusText
    }

    private var statusText: String {
        if group.latest.isMissed { return "Missed" }
        return group.latest.direction == .incoming ? "Incoming" : "Outgoing"
    }

    private var shouldShowNumber: Bool {
        let title = presentation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = presentation.formattedNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return !number.isEmpty && number != title
    }

    private var dateLabel: String {
        if Calendar.current.isDateInToday(group.latest.endedAt) {
            return group.latest.endedAt.formatted(
                .dateTime.hour().minute()
            )
        }
        if Calendar.current.isDateInYesterday(group.latest.endedAt) {
            return "Yesterday"
        }
        return group.latest.endedAt.formatted(
            .dateTime.month(.abbreviated).day()
        )
    }

    private func refreshContact() async {
        let raw = group.latest.number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty && raw != "Unknown" else {
            presentation = RecentContactPresentation(
                title: "Unknown",
                formattedNumber: "Unknown",
                thumbnailData: nil,
                avatarCacheKey: "recent:unknown"
            )
            return
        }

        let metadata = await contacts.resolve(number: raw)
        let title = metadata.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false)
            ? title!
            : metadata.formattedNumber

        presentation = RecentContactPresentation(
            title: resolvedTitle.isEmpty ? raw : resolvedTitle,
            formattedNumber: metadata.formattedNumber.isEmpty ? raw : metadata.formattedNumber,
            thumbnailData: metadata.thumbnailImageData,
            avatarCacheKey: metadata.contactIdentifier
                ?? "recent:\(metadata.normalizedNumber)"
        )
    }
}
