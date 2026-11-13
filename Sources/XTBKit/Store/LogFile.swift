import Foundation

/// Appends `line` and a newline to the file at `url`, creating the file and its folder if needed.
public func appendLine(_ line: String, to url: URL) throws {
    let data = Data("\(line)\n".utf8)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let handle = try? FileHandle(forWritingTo: url) else { return try data.write(to: url) }
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}
