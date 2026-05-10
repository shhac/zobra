# Changelog

All notable changes to zobra are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-05-11

First public release. Cobra parity is feature-complete for the core, doc generators, and shell completion. **Zig 0.16+ only.**

### Added — core (Phases 0–6, cobra-parity)

- **Parser** — pflag-faithful argv tokenizer; schema-aware short-group splitter; `--`/passthrough; positional and flag-value interleaving with cobra-byte-identical errors.
- **34 flag types** — full pflag parity: 16 scalars, 9 slices, 3 maps, 3 network (IP/IPMask/IPNet), 2 bytes (hex/base64), 1 `CustomFlag` vtable (the `pflag.Value` interface escape hatch).
- **Command tree** — children, aliases, deprecated marker, `findCommand`/`findChildByNameOrAlias`/`commandPathString`, `argsLenAtDash`.
- **Five-stage hook chain** — `persistent_pre_run` → `pre_run` → `run` → `post_run` → `persistent_post_run`, with first-found-wins parent walk. Both `Fn` (void) and `FnE` (anyerror) variants.
- **Args validators** — `noArgs`, `arbitraryArgs`, `minimumN`, `maximumN`, `exactN`, `range`, `onlyValidArgs`.
- **Flag groups** — `markFlagsMutuallyExclusive`, `markFlagsRequiredTogether`, `markFlagsOneRequired`, with cobra-byte-identical violation messages.
- **Help renderer** — pflag-byte-aligned columns, `--help`/`-h` auto-injection (lazy on first execute), `help [command]` subcommand, `setHelpFunc`/`setUsageFunc` overrides.
- **`--version` auto-injection** — when `Command.version` is non-empty, lazy long-only `--version` flag matching cobra's behaviour.
- **Levenshtein suggestions** — on unknown subcommand names (`disable_suggestions` to turn off, `suggestions_minimum_distance` to tune).
- **`executeAndPrint`** — cobra's `Execute()` auto-print path: on parse-layer error, prints `Error: <msg>\n` + usage block to `err_writer`, then propagates the typed error. `silence_errors` / `silence_usage` toggles.
- **`setOut` / `setErr`** — explicit-IO writer plumbing per Zig 0.16's `*std.Io.Writer`.

### Added — satellite modules

- **`zobra-doc`** (`@import("zobra-doc")`) — `genMarkdown` / `genMarkdownTree` / `genYaml` / `genYamlTree` / `genReST` / `genReSTTree` / `genMan` / `genManTree`. The tree generators take `io: std.Io` (Zig 0.16's explicit-IO).
- **`zobra-completion`** (`@import("zobra-completion")`) — `genBashCompletion` (V2) / `genZshCompletion` / `genFishCompletion` / `genPowerShellCompletion`; the `__complete` runtime callback hidden subcommand; `installCompletionCommand` for cobra's auto-registered `completion [shell]` subcommand. `ShellCompDirective` constants byte-identical to cobra.

### Added — testing infrastructure

- **277 unit tests** across `test/parser/`, `test/command/`, `test/flag/`, `test/coverage/`, `test/completion/`, `test/doc/`, plus inline tests in `src/`.
- **9 E2E smoke tests** in `examples/hello/test_e2e.zig` — spawn the built `zobra-example` binary as a subprocess and assert on stdout/stderr/exit code.
- **Shared oracle with vipvot** — `oracle/main.go` builds a Go cobra binary; `test/fixtures/` captures stdout/stderr/exit for the differential matrix.

### Architecture

- **Explicit allocators.** Every fallible function that allocates takes an `Allocator`; caller owns returned slices unless the function name says otherwise. See `design-docs/08-allocator-conventions.md`.
- **`Diagnostic` out-parameter.** Errors are flat tags (`error.UnknownFlag`); rich structured context (the pflag-byte-identical wording, the flag name, the raw argv element) goes via `?*Diagnostic`. See `design-docs/07-error-model.md`.
- **No `*Var` ambiguity.** Only the `*VarP` family (with shorthand). Pass `0` for no shorthand.
- **Layered source tree:** `parser/` → `flag/` → `command/` → `help/` → `doc/` / `completion/`. Lower layers never import upward.

### Documentation

- `README.md` — quick taste + status of record + design-doc index.
- `COMPARISON.md` — full cobra-vs-zobra feature matrix.
- `examples/` — runnable demo + porting recipes (more to land iteratively).
- `design-docs/00–11` — vision, name, cobra mapping, architecture, parser, oracle testing, roadmap, error model, allocator conventions, divergences, comptime-vs-runtime, public surface.

### Known divergences from cobra

See `design-docs/09-zobra-divergences.md` for the full list. Highlights:

- `pflag.Value` interface → `CustomFlag` vtable struct (Zig has no nominal interfaces).
- `text/template` help templates → function-form `setHelpFunc` / `setUsageFunc` only.
- Dynamic completion (`ValidArgsFunction`, `RegisterFlagCompletionFunc`) — deferred; static `valid_args` is supported.
- `intSlice` accepts hex/octal/binary (pflag is decimal-only). Documented strconv exception.

### Installation

```zig
// build.zig.zon
.dependencies = .{
    .zobra = .{
        .url = "https://github.com/shhac/zobra/archive/refs/tags/v0.1.0.tar.gz",
        // .hash filled in by `zig fetch --save`
    },
},
```

```zig
// build.zig
const zobra = b.dependency("zobra", .{ .target = target, .optimize = optimize });
my_module.addImport("zobra", zobra.module("zobra"));
// Optional satellites:
my_module.addImport("zobra-doc", zobra.module("zobra-doc"));
my_module.addImport("zobra-completion", zobra.module("zobra-completion"));
```
