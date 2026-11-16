//
//  PropertyVisitor.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

/// Visits assignment expressions and flags `<x>.delegate = self` when the
/// delegate property is not known to be weak.
///
/// The receiver's type cannot be resolved from syntax, so the property is
/// looked up by name among the declarations in the same file:
/// - every declaration with that name is `weak`/`unowned` → not reported
/// - a strong declaration exists → reported as a warning
/// - no declaration in the file (a UIKit type, say) → reported as a hint,
///   since such delegates are usually weak
final class PropertyVisitor: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Context
    let context: SourceContext

    /// Known delegate property names to flag.
    private static let delegateKeywords: Set<String> = [
        "delegate", "dataSource", "prefetchDataSource",
        "scrollViewDelegate", "textInputDelegate"
    ]

    /// Delegate-named properties declared in this file, by name.
    private let declarations: [String: [DelegateDeclaration]]

    init(context: SourceContext) {
        self.context = context
        let collector = DelegateDeclarationCollector(
            names: Self.delegateKeywords,
            converter: context.locationConverter
        )
        collector.walk(context.tree)
        self.declarations = Dictionary(grouping: collector.declarations, by: \.name)
        super.init(viewMode: .sourceAccurate)
    }

    convenience init(filePath: String, source: String) {
        self.init(context: SourceContext(filePath: filePath, source: source))
    }

    // MARK: - Visitor

    // `a.delegate = self` is an unfolded SequenceExprSyntax in SwiftSyntax 510.
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkAssignment(node)
        return .visitChildren
    }

    // MARK: - Detection Logic

    /// How the assigned property is declared, as far as this file shows.
    private enum Resolution {
        case strong(line: Int)
        case unresolved
    }

    private func checkAssignment(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)

        // Pattern: [lhs, AssignmentExprSyntax, rhs]
        guard elements.count == 3,
              elements[1].is(AssignmentExprSyntax.self) else { return }

        let lhs = elements[0].trimmedDescription
        let rhs = elements[2].trimmedDescription

        guard rhs == "self" else { return }

        let lhsParts = lhs.split(separator: ".").map(String.init)
        guard let property = lhsParts.last,
              Self.delegateKeywords.contains(property) else { return }

        let resolution: Resolution
        if let declared = declarations[property] {
            // Declared in this file and weak everywhere: no cycle.
            guard let strong = declared.first(where: { !$0.isWeak }) else { return }
            resolution = .strong(line: strong.line)
        } else {
            resolution = .unresolved
        }

        let loc = location(of: node)
        let isResolved: Bool
        if case .strong = resolution { isResolved = true } else { isResolved = false }

        issues.append(LeakIssue(
            kind: .strongDelegate,
            severity: isResolved ? nil : .hint,
            filePath: filePath,
            line: loc.line,
            column: loc.column,
            message: "\(lhs) = self may cause a strong reference cycle",
            codeSnippet: codeLine(at: loc.line),
            suggestion: isResolved
                ? nil
                : "Check that `\(property)` is declared weak on the receiving type",
            detectionTrail: buildTrail(lhs: lhs, property: property, line: loc.line, resolution: resolution)
        ))
    }

    // MARK: - Helpers

    private func buildTrail(
        lhs: String,
        property: String,
        line: Int,
        resolution: Resolution
    ) -> [TrailStep] {
        let declarationStep: TrailStep
        switch resolution {
        case .strong(let declaredAt):
            declarationStep = TrailStep(
                step: 5, label: "Declared strong",
                detail: "`\(property)` is declared without weak/unowned at line \(declaredAt)")
        case .unresolved:
            declarationStep = TrailStep(
                step: 5, label: "Declaration not resolved",
                detail: "Name-based heuristic: `\(property)` is not declared in this file, reported as a hint")
        }

        return [
            TrailStep(step: 1, label: "Parsed file", detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "PropertyVisitor matched", detail: "Assignment at line \(line)"),
            TrailStep(step: 3, label: "Delegate keyword detected", detail: "\(lhs) matches known delegate pattern"),
            TrailStep(step: 4, label: "RHS is self", detail: "self is assigned to the property"),
            declarationStep
        ]
    }
}

// MARK: - Delegate Declarations

private struct DelegateDeclaration {
    let name: String
    let isWeak: Bool
    let line: Int
}

/// Collects every property declaration whose name is a delegate keyword.
private final class DelegateDeclarationCollector: SyntaxVisitor {
    private(set) var declarations: [DelegateDeclaration] = []

    private let names: Set<String>
    private let converter: SourceLocationConverter

    init(names: Set<String>, converter: SourceLocationConverter) {
        self.names = names
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let isWeak = node.modifiers.contains {
            $0.name.text == "weak" || $0.name.text == "unowned"
        }
        for binding in node.bindings {
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                  names.contains(name) else { continue }
            let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
            declarations.append(DelegateDeclaration(name: name, isWeak: isWeak, line: line))
        }
        return .visitChildren
    }
}
