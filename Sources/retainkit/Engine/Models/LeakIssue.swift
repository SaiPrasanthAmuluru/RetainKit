//
//  LeakIssue.swift
//  retainkit
//
//  Created by Sai Prasanth Amuluru on 25/09/26.
//

import Foundation

// MARK: - Severity

/// How serious a detected issue is.
public enum IssueSeverity: String, Sendable, Comparable, CaseIterable {
    case hint    = "hint"
    case warning = "warning"
    case error   = "error"

    private var sortOrder: Int {
        switch self {
        case .error:   return 0
        case .warning: return 1
        case .hint:    return 2
        }
    }

    public static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - Issue Kind

/// The category of memory leak pattern detected.
public enum IssueKind: String, Sendable, CaseIterable {
    case escapingClosure     = "LC-W001"
    case implicitSelf        = "LC-W002"
    case storedClosure       = "LC-W003"
    case uninvalidatedTimer  = "LC-W004"
    case unremovedObserver   = "LC-W005"
    case strongDelegate      = "LC-W006"
    case closureInCollection = "LC-W007"
    case referenceCycle      = "LC-W008"

    public var displayName: String {
        switch self {
        case .escapingClosure:     return "Escaping closure captures self strongly"
        case .implicitSelf:        return "Implicit self capture in closure"
        case .storedClosure:       return "Stored closure captures self"
        case .uninvalidatedTimer:  return "Timer is not invalidated"
        case .unremovedObserver:   return "Observer registered but never removed"
        case .strongDelegate:      return "Strong delegate assignment"
        case .closureInCollection: return "Closure with self stored in collection"
        case .referenceCycle:      return "Circular reference cycle detected"
        }
    }

    public var defaultSeverity: IssueSeverity {
        switch self {
        case .escapingClosure:     return .error
        case .implicitSelf:        return .warning
        case .storedClosure:       return .error
        case .uninvalidatedTimer:  return .error
        case .unremovedObserver:   return .warning
        case .strongDelegate:      return .warning
        case .closureInCollection: return .warning
        case .referenceCycle:      return .error
        }
    }

    public var suggestion: String {
        switch self {
        case .escapingClosure:
            return "Add [weak self] to the closure capture list"
        case .implicitSelf:
            return "Add explicit [weak self] capture list"
        case .storedClosure:
            return "Use [weak self] in the closure or make the property weak"
        case .uninvalidatedTimer:
            return "Call timer?.invalidate() in deinit"
        case .unremovedObserver:
            return "Call removeObserver(self) in deinit"
        case .strongDelegate:
            return "Declare the delegate property as weak"
        case .closureInCollection:
            return "Capture self weakly inside the closure before appending"
        case .referenceCycle:
            return "Make one of the references weak or unowned"
        }
    }
}

// MARK: - Trail Step

/// One step in the detection reasoning chain.
/// Shown in the detail panel (screen 04 of the design).
public struct TrailStep: Sendable {
    public let step: Int
    public let label: String
    public let detail: String

    public init(step: Int, label: String, detail: String) {
        self.step = step
        self.label = label
        self.detail = detail
    }
}

// MARK: - LeakIssue

/// A single detected memory leak or retention issue.
public struct LeakIssue: Sendable, Hashable {

    // MARK: Identity
    public let kind: IssueKind
    public let severity: IssueSeverity

    // MARK: Location
    public let filePath: String
    public let line: Int
    public let column: Int

    // MARK: Content
    public let message: String
    public let codeSnippet: String
    public let suggestion: String
    public let detectionTrail: [TrailStep]
    public let isAutoFixable: Bool

    // MARK: Init
    public init(
        kind: IssueKind,
        severity: IssueSeverity? = nil,
        filePath: String,
        line: Int,
        column: Int,
        message: String,
        codeSnippet: String,
        suggestion: String? = nil,
        detectionTrail: [TrailStep] = [],
        isAutoFixable: Bool = false
    ) {
        self.kind = kind
        self.severity = severity ?? kind.defaultSeverity
        self.filePath = filePath
        self.line = line
        self.column = column
        self.message = message
        self.codeSnippet = codeSnippet
        self.suggestion = suggestion ?? kind.suggestion
        self.detectionTrail = detectionTrail
        self.isAutoFixable = isAutoFixable
    }

    // MARK: Hashable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(filePath)
        hasher.combine(line)
        hasher.combine(column)
    }

    public static func == (lhs: LeakIssue, rhs: LeakIssue) -> Bool {
        lhs.kind == rhs.kind &&
        lhs.filePath == rhs.filePath &&
        lhs.line == rhs.line &&
        lhs.column == rhs.column
    }
}
