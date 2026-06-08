import Foundation

enum TextPredictorConfig {
    /// Bundle identifiers of apps TextPredictor activates in.
    /// Use `["*"]` to allow all apps, or a specific set like:
    ///   `["com.apple.Notes", "com.microsoft.VSCode", "com.slack.Slack"]`
    static let allowedApps: Set<String> = ["*"]

    /// Returns true if the given bundle ID is allowed.
    /// `["*"]` is treated as a wildcard allowing all apps.
    static func isAppAllowed(_ bundleID: String) -> Bool {
        allowedApps == ["*"] || allowedApps.contains(bundleID)
    }

    nonisolated(unsafe) static var debugLogFile: String? = "/tmp/text-predictor-debug.log"

    nonisolated(unsafe) static func debugLog(_ msg: String) {
        guard let path = Self.debugLogFile, !path.isEmpty else { return }
        let line = "[\(Date().ISO8601Format())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data, attributes: nil)
        }
    }
}
