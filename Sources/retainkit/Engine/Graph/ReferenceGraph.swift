//
//  ReferenceGraph.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax
import SwiftParser

// MARK: - Graph Node

/// Represents a class in the reference graph.
final class GraphNode {
    let name: String
    var edges: [GraphEdge] = []

    init(name: String) {
        self.name = name
    }
}

// MARK: - Graph Edge

/// A directed strong reference from one class to another.
struct GraphEdge {
    let from: String
    let to: String
    let propertyName: String
    let line: Int
}

// MARK: - Reference Graph

/// Builds a directed graph of strong class references and
/// detects retain cycles using depth-first search.
final class ReferenceGraph: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Graph
    private var nodes: [String: GraphNode] = [:]

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

    // MARK: - Build Phase

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let className = node.name.text
        let graphNode = GraphNode(name: className)
        nodes[className] = graphNode

        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            // Skip weak and unowned properties — they can't form cycles
            let isWeak = varDecl.modifiers.contains {
                $0.name.text == "weak" || $0.name.text == "unowned"
            }
            guard !isWeak else { continue }

            for binding in varDecl.bindings {
                guard let typeAnnotation = binding.typeAnnotation else { continue }

                let typeName = extractTypeName(from: typeAnnotation.type)
                let propName = binding.pattern
                    .as(IdentifierPatternSyntax.self)?
                    .identifier.text ?? "unknown"
                let loc = location(of: varDecl)  // ← SourceLocating

                graphNode.edges.append(GraphEdge(
                    from: className,
                    to: typeName,
                    propertyName: propName,
                    line: loc.line
                ))
            }
        }

        return .visitChildren
    }

    // MARK: - Cycle Detection

    /// Run after visiting — detects all cycles in the built graph.
    func detectCycles() {
        var visited = Set<String>()
        var stack   = Set<String>()

        for nodeName in nodes.keys where !visited.contains(nodeName) {
            dfs(current: nodeName, visited: &visited, stack: &stack, path: [])
        }
    }

    private func dfs(
        current: String,
        visited: inout Set<String>,
        stack: inout Set<String>,
        path: [GraphEdge]
    ) {
        visited.insert(current)
        stack.insert(current)

        defer { stack.remove(current) }

        guard let node = nodes[current] else { return }

        for edge in node.edges {
            guard nodes[edge.to] != nil else { continue }

            if !visited.contains(edge.to) {
                dfs(
                    current: edge.to,
                    visited: &visited,
                    stack: &stack,
                    path: path + [edge]
                )
            } else if stack.contains(edge.to) {
                reportCycle(path: path + [edge], closingNode: edge.to)
            }
        }
    }

    private func reportCycle(path: [GraphEdge], closingNode: String) {
        guard let firstEdge = path.first else { return }

        let breakEdge = path.last ?? firstEdge
        let cycleDescription = path
            .map { "\($0.from).\($0.propertyName)" }
            .joined(separator: " → ")

        issues.append(LeakIssue(
            kind: .referenceCycle,
            filePath: filePath,
            line: breakEdge.line,
            column: 1,
            message: "Retain cycle: \(cycleDescription) → \(closingNode)",
            codeSnippet: codeLine(at: breakEdge.line),
            suggestion: "Make \(breakEdge.from).\(breakEdge.propertyName) weak: weak var \(breakEdge.propertyName): \(breakEdge.to)?",
            detectionTrail: buildTrail(path: path, closingNode: closingNode)
        ))
    }

    // MARK: - Helpers

    private func extractTypeName(from type: TypeSyntax) -> String {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return extractTypeName(from: optional.wrappedType)
        }
        return type.trimmedDescription
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func buildTrail(path: [GraphEdge], closingNode: String) -> [TrailStep] {
        let cycleStr = (path.map { $0.from } + [closingNode]).joined(separator: " → ")
        return [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "Graph built",
                      detail: "\(nodes.count) classes analysed"),
            TrailStep(step: 3, label: "DFS traversal",
                      detail: "Depth-first search over reference edges"),
            TrailStep(step: 4, label: "Cycle detected",
                      detail: cycleStr),
            TrailStep(step: 5, label: "Break point scored",
                      detail: "\(path.last?.from ?? "").\(path.last?.propertyName ?? "") recommended")
        ]
    }

    private func codeLine(at line: Int) -> String {
        guard line > 0, line <= sourceLines.count else { return "" }
        return sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}
