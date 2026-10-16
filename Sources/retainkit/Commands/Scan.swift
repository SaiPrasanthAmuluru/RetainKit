//
//  Scan.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import ArgumentParser
import Foundation

/// Scans a Swift file or project directory for memory leaks.
struct Scan: ParsableCommand {

    static let configuration = CommandConfiguration(
        abstract: "Scan a Swift project for memory leaks."
    )

    // MARK: - Arguments

    @Argument(help: "Path to a Swift file or project directory.")
    var path: String

    @Flag(name: .long, help: "Output results as JSON.")
    var json: Bool = false

    @Flag(name: .long, help: "Exit with code 1 if any errors are found.")
    var failOnError: Bool = false

    // MARK: - Run

    mutating func run() throws {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("Path not found: \(path)")
        }

        let engine = DetectionEngine()
        let start = Date()

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        let results: [FileScanResult]

        if isDirectory.boolValue {
            results = try engine.analyzeDirectory(path)
        } else {
            let source = try String(contentsOf: url, encoding: .utf8)
            results = [engine.analyze(filePath: path, source: source)]
        }

        let elapsed = Date().timeIntervalSince(start)
        let allIssues = results.flatMap { $0.issues }

        if json {
            printJSON(results: results)
        } else {
            printHuman(results: results, elapsed: elapsed)
        }

        if failOnError && allIssues.contains(where: { $0.severity == .error }) {
            throw ExitCode(1)
        }
    }

    // MARK: - Output

    private func printHuman(results: [FileScanResult], elapsed: TimeInterval) {
        let allIssues  = results.flatMap { $0.issues }
        let fileCount  = results.filter { !$0.issues.isEmpty }.count
        let critical   = allIssues.filter { $0.severity == .error   }.count
        let warnings   = allIssues.filter { $0.severity == .warning  }.count
        let hints      = allIssues.filter { $0.severity == .hint     }.count
        let autoFix    = allIssues.filter { $0.isAutoFixable }.count
        let totalFiles = results.count

        print("scanned \(totalFiles) files in \(String(format: "%.1f", elapsed))s")

        if allIssues.isEmpty {
            print("✓ No issues found")
            return
        }

        print("\(critical) critical  ·  \(warnings) warnings  ·  \(hints) hints")
        if autoFix > 0 { print("✓ \(autoFix) auto-fixable") }
        print("")

        for result in results where !result.issues.isEmpty {
            print("── \(result.filePath)")
            for issue in result.issues {
                let icon = issue.severity == .error ? "●" : issue.severity == .warning ? "▲" : "◆"
                print("   \(icon) \(issue.kind.rawValue) · :\(issue.line)")
                print("     \(issue.message)")
                print("     \(issue.codeSnippet)")
                print("     💡 \(issue.suggestion)")
                print("")
            }
        }
    }

    private func printJSON(results: [FileScanResult]) {
        // Simple JSON output without Codable for now
        var output: [[String: Any]] = []

        for result in results {
            for issue in result.issues {
                output.append([
                    "kind":       issue.kind.rawValue,
                    "severity":   issue.severity.rawValue,
                    "file":       issue.filePath,
                    "line":       issue.line,
                    "column":     issue.column,
                    "message":    issue.message,
                    "suggestion": issue.suggestion
                ])
            }
        }

        if let data = try? JSONSerialization.data(
            withJSONObject: output,
            options: .prettyPrinted
        ),
        let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
