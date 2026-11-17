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
///
/// ## Suppression
/// A `// retainkit:ignore` comment silences issues on one line:
/// - on a line of its own, it applies to the next line
/// - trailing some code, it applies to that same line
///
/// Only real comments count; the text inside a string literal does not.
public final class DetectionEngine {

    static let suppressionMarker = "retainkit:ignore"

    public init() {}

    // MARK: - Public API

    /// Analyse a single source file.
    /// - Parameters:
    ///   - filePath: Absolute path — used for issue location reporting.
    ///   - source: Swift source code string.
    /// - Returns: All detected issues, sorted by severity then line number.
    public func analyze(filePath: String, source: String) -> FileScanResult {
        let start = Date()
        let scan = scanFile(filePath: filePath, source: source)

        scan.graph.detectCycles()

        return FileScanResult(
            filePath: filePath,
            issues: Self.finalize(scan.issues + scan.graph.issues, context: scan.context),
            scanDuration: Date().timeIntervalSince(start)
        )
    }

    /// Analyse every Swift file under a directory path.
    ///
    /// Reference cycles are detected across the whole directory, so a cycle
    /// between classes in different files is reported.
    ///
    /// A file that cannot be read (missing permissions, not UTF-8) is passed to
    /// `onFileError` and skipped; the rest of the directory is still scanned.
    ///
    /// - Parameters:
    ///   - directoryPath: Root directory to scan.
    ///   - excluding: Patterns for files and directories to skip, relative to
    ///     `directoryPath`. See `ExcludeMatcher` for the syntax. Defaults to
    ///     `ScanConfiguration.defaultExcludes`; pass `[]` to scan everything.
    ///   - onFileError: Called once per unreadable file. Defaults to a line on stderr.
    /// - Returns: Results per readable file, in alphabetical order.
    public func analyzeDirectory(
        _ directoryPath: String,
        excluding excludePatterns: [String] = ScanConfiguration.defaultExcludes,
        onFileError: (_ filePath: String, _ error: Error) -> Void = DetectionEngine.reportFileError
    ) throws -> [FileScanResult] {
        let url = URL(fileURLWithPath: directoryPath)
        let files = try swiftFiles(under: url, excluding: ExcludeMatcher(patterns: excludePatterns))

        var scans: [(scan: FileScan, start: Date)] = []
        for fileURL in files {
            let start = Date()
            do {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                scans.append((scanFile(filePath: fileURL.path, source: source), start))
            } catch {
                onFileError(fileURL.path, error)
            }
        }

        // One graph for the whole directory: cycles usually cross files.
        var cycleIssues: [String: [LeakIssue]] = [:]
        if let combined = scans.first?.scan.graph {
            for entry in scans.dropFirst() { combined.merge(entry.scan.graph) }
            combined.detectCycles()
            cycleIssues = Dictionary(grouping: combined.issues, by: \.filePath)
        }

        return scans.map { entry in
            let path = entry.scan.context.filePath
            return FileScanResult(
                filePath: path,
                issues: Self.finalize(
                    entry.scan.issues + (cycleIssues[path] ?? []),
                    context: entry.scan.context
                ),
                scanDuration: Date().timeIntervalSince(entry.start)
            )
        }
    }

    /// Default `onFileError` handler: one line on stderr.
    public static func reportFileError(filePath: String, error: Error) {
        let message = "retainkit: skipped \(filePath): \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
    }

    // MARK: - Per-file Scan

    /// One file's visitor output, before cycle detection and filtering.
    struct FileScan {
        let context: SourceContext
        /// Issues from the closure, timer and property visitors.
        let issues: [LeakIssue]
        /// This file's classes and edges; cycles are not detected yet.
        let graph: ReferenceGraph
    }

    /// Parses `source` once and runs every visitor over the same tree.
    func scanFile(filePath: String, source: String) -> FileScan {
        let context = SourceContext(filePath: filePath, source: source)

        let closureVisitor  = ClosureVisitor(context: context)
        let timerVisitor    = TimerVisitor(context: context)
        let propertyVisitor = PropertyVisitor(context: context)
        let referenceGraph  = ReferenceGraph(context: context)

        closureVisitor.walk(context.tree)
        timerVisitor.walk(context.tree)
        propertyVisitor.walk(context.tree)
        referenceGraph.walk(context.tree)

        return FileScan(
            context: context,
            issues: closureVisitor.issues + timerVisitor.issues + propertyVisitor.issues,
            graph: referenceGraph
        )
    }

    // MARK: - Post-processing

    /// Deduplicates, drops suppressed lines, and sorts by severity then line.
    static func finalize(_ issues: [LeakIssue], context: SourceContext) -> [LeakIssue] {
        var seen = Set<LeakIssue>()
        let suppressed = suppressedLines(in: context)

        return issues
            .filter { seen.insert($0).inserted }
            .filter { !suppressed.contains($0.line) }
            .sorted {
                if $0.severity != $1.severity { return $0.severity.rank < $1.severity.rank }
                return $0.line < $1.line
            }
    }

    /// Lines silenced by a `// retainkit:ignore` comment.
    ///
    /// Comments are read from the syntax tree's trivia, so the marker inside a
    /// string literal is not a suppression.
    static func suppressedLines(in context: SourceContext) -> Set<Int> {
        var lines = Set<Int>()

        func collect(_ trivia: Trivia, startingAt start: AbsolutePosition) {
            var position = start
            for piece in trivia {
                defer { position += piece.sourceLength }

                let text: String
                switch piece {
                case .lineComment(let comment), .blockComment(let comment):
                    text = comment
                default:
                    continue
                }
                guard text.contains(suppressionMarker) else { continue }

                let line = context.locationConverter.location(for: position).line
                let lineText = line <= context.sourceLines.count
                    ? context.sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
                    : ""
                // A comment that starts its line applies to the next line;
                // one that trails code applies to its own.
                let startsLine = lineText.hasPrefix("//") || lineText.hasPrefix("/*")
                lines.insert(startsLine ? line + 1 : line)
            }
        }

        for token in context.tree.tokens(viewMode: .sourceAccurate) {
            collect(token.leadingTrivia, startingAt: token.position)
            collect(token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia)
        }
        return lines
    }

    // MARK: - Private

    private func swiftFiles(under root: URL, excluding matcher: ExcludeMatcher) throws -> [URL] {
        // Relative URLs give the path below the scan root directly. Comparing
        // absolute paths instead breaks when the root goes through a symlink
        // (/var → /private/var), because the enumerator resolves it.
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .producesRelativePathURLs]
        ) else { return [] }

        var files: [URL] = []

        for case let url as URL in enumerator {
            if matcher.excludes(url.relativePath) {
                // Don't walk into an excluded directory at all.
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "swift",
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                files.append(root.appendingPathComponent(url.relativePath))
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
