//
//  retainkitTests.swift
//  RetainKitTests
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import XCTest
import SwiftParser
import SwiftSyntax
@testable import retainkit

final class RetainKitTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ source: String) -> SourceFileSyntax {
        Parser.parse(source: source)
    }

    // MARK: - IssueSeverity Tests

    func testSeverityOrdering() {
        XCTAssertLessThan(IssueSeverity.error, IssueSeverity.warning)
        XCTAssertLessThan(IssueSeverity.warning, IssueSeverity.hint)
    }

    func testSeveritySortedArray() {
        let unsorted: [IssueSeverity] = [.hint, .error, .warning]
        XCTAssertEqual(unsorted.sorted(), [.error, .warning, .hint])
    }

    // MARK: - IssueKind Tests

    func testAllKindsHaveDisplayName() {
        for kind in IssueKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind.rawValue) has empty displayName")
        }
    }

    func testAllKindsHaveSuggestion() {
        for kind in IssueKind.allCases {
            XCTAssertFalse(kind.suggestion.isEmpty, "\(kind.rawValue) has empty suggestion")
        }
    }

    func testDefaultSeverities() {
        XCTAssertEqual(IssueKind.escapingClosure.defaultSeverity,     .error)
        XCTAssertEqual(IssueKind.storedClosure.defaultSeverity,       .error)
        XCTAssertEqual(IssueKind.uninvalidatedTimer.defaultSeverity,  .error)
        XCTAssertEqual(IssueKind.referenceCycle.defaultSeverity,      .error)
        XCTAssertEqual(IssueKind.implicitSelf.defaultSeverity,        .warning)
        XCTAssertEqual(IssueKind.unremovedObserver.defaultSeverity,   .warning)
        XCTAssertEqual(IssueKind.strongDelegate.defaultSeverity,      .warning)
        XCTAssertEqual(IssueKind.closureInCollection.defaultSeverity, .warning)
    }

    // MARK: - LeakIssue Hashable / Deduplication Tests

    func testLeakIssueDeduplication() {
        let a = LeakIssue(kind: .escapingClosure, filePath: "Foo.swift",
                          line: 10, column: 5,
                          message: "msg", codeSnippet: "code")
        let b = LeakIssue(kind: .escapingClosure, filePath: "Foo.swift",
                          line: 10, column: 5,
                          message: "different message", codeSnippet: "different code")
        XCTAssertEqual(Set([a, b]).count, 1,
                       "Same kind + file + line + column must deduplicate")
    }

    func testLeakIssuesDifferentLinesAreDistinct() {
        let a = LeakIssue(kind: .escapingClosure, filePath: "Foo.swift",
                          line: 10, column: 5, message: "m", codeSnippet: "c")
        let b = LeakIssue(kind: .escapingClosure, filePath: "Foo.swift",
                          line: 11, column: 5, message: "m", codeSnippet: "c")
        XCTAssertEqual(Set([a, b]).count, 2)
    }

    func testLeakIssueUsesCustomSeverityOverDefault() {
        let issue = LeakIssue(kind: .escapingClosure, severity: .hint,
                              filePath: "Foo.swift", line: 1, column: 1,
                              message: "m", codeSnippet: "c")
        XCTAssertEqual(issue.severity, .hint)
    }

    // MARK: - ClosureVisitor Tests

    func testClosureVisitor_detectsImplicitSelf() {
        let source = """
        class Foo {
            func bar() {
                DispatchQueue.main.async {
                    self.update()
                }
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "Should detect implicit self capture")
        XCTAssertEqual(visitor.issues.first?.kind, .implicitSelf)
    }

    func testClosureVisitor_skipsWeakSelf() {
        let source = """
        class Foo {
            func bar() {
                DispatchQueue.main.async { [weak self] in
                    self?.update()
                }
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "[weak self] should not be flagged")
    }

    func testClosureVisitor_skipsUnownedSelf() {
        let source = """
        class Foo {
            func bar() {
                DispatchQueue.main.async { [unowned self] in
                    self.update()
                }
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "[unowned self] should not be flagged")
    }

    func testClosureVisitor_detectsStoredClosure() {
        let source = """
        class Foo {
            var handler: (() -> Void)?
            func setup() {
                handler = { self.update() }
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "Stored closure capturing self should be flagged")
        XCTAssertEqual(visitor.issues.first?.kind, .storedClosure)
    }

    func testClosureVisitor_detectsClosureAppendedToArray() {
        let source = """
        class Foo {
            var callbacks: [() -> Void] = []
            func add() {
                callbacks.append { self.update() }
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "Closure appended to array capturing self should be flagged")
    }

    func testClosureVisitor_doesNotFlagClosureWithoutSelf() {
        let source = """
        class Foo {
            func bar() {
                [1, 2, 3].forEach { item in
                    print(item)
                }
            }
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "Closure without self reference should not be flagged")
    }

    func testClosureVisitor_issueContainsDetectionTrail() {
        let source = """
        class Foo {
            func bar() {
                DispatchQueue.main.async {
                    self.update()
                }
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertEqual(visitor.issues.first?.detectionTrail.count, 5,
                       "Should have 5 trail steps")
    }

    // MARK: - TimerVisitor Tests

    func testTimerVisitor_detectsMissingInvalidate() {
        let source = """
        class Foo {
            var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
        }
        """
        let visitor = TimerVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "Timer without invalidate should be flagged")
        XCTAssertEqual(visitor.issues.first?.kind, .uninvalidatedTimer)
    }

    func testTimerVisitor_skipsWhenDeinitInvalidates() {
        let source = """
        class Foo {
            var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            deinit { timer?.invalidate() }
        }
        """
        let visitor = TimerVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "Timer with invalidate in deinit should not be flagged")
    }

    func testTimerVisitor_detectsMissingRemoveObserver() {
        let source = """
        class Foo {
            func setup() {
                NotificationCenter.default.addObserver(self,
                    selector: #selector(handle),
                    name: NSNotification.Name("test"),
                    object: nil)
            }
            @objc func handle() {}
        }
        """
        let visitor = TimerVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "Observer without removeObserver should be flagged")
        XCTAssertEqual(visitor.issues.first?.kind, .unremovedObserver)
    }

    func testTimerVisitor_skipsWhenObserverRemoved() {
        let source = """
        class Foo {
            func setup() {
                NotificationCenter.default.addObserver(self,
                    selector: #selector(handle),
                    name: NSNotification.Name("test"),
                    object: nil)
            }
            @objc func handle() {}
            deinit { NotificationCenter.default.removeObserver(self) }
        }
        """
        let visitor = TimerVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "Observer removed in deinit should not be flagged")
    }

    // MARK: - PropertyVisitor Tests

    func testPropertyVisitor_detectsStrongDelegate() {
        let source = """
        class Foo {
            func setup(tableView: UITableView) {
                tableView.delegate = self
            }
        }
        """
        let visitor = PropertyVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "delegate = self should be flagged")
        XCTAssertEqual(visitor.issues.first?.kind, .strongDelegate)
    }

    func testPropertyVisitor_detectsStrongDataSource() {
        let source = """
        class Foo {
            func setup(tableView: UITableView) {
                tableView.dataSource = self
            }
        }
        """
        let visitor = PropertyVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.isEmpty,
                       "dataSource = self should be flagged")
    }

    func testPropertyVisitor_doesNotFlagNonDelegateAssignment() {
        let source = """
        class Foo {
            var name: String = ""
            func setup() {
                name = "RetainKit"
            }
        }
        """
        let visitor = PropertyVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "Non-delegate assignment should not be flagged")
    }

    // MARK: - ReferenceGraph Tests

    func testReferenceGraph_detectsTwoNodeCycle() {
        let source = """
        class A {
            var b: B?
        }
        class B {
            var a: A?
        }
        """
        let graph = ReferenceGraph(filePath: "Foo.swift", source: source)
        graph.walk(parse(source))
        graph.detectCycles()
        XCTAssertFalse(graph.issues.isEmpty,
                       "A → B → A should be detected as a cycle")
        XCTAssertEqual(graph.issues.first?.kind, .referenceCycle)
    }

    func testReferenceGraph_detectsThreeNodeCycle() {
        let source = """
        class A { var b: B? }
        class B { var c: C? }
        class C { var a: A? }
        """
        let graph = ReferenceGraph(filePath: "Foo.swift", source: source)
        graph.walk(parse(source))
        graph.detectCycles()
        XCTAssertFalse(graph.issues.isEmpty,
                       "A → B → C → A should be detected")
    }

    func testReferenceGraph_skipsWeakProperties() {
        let source = """
        class A {
            var b: B?
        }
        class B {
            weak var a: A?
        }
        """
        let graph = ReferenceGraph(filePath: "Foo.swift", source: source)
        graph.walk(parse(source))
        graph.detectCycles()
        XCTAssertTrue(graph.issues.isEmpty,
                      "Weak back-reference should break the cycle — no issue")
    }

    func testReferenceGraph_cycleIssueContainsSuggestion() {
        let source = """
        class A { var b: B? }
        class B { var a: A? }
        """
        let graph = ReferenceGraph(filePath: "Foo.swift", source: source)
        graph.walk(parse(source))
        graph.detectCycles()
        XCTAssertFalse(graph.issues.first?.suggestion.isEmpty ?? true,
                       "Cycle issue should include a fix suggestion")
    }

    // MARK: - DetectionEngine Integration Tests

    func testEngine_returnsNoIssuesForCleanCode() {
        let source = """
        class Foo {
            var timer: Timer?
            func bar() {
                DispatchQueue.main.async { [weak self] in
                    self?.update()
                }
            }
            func update() {}
            deinit { timer?.invalidate() }
        }
        """
        let result = DetectionEngine().analyze(filePath: "Foo.swift", source: source)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testEngine_detectsMultipleIssuesInOneFile() {
        let source = """
        class Foo {
            var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            func bar() {
                DispatchQueue.main.async {
                    self.update()
                }
            }
            func update() {}
        }
        """
        let result = DetectionEngine().analyze(filePath: "Foo.swift", source: source)
        XCTAssertGreaterThanOrEqual(result.issues.count, 2,
                                    "Should detect timer leak + closure leak")
    }

    func testEngine_issuesSortedBySeverityThenLine() {
        let source = """
        class Foo {
            var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            func bar() {
                DispatchQueue.main.async {
                    self.update()
                }
            }
            func update() {}
        }
        """
        let result = DetectionEngine().analyze(filePath: "Foo.swift", source: source)
        let severities = result.issues.map { $0.severity }
        XCTAssertEqual(severities, severities.sorted(),
                       "Issues should be sorted by severity")
    }

    func testEngine_deduplicatesDuplicateIssues() {
        let source = """
        class Foo {
            func bar() {
                DispatchQueue.main.async {
                    self.update()
                }
            }
            func update() {}
        }
        """
        let result = DetectionEngine().analyze(filePath: "Foo.swift", source: source)
        let uniqueLocations = Set(result.issues.map { "\($0.line):\($0.column)" })
        XCTAssertEqual(result.issues.count, uniqueLocations.count,
                       "No duplicate issues at same location")
    }

    func testEngine_countsCorrectly() {
        let source = """
        class Foo {
            var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            func bar() {
                DispatchQueue.main.async {
                    self.update()
                }
            }
            func update() {}
        }
        """
        let result = DetectionEngine().analyze(filePath: "Foo.swift", source: source)
        XCTAssertEqual(
            result.criticalCount + result.warningCount + result.hintCount,
            result.issues.count,
            "Count properties must sum to total issues"
        )
    }
    
    func testDebug_printAST() {
        let source = """
        class Foo {
            var handler: (() -> Void)?
            func setup() {
                handler = { self.update() }
            }
            func update() {}
        }
        """
        // Print the full AST so we can see the exact node types
        let tree = parse(source)
        print(tree.debugDescription)
    }

    func testDebug_printDelegateAST() {
        let source = """
        class Foo {
            func setup(tableView: UITableView) {
                tableView.delegate = self
            }
        }
        """
        let tree = parse(source)
        print(tree.debugDescription)
    }
}
