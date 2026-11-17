# RetainKit

Static memory leak detection for Swift. RetainKit reads your source with [SwiftSyntax](https://github.com/swiftlang/swift-syntax) and reports the patterns that most often cause retain cycles: closures that capture `self` strongly, timers and observers that are never cleaned up, strong delegates, and classes that hold each other.

It works on syntax alone. Nothing is compiled or run, so a scan takes well under a second for a typical module.

```
$ retainkit scan Sources
scanned 1 files in 0.0s
1 errors  ·  1 warnings  ·  0 hints

── Sources/ProfileViewModel.swift
   ● LC-W003 · :8
     Stored closure captures self
     onUpdate = { self.name = "loaded" }
     💡 Use [weak self] in the closure or make the property weak

   ▲ LC-W002 · :9
     Closure uses self without a capture list
     DispatchQueue.main.async {
     💡 Add a [weak self] capture list
```

## Requirements

- macOS 13 or later
- Swift 5.10 or later

## Install

Build from source:

```bash
git clone https://github.com/SaiPrasanthAmuluru/RetainKit.git
cd RetainKit
swift build -c release
```

The binary is at `.build/release/retainkit`. Copy it somewhere on your `PATH`, or run it in place with `swift run retainkit`.

## Usage

```bash
retainkit scan <path> [--json] [--fail-on-error]
```

| Argument | Meaning |
|---|---|
| `<path>` | A Swift file, or a directory to scan recursively. |
| `--json` | Print the issues as a JSON array instead of text. |
| `--fail-on-error` | Exit with code 1 if any issue has severity `error`. |

Without `--fail-on-error` the exit code is 0 whatever is found. Warnings and hints never change the exit code.

A file that cannot be read is reported on stderr and skipped; the rest of the directory is still scanned.

### In CI

```bash
retainkit scan Sources --fail-on-error
```

## Rules

| Code | Reported when | Severity |
|---|---|---|
| LC-W001 | A closure captures `[self]` strongly and is passed to an escaping API | error |
| LC-W002 | A closure uses `self` with no capture list and is passed to an escaping API | warning |
| LC-W003 | A closure that uses `self` is assigned to a property | error |
| LC-W004 | A `Timer` is created in a class that never calls `invalidate()` | error |
| LC-W005 | A `NotificationCenter` observer is added and never removed | warning |
| LC-W006 | `x.delegate = self` where `delegate` is not known to be `weak` | warning |
| LC-W007 | A closure that uses `self` is passed to `append` or `insert` | warning |
| LC-W008 | Classes hold strong references to each other in a cycle | error |

Some findings are downgraded to **hint** because syntax alone cannot settle them:

- a closure passed to a function RetainKit does not know (see [Escaping](#escaping))
- a closure assigned to a local variable
- `delegate = self` when the delegate property is declared in another file
- a class that refers to its own type, such as `var next: Node?`

### Escaping

A closure can only retain `self` if it outlives the call it is passed to. RetainKit cannot see a parameter's `@escaping` attribute, so it decides by the name of the function being called:

- **Known non-escaping** (`map`, `filter`, `forEach`, `sync`, …): not reported.
- **Known escaping** (`async`, `Task`, `sink`, `dataTask`, …): reported at the rule's severity.
- **Anything else**: reported as a hint.

The two lists are in [`KnownEscaping.swift`](Sources/RetainKitCore/KnownEscaping.swift).

### What is never reported

- Closures with `[weak self]` or `[unowned self]`, and closures nested inside one (unless it rebinds `self` strongly with `guard let self` first)
- Closures in `struct` and `enum` methods, where `self` is a value
- Closures that run immediately, such as `lazy var x: Foo = { ... }()`
- `weak`, `unowned`, `static` and computed properties, in cycle detection

## Suppressing a finding

Add a `// retainkit:ignore` comment. On a line of its own it silences the next line; after code it silences that line.

```swift
// retainkit:ignore
DispatchQueue.main.async { self.refresh() }

DispatchQueue.main.async { self.refresh() } // retainkit:ignore
```

## JSON output

`--json` prints one object per issue:

```json
{
  "kind": "LC-W003",
  "severity": "error",
  "file": "Sources/ProfileViewModel.swift",
  "line": 8,
  "column": 20,
  "message": "Stored closure captures self",
  "suggestion": "Use [weak self] in the closure or make the property weak",
  "isAutoFixable": false,
  "detectionTrail": [
    { "step": 1, "label": "Parsed file", "detail": "SwiftSyntax → AST" }
  ]
}
```

`detectionTrail` lists the steps that led to the finding. `isAutoFixable` marks issues that a capture list would fix; RetainKit does not apply fixes yet.

## Using the engine as a library

The detection engine is a separate product, `RetainKitCore`, with no dependency on the command-line tool.

```swift
// Package.swift
.package(url: "https://github.com/SaiPrasanthAmuluru/RetainKit.git", branch: "main"),

// target dependencies
.product(name: "RetainKitCore", package: "RetainKit"),
```

```swift
import RetainKitCore

let engine = DetectionEngine()

// One file
let result = engine.analyze(filePath: path, source: source)
for issue in result.issues {
    print(issue.kind.rawValue, issue.line, issue.message)
}

// A directory, with reference cycles detected across files
let results = try engine.analyzeDirectory("Sources")
```

## Limitations

RetainKit reads syntax and resolves no types, so some results are approximate:

- **Escaping is decided by name.** `map` on a Combine publisher is treated as non-escaping, like `map` on an array.
- **Cycles are between types, not instances.** Two classes that reference each other are reported even if no two instances ever do.
- **Extensions of types from other files** are treated as possible classes.
- **A type name declared in several files** is ambiguous in cycle detection and adds no edge.
- **Timers and observers** are checked per class. `invalidate()` on any receiver counts as cleanup, and a `NotificationCenter` stored in a variable is not recognised.
- **Syntax newer than Swift 5.10** may not parse, because the parser is swift-syntax 510.

Treat errors as worth a look and hints as prompts, not proof.

## Development

```bash
swift build
swift test
```

Sources are split into two targets:

| Target | Path | Contents |
|---|---|---|
| `RetainKitCore` | `Sources/RetainKitCore` | Detection engine, visitors, reference graph, models |
| `retainkit` | `Sources/retainkit` | Command-line interface |

## License

RetainKit is available under the MIT License. See [LICENSE](LICENSE).
