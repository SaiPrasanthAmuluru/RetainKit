//
//  SourceLocating.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import SwiftSyntax
import SwiftParser

// MARK: - SourceLocating Protocol

/// Provides line/column resolution for syntax nodes.
/// Conform any visitor to this to get location lookup for free.
protocol SourceLocating {
    var locationConverter: SourceLocationConverter { get }
}

extension SourceLocating {

    /// Returns the 1-based line and column for any syntax node.
    func location(of node: some SyntaxProtocol) -> (line: Int, column: Int) {
        let loc = locationConverter.location(
            for: node.positionAfterSkippingLeadingTrivia
        )
        return (loc.line, loc.column)
    }
}

// MARK: - Convenience Init Helper

/// Builds a SourceLocationConverter from raw source text.
/// Call this once per visitor init — not per node visit.
func makeLocationConverter(filePath: String, source: String) -> SourceLocationConverter {
    SourceLocationConverter(
        fileName: filePath,
        tree: Parser.parse(source: source)
    )
}
