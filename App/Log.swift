import Foundation

/// Appends a line to ~/Library/Application Support/XTBBar/log.txt. Never pass secrets here.
enum Log {
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("XTBBar/log.txt")

    static func write(_ message: String) {
        let line = Data("\(Date().formatted(date: .numeric, time: .standard)) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
