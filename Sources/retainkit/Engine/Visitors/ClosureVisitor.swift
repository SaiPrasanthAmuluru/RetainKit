//
//  ClosureVisitor.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

/// Visits every closure in a Swift source file and flags
/// those that capture `self` strongly in a context that can outlive the call.
final class ClosureVisitor: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Context
    let context: SourceContext

    /// Names of the structs and enums declared in this file, used to
    /// recognise `extension Point { ... }` as an extension of a value type.
    private let valueTypeNames: Set<String>

    init(context: SourceContext) {
        self.context = context
        let collector = ValueTypeNameCollector()
        collector.walk(context.tree)
        self.valueTypeNames = collector.names
        super.init(viewMode: .sourceAccurate)
    }

    convenience init(filePath: String, source: String) {
        self.init(context: SourceContext(filePath: filePath, source: source))
    }

    // MARK: - Visitor

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        checkClosure(node)
        return .visitChildren
    }

    // MARK: - Detection Logic

    /// Where a closure ends up, which decides whether it can retain `self`.
    private enum Destination {
        /// Initializer of a binding or right-hand side of an assignment.
        case stored
        /// Argument of `append` / `insert`.
        case collection
        /// Passed to an API listed in `KnownEscaping.escaping`.
        case escapingCall(String)
        /// Runs before the enclosing expression finishes; cannot leak.
        case nonEscaping
        /// Passed to a callee RetainKit knows nothing about, or returned.
        case unknown(String?)
    }

    private func checkClosure(_ node: ClosureExprSyntax) {
        // 1. Does this closure reference self at all?
        guard closureReferencesSelf(node) else { return }

        // A struct or enum `self` is copied into the closure, not retained.
        if isInsideValueType(node) { return }

        // 2. Is self captured weakly or unowned, here or in an enclosing closure?
        if hasSafeCapture(node) || usesWeakSelfOfEnclosingClosure(node) { return }

        // 3. Can the closure outlive the call it appears in?
        let destination = resolveDestination(node)
        if case .nonEscaping = destination { return }

        let kind = resolveKind(node, destination: destination)
        let loc = location(of: node)

        // An unknown callee may or may not escape: report it, but only as a hint.
        var severity: IssueSeverity?
        if case .unknown = destination { severity = .hint }

        issues.append(LeakIssue(
            kind: kind,
            severity: severity,
            filePath: filePath,
            line: loc.line,
            column: loc.column,
            message: kind.displayName,
            codeSnippet: codeLine(at: loc.line),
            detectionTrail: buildTrail(node: node, destination: destination),
            isAutoFixable: kind == .escapingClosure || kind == .implicitSelf
        ))
    }

    // MARK: - Self Detection

    /// Returns true if the closure captures `self` explicitly or uses it in its body.
    private func closureReferencesSelf(_ node: ClosureExprSyntax) -> Bool {
        hasExplicitSelfCapture(node) || bodyContainsSelf(node.statements)
    }

    /// Returns true if the capture list names `self` (with or without a specifier).
    private func hasExplicitSelfCapture(_ node: ClosureExprSyntax) -> Bool {
        guard let captures = node.signature?.capture?.items else { return false }
        return captures.contains {
            $0.expression.as(DeclReferenceExprSyntax.self)?.baseName.text == "self"
        }
    }

    /// Returns true if any statement in the body references `self`.
    private func bodyContainsSelf(_ statements: CodeBlockItemListSyntax) -> Bool {
        var found = false
        let finder = SelfReferenceFinder { found = true }
        finder.walk(Syntax(statements))
        return found
    }

    // MARK: - Enclosing Type

    /// Returns true if the nearest enclosing type is a struct or enum, so
    /// `self` is a value. An extension counts when it extends a struct or enum
    /// declared in the same file; an extension of any other type is not
    /// resolvable from syntax and is treated as a possible class.
    private func isInsideValueType(_ node: ClosureExprSyntax) -> Bool {
        var ancestor = node.parent
        while let current = ancestor {
            if current.is(StructDeclSyntax.self) || current.is(EnumDeclSyntax.self) {
                return true
            }
            if current.is(ClassDeclSyntax.self) || current.is(ActorDeclSyntax.self)
                || current.is(ProtocolDeclSyntax.self) {
                return false
            }
            if let ext = current.as(ExtensionDeclSyntax.self) {
                return valueTypeNames.contains(ext.extendedType.trimmedDescription)
            }
            ancestor = current.parent
        }
        return false
    }

    // MARK: - Capture Safety

    /// Returns true if the closure has [weak self] or [unowned self].
    private func hasSafeCapture(_ node: ClosureExprSyntax) -> Bool {
        guard let captures = node.signature?.capture?.items else { return false }
        return captures.contains { item in
            let specifier = item.specifier?.specifier.text ?? ""
            let isWeakOrUnowned = specifier == "weak" || specifier == "unowned"
            let capturesSelf = item.expression
                .as(DeclReferenceExprSyntax.self)?
                .baseName.text == "self"
            return isWeakOrUnowned && capturesSelf
        }
    }

    /// Returns true if `self` inside this closure is the weak or unowned
    /// binding of an enclosing closure, so this closure holds no strong reference:
    ///
    ///     queue.async { [weak self] in
    ///         other.async { self?.update() }   // captures the weak `self`
    ///     }
    ///
    /// If the enclosing closure rebinds `self` strongly before this one
    /// (`guard let self`), this closure captures that strong reference and
    /// is still reported.
    private func usesWeakSelfOfEnclosingClosure(_ node: ClosureExprSyntax) -> Bool {
        // A capture list on this closure decides for itself.
        guard !hasExplicitSelfCapture(node) else { return false }

        var ancestor = node.parent
        while let current = ancestor {
            // `self` means something else outside the enclosing type.
            if current.is(ClassDeclSyntax.self) || current.is(StructDeclSyntax.self)
                || current.is(ActorDeclSyntax.self) || current.is(EnumDeclSyntax.self)
                || current.is(ExtensionDeclSyntax.self) {
                return false
            }
            if let closure = current.as(ClosureExprSyntax.self), hasExplicitSelfCapture(closure) {
                // The nearest closure that captures self decides what `self` is here.
                return hasSafeCapture(closure)
                    && !rebindsSelfStrongly(in: closure, before: node)
            }
            ancestor = current.parent
        }
        return false
    }

    /// True if `closure` contains `guard let self` / `if let self` ahead of `node`.
    private func rebindsSelfStrongly(in closure: ClosureExprSyntax, before node: ClosureExprSyntax) -> Bool {
        let finder = SelfRebindingFinder(before: node.position)
        finder.walk(closure.statements)
        return finder.found
    }

    // MARK: - Kind Resolution

    private func resolveKind(_ node: ClosureExprSyntax, destination: Destination) -> IssueKind {
        switch destination {
        case .stored:
            return .storedClosure
        case .collection:
            return .closureInCollection
        case .escapingCall, .unknown, .nonEscaping:
            // `[self]` is a deliberate strong capture; no capture list is LC-W002.
            return hasExplicitSelfCapture(node) ? .escapingClosure : .implicitSelf
        }
    }

    // MARK: - Destination Resolution

    /// Classifies the closure by its immediate context only. A closure that
    /// merely sits somewhere inside a stored expression
    /// (`let names = items.map { ... }`) is not stored — its result is.
    private func resolveDestination(_ node: ClosureExprSyntax) -> Destination {
        guard let parent = node.parent else { return .unknown(nil) }

        // var handler: () -> Void = { ... }
        if parent.is(InitializerClauseSyntax.self),
           parent.parent?.is(PatternBindingSyntax.self) == true {
            return .stored
        }

        // handler = { ... } is an unfolded SequenceExprSyntax in SwiftSyntax 510:
        // the closure must be the element right after the `=`.
        if let elements = parent.as(ExprListSyntax.self),
           parent.parent?.is(SequenceExprSyntax.self) == true {
            let list = Array(elements)
            if let index = list.firstIndex(where: { $0.id == node.id }),
               index > 0,
               list[index - 1].is(AssignmentExprSyntax.self) {
                return .stored
            }
        }

        if let call = parent.as(FunctionCallExprSyntax.self) {
            // { ... }() runs immediately, e.g. `lazy var x: Foo = { ... }()`.
            if call.calledExpression.id == node.id { return .nonEscaping }
            // callbacks.append { ... } / queue.async { ... }
            if call.trailingClosure?.id == node.id { return destination(ofArgumentTo: call) }
        }

        // foo(bar) { ... } second: { ... }
        if parent.is(MultipleTrailingClosureElementSyntax.self),
           let call = parent.parent?.parent?.as(FunctionCallExprSyntax.self) {
            return destination(ofArgumentTo: call)
        }

        // callbacks.append({ ... }) / callbacks.insert({ ... }, at: 0)
        if parent.is(LabeledExprSyntax.self),
           let call = parent.parent?.parent?.as(FunctionCallExprSyntax.self) {
            return destination(ofArgumentTo: call)
        }

        // Returned, wrapped in a tuple, etc. — not resolvable from syntax.
        return .unknown(nil)
    }

    private func destination(ofArgumentTo call: FunctionCallExprSyntax) -> Destination {
        guard let name = calleeName(of: call) else { return .unknown(nil) }
        if name == "append" || name == "insert" { return .collection }

        switch KnownEscaping.behavior(ofCallee: name) {
        case .escaping:    return .escapingCall(name)
        case .nonEscaping: return .nonEscaping
        case .unknown:     return .unknown(name)
        }
    }

    /// `queue.async` → "async", `Task` → "Task".
    private func calleeName(of call: FunctionCallExprSyntax) -> String? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
    }

    // MARK: - Helpers

    private func buildTrail(node: ClosureExprSyntax, destination: Destination) -> [TrailStep] {
        let loc = location(of: node)
        let hasCaptureList = node.signature?.capture != nil

        let escapeLabel: String
        let escapeDetail: String
        switch destination {
        case .stored:
            escapeLabel = "Closure is stored"
            escapeDetail = "Initializer of a binding or right-hand side of an assignment"
        case .collection:
            escapeLabel = "Closure is stored"
            escapeDetail = "Argument of append/insert"
        case .escapingCall(let name):
            escapeLabel = "Escaping API"
            escapeDetail = "`\(name)` is listed in KnownEscaping"
        case .unknown(let name):
            escapeLabel = "Escape not known"
            escapeDetail = name.map { "`\($0)` is not in KnownEscaping; reported as a hint" }
                ?? "Closure is not a direct call argument; reported as a hint"
        case .nonEscaping:
            escapeLabel = "Non-escaping"
            escapeDetail = "Closure runs before the call returns"
        }

        return [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "ClosureVisitor matched",
                      detail: "ClosureExprSyntax at \(loc.line):\(loc.column)"),
            TrailStep(step: 3, label: escapeLabel, detail: escapeDetail),
            TrailStep(step: 4, label: "Capture is strong",
                      detail: hasCaptureList
                          ? "Capture list has no [weak self] / [unowned self]"
                          : "No capture list"),
            TrailStep(step: 5, label: "self used in closure",
                      detail: "`self` appears in the capture list or body")
        ]
    }
}

// MARK: - Value Type Name Collector

/// Collects the names of every struct and enum declared in a file.
private final class ValueTypeNameCollector: SyntaxVisitor {
    private(set) var names: Set<String> = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }
}

// MARK: - Self Rebinding Finder

/// Finds `guard let self` / `if let self = self` that starts before a position.
private final class SelfRebindingFinder: SyntaxVisitor {
    private(set) var found = false
    private let limit: AbsolutePosition

    init(before limit: AbsolutePosition) {
        self.limit = limit
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if node.position < limit,
           node.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "self" {
            found = true
        }
        return .visitChildren
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
}
