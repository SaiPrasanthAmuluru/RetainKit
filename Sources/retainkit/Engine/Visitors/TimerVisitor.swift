//
//  TimerVisitor.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

/// Visits class declarations and flags Timer or NotificationCenter
/// registrations that the same class never cleans up.
///
/// Each class is judged on its own members: calls inside a nested class
/// belong to that nested class, not to the one enclosing it.
final class TimerVisitor: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Context
    let context: SourceContext

    init(context: SourceContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    convenience init(filePath: String, source: String) {
        self.init(context: SourceContext(filePath: filePath, source: source))
    }

    // MARK: - Visitor

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkClass(node)
        // Nested classes are visited here and checked separately.
        return .visitChildren
    }

    // MARK: - Detection Logic

    private func checkClass(_ node: ClassDeclSyntax) {
        let calls = ownCalls(in: node)

        checkTimers(calls)
        checkObservers(calls)
    }

    private func checkTimers(_ calls: [FunctionCallExprSyntax]) {
        let timerCalls = calls.filter(isTimerCreation)
        guard !timerCalls.isEmpty else { return }

        // A target-based timer retains its target, so deinit never runs while
        // it is scheduled. Any invalidate() in the class counts as cleanup,
        // wherever it lives.
        let hasInvalidate = calls.contains { memberName(of: $0) == "invalidate" }
        guard !hasInvalidate else { return }

        for call in timerCalls {
            let retainsTarget = hasArgument(labeled: "target", in: call)
            let loc = location(of: call)
            issues.append(LeakIssue(
                kind: .uninvalidatedTimer,
                filePath: filePath,
                line: loc.line,
                column: loc.column,
                message: IssueKind.uninvalidatedTimer.displayName,
                codeSnippet: codeLine(at: loc.line),
                suggestion: retainsTarget
                    ? "Call invalidate() from a teardown method such as viewWillDisappear or stop(). "
                      + "The run loop retains the timer's target, so deinit is never reached while it is scheduled"
                    : nil,
                detectionTrail: buildTimerTrail(line: loc.line, retainsTarget: retainsTarget)
            ))
        }
    }

    private func checkObservers(_ calls: [FunctionCallExprSyntax]) {
        let removals = calls.filter {
            memberName(of: $0) == "removeObserver" && isNotificationCenterCall($0)
        }
        // removeObserver(self) only removes selector-based registrations.
        let removesSelf  = removals.contains { firstArgument(of: $0) == "self" }
        // Block-based registrations are removed by passing the returned token.
        let removesToken = removals.contains { firstArgument(of: $0) != "self" }

        for call in calls where memberName(of: call) == "addObserver" && isNotificationCenterCall(call) {
            let isBlockBased = hasArgument(labeled: "forName", in: call)
            let hasCleanup = isBlockBased ? removesToken : removesSelf
            guard !hasCleanup else { continue }

            let loc = location(of: call)
            issues.append(LeakIssue(
                kind: .unremovedObserver,
                filePath: filePath,
                line: loc.line,
                column: loc.column,
                message: IssueKind.unremovedObserver.displayName,
                codeSnippet: codeLine(at: loc.line),
                suggestion: isBlockBased
                    ? "Keep the token returned by addObserver(forName:object:queue:using:) "
                      + "and pass it to removeObserver(_:)"
                    : nil,
                detectionTrail: buildObserverTrail(line: loc.line, isBlockBased: isBlockBased)
            ))
        }
    }

    // MARK: - Matching

    /// Every function call in the class body, excluding nested classes.
    private func ownCalls(in node: ClassDeclSyntax) -> [FunctionCallExprSyntax] {
        let collector = OwnCallCollector()
        collector.walk(node.memberBlock)
        return collector.calls
    }

    /// `foo.bar()` → "bar". Nil when the callee is not a member access.
    private func memberName(of call: FunctionCallExprSyntax) -> String? {
        call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }

    /// `Timer.scheduledTimer(...)`, `Timer(...)` or `Timer.init(...)`.
    private func isTimerCreation(_ call: FunctionCallExprSyntax) -> Bool {
        if let reference = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            return reference.baseName.text == "Timer"
        }
        guard let member = call.calledExpression.as(MemberAccessExprSyntax.self),
              member.base?.trimmedDescription == "Timer" else { return false }
        let name = member.declName.baseName.text
        return name == "scheduledTimer" || name == "init"
    }

    /// True when the receiver is spelled as a NotificationCenter, e.g.
    /// `NotificationCenter.default`. This keeps KVO's `addObserver(_:forKeyPath:)`
    /// and unrelated `removeObserver` calls out of the rule.
    private func isNotificationCenterCall(_ call: FunctionCallExprSyntax) -> Bool {
        guard let base = call.calledExpression.as(MemberAccessExprSyntax.self)?.base else {
            return false
        }
        return base.trimmedDescription.hasPrefix("NotificationCenter")
    }

    private func hasArgument(labeled label: String, in call: FunctionCallExprSyntax) -> Bool {
        call.arguments.contains { $0.label?.text == label }
    }

    private func firstArgument(of call: FunctionCallExprSyntax) -> String? {
        call.arguments.first?.expression.trimmedDescription
    }

    // MARK: - Helpers

    private func buildTimerTrail(line: Int, retainsTarget: Bool) -> [TrailStep] {
        [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "TimerVisitor matched",
                      detail: "Timer created at line \(line)"),
            TrailStep(step: 3, label: retainsTarget ? "Target-based timer" : "Block-based timer",
                      detail: retainsTarget
                          ? "The run loop retains the target until the timer is invalidated"
                          : "The timer keeps firing until it is invalidated"),
            TrailStep(step: 4, label: "Cleanup check",
                      detail: "Searched every method of the class, nested classes excluded"),
            TrailStep(step: 5, label: "No cleanup found",
                      detail: "No invalidate() call in the class")
        ]
    }

    private func buildObserverTrail(line: Int, isBlockBased: Bool) -> [TrailStep] {
        [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "TimerVisitor matched",
                      detail: "NotificationCenter addObserver at line \(line)"),
            TrailStep(step: 3, label: isBlockBased ? "Block-based observer" : "Selector-based observer",
                      detail: isBlockBased
                          ? "Registration returns a token that must be removed"
                          : "self registered with NotificationCenter"),
            TrailStep(step: 4, label: "Cleanup check",
                      detail: "Searched every method of the class, nested classes excluded"),
            TrailStep(step: 5, label: "No cleanup found",
                      detail: isBlockBased
                          ? "No NotificationCenter removeObserver(token) call in the class"
                          : "No NotificationCenter removeObserver(self) call in the class")
        ]
    }
}

// MARK: - Own Call Collector

/// Collects function calls without descending into nested classes.
private final class OwnCallCollector: SyntaxVisitor {
    private(set) var calls: [FunctionCallExprSyntax] = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        calls.append(node)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        .skipChildren
    }
}
