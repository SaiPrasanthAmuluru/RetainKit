//
//  ScanConfiguration.swift
//  retainkit
//

import Foundation

/// Options for a directory scan, usually read from a `.retainkit.json` file:
///
///     {
///       "exclude": ["Tests", "Generated/*", "*.generated.swift"]
///     }
///
/// Unknown keys are ignored, so a file written for a newer RetainKit still loads.
public struct ScanConfiguration: Codable, Equatable, Sendable {

    /// File name looked up in the scanned directory.
    public static let defaultFileName = ".retainkit.json"

    /// Directories that hold third-party or generated code and are skipped
    /// unless a scan is pointed at them directly. Hidden directories such as
    /// `.build` are always skipped and need no entry here.
    public static let defaultExcludes = ["Pods", "Carthage", "DerivedData"]

    /// Patterns for files and directories to skip. See `ExcludeMatcher`.
    public var exclude: [String]

    public init(exclude: [String] = []) {
        self.exclude = exclude
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exclude = try container.decodeIfPresent([String].self, forKey: .exclude) ?? []
    }

    /// Reads a configuration file.
    /// - Throws: `ScanConfigurationError` if the file is unreadable or not valid.
    public static func load(from url: URL) throws -> ScanConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ScanConfigurationError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(ScanConfiguration.self, from: data)
        } catch {
            throw ScanConfigurationError.invalid(path: url.path, reason: "\(error)")
        }
    }

    /// Reads `.retainkit.json` from `directory`, or returns nil when there is none.
    public static func loadIfPresent(in directory: URL) throws -> ScanConfiguration? {
        let url = directory.appendingPathComponent(defaultFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try load(from: url)
    }
}

public enum ScanConfigurationError: Error, LocalizedError, Equatable {
    case unreadable(path: String, reason: String)
    case invalid(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let path, let reason):
            return "Cannot read configuration \(path): \(reason)"
        case .invalid(let path, let reason):
            return "Invalid configuration \(path): \(reason)"
        }
    }
}

// MARK: - Exclude Matcher

/// Decides whether a path, relative to the scan root, is excluded.
///
/// A pattern without `/` is compared with each path component, so `Tests`
/// skips every directory or file named `Tests` at any depth, and
/// `*.generated.swift` skips matching files anywhere.
///
/// A pattern with `/` is compared with the whole relative path, and also
/// excludes everything beneath a directory it names: `Sources/Legacy` skips
/// that directory, `Sources/*/Mocks` skips `Mocks` one level down.
///
/// `*` matches any run of characters, `?` one character, `[abc]` a set.
/// In a pattern with `/`, `*` also matches across `/`.
public struct ExcludeMatcher: Sendable {

    private let patterns: [String]

    public init(patterns: [String]) {
        // "Tests/" and "./Tests" mean "Tests".
        self.patterns = patterns.compactMap { raw in
            var pattern = raw.trimmingCharacters(in: .whitespaces)
            while pattern.hasPrefix("./") { pattern.removeFirst(2) }
            while pattern.hasSuffix("/") { pattern.removeLast() }
            return pattern.isEmpty ? nil : pattern
        }
    }

    public var isEmpty: Bool { patterns.isEmpty }

    /// - Parameter relativePath: Path below the scan root, e.g. `App/Tests/FooTests.swift`.
    public func excludes(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        return patterns.contains { pattern in
            if pattern.contains("/") {
                return Self.matches(pattern, relativePath)
                    || Self.matches(pattern + "/*", relativePath)
            }
            return components.contains { Self.matches(pattern, $0) }
        }
    }

    private static func matches(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern, string, 0) == 0
    }
}
