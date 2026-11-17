//
//  PublicAPITests.swift
//  RetainKitTests
//

import XCTest
import RetainKitCore  // deliberately not @testable

/// Uses RetainKitCore the way another target would, so anything an embedding
/// app needs stays public.
final class PublicAPITests: XCTestCase {

    func testEngineIsUsableThroughPublicAPIOnly() {
        let source = """
        class Foo {
            func bar() { DispatchQueue.main.async { self.update() } }
            func update() {}
        }
        """
        let result: FileScanResult = DetectionEngine().analyze(filePath: "Foo.swift", source: source)

        XCTAssertEqual(result.filePath, "Foo.swift")
        XCTAssertEqual(result.warningCount, 1)
        XCTAssertEqual(result.criticalCount + result.hintCount, 0)
        XCTAssertEqual(result.autoFixableCount, 1)

        let issue: LeakIssue = result.issues[0]
        XCTAssertEqual(issue.kind, IssueKind.implicitSelf)
        XCTAssertEqual(issue.kind.rawValue, "LC-W002")
        XCTAssertEqual(issue.severity, IssueSeverity.warning)
        XCTAssertEqual(issue.line, 2)
        XCTAssertFalse(issue.message.isEmpty)
        XCTAssertFalse(issue.suggestion.isEmpty)
        XCTAssertFalse(issue.codeSnippet.isEmpty)

        let step: TrailStep = issue.detectionTrail[0]
        XCTAssertEqual(step.step, 1)
        XCTAssertFalse(step.label.isEmpty)
        XCTAssertFalse(step.detail.isEmpty)
    }

    func testDirectoryScanIsUsableThroughPublicAPIOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retainkit-public-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try "class A {}\n".write(to: dir.appendingPathComponent("A.swift"),
                                 atomically: true, encoding: .utf8)

        let results = try DetectionEngine().analyzeDirectory(dir.path) { _, _ in }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].issues.isEmpty)
    }
}
