//
//  retainkitTests.swift
//  RetainKitTests
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import XCTest
import ArgumentParser
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
        XCTAssertEqual(visitor.issues.first?.kind, .closureInCollection)
    }

    func testClosureVisitor_storedPropertyInitializerIsStored() {
        let source = """
        class Foo {
            var y = 0
            lazy var h: () -> Void = { self.y += 1 }
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertEqual(visitor.issues.map(\.kind), [.storedClosure])
    }

    func testClosureVisitor_closureInsideBindingInitializerIsNotStored() {
        let source = """
        class Foo {
            var items: [Int] = []
            func bar() {
                let names = items.map { self.format($0) }
                _ = names
            }
            func format(_ i: Int) -> String { "\\(i)" }
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertTrue(visitor.issues.isEmpty,
                      "map is non-escaping: binding its result stores no closure")
    }

    func testClosureVisitor_closureInsideAssignmentIsNotStored() {
        let source = """
        class Foo {
            var items: [Int] = []
            var total = 0
            func bar() {
                total = items.reduce(0) { $0 + self.weight($1) }
            }
            func weight(_ i: Int) -> Int { i }
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.contains { $0.kind == .storedClosure })
    }

    func testClosureVisitor_closureNestedInAppendArgumentIsNotStored() {
        let source = """
        class Foo {
            var items: [Int] = []
            var all: [[Int]] = []
            var x = 1
            func bar() {
                all.append(items.map { $0 * self.x })
            }
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertFalse(visitor.issues.contains { $0.kind == .storedClosure })
    }

    func testClosureVisitor_closurePassedAsInsertArgumentIsInCollection() {
        let source = """
        class Foo {
            var callbacks: [() -> Void] = []
            func add() {
                callbacks.insert({ self.update() }, at: 0)
            }
            func update() {}
        }
        """
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        XCTAssertEqual(visitor.issues.map(\.kind), [.closureInCollection])
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
        let context = SourceContext(filePath: "Foo.swift", source: "class Foo {}\n")
        let issue = LeakIssue(kind: .escapingClosure, filePath: "Foo.swift",
                              line: 1, column: 1, message: "m", codeSnippet: "")
        let other = LeakIssue(kind: .escapingClosure, filePath: "Foo.swift",
                              line: 2, column: 1, message: "m", codeSnippet: "")
        let result = DetectionEngine.finalize([issue, other, issue], context: context)
        XCTAssertEqual(result.map(\.line), [1, 2],
                       "The same issue reported twice should appear once")
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

    // MARK: - Closure escape rules

    private func closureIssues(_ source: String) -> [LeakIssue] {
        let visitor = ClosureVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        return visitor.issues
    }

    func testClosureVisitor_skipsNonEscapingCalls() {
        let source = """
        class Foo {
            var items: [Int] = []
            var x = 1
            func bar() {
                items.forEach { print($0 + self.x) }
                _ = items.filter { $0 > self.x }.sorted { $0 < $1 + self.x }
                DispatchQueue.main.sync { self.x += 1 }
            }
        }
        """
        XCTAssertTrue(closureIssues(source).isEmpty,
                      "Closures passed to non-escaping APIs cannot leak self")
    }

    func testClosureVisitor_skipsImmediatelyInvokedClosure() {
        let source = """
        class Foo {
            var x = 1
            lazy var doubled: Int = { self.x * 2 }()
        }
        """
        XCTAssertTrue(closureIssues(source).isEmpty)
    }

    func testClosureVisitor_unknownCalleeIsHint() {
        let source = """
        class Foo {
            func bar(api: API) {
                api.fetch { self.update() }
            }
            func update() {}
        }
        """
        let issues = closureIssues(source)
        XCTAssertEqual(issues.map(\.kind), [.implicitSelf])
        XCTAssertEqual(issues.first?.severity, .hint)
        XCTAssertEqual(issues.first?.detectionTrail[2].label, "Escape not known")
    }

    func testClosureVisitor_knownEscapingKeepsDefaultSeverity() {
        let source = """
        class Foo {
            func bar() {
                DispatchQueue.main.async { [self] in self.update() }
                Task { self.update() }
            }
            func update() {}
        }
        """
        let issues = closureIssues(source)
        XCTAssertEqual(issues.map(\.kind), [.escapingClosure, .implicitSelf])
        XCTAssertEqual(issues.map(\.severity), [.error, .warning])
        XCTAssertEqual(issues.first?.detectionTrail[2].label, "Escaping API")
    }

    func testClosureVisitor_nestedEscapingInsideNonEscapingIsFlaggedOnce() {
        let source = """
        class Foo {
            var items: [Int] = []
            func bar() {
                items.forEach { _ in
                    DispatchQueue.main.async { self.update() }
                }
            }
            func update() {}
        }
        """
        let issues = closureIssues(source)
        XCTAssertEqual(issues.map(\.line), [5])
    }

    func testKnownEscaping_classifiesNames() {
        XCTAssertEqual(KnownEscaping.behavior(ofCallee: "async"), .escaping)
        XCTAssertEqual(KnownEscaping.behavior(ofCallee: "map"), .nonEscaping)
        XCTAssertEqual(KnownEscaping.behavior(ofCallee: "fetch"), .unknown)
        XCTAssertTrue(KnownEscaping.escaping.isDisjoint(with: KnownEscaping.nonEscaping))
    }

    // MARK: - Timer and observer rules

    private func timerIssues(_ source: String) -> [LeakIssue] {
        let visitor = TimerVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        return visitor.issues
    }

    func testTimerVisitor_acceptsInvalidateInTeardownMethod() {
        let source = """
        class Foo {
            var timer: Timer?
            func start() {
                timer = Timer.scheduledTimer(timeInterval: 1, target: self,
                    selector: #selector(tick), userInfo: nil, repeats: true)
            }
            func viewWillDisappear() { timer?.invalidate() }
            @objc func tick() {}
        }
        """
        XCTAssertTrue(timerIssues(source).isEmpty,
                      "A target-based timer can only be invalidated outside deinit")
    }

    func testTimerVisitor_targetTimerSuggestionDoesNotPointAtDeinit() {
        let source = """
        class Foo {
            func start() {
                _ = Timer.scheduledTimer(timeInterval: 1, target: self,
                    selector: #selector(tick), userInfo: nil, repeats: true)
            }
            @objc func tick() {}
        }
        """
        let issues = timerIssues(source)
        XCTAssertEqual(issues.map(\.kind), [.uninvalidatedTimer])
        XCTAssertTrue(issues[0].suggestion.contains("deinit is never reached"))
        XCTAssertEqual(issues[0].detectionTrail[2].label, "Target-based timer")
    }

    func testTimerVisitor_nestedClassTimerIsNotAttributedToOuterClass() {
        let source = """
        class Outer {
            deinit { cache.invalidate() }
            class Inner {
                var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
            }
        }
        """
        let issues = timerIssues(source)
        XCTAssertEqual(issues.map(\.line), [4],
                       "Inner's timer is reported once, and Outer's deinit does not mask it")
    }

    func testTimerVisitor_nestedClassWithOwnCleanupIsNotFlagged() {
        let source = """
        class Outer {
            class Inner {
                var timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in }
                deinit { timer.invalidate() }
            }
        }
        """
        XCTAssertTrue(timerIssues(source).isEmpty)
    }

    func testTimerVisitor_ignoresKVOAddObserver() {
        let source = """
        class Foo {
            func setup(player: Player) {
                player.addObserver(self, forKeyPath: "status", options: [], context: nil)
            }
        }
        """
        XCTAssertTrue(timerIssues(source).isEmpty,
                      "Only NotificationCenter registrations are covered")
    }

    func testTimerVisitor_unrelatedRemoveObserverDoesNotSatisfyCheck() {
        let source = """
        class Foo {
            func setup(player: Player) {
                NotificationCenter.default.addObserver(self,
                    selector: #selector(handle), name: nil, object: nil)
            }
            @objc func handle() {}
            deinit { player.removeObserver(self, forKeyPath: "status") }
        }
        """
        XCTAssertEqual(timerIssues(source).map(\.kind), [.unremovedObserver])
    }

    func testTimerVisitor_blockObserverNeedsTokenRemoval() {
        let flagged = """
        class Foo {
            func setup() {
                _ = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in }
            }
            deinit { NotificationCenter.default.removeObserver(self) }
        }
        """
        let issues = timerIssues(flagged)
        XCTAssertEqual(issues.map(\.kind), [.unremovedObserver],
                       "removeObserver(self) does not remove a block-based observer")
        XCTAssertTrue(issues[0].suggestion.contains("token"))

        let clean = """
        class Foo {
            var token: NSObjectProtocol?
            func setup() {
                token = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: nil) { _ in }
            }
            deinit { if let token { NotificationCenter.default.removeObserver(token) } }
        }
        """
        XCTAssertTrue(timerIssues(clean).isEmpty)
    }

    // MARK: - Reference graph rules

    private func cycleIssues(_ source: String) -> [LeakIssue] {
        let graph = ReferenceGraph(filePath: "Foo.swift", source: source)
        graph.walk(parse(source))
        graph.detectCycles()
        return graph.issues
    }

    func testReferenceGraph_reportsOnlyCycleEdgesDeterministically() {
        let source = """
        class A { var b: B? }
        class B { var c: C? }
        class C { var b: B? }
        """
        for _ in 0..<20 {
            let issues = cycleIssues(source)
            XCTAssertEqual(issues.map(\.message), ["Retain cycle: B.c → C.b → B"],
                           "A leads into the cycle but is not part of it")
            XCTAssertEqual(issues.map(\.line), [3])
        }
    }

    func testReferenceGraph_prefersBackReferenceNameAsBreakPoint() {
        let source = """
        class Child { var parent: Parent? }
        class Parent { var child: Child? }
        """
        let issues = cycleIssues(source)
        XCTAssertEqual(issues.map(\.line), [1])
        XCTAssertTrue(issues[0].suggestion.contains("Child.parent"))
        XCTAssertEqual(issues[0].detectionTrail.last?.label, "Break point chosen")
    }

    func testReferenceGraph_skipsComputedAndStaticProperties() {
        let source = """
        class A {
            var b: B?
        }
        class B {
            var a: A { A() }
            static var shared: A = A()
            class var other: A { A() }
        }
        """
        XCTAssertTrue(cycleIssues(source).isEmpty)
    }

    func testReferenceGraph_observedPropertyIsStillStored() {
        let source = """
        class A { var b: B? }
        class B { var a: A? { didSet {} } }
        """
        XCTAssertEqual(cycleIssues(source).count, 1)
    }

    func testReferenceGraph_unwrapsCollections() {
        let source = """
        class A { var children: [B] = [] }
        class B { var owners: [String: A] = [:] }
        """
        XCTAssertEqual(cycleIssues(source).count, 1)
    }

    // MARK: - Delegate rule

    private func delegateIssues(_ source: String) -> [LeakIssue] {
        let visitor = PropertyVisitor(filePath: "Foo.swift", source: source)
        visitor.walk(parse(source))
        return visitor.issues
    }

    func testPropertyVisitor_skipsWhenDelegateDeclaredWeak() {
        let source = """
        class Child { weak var delegate: Parent? }
        class Parent {
            let child = Child()
            func setup() { child.delegate = self }
        }
        """
        XCTAssertTrue(delegateIssues(source).isEmpty)
    }

    func testPropertyVisitor_warnsWhenDelegateDeclaredStrong() {
        let source = """
        class Child { var delegate: Parent? }
        class Parent {
            let child = Child()
            func setup() { child.delegate = self }
        }
        """
        let issues = delegateIssues(source)
        XCTAssertEqual(issues.map(\.severity), [.warning])
        XCTAssertEqual(issues[0].detectionTrail.last?.label, "Declared strong")
    }

    func testPropertyVisitor_unresolvedDelegateIsHintWithHonestTrail() {
        let source = """
        class Foo {
            func setup(tableView: UITableView) {
                tableView.delegate = self
            }
        }
        """
        let issues = delegateIssues(source)
        XCTAssertEqual(issues.map(\.severity), [.hint])
        XCTAssertEqual(issues[0].detectionTrail.last?.label, "Declaration not resolved")
        XCTAssertFalse(issues[0].detectionTrail.contains { $0.label == "Weak check failed" })
    }

    // MARK: - Suppression

    private let leakingLine = "DispatchQueue.main.async { self.update() }"

    private func engineIssues(body: String) -> [LeakIssue] {
        let source = """
        class Foo {
            func bar() {
        \(body)
            }
            func update() {}
        }
        """
        return DetectionEngine().analyze(filePath: "Foo.swift", source: source).issues
    }

    func testSuppression_commentOnPreviousLine() {
        XCTAssertEqual(engineIssues(body: leakingLine).count, 1)
        XCTAssertTrue(engineIssues(body: "// retainkit:ignore\n\(leakingLine)").isEmpty)
    }

    func testSuppression_trailingCommentOnSameLine() {
        XCTAssertTrue(engineIssues(body: "\(leakingLine) // retainkit:ignore").isEmpty)
    }

    func testSuppression_trailingCommentDoesNotSuppressNextLine() {
        let body = "let a = 1 // retainkit:ignore\n\(leakingLine)"
        XCTAssertEqual(engineIssues(body: body).count, 1)
    }

    func testSuppression_markerInStringLiteralIsIgnored() {
        let body = "let note = \"retainkit:ignore\"\n\(leakingLine)"
        XCTAssertEqual(engineIssues(body: body).count, 1)
    }

    // MARK: - Directory scan

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("retainkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testAnalyzeDirectory_detectsCycleAcrossFiles() throws {
        let dir = try makeTempDirectory()
        try "class A { var b: B? }\n".write(
            to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "class B { var a: A? }\n".write(
            to: dir.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)

        let results = try DetectionEngine().analyzeDirectory(dir.path)
        let cycles = results.flatMap(\.issues).filter { $0.kind == .referenceCycle }
        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles.first?.message, "Retain cycle: A.b → B.a → A")
        XCTAssertEqual(cycles.first?.codeSnippet, "class B { var a: A? }")
        XCTAssertTrue(cycles.first?.filePath.hasSuffix("B.swift") ?? false)
    }

    func testAnalyzeDirectory_skipsUnreadableFileAndContinues() throws {
        let dir = try makeTempDirectory()
        try Data([0xFF, 0xFE, 0xFD]).write(to: dir.appendingPathComponent("Bad.swift"))
        try "class Good {}\n".write(
            to: dir.appendingPathComponent("Good.swift"), atomically: true, encoding: .utf8)

        var failed: [String] = []
        let results = try DetectionEngine().analyzeDirectory(dir.path) { path, _ in
            failed.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        XCTAssertEqual(failed, ["Bad.swift"])
        XCTAssertEqual(results.map { URL(fileURLWithPath: $0.filePath).lastPathComponent },
                       ["Good.swift"])
    }

    // MARK: - Scan command

    func testScan_jsonIncludesTrailAndAutoFixFlag() throws {
        let source = """
        class Foo {
            func bar() { DispatchQueue.main.async { self.update() } }
            func update() {}
        }
        """
        let result = DetectionEngine().analyze(filePath: "Foo.swift", source: source)
        let json = try Scan.jsonString(results: [result])
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["isAutoFixable"] as? Bool, true)
        XCTAssertEqual((parsed[0]["detectionTrail"] as? [[String: Any]])?.count, 5)
    }

    func testScan_failOnErrorExitsNonZeroOnlyForErrors() throws {
        let dir = try makeTempDirectory()
        let leaky = dir.appendingPathComponent("Leaky.swift")
        try "class A { var b: B? }\nclass B { var a: A? }\n".write(
            to: leaky, atomically: true, encoding: .utf8)
        let clean = dir.appendingPathComponent("Clean.swift")
        try "class C {}\n".write(to: clean, atomically: true, encoding: .utf8)

        var failing = try Scan.parse([leaky.path, "--json", "--fail-on-error"])
        XCTAssertThrowsError(try failing.run()) { error in
            XCTAssertEqual(error as? ExitCode, ExitCode(1))
        }

        var withoutFlag = try Scan.parse([leaky.path, "--json"])
        XCTAssertNoThrow(try withoutFlag.run())

        var passing = try Scan.parse([clean.path, "--json", "--fail-on-error"])
        XCTAssertNoThrow(try passing.run())
    }
}
