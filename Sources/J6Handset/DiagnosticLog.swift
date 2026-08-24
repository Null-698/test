import Foundation
import UIKit

/// Opt-in production diagnostic recorder for call/audio troubleshooting.
///
/// Diagnostics are disabled by default. While disabled, no live diagnostic file
/// is created and production call sites do not invoke `log(...)`. When the user explicitly
/// enables diagnostics, a fresh live file is opened and event-level evidence is
/// recorded until diagnostics are disabled again.
final class DiagnosticLog: @unchecked Sendable {
    struct SnapshotFile {
        let url: URL
        let text: String
    }

    static let shared = DiagnosticLog()

    /// Fast optional sink used by production call sites. When diagnostics are
    /// disabled, optional chaining prevents both `log(...)` invocation and
    /// evaluation of interpolated log-message arguments.
    static var active: DiagnosticLog? {
        shared.isEnabled() ? shared : nil
    }

    private static let enabledDefaultsKey = "J6DiagnosticLoggingEnabled"

    private let queue = DispatchQueue(label: "J6Handset.DiagnosticLog")
    private let stateLock = NSLock()
    private let startUptimeNS = DispatchTime.now().uptimeNanoseconds
    private let formatter: DateFormatter

    private var enabled = false
    private var liveURL: URL?
    private var fileHandle: FileHandle?

    private init() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        self.formatter = formatter

        // New production behavior: diagnostics are opt-in. This key did not
        // exist in previous builds, therefore upgraded installations also start
        // with logging disabled unless the user explicitly enables it.
        enabled = UserDefaults.standard.bool(
            forKey: Self.enabledDefaultsKey
        )

        if enabled {
            queue.sync {
                openLiveFileLocked()
            }
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    func isEnabled() -> Bool {
        stateLock.lock()
        let value = enabled
        stateLock.unlock()
        return value
    }

    func setEnabled(_ newValue: Bool) {
        stateLock.lock()
        let changed = enabled != newValue
        enabled = newValue
        stateLock.unlock()

        UserDefaults.standard.set(
            newValue,
            forKey: Self.enabledDefaultsKey
        )

        guard changed else { return }

        queue.sync {
            if newValue {
                openLiveFileLocked()
            } else {
                closeLiveFileLocked()
            }
        }
    }

    func log(_ category: String, _ message: String) {
        let now = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        let elapsedMS = Double(uptime &- startUptimeNS) / 1_000_000.0

        queue.async { [weak self] in
            guard let self, self.fileHandle != nil else {
                return
            }

            let line = String(
                format: "%@  +%010.1fms  [%@] %@\n",
                self.formatter.string(from: now),
                elapsedMS,
                category,
                message
            )

            guard let data = line.data(using: .utf8) else { return }
            do {
                try self.fileHandle?.write(contentsOf: data)
            } catch {
                // Diagnostics must never interfere with call audio.
            }
        }
    }

    func snapshot(reason: String) -> SnapshotFile? {
        guard isEnabled() else { return nil }

        return queue.sync {
            guard isEnabled(), let liveURL, fileHandle != nil else {
                return nil
            }

            do {
                try fileHandle?.synchronize()

                let docs = liveURL.deletingLastPathComponent()
                let stamp = DiagnosticLog.fileStamp(Date())
                let name = "J6AudioDebug-\(reason)-\(stamp).txt"
                let destination = docs.appendingPathComponent(name)

                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: liveURL, to: destination)

                var text = try String(
                    contentsOf: destination,
                    encoding: .utf8
                )
                text += "\n--- SNAPSHOT ---\nreason=\(reason)\nsource=\(liveURL.lastPathComponent)\ncreated=\(formatter.string(from: Date()))\n"
                try text.write(
                    to: destination,
                    atomically: true,
                    encoding: .utf8
                )

                return SnapshotFile(url: destination, text: text)
            } catch {
                return nil
            }
        }
    }

    func liveFilename() -> String {
        guard isEnabled() else { return "Disabled" }
        return queue.sync {
            liveURL?.lastPathComponent ?? "Starting"
        }
    }

    private func openLiveFileLocked() {
        guard fileHandle == nil else { return }

        let docs = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!

        try? FileManager.default.createDirectory(
            at: docs,
            withIntermediateDirectories: true
        )
        DiagnosticLog.pruneOldDiagnostics(in: docs)

        let stamp = DiagnosticLog.fileStamp(Date())
        let url = docs.appendingPathComponent(
            "J6AudioDebug-LIVE-\(stamp).txt"
        )

        FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        )
        liveURL = url
        fileHandle = try? FileHandle(forWritingTo: url)

        guard fileHandle != nil else {
            liveURL = nil
            stateLock.lock()
            enabled = false
            stateLock.unlock()
            UserDefaults.standard.set(
                false,
                forKey: Self.enabledDefaultsKey
            )
            return
        }

        writeHeaderLocked()
    }

    private func closeLiveFileLocked() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        liveURL = nil
    }

    private func writeHeaderLocked() {
        guard let fileHandle, let liveURL else { return }

        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        let bundleID = Bundle.main.bundleIdentifier ?? "?"

        let now = Date()
        let header = [
            "\(formatter.string(from: now))  [APP] logger_started live=\(liveURL.lastPathComponent)",
            "\(formatter.string(from: now))  [APP] device=\(UIDevice.current.model) ios=\(UIDevice.current.systemVersion) app=\(appVersion) build=\(appBuild) bundle=\(bundleID)"
        ].joined(separator: "\n") + "\n"

        guard let data = header.data(using: .utf8) else { return }
        try? fileHandle.write(contentsOf: data)
    }


    private static func pruneOldDiagnostics(in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let diagnostics = files.filter {
            $0.lastPathComponent.hasPrefix("J6AudioDebug-") ||
            $0.lastPathComponent.hasPrefix("J6CallDiagnostics-")
        }

        let sorted = diagnostics.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            return left > right
        }

        for stale in sorted.dropFirst(6) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
