import ArgumentParser

/// RetainKit — static memory leak detection for Swift.
/// Part of Taiju Tech open-source tooling.
@main
struct RetainKit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retainkit",
        abstract: "Static memory leak detection for Swift.",
        version: "0.1.0",
        subcommands: [Scan.self]
    )
}
