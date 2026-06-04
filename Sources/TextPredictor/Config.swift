// Config.swift — Global configuration for TextPredictor.
//
// M1A: single allowlist controlling which apps TextPredictor activates in.
// Default: all apps (["*"]). Set to a specific set of bundle identifiers
// to restrict to known-good apps.

import Foundation

enum TextPredictorConfig {
    /// Bundle identifiers of apps TextPredictor activates in.
    /// Use ["*"] to allow all apps, or a specific set like:
    ///   ["com.apple.Notes", "com.microsoft.VSCode", "com.slack.Slack"]
    static let allowedApps: Set<String> = ["*"]
}
