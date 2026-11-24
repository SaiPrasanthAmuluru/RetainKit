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
/// The receiver's type is not known, so `map` on an array and `map` on a
/// Combine publisher look alike by name. `isReactiveChain(memberNames:)`
/// tells them apart from the rest of the call chain: every closure handed to
/// an operator in a publisher chain is kept by the subscription.
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

    /// Members that only appear in a Combine publisher chain: ways to get a
    /// publisher, operators with no `Sequence` counterpart, and subscribers.
    /// Everyday words that Combine also uses (`store`, `share`, `publish`)
    /// are left out on purpose, so `cache.store.items.map { }` stays a
    /// plain sequence call.
    static let reactiveMarkers: Set<String> = [
        // Sources
        "publisher", "dataTaskPublisher", "objectWillChange",
        "Just", "Future", "Deferred", "Empty", "Fail", "Publishers",
        "PassthroughSubject", "CurrentValueSubject", "AnyPublisher",
        // Operators
        "eraseToAnyPublisher", "receive", "subscribe", "debounce", "throttle",
        "removeDuplicates", "switchToLatest", "combineLatest",
        "autoconnect", "handleEvents", "tryMap", "replaceError", "setFailureType",
        // Subscribers
        "sink", "assign",
    ]

    /// True when a call chain is a Combine pipeline.
    ///
    /// - Parameter memberNames: Every name in the chain a call belongs to,
    ///   e.g. `["$query", "debounce", "map", "sink", "store"]` for
    ///   `$query.debounce(...).map { }.sink { }.store(in: &bag)`.
    ///
    /// A `$name` member is a property wrapper's projected value, which for
    /// `@Published` is its publisher.
    static func isReactiveChain(memberNames: [String]) -> Bool {
        memberNames.contains { isProjectedValue($0) || reactiveMarkers.contains($0) }
    }

    /// `$query` is a `@Published` projected value; `$0` and `$1` are
    /// closure parameters and say nothing about the chain.
    private static func isProjectedValue(_ name: String) -> Bool {
        name.hasPrefix("$") && !name.dropFirst().allSatisfy(\.isNumber)
    }

    static func behavior(ofCallee name: String) -> EscapeBehavior {
        if escaping.contains(name) { return .escaping }
        if nonEscaping.contains(name) { return .nonEscaping }
        return .unknown
    }
}
