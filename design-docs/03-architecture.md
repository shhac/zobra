# 03 — Architecture

## Layering

zobra is five layers stacked, each independently testable:

```
┌────────────────────────────────────────────────────────────────────┐
│ 5. Public API           src/root.zig                                │  re-exports, type surface
├────────────────────────────────────────────────────────────────────┤
│ 4. Help renderer        src/core/help.zig                           │  formats command/flag tree → owned slice
├────────────────────────────────────────────────────────────────────┤
│ 3. Command runtime      src/core/command.zig                        │  tree, dispatch, hook chain, group constraints
├────────────────────────────────────────────────────────────────────┤
│ 2. Flag registry        src/core/flag.zig (+ flag/*.zig)            │  flag definitions, type coercion, validation
├────────────────────────────────────────────────────────────────────┤
│ 1. Argv parser          src/core/parser/                            │  pure tokenizer; argv → token stream
└────────────────────────────────────────────────────────────────────┘
```

Lower layers do not import from higher layers. Layer 1 is pure; layers 2–4 each have a clear input/output contract; layer 5 is a re-export surface.

This layering enables:

- **Unit testing each layer in isolation.** The argv parser has no awareness of command trees, so its tests are pure-function table tests. The flag registry never sees raw argv. The command runtime never sees a raw token stream.
- **Substituting layers.** If we ever want a different argv dialect (Windows-style `/flag`, or a JSON-shaped input), we replace layer 1 only.
- **Incremental implementation.** We can land Phase 1 (parser) without touching higher layers, ship Phase 2 (flags) without touching Phase 3, and so on.

## Source layout

```
zobra/
├── build.zig                    # build graph
├── build.zig.zon                # package manifest
├── src/
│   ├── root.zig                 # public API: re-exports + a small smoke test
│   ├── core/
│   │   ├── command/
│   │   │   ├── command.zig      # Command type, addCommand, execute
│   │   │   ├── hook.zig         # five-stage hook chain dispatcher
│   │   │   ├── args.zig         # args validators: minimumN, exactN, range, onlyValid, …
│   │   │   └── suggest.zig      # Levenshtein-based "did you mean?"
│   │   ├── flag/
│   │   │   ├── flag.zig         # FlagSet type, registration entry points
│   │   │   ├── custom.zig       # CustomFlag vtable (the pflag.Value escape hatch)
│   │   │   ├── coerce.zig       # string → typed (ParseInt/ParseFloat/ParseDuration parity)
│   │   │   ├── duration.zig     # Go time.ParseDuration parity
│   │   │   ├── network.zig      # IP / IPMask / IPNet validation
│   │   │   ├── bytes.zig        # hex / base64 byte slices
│   │   │   ├── slice.zig        # slice-flag handling (split vs no-split)
│   │   │   ├── map.zig          # map-flag handling (StringHashMap-backed)
│   │   │   ├── group.zig        # mutex / required-together / one-required
│   │   │   ├── modifiers.zig    # markRequired / markHidden / markDeprecated
│   │   │   └── format.zig       # flag-value → string for help/defaults
│   │   ├── parser/
│   │   │   ├── parser.zig       # pure parse(argv, schema) → []Token
│   │   │   ├── token.zig        # Token tagged union
│   │   │   ├── long.zig         # long-flag handling
│   │   │   └── short.zig        # short-flag handling, schema-aware disambiguation
│   │   ├── help/
│   │   │   ├── help.zig         # help renderer (Usage, Aliases, Examples, Available Commands, Flags)
│   │   │   └── usage.zig        # usage block (shared by help + error path)
│   │   ├── diagnostic.zig       # Diagnostic struct + categories
│   │   └── errors.zig           # error sets (ParseError, FlagError, CommandError)
│   └── examples/
│       └── todo/
│           └── main.zig         # the demo executable
├── test/
│   ├── all.zig                  # integration entry point (imports unit-test files)
│   ├── parser/                  # pure unit tests for the tokenizer
│   ├── flag/                    # flag-type tests
│   ├── command/                 # tree dispatch, hooks
│   ├── differential/
│   │   ├── matrix.zig           # input cases — argv arrays + metadata
│   │   ├── runner.zig           # runs cases through zobra, compares to fixtures
│   │   └── cases/               # one file per category
│   └── fixtures/
│       └── *.json               # captured oracle outputs (committed)
├── oracle/
│   ├── main.go                  # cobra reference binary (copied verbatim from vipvot)
│   ├── go.mod
│   ├── go.sum
│   └── bin/cobra-oracle         # gitignored
├── scripts/
│   ├── oracle-build.sh
│   ├── oracle-capture.sh
│   └── oracle-sync.sh           # rsync from ../vipvot/oracle/ to ./oracle/
└── design-docs/
```

The `examples/` directory under `src/` is unusual — it lives there so the example shares the `zig fmt --check src/` invocation, but the example exe's `build.zig` rule explicitly puts it under `examples/` for the user-facing path. (Implementation detail; revisit if it confuses.)

## Data flow during `cmd.execute(allocator, argv)`

```
allocator + argv: []const []const u8
  │
  ▼
[1. parser]    tokenize argv into typed tokens (long, short, shortGroup, negated, =, value, --, positional, passthrough)
  │            one resolveCommand pass walks tokens + the command tree to find the
  │            terminal command and its inherited flag set (peek-only; no consumption).
  ▼
[2. flag]      bind tokens to typed values; apply defaults; coerce; validate types;
  │            enforce required, deprecation warnings, group constraints.
  ▼
[3. command]   run the hook chain on the resolved command, walking the parent chain
  │            for persistent hooks. Catch errors, route to error renderer.
  ▼
[4. help]      only invoked when (a) `--help` parsed, (b) no run defined, (c) explicit
  │            `help <command>` subcommand. Reads the command tree and prints.
  ▼
exit code
```

## Module-level rules

- `src/core/parser/` is **pure**: no I/O, no `std.process.exit`, no allocator dependence beyond what the caller passes for token-list storage. Returns data; signals errors via error union + Diagnostic.
- `src/core/flag.zig` and the `flag/` subtree are **pure** in the same sense.
- `src/core/command.zig` is the only place that touches I/O writers (`out_writer`, `err_writer`, `exit`). All I/O paths are injectable for testability — `Command.execute` accepts an optional `Io` struct with `out_writer`, `err_writer`, and an `exit` callback.
- `src/core/help.zig` returns an owned slice. Printing is the caller's job (typically `command.zig`).
- `src/core/errors.zig` defines the error sets. Layers return these; the command runtime translates them into stderr text + exit code.
- `src/core/diagnostic.zig` defines the Diagnostic struct used as the out-parameter on every fallible API.

## Error hierarchy

zobra error sets live in `errors.zig`:

```zig
pub const ParseError = error{
    UnknownFlag,
    UnknownCommand,
    MissingValue,
    InvalidShortGroup,
    BadFlagSyntax,
};

pub const FlagError = error{
    TypeCoercionFailed,
    RequiredFlagMissing,
    FlagGroupViolation,
    DeprecatedFlagUsed,    // not always returned; collected as warning
};

pub const CommandError = error{
    ArgsValidationFailed,
    NoRunDefined,
};
```

The error tag is minimal. Rich context — flag name, raw value, position, suggestion, valid values — lives on the `Diagnostic` struct the caller passes in. Full discussion in [07-error-model.md](07-error-model.md).

## Public surface

```zig
// src/root.zig
pub const Command = @import("core/command.zig").Command;
pub const FlagSet = @import("core/flag.zig").FlagSet;
pub const FlagValue = @import("core/flag/value.zig").FlagValue;
pub const Diagnostic = @import("core/diagnostic.zig").Diagnostic;

pub const args = @import("core/args.zig");
pub const errors = @import("core/errors.zig");

pub const ParseError = errors.ParseError;
pub const FlagError = errors.FlagError;
pub const CommandError = errors.CommandError;
```

The exports mirror cobra's API namespace. Internal modules (`parser/`, `help.zig`, the `flag/` subtree) aren't part of the public surface — if a user needs to render help, they call `try cmd.helpString(allocator)`.

## Concurrency

zobra is single-threaded by design. Hooks return `anyerror!void` synchronously; there is no async/await runtime in zobra. (Zig 0.16's async story is unsettled; we don't depend on it.)

If a future Zig release stabilises async, we revisit. Until then: synchronous everywhere.

## Testing posture

- **Unit tests** for layers 1–2 — pure functions, table tests, fast. Run via `zig build test`.
- **Integration tests** for layer 3 — full `command.execute()` calls with captured stdout/stderr, also via `zig build test`.
- **Differential tests** for the whole stack — zobra vs oracle fixtures. See [05-oracle-testing.md](05-oracle-testing.md).
- **Snapshot tests** for layer 4 — help output is verbatim; fixtures live under `test/fixtures/`.

Coverage targets:

- Parser: high — it is the foundation, gaps cascade. (Zig has no built-in branch-coverage tool yet; we verify completeness by case enumeration in `test/parser/`.)
- Flag registry: high.
- Command runtime: high; some I/O edge cases (e.g. exit-callback paths) may be hard to exercise.
- Help: snapshot via committed fixtures, no coverage target.
