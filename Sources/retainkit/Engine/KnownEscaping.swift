//
//  KnownEscaping.swift
//  retainkit
//

/// Whether a closure passed to a given API outlives the call.
enum EscapeBehavior: Equatable {
    /// The API stores or defers the closure.
    case escaping
    /// The API runs the closure before it returns, so it cannot retain `self`.
    case nonEscaping
    /// The callee is not in either list.
    case unknown
}

/// Name-based lookup of how common APIs treat their closure arguments.
///
/// RetainKit works on syntax only and cannot see a parameter's `@escaping`
/// attribute, so the decision is made from the called function's name.
/// A name that appears in neither list is `.unknown`, which the closure rules
/// report at hint severity instead of guessing.
///
/// Limitation: the match ignores the receiver's type. `map` is treated as
/// non-escaping, which is right for `Sequence` but not for a Combine publisher.
enum KnownEscaping {

    /// APIs that keep the closure after returning.
    static let escaping: Set<String> = [
        // Dispatch / concurrency
        "async", "asyncAfter", "asyncAndWait", "notify", "Task", "detached",
        "addOperation", "addBarrierBlock",
        // Timers and run loops
        "scheduledTimer", "Timer", "perform",
        // Networking
        "dataTask", "downloadTask", "uploadTask", "webSocketTask",
        // Notifications and observation
        "addObserver", "observe", "publisher",
        // Combine
        "sink", "handleEvents", "receive", "assign",
        // UIKit / SwiftUI callbacks that are stored
        "animate", "transition", "addAction", "addTarget", "present", "dismiss",
        "onAppear", "onDisappear", "onChange", "onReceive", "onTapGesture",
    ]

    /// APIs that run the closure synchronously and drop it.
    static let nonEscaping: Set<String> = [
        // Sequence / Collection
        "map", "compactMap", "flatMap", "filter", "forEach", "reduce",
        "sorted", "sort", "first", "last", "firstIndex", "lastIndex",
        "contains", "allSatisfy", "min", "max", "removeAll", "partition",
        "drop", "prefix", "split", "zip", "elementsEqual", "starts",
        // Optional / Result
        "mapError", "flatMapError", "get",
        // Synchronous execution
        "sync", "performAndWait", "performWithoutAnimation", "withAnimation",
        "withExtendedLifetime", "withUnsafePointer", "withUnsafeMutablePointer",
        "withUnsafeBytes", "withUnsafeMutableBytes", "withLock", "autoreleasepool",
        "withCheckedContinuation", "withCheckedThrowingContinuation",
        "withTaskGroup", "withThrowingTaskGroup",
    ]

    static func behavior(ofCallee name: String) -> EscapeBehavior {
        if escaping.contains(name) { return .escaping }
        if nonEscaping.contains(name) { return .nonEscaping }
        return .unknown
    }
}
