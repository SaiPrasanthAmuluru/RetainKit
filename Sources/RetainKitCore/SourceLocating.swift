//
//  SourceLocating.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import Foundation
import SwiftSyntax
import SwiftParser

// MARK: - Source Context

/// Everything a visitor needs to know about the file it is walking.
///
/// Built once per file and shared by all visitors, so the source is parsed
/// a single time no matter how many visitors run over it.
struct SourceContext {
    let filePath: String
    let tree: SourceFileSyntax
    let sourceLines: [String]
    let locationConverter: SourceLocationConverter

    /// Wraps an already-parsed tree.
    init(filePath: String, tree: SourceFileSyntax, source: String) {
        self.filePath = filePath
        self.tree = tree
        self.sourceLines = source.components(separatedBy: .newlines)
        self.locationConverter = SourceLocationConverter(fileName: filePath, tree: tree)
    }

    /// Parses `source`. Use `init(filePath:tree:source:)` when a tree already exists.
    init(filePath: String, source: String) {
        self.init(filePath: filePath, tree: Parser.parse(source: source), source: source)
    }
}

// MARK: - SourceLocating Protocol

/// Provides line/column resolution and snippet lookup for syntax nodes.
/// Conform any visitor to this to get both for free.
protocol SourceLocating {
    var context: SourceContext { get }
}

extension SourceLocating {

    var filePath: String { context.filePath }

    /// Returns the 1-based line and column for any syntax node.
    func location(of node: some SyntaxProtocol) -> (line: Int, column: Int) {
        let loc = context.locationConverter.location(
            for: node.positionAfterSkippingLeadingTrivia
        )
        return (loc.line, loc.column)
    }

    /// Returns the trimmed source text of a 1-based line, or "" when out of range.
    func codeLine(at line: Int) -> String {
        guard line > 0, line <= context.sourceLines.count else { return "" }
        return context.sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
    }
}
