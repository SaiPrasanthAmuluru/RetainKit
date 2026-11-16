//
//  ReferenceGraph.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

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
    let filePath: String
    let line: Int
    let codeSnippet: String
}

// MARK: - Reference Graph

/// Builds a directed graph of strong class references and
/// detects retain cycles using depth-first search.
///
/// An edge is added for every stored, non-`weak`/`unowned` instance property
/// with a type annotation. Computed properties and `static`/`class` members
/// hold no instance reference and are skipped. Optionals, arrays, dictionary
/// values and single-argument generics (`Array<B>`, `Set<B>`) are unwrapped
/// to the type they contain.
///
/// Edges are between types, not instances. A class that refers to its own
/// type (`var next: Node?`) is a normal linked list or tree, so it is reported
/// as a hint, not as a cycle.
///
/// One graph covers one file. Use `merge(_:)` to combine the graphs of several
/// files before calling `detectCycles()`, so cycles that span files are found.
final class ReferenceGraph: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Graph
    private var nodes: [String: GraphNode] = [:]

    /// Property names that usually point "up" at an owner. These are the
    /// natural place to break a cycle with `weak`.
    private static let backReferenceKeywords = [
        "delegate", "owner", "parent", "coordinator", "datasource",
        "presenter", "container", "superview", "root",
    ]

    // MARK: - Context
    let context: SourceContext

    init(context: SourceContext) {
        self.context = context
        super.init(viewMode: .sourceAccurate)
    }

    convenience init(filePath: String, source: String) {
        self.init(context: SourceContext(filePath: filePath, source: source))
    }

    // MARK: - Build Phase

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let className = node.name.text
        let graphNode = nodes[className] ?? GraphNode(name: className)
        nodes[className] = graphNode

        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }

            let modifiers = Set(varDecl.modifiers.map(\.name.text))
            // weak / unowned can't form cycles; static / class hold no instance reference.
            guard modifiers.isDisjoint(with: ["weak", "unowned", "static", "class"]) else { continue }

            for binding in varDecl.bindings {
                guard let typeAnnotation = binding.typeAnnotation,
                      !isComputed(binding) else { continue }

                let propName = binding.pattern
                    .as(IdentifierPatternSyntax.self)?
                    .identifier.text ?? "unknown"
                let loc = location(of: varDecl)

                graphNode.edges.append(GraphEdge(
                    from: className,
                    to: extractTypeName(from: typeAnnotation.type),
                    propertyName: propName,
                    filePath: filePath,
                    line: loc.line,
                    codeSnippet: codeLine(at: loc.line)
                ))
            }
        }

        return .visitChildren
    }

    /// Adds another file's classes and edges to this graph.
    func merge(_ other: ReferenceGraph) {
        for (name, node) in other.nodes {
            if let existing = nodes[name] {
                existing.edges.append(contentsOf: node.edges)
            } else {
                nodes[name] = node
            }
        }
    }

    // MARK: - Cycle Detection

    /// Run after visiting — detects all cycles in the built graph.
    ///
    /// Roots are visited in name order so the same input always reports the
    /// same cycles on the same lines.
    func detectCycles() {
        var visited = Set<String>()
        var stack   = Set<String>()

        for nodeName in nodes.keys.sorted() where !visited.contains(nodeName) {
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

            // A type that refers to itself is not a cycle between instances.
            if edge.to == current {
                reportSelfReference(edge)
                continue
            }

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
        // `path` starts at the DFS root. Keep only the edges from the closing
        // node onwards: the ones before it lead into the cycle but aren't part of it.
        let cycle = Array(path.drop { $0.from != closingNode })
        guard let lastEdge = cycle.last else { return }

        let keywordEdge = cycle.first(where: isBackReference)
        let breakEdge = keywordEdge ?? lastEdge
        let cycleDescription = cycle
            .map { "\($0.from).\($0.propertyName)" }
            .joined(separator: " → ")

        issues.append(LeakIssue(
            kind: .referenceCycle,
            filePath: breakEdge.filePath,
            line: breakEdge.line,
            column: 1,
            message: "Retain cycle: \(cycleDescription) → \(closingNode)",
            codeSnippet: breakEdge.codeSnippet,
            suggestion: "Make \(breakEdge.from).\(breakEdge.propertyName) weak: weak var \(breakEdge.propertyName): \(breakEdge.to)?",
            detectionTrail: buildTrail(
                cycle: cycle,
                closingNode: closingNode,
                breakEdge: breakEdge,
                matchedKeyword: keywordEdge != nil
            )
        ))
    }

    private func reportSelfReference(_ edge: GraphEdge) {
        let property = "\(edge.from).\(edge.propertyName)"
        issues.append(LeakIssue(
            kind: .referenceCycle,
            severity: .hint,
            filePath: edge.filePath,
            line: edge.line,
            column: 1,
            message: "\(property): type refers to itself",
            codeSnippet: edge.codeSnippet,
            suggestion: "Fine for a list or tree. Make \(edge.propertyName) weak only if an instance can point back at one that already holds it",
            detectionTrail: [
                TrailStep(step: 1, label: "Parsed file",
                          detail: "SwiftSyntax → AST"),
                TrailStep(step: 2, label: "Graph built",
                          detail: "\(nodes.count) classes analysed"),
                TrailStep(step: 3, label: "Self-reference found",
                          detail: "\(property) has type \(edge.to)"),
                TrailStep(step: 4, label: "Not a proven cycle",
                          detail: "The graph tracks types, not instances; reported as a hint")
            ]
        ))
    }

    private func isBackReference(_ edge: GraphEdge) -> Bool {
        let name = edge.propertyName.lowercased()
        return Self.backReferenceKeywords.contains { name.contains($0) }
    }

    // MARK: - Helpers

    /// A binding with a getter (`var x: Foo { ... }` or `get`/`set` accessors)
    /// stores nothing. `willSet`/`didSet` observers leave it a stored property.
    private func isComputed(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessorBlock = binding.accessorBlock else { return false }
        switch accessorBlock.accessors {
        case .getter:
            return true
        case .accessors(let list):
            return list.contains {
                let kind = $0.accessorSpecifier.text
                return kind != "willSet" && kind != "didSet"
            }
        }
    }

    private func extractTypeName(from type: TypeSyntax) -> String {
        if let optional = type.as(OptionalTypeSyntax.self) {
            return extractTypeName(from: optional.wrappedType)
        }
        if let unwrapped = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return extractTypeName(from: unwrapped.wrappedType)
        }
        if let array = type.as(ArrayTypeSyntax.self) {
            return extractTypeName(from: array.element)
        }
        if let dictionary = type.as(DictionaryTypeSyntax.self) {
            return extractTypeName(from: dictionary.value)
        }
        if let identifier = type.as(IdentifierTypeSyntax.self),
           let arguments = identifier.genericArgumentClause?.arguments,
           arguments.count == 1,
           let argument = arguments.first {
            return extractTypeName(from: argument.argument)
        }
        return type.trimmedDescription
    }

    private func buildTrail(
        cycle: [GraphEdge],
        closingNode: String,
        breakEdge: GraphEdge,
        matchedKeyword: Bool
    ) -> [TrailStep] {
        let cycleStr = (cycle.map { $0.from } + [closingNode]).joined(separator: " → ")
        let breakPoint = "\(breakEdge.from).\(breakEdge.propertyName)"
        return [
            TrailStep(step: 1, label: "Parsed file",
                      detail: "SwiftSyntax → AST"),
            TrailStep(step: 2, label: "Graph built",
                      detail: "\(nodes.count) classes analysed"),
            TrailStep(step: 3, label: "DFS traversal",
                      detail: "Depth-first search over reference edges"),
            TrailStep(step: 4, label: "Cycle detected",
                      detail: cycleStr),
            TrailStep(step: 5, label: "Break point chosen",
                      detail: matchedKeyword
                          ? "\(breakPoint): name looks like a back-reference"
                          : "\(breakPoint): last edge of the cycle, no back-reference name found")
        ]
    }
}
