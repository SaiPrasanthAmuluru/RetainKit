//
//  PropertyVisitor.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

/// Visits assignment expressions and flags strong delegate assignments.
final class PropertyVisitor: SyntaxVisitor, SourceLocating {
    
    // MARK: - Output
    private(set) var issues: [LeakIssue] = []
    
    // MARK: - Context
    private let filePath: String
    private let sourceLines: [String]
    
    /// Known delegate property suffixes to flag.
    private static let delegateKeywords: Set<String> = [
        "delegate", "dataSource", "prefetchDataSource",
        "scrollViewDelegate", "textInputDelegate"
    ]
    
    let locationConverter: SourceLocationConverter
    
    init(filePath: String, source: String) {
        self.filePath = filePath
        self.sourceLines = source.components(separatedBy: .newlines)
        self.locationConverter = makeLocationConverter(filePath: filePath, source: source)
        super.init(viewMode: .sourceAccurate)
    }
    
    // MARK: - Visitor
    
    // Change visit method from AssignmentExprSyntax to InfixOperatorExprSyntax
    override func visit(_ node: SequenceExprSyntax) -> SyntaxVisitorContinueKind {
        checkAssignment(node)
        return .visitChildren
    }
    
    // MARK: - Detection Logic
    
    // Update checkAssignment to take InfixOperatorExprSyntax directly
    private func checkAssignment(_ node: SequenceExprSyntax) {
        let elements = Array(node.elements)

        // Pattern: [lhs, AssignmentExprSyntax, rhs]
        guard elements.count == 3,
              elements[1].is(AssignmentExprSyntax.self) else { return }

        let lhs = elements[0].trimmedDescription
        let rhs = elements[2].trimmedDescription

        guard rhs == "self" else { return }

        let lhsParts = lhs.split(separator: ".").map(String.init)
        guard let lastPart = lhsParts.last,
              Self.delegateKeywords.contains(lastPart) else { return }

        let loc = location(of: node)

        issues.append(LeakIssue(
            kind: .strongDelegate,
            filePath: filePath,
            line: loc.line,
            column: loc.column,
            message: "\(lhs) = self may cause a strong reference cycle",
            codeSnippet: codeLine(at: loc.line),
            detectionTrail: buildTrail(lhs: lhs, line: loc.line)
        ))
    }
    
    // MARK: - Helpers
    
    private func buildTrail(lhs: String, line: Int) -> [TrailStep] {
        [
            TrailStep(step: 1, label: "Parsed file", detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "PropertyVisitor matched", detail: "AssignmentExpr at line \(line)"),
            TrailStep(step: 3, label: "Delegate keyword detected", detail: "\(lhs) matches known delegate pattern"),
            TrailStep(step: 4, label: "RHS is self", detail: "Strong reference to self assigned"),
            TrailStep(step: 5, label: "Weak check failed", detail: "Property not declared as weak")
        ]
    }
    
    private func codeLine(at line: Int) -> String {
        guard line > 0, line <= sourceLines.count else { return "" }
        return sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}
