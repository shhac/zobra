# 00 — Vision

## What zobra is

A zero-dependency Zig implementation of the cobra CLI framework. Built for **Zig 0.16+**. Designed as a library other Zig projects pull in via `build.zig.zon`; ships a small example executable so the usage shape is self-evident.

The deliverable is a Zig module — `@import("zobra")` — that lets you describe a CLI as a tree of commands with strongly-typed flags, behaves like cobra in observable ways (flag parsing, help output, exit codes, error messages), and stays small enough that bringing it into a Zig project doesn't feel like a tax.

## What "behaves like cobra" actually means

Two things at once:

**(1) API parity, where Zig allows.** A developer fluent in cobra Go should be able to port code to zobra by mechanical rewrite, with a small set of forced changes. The forced changes — described in detail in [02-cobra-mapping.md](02-cobra-mapping.md) — are:

- struct literals `&cobra.Command{Use: "x"}` become `Command.init(allocator, .{ .use = "x" })`. Zig has no global `init()` registration, so command construction is explicit and takes an allocator.
- Field names become `snake_case` (`run_e`, `persistent_pre_run`, `use`, `short`). PascalCase exists in Zig only for types and namespaces.
- Pointer-binding `*VarP(&v, ...)` becomes binding to `*T` directly: `try cmd.flags().stringVarP(&name, "name", "n", "world", "who to greet")`. Zig already has `*T` natively; no `Ref<T>` shim is needed.
- Errors return as Zig error sets (`error{...}`). Cobra's `fmt.Errorf("%w: …", err, …)` rich-context wrapping is replaced by the **diagnostic out-parameter** pattern that `std.json` uses — callers pass an optional `*Diagnostic`, the parser fills in structured context on failure. See [07-error-model.md](07-error-model.md).
- Anywhere cobra returns a slice or string, zobra takes an `Allocator` and the caller owns the result. See [08-allocator-conventions.md](08-allocator-conventions.md).

**(2) Behavioural parity, demonstrably.** Externally observable behaviour matches a real cobra binary for the same inputs:

- Same flag-parsing semantics for short combining, attached values, `--`, `--no-foo`
- Same help output structure (sections, ordering, columns)
- Same exit-code shape (cobra exits 0 on success, 1 on any failure — zobra matches)
- Same hook-firing order across persistent/non-persistent and parent/child boundaries
- Same flag-group enforcement semantics (mutex, required-together, one-required)
- Same error wording, byte-for-byte, where it doesn't conflict with Zig idioms

This is what makes the differential test harness possible: we encode "cobra's behaviour" as captured outputs of a real cobra binary, and assert zobra reproduces them. See [05-oracle-testing.md](05-oracle-testing.md). The harness — and the oracle itself — is shared with the sister project [vipvot](https://github.com/shhac/vipvot) (the TypeScript port). One source of truth across two ports.

## What it isn't

- **Not a fork of cobra.** No Go-to-Zig code translation. The implementation is ours; the contract is cobra's.
- **Not a viper-equivalent.** Configuration loading lives outside this library. If we ever build one, it ships separately.
- **Not a kitchen sink.** No plugin system, no built-in TUI primitives, no logging framework. CLI parsing and dispatch — that is all.
- **Not aiming to replace yazap, zli, zig-clap, or zig-flags.** Those libraries are well-served. zobra exists for the specific case of "I want cobra in Zig" — typically because the developer is fluent in Go cobra and wants the same mental model, or wants the cobra surface (persistent flags, lifecycle hooks, flag groups, suggestions, help templates) without rebuilding it on top of a thin parser.

## Why zobra exists (the gap analysis)

The Zig ecosystem already has good *parsers*:

- **yazap** — declarative, sub-command capable, but parser-shaped — flags and args, not the cobra command-tree mental model.
- **zig-clap** — parser/coercer, no command-tree primitives.
- **zli**, **zig-flags** — similar shape.

What none of them ship is **the cobra mental model**: persistent flags inherited down a tree, the five-stage hook chain, declarative flag-group constraints, command groups in help, suggestions on unknown commands, templated help/usage, and the `*VarP` / args-validator vocabulary. zobra fills exactly that gap — and shares the differential-testing harness with vipvot, so behavioural parity isn't aspirational, it's verifiable.

## Success criteria

In rough order of importance:

1. **Behavioural parity, demonstrably.** A test suite of >200 differential cases, each running through both zobra and cobra, asserting identical observable output (stdout / stderr / exit code).
2. **Zero runtime dependencies.** Importable from `build.zig.zon` with no transitive surface area. Verified by `dependencies = .{}` in our own zon.
3. **Clear separation of layers.** Argv parser, flag registry, command tree, help renderer, and error model are independently testable units.
4. **Port-friendly API.** A cobra Go file translates to zobra Zig by mechanical rewrite. The forced changes are documented and predictable.
5. **Idiomatic Zig.** Allocators are explicit; errors are flat tags with diagnostic out-params; comptime is used where it clarifies (struct-of-flags reflection); runtime is used where dynamism matters (subcommand registration). See [10-comptime-vs-runtime.md](10-comptime-vs-runtime.md).
6. **LLM-friendly diagnostics.** Diagnostic structs include valid values and self-correction hints. We are building this with AI-agent CLIs as a primary use case.

## Non-goals (now, possibly later)

- Man-page generation
- A scaffolder à la `cobra-cli`
- A plugin system
- Internationalisation of help text
- Shell completion generation — deferred to a later phase. Will live behind a separate `zobra/completion` module path so consumers that don't need it pay nothing.

## Audience

- **Primary**: developers fluent in Go cobra who want the same shape in Zig, without giving up Zig's allocator discipline or comptime.
- **Secondary**: agent-CLI authors (and especially LLM-driven CLIs) who want cobra-style help and structured diagnostics out of the box.
- **Tertiary**: Zig CLI authors who like the cobra surface but don't know the Go original.

## How this relates to vipvot

[vipvot](https://github.com/shhac/vipvot) is the same library, in TypeScript, by the same author. Same surface, same differential-testing approach, same oracle binary. Where the two diverge:

- vipvot uses `Ref<T>`; zobra uses native `*T`.
- vipvot uses thrown `Error`s with a typed hierarchy; zobra uses error sets with a `Diagnostic` out-parameter.
- vipvot returns owned `string`s; zobra takes an `Allocator` and returns owned slices the caller frees.
- vipvot is mostly runtime-built; zobra supports both runtime registration *and* a comptime-declarative path that resolves the command tree at compile time.

Everything else — the cobra contract — is the same. A bug found in vipvot's parser is almost certainly the same bug in zobra's parser; the JSON fixture that pinned the cobra wording in vipvot pins it in zobra too.
