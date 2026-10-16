//
//  TimerVisitor.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax
import SwiftParser

/// Visits class declarations and flags Timer or NotificationCenter
/// registrations that are never cleaned up in deinit.
final class TimerVisitor: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Context
    private let filePath: String
    private let sourceLines: [String]
    let locationConverter: SourceLocationConverter

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.sourceLines = source.components(separatedBy: .newlines)
        self.locationConverter = makeLocationConverter(filePath: filePath, source: source)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - Visitor

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        checkClass(node)
        return .visitChildren
    }

    // MARK: - Detection Logic

    private func checkClass(_ node: ClassDeclSyntax) {
        let members = node.memberBlock.members

        let timerCalls    = findTimerCalls(in: members)
        let observerCalls = findObserverCalls(in: members)
        let deinitBlock   = findDeinit(in: members)

        // Check timer cleanup
        for call in timerCalls {
            let hasCleanup = deinitBlock.map { hasInvalidate(in: $0) } ?? false
            guard !hasCleanup else { continue }

            let loc = location(of: call)
            issues.append(LeakIssue(
                kind: .uninvalidatedTimer,
                filePath: filePath,
                line: loc.line,
                column: loc.column,
                message: IssueKind.uninvalidatedTimer.displayName,
                codeSnippet: codeLine(at: loc.line),
                detectionTrail: buildTimerTrail(line: loc.line, hasDeinit: deinitBlock != nil)
            ))
        }

        // Check observer cleanup
        for call in observerCalls {
            let hasCleanup = deinitBlock.map { hasRemoveObserver(in: $0) } ?? false
            guard !hasCleanup else { continue }

            let loc = location(of: call)
            issues.append(LeakIssue(
                kind: .unremovedObserver,
                filePath: filePath,
                line: loc.line,
                column: loc.column,
                message: IssueKind.unremovedObserver.displayName,
                codeSnippet: codeLine(at: loc.line),
                detectionTrail: buildObserverTrail(line: loc.line, hasDeinit: deinitBlock != nil)
            ))
        }
    }

    // MARK: - Finders

    private func findTimerCalls(in members: MemberBlockItemListSyntax) -> [FunctionCallExprSyntax] {
        var calls: [FunctionCallExprSyntax] = []
        let finder = FunctionCallFinder(matching: { call in
            let expr = call.calledExpression.trimmedDescription
            return expr.contains("Timer.scheduledTimer") ||
                   expr.contains("Timer.init")
        }) { call in
            calls.append(call)
        }
        finder.walk(Syntax(members))
        return calls
    }

    private func findObserverCalls(in members: MemberBlockItemListSyntax) -> [FunctionCallExprSyntax] {
        var calls: [FunctionCallExprSyntax] = []
        let finder = FunctionCallFinder(matching: { call in
            let expr = call.calledExpression.trimmedDescription
            return expr.contains("addObserver") ||
                   expr.contains("addObserver(forName")
        }) { call in
            calls.append(call)
        }
        finder.walk(Syntax(members))
        return calls
    }

    private func findDeinit(in members: MemberBlockItemListSyntax) -> DeinitializerDeclSyntax? {
        for member in members {
            if let deinit_ = member.decl.as(DeinitializerDeclSyntax.self) {
                return deinit_
            }
        }
        return nil
    }

    private func hasInvalidate(in deinit_: DeinitializerDeclSyntax) -> Bool {
        var found = false
        let finder = FunctionCallFinder(matching: { call in
            call.calledExpression.trimmedDescription.contains("invalidate")
        }) { _ in found = true }
        finder.walk(Syntax(deinit_))
        return found
    }

    private func hasRemoveObserver(in deinit_: DeinitializerDeclSyntax) -> Bool {
        var found = false
        let finder = FunctionCallFinder(matching: { call in
            call.calledExpression.trimmedDescription.contains("removeObserver")
        }) { _ in found = true }
        finder.walk(Syntax(deinit_))
        return found
    }

    // MARK: - Helpers

    private func buildTimerTrail(line: Int, hasDeinit: Bool) -> [TrailStep] {
        [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "TimerVisitor matched",
                      detail: "Timer.scheduledTimer at line \(line)"),
            TrailStep(step: 3, label: "Stored in property",
                      detail: "Timer assigned to instance variable"),
            TrailStep(step: 4, label: "deinit check",
                      detail: hasDeinit ? "deinit exists but no invalidate()" : "No deinit block found"),
            TrailStep(step: 5, label: "No cleanup found",
                      detail: "timer?.invalidate() missing")
        ]
    }

    private func buildObserverTrail(line: Int, hasDeinit: Bool) -> [TrailStep] {
        [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "ObserverVisitor matched",
                      detail: "addObserver at line \(line)"),
            TrailStep(step: 3, label: "Registered observer",
                      detail: "self registered with NotificationCenter"),
            TrailStep(step: 4, label: "deinit check",
                      detail: hasDeinit ? "deinit exists but no removeObserver" : "No deinit block found"),
            TrailStep(step: 5, label: "No cleanup found",
                      detail: "removeObserver(self) missing")
        ]
    }

    private func codeLine(at line: Int) -> String {
        guard line > 0, line <= sourceLines.count else { return "" }
        return sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Function Call Finder

/// Generic visitor that finds function calls matching a predicate.
private final class FunctionCallFinder: SyntaxVisitor {
    private let predicate: (FunctionCallExprSyntax) -> Bool
    private let onMatch: (FunctionCallExprSyntax) -> Void

    init(
        matching predicate: @escaping (FunctionCallExprSyntax) -> Bool,
        onMatch: @escaping (FunctionCallExprSyntax) -> Void
    ) {
        self.predicate = predicate
        self.onMatch = onMatch
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if predicate(node) { onMatch(node) }
        return .visitChildren
    }
}
