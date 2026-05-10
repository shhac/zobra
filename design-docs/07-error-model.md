# 07 — Error model

## The problem

Zig errors are flat tags with no payload. Cobra/pflag rely on `fmt.Errorf("%w: parsing flag %q: %s", err, name, raw)` to attach rich context — flag name, raw value, position, suggestion — to each error. Going from "flat error tag" to "rich diagnostic" is the core API-shape decision for any port.

## The pattern: error tag + Diagnostic out-parameter

We use a **diagnostic out-parameter** pattern: callers pass a `?*Diagnostic`; the failing layer fills it with structured context before returning the error tag.

The pattern is in the same spirit as `std.json`'s `Diagnostics` (which captures the source-position context for parser errors via `Scanner.enableDiagnostics(&diag)`), but tailored to flag and command errors. The shared insight: Zig error tags carry no payload, so structured context must travel through a separate channel that the caller controls.

```zig
pub const Diagnostic = struct {
    category: ?Category = null,
    code: ?Code = null,
    flag_name: ?[]const u8 = null,
    raw_value: ?[]const u8 = null,
    position: ?usize = null,           // index into argv
    suggestion: ?[]const u8 = null,    // "did you mean --name?"
    valid_values: ?[]const []const u8 = null,
    message: ?[]const u8 = null,       // human-readable, allocated; null if not yet rendered

    // Slices into argv (which outlives the Diagnostic) are NOT owned.
    // `message` and `suggestion` MAY be owned, depending on how they were
    // produced — the helper that allocates them sets `owns_message` /
    // `owns_suggestion` so `deinit` knows what to free.
    owns_message: bool = false,
    owns_suggestion: bool = false,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void { ... }

    pub const Category = enum { parse, flag, command };

    pub const Code = enum {
        unknown_flag,
        unknown_command,
        missing_value,
        invalid_short_group,
        bad_flag_syntax,
        type_coercion_failed,
        required_flag_missing,
        flag_group_violation,
        deprecated_flag_used,
        args_validation_failed,
        no_run_defined,
    };
};
```

All fields are optional and zero-initialised. The library sets `category` and `code` on failure; the caller never pre-fills them with a sentinel. This avoids the misleading "I expected unknown_flag and got something else" anti-pattern.

## The error sets

Error tags are one-to-one with `Code` values where possible:

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
};

pub const CommandError = error{
    ArgsValidationFailed,
    NoRunDefined,
};
```

The mapping from error tag to `Code` is mechanical — the runtime fills the `Code` field on the Diagnostic before returning the tag. This is the "single source of truth" pattern: `Code` is the structured representation, the error tag is the unstructured Zig-language signal.

`DeprecatedFlagUsed` is intentionally **not** an error tag — using a deprecated flag is a warning, not a failure. It's surfaced as a `Diagnostic` written to a separate `warnings_diag` slice (or via a callback); the parse continues.

## Calling pattern

The fallible API takes Diagnostic optionally:

```zig
pub fn parseFlags(
    allocator: std.mem.Allocator,
    flag_set: *FlagSet,
    tokens: []const Token,
    diag: ?*Diagnostic,
) FlagError!void { ... }
```

Caller code looks like:

```zig
var diag: zobra.Diagnostic = .{};
defer diag.deinit(allocator);

zobra.parseFlags(allocator, &flag_set, tokens, &diag) catch |err| {
    // diag is populated; err is the tag
    std.debug.print("{}: {?s}\n", .{ err, diag.message });
    return err;
};
```

When the caller doesn't care about structured context, they pass `null`:

```zig
try zobra.parseFlags(allocator, &flag_set, tokens, null);
```

## Why not multi-error?

Pflag returns at the first parse error — subsequent flags are not bound. zobra matches this; we do not collect a multi-error array. The reason is fixture-level: multi-error semantics would diverge from cobra's observable behaviour.

If a user wants to keep parsing past the first error, they call `parseFlags` repeatedly with the remaining tokens; that's the cobra escape hatch (`fParseErrWhitelist.unknownFlags`) and we mirror it.

## Wording

The `message` field carries the human-readable rendering. Wording matches pflag's `strconv.Parse{Bool,Int,Uint,Float,CSV}` / `Atoi` / `time.ParseDuration` / IP / hex / base64 family **byte-for-byte**, captured from the oracle and pinned by the differential fixtures.

When the wording requires composition (e.g. `unknown flag: --foo`), the renderer in `command.zig` composes from the Diagnostic. The renderer is a small format function; it's not in the parser or flag layer (which would be a layering violation).

## The "auto-print on error" path

Cobra prints the error to stderr and the usage block, then exits 1. zobra mirrors this in the command runtime:

```zig
pub fn execute(self: *Command, allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var diag: Diagnostic = undefined;
    self.runOnce(allocator, argv, &diag) catch |err| {
        if (!self.silence_errors) try self.errWriter().print("Error: {s}\n", .{diag.messageOrFallback(err)});
        if (!self.silence_usage and diag.category == .parse) try self.printUsage();
        return err;
    };
}
```

`silence_errors` and `silence_usage` toggle each path independently, matching cobra.

## How this maps to cobra

| Cobra | zobra |
|---|---|
| `errors.New("unknown flag: --foo")` | `error.UnknownFlag` + `diag.flag_name = "foo"` |
| `fmt.Errorf("%w: %s", ErrParseInt, raw)` | `error.TypeCoercionFailed` + `diag.raw_value = raw, diag.code = .type_coercion_failed` |
| `errors.Is(err, ErrParseInt)` | switch on the tag: `if (err == error.TypeCoercionFailed)` |
| Wrapping (`%w`) chain | flattened into a single Diagnostic struct |

The flattening is intentional. Zig's design pushes against deep error chains; the Diagnostic struct gives us the equivalent structured context without the chain.

## LLM-friendly errors

The Diagnostic struct includes `suggestion` and `valid_values` because the primary use case for zobra (alongside human CLIs) is AI-agent CLIs. An agent that gets `error.UnknownFlag` with `suggestion = "--name"` and `valid_values = ["--name", "--age"]` can self-correct without the user reading the message.

The `message` field is for humans; `suggestion` / `valid_values` are for programmatic consumers.

## Open questions

- **Should `Diagnostic` be one struct or per-category structs?** Currently one struct with optional fields, mirroring `std.json.ParseDiagnostics`. If field-set divergence between categories grows large, split into `ParseDiagnostic`, `FlagDiagnostic`, `CommandDiagnostic` — but for now, one struct is simpler.
- **Should we vendor `pflag`'s error wording table at comptime?** Probably yes once we have ≥ 30 messages; defer until the table is sizeable.
