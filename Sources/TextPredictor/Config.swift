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
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        let line = "[\(Date().ISO8601Format())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
