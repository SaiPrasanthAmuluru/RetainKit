//
//  DetectionEngine.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Scan Result

/// The complete output of scanning one file.
public struct FileScanResult: Sendable {
    public let filePath: String
    public let issues: [LeakIssue]
    public let scanDuration: TimeInterval

    public var criticalCount: Int  { issues.filter { $0.severity == .error   }.count }
    public var warningCount: Int   { issues.filter { $0.severity == .warning  }.count }
    public var hintCount: Int      { issues.filter { $0.severity == .hint     }.count }
    public var autoFixableCount: Int { issues.filter { $0.isAutoFixable }.count }
}

// MARK: - Detection Engine

/// Orchestrates all visitors over a Swift source file and
/// returns a deduplicated, severity-sorted list of issues.
public final class DetectionEngine {

    public init() {}

    // MARK: - Public API

    /// Analyse a single source file.
    /// - Parameters:
    ///   - filePath: Absolute path — used for issue location reporting.
    ///   - source: Swift source code string.
    /// - Returns: All detected issues, sorted by severity then line number.
    public func analyze(filePath: String, source: String) -> FileScanResult {
        let start = Date()
        let tree = Parser.parse(source: source)

        let closureVisitor  = ClosureVisitor(filePath: filePath, source: source)
        let timerVisitor    = TimerVisitor(filePath: filePath, source: source)
        let propertyVisitor = PropertyVisitor(filePath: filePath, source: source)
        let referenceGraph  = ReferenceGraph(filePath: filePath, source: source)

        closureVisitor.walk(tree)
        timerVisitor.walk(tree)
        propertyVisitor.walk(tree)
        referenceGraph.walk(tree)
        referenceGraph.detectCycles()

        // Merge and deduplicate
        var seen = Set<LeakIssue>()
        let allIssues = (
            closureVisitor.issues +
            timerVisitor.issues +
            propertyVisitor.issues +
            referenceGraph.issues
        ).filter { seen.insert($0).inserted }

        // Sort: severity first, then line number
        let sorted = allIssues.sorted {
            if $0.severity != $1.severity { return $0.severity < $1.severity }
            return $0.line < $1.line
        }

        // Remove lines suppressed with: // retainkit:ignore
        let sourceLines = source.components(separatedBy: .newlines)
        let suppressedLines = Set(
            sourceLines.enumerated().compactMap { index, line -> Int? in
                // Comment on line N suppresses the issue on line N+1
                line.trimmingCharacters(in: .whitespaces)
                    .contains("retainkit:ignore") ? index + 2 : nil
            }
        )

        let filtered = sorted.filter { !suppressedLines.contains($0.line) }

        return FileScanResult(
            filePath: filePath,
            issues: filtered,
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    /// Analyse every Swift file under a directory path.
    /// - Parameter directoryPath: Root directory to scan.
    /// - Returns: Results per file, in alphabetical order.
    public func analyzeDirectory(_ directoryPath: String) throws -> [FileScanResult] {
        let url = URL(fileURLWithPath: directoryPath)
        let files = try swiftFiles(under: url)

        return try files.map { fileURL in
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            return analyze(filePath: fileURL.path, source: source)
        }
    }

    // MARK: - Private

    private func swiftFiles(under url: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
