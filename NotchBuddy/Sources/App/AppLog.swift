import Foundation
import Darwin

// MARK: - Shared diagnostic log helpers

/// Escapes ASCII control characters so log lines can't inject terminal sequences.
func escapedForLog(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return s }
    return s.unicodeScalars.map { sc -> String in
        let v = sc.value
        return (v < 0x20 || v == 0x7F) ? "\\u\(String(format: "%04X", v))" : String(sc)
    }.joined()
}

/// Appends one timestamped line to `~/Library/Logs/NotchBuddy/<fileName>`. Callable from any
/// thread: the line is timestamped now and written later on the log queue (see AppLog).
func appendAppLog(_ fileName: String, _ message: String,
                  timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {
    AppLog.shared.append(fileName, message, timestampFormat: timestampFormat)
}

/// Writes the diagnostic logs on one serial background queue, so a hook event never waits
/// for the disk on the main thread.
/// - The log directory is created at mode 0700, once.
/// - Each log file is opened once (O_APPEND) and kept open; it is set to mode 0600 when opened.
/// - A file is rotated (emptied, then written from the new line) when it reaches `maxBytes`.
///   The size comes from the open file itself, so lines written by another process count,
///   and a file deleted behind our back is recreated.
/// - `flush()` waits for every pending line; the app calls it when it quits.
final class AppLog: @unchecked Sendable {
    static let shared = AppLog(directory: defaultDirectory)

    static var defaultDirectory: URL { AppPaths.logsDirectory }

    static let defaultMaxBytes = 1_048_576 // 1 MB

    let directory: URL
    let maxBytes: Int
    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.log", qos: .utility)

    // Touched only on `queue`.
    private var directoryReady = false
    private var handles: [String: FileHandle] = [:]
    private var formatters: [String: DateFormatter] = [:]

    init(directory: URL, maxBytes: Int = AppLog.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    func append(_ fileName: String, _ message: String, timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {
        let date = Date()
        queue.async { [self] in
            write(fileName, message: message, date: date, timestampFormat: timestampFormat)
        }
    }

    /// Returns once every line appended before the call is written.
    func flush() {
        queue.sync {}
    }

    // MARK: On the queue

    private func write(_ fileName: String, message: String, date: Date, timestampFormat: String) {
        let line = "\(formatter(timestampFormat).string(from: date)) \(escapedForLog(message))\n"
        guard let data = line.data(using: .utf8), var handle = handle(for: fileName) else { return }
        var info = stat()
        if fstat(handle.fileDescriptor, &info) == 0 {
            if info.st_nlink == 0 {
                // Deleted (or rotated) by someone else: start a new file.
                guard let reopened = reopen(fileName) else { return }
                handle = reopened
            } else if info.st_size >= off_t(maxBytes) {
                // Rotate: the new file starts with this line.
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
                guard let reopened = reopen(fileName) else { return }
                handle = reopened
            }
        }
        try? handle.write(contentsOf: data)
    }

    private func formatter(_ format: String) -> DateFormatter {
        if let f = formatters[format] { return f }
        let f = DateFormatter()
        f.dateFormat = format
        formatters[format] = f
        return f
    }

    private func handle(for fileName: String) -> FileHandle? {
        if let h = handles[fileName] { return h }
        return reopen(fileName)
    }

    private func reopen(_ fileName: String) -> FileHandle? {
        if let old = handles.removeValue(forKey: fileName) { try? old.close() }
        let path = directory.appendingPathComponent(fileName).path
        var fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        if fd < 0 {
            // The directory may be missing (first line, or deleted while running).
            directoryReady = false
            prepareDirectory()
            fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        } else {
            prepareDirectory()
        }
        guard fd >= 0 else { return nil }
        fchmod(fd, 0o600)
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handles[fileName] = h
        return h
    }

    private func prepareDirectory() {
        guard !directoryReady else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700 as NSNumber])
        try? fm.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: directory.path)
        directoryReady = fm.fileExists(atPath: directory.path)
    }
}
