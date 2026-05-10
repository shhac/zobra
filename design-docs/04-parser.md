# 04 — Parser

The argv parser is the foundation. Every other layer trusts that the parser handles every weird POSIX/GNU edge case. This document is the catalogue.

## Source of truth: pflag's Go source

When porting parser behaviour, the **canonical reference is [spf13/pflag](https://github.com/spf13/pflag)'s Go source** — specifically `flag.go` (the `parseArgs` / `parseLongArg` / `parseShortArg` / `parseSingleShortArg` family) and `errors.go` (the wording table). cobra wraps pflag for argv parsing; the actual algorithm lives in pflag.

The precedence is:

1. **Behaviour** — the differential fixtures captured from the oracle. The oracle uses real pflag/cobra; if the fixture says X, that's what the parser must produce.
2. **Algorithm** — pflag's Go source. When implementing, read pflag first; the algorithm is small (≈300 lines for the parse path) and unambiguous.
3. **Cross-reference** — the [vipvot](https://github.com/shhac/vipvot) TypeScript port is a parallel implementation, useful as a sanity check and for catching corner cases someone else has already noticed. **It is not authoritative.** If vipvot disagrees with pflag, pflag wins; treating vipvot as the source would compound any drift in vipvot back into zobra.

## Why we write our own

Zig's stdlib has no argv parser equivalent to cobra/pflag. Existing third-party Zig parsers (yazap, zig-clap, zig-flags) are good but each makes design choices that don't compose with the cobra command-tree mental model — they own the dispatch, not just the tokenization. We need a tokenizer we can layer the cobra runtime on top of, so we write our own.

The vipvot port made the same call (see vipvot's `04-parser.md` for the rationale against `util.parseArgs`); zobra inherits that decision but ports from pflag directly, not from vipvot.

## Token alphabet

The parser emits a stream of tokens, not a structured result. Higher layers consume the stream:

```zig
pub const Token = union(enum) {
    long: Long,                 // --foo, --foo=bar, --foo bar
    short: Short,               // -f, -fbar, -f bar (one per shorthand char)
    negated: Negated,           // --no-foo (zobra divergence: universal for booleans)
    positional: Positional,     // anything not starting with -
    terminator,                 // --
    passthrough: []const u8,    // emitted only after a terminator

    pub const Long = struct {
        name: []const u8,        // "foo"
        value: ?[]const u8,      // null if --foo had no attached or consumed value
        raw: []const u8,         // "--foo=bar" — for error wording
    };
    pub const Short = struct {
        name: u8,                // 'f'
        value: ?[]const u8,      // null for boolean/count-style standalone
        raw: []const u8,         // the source argv element ("-fbar", "-abc")
    };
    pub const Negated = struct {
        name: []const u8,        // "foo" for --no-foo
        raw: []const u8,         // "--no-foo"
    };
    pub const Positional = struct {
        value: []const u8,
    };
};
```

There is **no `short_group` kind**. pflag processes each shorthand character independently — `-abc` becomes three logical flag operations, not one group. Our parser mirrors this: `-abc` emits three `short` tokens, each with `raw = "-abc"` so error renderers can still cite the original group.

Crucially, the parser is **schema-aware**: it must know which flags are value-taking to disambiguate `-fbar` (= `-f bar`) from `-fbar` (= `-f -b -a -r`). The parser takes a `FlagSchema` parameter alongside argv.

```zig
pub const FlagSchema = struct {
    /// True if a short flag named `c` exists AND takes a value.
    /// In pflag terms: the flag exists and `NoOptDefVal == ""`.
    /// Returns false for unknown shorts (the parser emits a token; the flag
    /// layer is responsible for rejecting unknown flags).
    is_value_taking_short: *const fn (c: u8) bool,

    /// Same predicate, long form.
    is_value_taking_long: *const fn (name: []const u8) bool,

    /// True if a long flag named `name` is registered (any type). Used for
    /// the literal-no-foo precedence rule: a flag literally registered as
    /// `no-foo` wins over treating `--no-foo` as the negation of `foo`.
    is_known_long: *const fn (name: []const u8) bool,

    /// True if a long flag named `name` is registered as a boolean. Drives
    /// `--no-foo` recognition (zobra divergence — see 09-zobra-divergences.md).
    is_boolean_long: *const fn (name: []const u8) bool,
};
```

The function-pointer shape lets the command runtime build a schema view that already accounts for inherited persistent flags, without the parser knowing anything about command trees.

**Counts are not a parser concern.** A `count` flag (`-vvv` → 3) has no value-taking shape from the parser's POV; `is_value_taking_short('v')` returns false, and the parser emits one `short{name='v'}` token per `v`. The flag layer counts the occurrences. This matches pflag, which uses `NoOptDefVal = "+1"` for counts and processes them through the same standalone-shorthand path as booleans.

## Edge-case catalogue

The list below is the test matrix. Each entry has a corresponding case in `test/parser/`. Cases marked **(differential)** are also captured into `test/fixtures/` from the oracle.

### Long flags

- `--name` — boolean, sets true. (differential)
- `--name=value` — sets value. (differential)
- `--name value` — sets value (when defined as value-taking). (differential)
- `--name=` — sets empty string. (differential)
- `--unknown` — error: `error.UnknownFlag`, Diagnostic carries did-you-mean suggestion. (differential)
- `--name=foo=bar` — value is `foo=bar` (only the first `=` separates). (differential)
- `--no-name` — boolean negation; sets false. Only for boolean flags. **Note**: pflag does *not* enable `--no-` automatically — it requires per-flag `NoOptDefVal` opt-in. zobra treats `--no-` as universally available for booleans (matches cobra users' expectations); this is a deliberate divergence documented in [09-zobra-divergences.md](09-zobra-divergences.md).
- `--no-string-flag` — parser emits a regular `long` token; the flag layer rejects `"no-string-flag"` as unknown (matching pflag's `unknown flag: --no-string-flag`).
- `---name` — pflag rejects eagerly with `bad flag syntax: ---name` (its `parseLongArg` checks `name[0] == '-'` before flag lookup). zobra mirrors pflag exactly: the parser raises `error.BadFlagSyntax` with the full source on the Diagnostic, before any token is emitted. The flag layer is not involved. (differential)
- `--=value` — pflag rejects eagerly with `bad flag syntax: --=value` (same `name[0] == '='` branch). zobra mirrors. (differential)

### Short flags

- `-n` — boolean true, or value-taking awaiting next token.
- `-n value` — separated value.
- `-nvalue` — attached value (only for value-taking flags).
- `-abc` — three boolean shorts (`-a -b -c`), if all three are booleans.
- `-abc` where `-a` takes a value — `-a bc`.
- `-abc` where `-b` takes a value but `-a` doesn't — `-a -b c`.
- `-abc` where `-c` takes a value but is followed by nothing — error: `error.MissingValue`.
- `-vvv` — boolean repeated → set true (last wins) **unless** declared as `count`, then → 3.
- `-n=value` — `=` form on shorts; cobra accepts it.
- `-x` followed by `-y` where `-x` is value-taking — error: `error.MissingValue` (cobra does *not* consume `-y` as the value of `-x`).

### Termination

- `--` — everything after is positional (passthrough).
- `cmd -- --foo` — `--foo` is passthrough, not a flag.
- `cmd --foo --` — `--foo` is parsed; nothing after `--`.

### Positionals & interspersal

- `cmd a --foo b` — flags and positionals interleaved (default cobra behaviour).
- `cmd --foo a b` — flag, then positionals.
- `cmd a b c` — three positionals, no flags.
- Subcommand resolution: `cmd sub a` — `sub` is a child; `a` is positional to `sub`. The parser does not resolve subcommands; it emits positionals and the command runtime consumes leading positionals against the command tree until it finds a terminal command.

### Help

- `--help`, `-h` — emitted as standard tokens; the runtime, not the parser, special-cases help.
- `cmd help sub` — `help` is a positional; runtime reroutes.

### Counted shorts

- `-v` once → 1.
- `-vv` → 2.
- `-vvv` → 3.
- `-vvv -v` → 4.
- `--verbose` (long form of a count) → +1.
- `--verbose=3` → exactly 3 (override).

### Slice flags

Two semantic variants — both exist in pflag:

- `[]const T` (split): `--tag=a,b,c` → `["a","b","c"]`. `--tag a --tag b` → `["a","b"]`.
- `[]const T` (no-split): `--tag=a,b,c` → `["a,b,c"]`. `--tag a --tag b` → `["a","b"]`.

Default is split (`StringSlice`); opt out with `StringArray` (no-split).

### Duration

cobra's duration type uses Go's `time.ParseDuration` syntax: `300ms`, `1.5h`, `2h45m`, `-30s`, `0`. We replicate it. Result is `i64` nanoseconds (matches Go's `time.Duration`).

### Number

Integer and float flags accept `42`, `-7`, `3.14`, `1e6`. Hex (`0xff`) and octal — pflag's `strconv.ParseInt` accepts these for the unsized `int` family but rejects them for `int-slice` / `int32-slice` (which use `strconv.Atoi`, decimal-only). zobra matches both behaviours.

`int64` and `uint64` flags coerce to `i64`/`u64` natively (Zig has the types; no `bigint` shim needed).

### Booleans

- `--bool` → true (when defined as boolean).
- `--bool=true`, `--bool=false`, `--bool=1`, `--bool=0`, `--bool=t`, `--bool=f`, `--bool=T`, `--bool=F` — all valid (cobra/pflag).
- `--no-bool` → false.
- `--bool foo` — does *not* consume `foo` (booleans don't take separated values).

## Algorithm sketch

```zig
/// Combined error set: parser-detected syntax errors plus the allocator's
/// `OutOfMemory`. Higher layers either bubble or normalise into a Diagnostic.
pub const ParserError = ParseError || std.mem.Allocator.Error;

pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    schema: FlagSchema,
    diag: ?*Diagnostic,
) ParserError![]const Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var terminated = false;

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (terminated) {
            try out.append(allocator, .{ .passthrough = arg });
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            try out.append(allocator, .terminator);
            terminated = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLong(allocator, &out, argv, &i, schema, diag);
        } else if (arg.len > 1 and arg[0] == '-') {
            try parseShort(allocator, &out, argv, &i, schema, diag);
        } else {
            try out.append(allocator, .{ .positional = .{ .value = arg } });
        }
    }
    return out.toOwnedSlice(allocator);
}
```

`parseLong` and `parseShort` are factored into `src/core/parser/long.zig` and `src/core/parser/short.zig`. The driver in `parser.zig` is short.

## Things the parser is *not* responsible for

- Type coercion (the flag layer does this).
- Required-flag enforcement.
- Subcommand resolution.
- Help printing.
- Exit codes.

If any of these creep into the parser, push back; that's a layering violation.

## Phase ordering

The parser's **token alphabet** lands in Phase 1 — including `negated` and the schema-aware short-group splitter that disambiguates `-vvv` (count) from `-abc` (boolean group). The parser knows how to *emit* every token kind from the start.

What changes phase-by-phase is the **flag layer's interpretation** of those tokens. Phase 1 wires only `string` and `boolean`. Counted shorts (`count` flag type) and `--no-foo` semantics arrive in Phase 5 with the flag-group constraints, since the flag-layer logic for counts depends on type metadata.

## Why two positional kinds (`positional` vs `passthrough`)

After `--`, every remaining argv element is a *passthrough* positional — distinguished from a regular positional so the flag layer can preserve the boundary if a consumer wants `argsLenAtDash()`-style introspection (cobra exposes this; some users depend on it).

If we conclude no consumer needs the distinction, the two kinds collapse to one. Default until then: keep them split.
