//
//  ClosureVisitor.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

/// Visits every closure in a Swift source file and flags
/// those that capture `self` strongly in an escaping context.
final class ClosureVisitor: SyntaxVisitor, SourceLocating {

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

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        checkClosure(node)
        return .visitChildren
    }

    // MARK: - Detection Logic

    private func checkClosure(_ node: ClosureExprSyntax) {
        // 1. Does this closure reference self at all?
        guard closureReferencesSelf(node) else { return }

        // 2. Is self captured weakly or unowned?
        if hasSafeCapture(node) { return }

        // 3. Determine the kind — implicit vs explicit vs stored
        let kind = resolveKind(node)
        let loc = location(of: node)
        let snippet = codeLine(at: loc.line)
        let trail = buildTrail(node: node, kind: kind)

        issues.append(LeakIssue(
            kind: kind,
            filePath: filePath,
            line: loc.line,
            column: loc.column,
            message: kind.displayName,
            codeSnippet: snippet,
            detectionTrail: trail,
            isAutoFixable: kind == .escapingClosure || kind == .implicitSelf
        ))
    }

    // MARK: - Self Detection

    /// Returns true if the closure body contains any reference to `self`.
    private func closureReferencesSelf(_ node: ClosureExprSyntax) -> Bool {
        // Check capture list for explicit [self]
        if let captures = node.signature?.capture?.items {
            for capture in captures {
                if let ref = capture.expression.as(DeclReferenceExprSyntax.self),
                   ref.baseName.text == "self" {
                    return true
                }
            }
        }
        // Check body for implicit self references
        return bodyContainsSelf(node.statements)
    }

    /// Returns true if any statement in the body references `self`.
    private func bodyContainsSelf(_ statements: CodeBlockItemListSyntax) -> Bool {
        var found = false
        let finder = SelfReferenceFinder { found = true }
        finder.walk(Syntax(statements))
        return found
    }

    // MARK: - Capture Safety

    /// Returns true if the closure has [weak self] or [unowned self].
    private func hasSafeCapture(_ node: ClosureExprSyntax) -> Bool {
        guard let captures = node.signature?.capture?.items else { return false }
        // retainkit:ignore — value-type closure, no self capture
        return captures.contains { item in
            let specifier = item.specifier?.specifier.text ?? ""
            let isWeakOrUnowned = specifier == "weak" || specifier == "unowned"
            let capturesSelf = item.expression
                .as(DeclReferenceExprSyntax.self)?
                .baseName.text == "self"
            return isWeakOrUnowned && capturesSelf
        }
    }

    // MARK: - Kind Resolution

    /// Resolves whether this is an escaping, implicit, or stored closure.
    private func resolveKind(_ node: ClosureExprSyntax) -> IssueKind {
        // Explicit [self] in capture list without weak/unowned
        if let captures = node.signature?.capture?.items {
            for capture in captures {
                if let ref = capture.expression.as(DeclReferenceExprSyntax.self),
                   ref.baseName.text == "self" {
                    if isStoredInProperty(node) { return .storedClosure }
                    return .escapingClosure
                }
            }
        }
        // No capture list — implicit self
        if isStoredInProperty(node) { return .storedClosure }
        return .implicitSelf
    }

    /// Returns true if the closure itself is the value being stored:
    /// the initializer of a binding, the right-hand side of an assignment,
    /// or an argument of `append` / `insert`.
    ///
    /// Only the closure's immediate context counts. A closure that merely
    /// sits somewhere inside such an expression (`let names = items.map { ... }`)
    /// is not stored — its result is.
    private func isStoredInProperty(_ node: ClosureExprSyntax) -> Bool {
        guard let parent = node.parent else { return false }

        // var handler: () -> Void = { ... }
        if parent.is(InitializerClauseSyntax.self),
           parent.parent?.is(PatternBindingSyntax.self) == true {
            return true
        }

        // handler = { ... } is an unfolded SequenceExprSyntax in SwiftSyntax 510:
        // the closure must be the element right after the `=`.
        if let elements = parent.as(ExprListSyntax.self),
           parent.parent?.is(SequenceExprSyntax.self) == true {
            let list = Array(elements)
            if let index = list.firstIndex(where: { $0.id == node.id }),
               index > 0,
               list[index - 1].is(AssignmentExprSyntax.self) {
                return true
            }
        }

        // callbacks.append { ... }
        if let call = parent.as(FunctionCallExprSyntax.self),
           call.trailingClosure?.id == node.id {
            return isCollectionInsertion(call)
        }

        // callbacks.append({ ... }) / callbacks.insert({ ... }, at: 0)
        if parent.is(LabeledExprSyntax.self),
           let call = parent.parent?.parent?.as(FunctionCallExprSyntax.self) {
            return isCollectionInsertion(call)
        }

        return false
    }

    private func isCollectionInsertion(_ call: FunctionCallExprSyntax) -> Bool {
        let name = call.calledExpression
            .as(MemberAccessExprSyntax.self)?
            .declName.baseName.text
        return name == "append" || name == "insert"
    }

    // MARK: - Helpers

    private func buildTrail(node: ClosureExprSyntax, kind: IssueKind) -> [TrailStep] {
        let loc = location(of: node)
        let hasCaptureList = node.signature?.capture != nil
        return [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "ClosureVisitor matched",
                      detail: "ClosureExprSyntax at \(loc.line):\(loc.column)"),
            TrailStep(step: 3,
                      label: hasCaptureList ? "Escape inferred" : "No capture list",
                      detail: hasCaptureList ? "Explicit capture without weak/unowned" : "Implicit self capture"),
            TrailStep(step: 4, label: "Capture is strong",
                      detail: "No [weak] / [unowned] in capture list"),
            TrailStep(step: 5, label: "self used in body",
                      detail: "References found in closure body")
        ]
    }

    private func codeLine(at line: Int) -> String {
        guard line > 0, line <= sourceLines.count else { return "" }
        return sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Self Reference Finder

/// Walks a syntax tree and calls a callback when `self` is referenced.
private final class SelfReferenceFinder: SyntaxVisitor {
    private let onFound: () -> Void

    init(onFound: @escaping () -> Void) {
        self.onFound = onFound
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if node.baseName.text == "self" { onFound() }
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            onFound()
        }
        return .visitChildren
    }
}
