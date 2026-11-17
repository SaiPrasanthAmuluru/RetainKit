//
//  ReferenceGraph.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax

// MARK: - Graph Node

/// Identifies one class declaration. Two classes may share a name
/// (`private class Helper` in two files, or the same name in two modules),
/// so the declaring file is part of the identity.
struct GraphNodeID: Hashable, Comparable {
    /// Name including enclosing types, e.g. `Outer.Inner`.
    let name: String
    let filePath: String

    static func < (lhs: GraphNodeID, rhs: GraphNodeID) -> Bool {
        (lhs.name, lhs.filePath) < (rhs.name, rhs.filePath)
    }
}

/// Represents a class in the reference graph.
final class GraphNode {
    let id: GraphNodeID
    var edges: [GraphEdge] = []

    init(id: GraphNodeID) {
        self.id = id
    }
}

// MARK: - Graph Edge

/// A directed strong reference from one class to another.
struct GraphEdge {
    /// The declaring class.
    let fromID: GraphNodeID
    /// The property's type as written, with containers unwrapped. It is
    /// resolved to a class when cycles are detected, see `resolve(_:)`.
    let to: String
    let propertyName: String
    let filePath: String
    let line: Int
    let codeSnippet: String

    /// Qualified name of the declaring class.
    var from: String { fromID.name }
}

// MARK: - Reference Graph

/// Builds a directed graph of strong class references and
/// detects retain cycles using depth-first search.
///
/// An edge is added for every stored, non-`weak`/`unowned` instance property
/// with a type annotation. Computed properties and `static`/`class` members
/// hold no instance reference and are skipped.
///
/// Standard containers are unwrapped to the type they hold: `B?`, `[B]`,
/// `[K: B]`, `Optional<B>`, `Array<B>`, `Set<B>`, `Dictionary<K, B>`.
/// Any other generic is an edge to the generic type itself, so `Node<T>`
/// points at `Node`, not at `T`.
///
/// Edges are between types, not instances. A class that refers to its own
/// type (`var next: Node?`) is a normal linked list or tree, so it is reported
/// as a hint, not as a cycle.
///
/// Classes are identified by qualified name and file, so two classes that
/// share a name stay separate. A property type is resolved like Swift does:
/// nested types of the declaring class first, then outwards, preferring a
/// declaration in the same file. A name declared in several other files is
/// ambiguous and adds no edge.
///
/// One graph covers one file. Use `merge(_:)` to combine the graphs of several
/// files before calling `detectCycles()`, so cycles that span files are found.
final class ReferenceGraph: SyntaxVisitor, SourceLocating {

    // MARK: - Output
    private(set) var issues: [LeakIssue] = []

    // MARK: - Graph
    private var nodes: [GraphNodeID: GraphNode] = [:]

    /// Declarations by qualified name; rebuilt by `detectCycles()`.
    private var idsByName: [String: [GraphNodeID]] = [:]

    /// Property names that usually point "up" at an owner. These are the
    /// natural place to break a cycle with `weak`.
    private static let backReferenceKeywords = [
        "delegate", "owner", "parent", "coordinator", "datasource",
        "presenter", "container", "superview", "root",
    ]

    /// Generic types that hold their single argument strongly.
    private static let singleElementContainers: Set<String> = [
        "Optional", "Array", "ContiguousArray", "ArraySlice", "Set",
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
        let id = GraphNodeID(name: qualifiedName(of: node), filePath: filePath)
        let graphNode = nodes[id] ?? GraphNode(id: id)
        nodes[id] = graphNode

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
                    fromID: id,
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
        for (id, node) in other.nodes {
            if let existing = nodes[id] {
                existing.edges.append(contentsOf: node.edges)
            } else {
                nodes[id] = node
            }
        }
    }

    // MARK: - Cycle Detection

    /// Run after visiting — detects all cycles in the built graph.
    ///
    /// Roots are visited in name order so the same input always reports the
    /// same cycles on the same lines.
    func detectCycles() {
        idsByName = Dictionary(grouping: nodes.keys.sorted(), by: \.name)

        var visited = Set<GraphNodeID>()
        var stack   = Set<GraphNodeID>()

        for id in nodes.keys.sorted() where !visited.contains(id) {
            dfs(current: id, visited: &visited, stack: &stack, path: [])
        }
    }

    /// Finds the class an edge points at, or nil when it is not a scanned
    /// class or the name is ambiguous.
    ///
    /// For a property of `Outer.Inner` typed `Item`, the candidates are
    /// `Outer.Inner.Item`, `Outer.Item`, then `Item`. The first name that is
    /// declared anywhere wins; among several declarations of it, the one in
    /// the edge's own file is used.
    private func resolve(_ edge: GraphEdge) -> GraphNodeID? {
        var scope = edge.from.split(separator: ".").map(String.init)
        while true {
            let candidate = (scope + [edge.to]).joined(separator: ".")
            if let ids = idsByName[candidate] {
                if let sameFile = ids.first(where: { $0.filePath == edge.filePath }) {
                    return sameFile
                }
                return ids.count == 1 ? ids[0] : nil
            }
            if scope.isEmpty { return nil }
            scope.removeLast()
        }
    }

    private func dfs(
        current: GraphNodeID,
        visited: inout Set<GraphNodeID>,
        stack: inout Set<GraphNodeID>,
        path: [GraphEdge]
    ) {
        visited.insert(current)
        stack.insert(current)

        defer { stack.remove(current) }

        guard let node = nodes[current] else { return }

        for edge in node.edges {
            guard let target = resolve(edge) else { continue }

            // A type that refers to itself is not a cycle between instances.
            if target == current {
                reportSelfReference(edge)
                continue
            }

            if !visited.contains(target) {
                dfs(
                    current: target,
                    visited: &visited,
                    stack: &stack,
                    path: path + [edge]
                )
            } else if stack.contains(target) {
                reportCycle(path: path + [edge], closingNode: target)
            }
        }
    }

    private func reportCycle(path: [GraphEdge], closingNode closingID: GraphNodeID) {
        let closingNode = closingID.name
        // `path` starts at the DFS root. Keep only the edges from the closing
        // node onwards: the ones before it lead into the cycle but aren't part of it.
        let cycle = Array(path.drop { $0.fromID != closingID })
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

    /// `Inner` declared inside `Outer` (or `extension Outer`) is `Outer.Inner`.
    private func qualifiedName(of node: ClassDeclSyntax) -> String {
        var parts = [node.name.text]
        var ancestor = node.parent
        while let current = ancestor {
            if let decl = current.as(ClassDeclSyntax.self) {
                parts.append(decl.name.text)
            } else if let decl = current.as(StructDeclSyntax.self) {
                parts.append(decl.name.text)
            } else if let decl = current.as(EnumDeclSyntax.self) {
                parts.append(decl.name.text)
            } else if let decl = current.as(ActorDeclSyntax.self) {
                parts.append(decl.name.text)
            } else if let decl = current.as(ExtensionDeclSyntax.self) {
                parts.append(decl.extendedType.trimmedDescription)
            }
            ancestor = current.parent
        }
        return parts.reversed().joined(separator: ".")
    }

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
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            let name = identifier.name.text
            guard let arguments = identifier.genericArgumentClause?.arguments else {
                return name
            }
            if Self.singleElementContainers.contains(name), arguments.count == 1,
               let element = arguments.first {
                return extractTypeName(from: element.argument)
            }
            if name == "Dictionary", arguments.count == 2, let value = arguments.last {
                return extractTypeName(from: value.argument)
            }
            // Node<T> refers to Node, whatever T is.
            return name
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
