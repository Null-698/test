import Combine
import Foundation

@MainActor
final class CallHistoryStore: ObservableObject {
    enum Direction: String, Codable, Sendable {
        case incoming
        case outgoing
    }

    enum Outcome: String, Codable, Sendable {
        case completed
        case missed
        case failed
    }

    struct Entry: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date
        let number: String
        let direction: Direction
        let outcome: Outcome
        let connectedAt: Date?

        var duration: TimeInterval {
            guard let connectedAt else { return 0 }
            return max(0, endedAt.timeIntervalSince(connectedAt))
        }

        var isMissed: Bool {
            outcome == .missed
        }
    }

    @Published private(set) var entries: [Entry] = []

    private let storageQueue = DispatchQueue(
        label: "com.regis.j6handset.call-history.storage",
        qos: .utility
    )
    private let maxEntries = 500

    init() {
        entries = Self.loadEntries()
    }

    func record(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        number: String,
        direction: Direction,
        outcome: Outcome,
        connectedAt: Date?
    ) {
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = Entry(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            number: trimmed.isEmpty ? "Unknown" : trimmed,
            direction: direction,
            outcome: outcome,
            connectedAt: connectedAt
        )

        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }

        sortAndTrim()
        persistAsync()
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        persistAsync()
    }

    private func sortAndTrim() {
        entries.sort { $0.endedAt > $1.endedAt }
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    private func persistAsync() {
        let snapshot = entries
        storageQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                let url = Self.storageURL()
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                // Call history must never interfere with call control.
            }
        }
    }

    private static func loadEntries() -> [Entry] {
        do {
            let data = try Data(contentsOf: storageURL())
            return try JSONDecoder().decode([Entry].self, from: data)
                .sorted { $0.endedAt > $1.endedAt }
        } catch {
            return []
        }
    }

    private nonisolated static func storageURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return base
            .appendingPathComponent("J6Handset", isDirectory: true)
            .appendingPathComponent("call-history.json", isDirectory: false)
    }
}
