# 04 — Parser

The argv parser is the foundation. Every other layer trusts that the parser handles every weird POSIX/GNU edge case. This document is the catalogue.

## Why we write our own

Zig's stdlib has no argv parser equivalent to cobra/pflag. Existing third-party Zig parsers (yazap, zig-clap, zig-flags) are good but each makes design choices that don't compose with the cobra command-tree mental model — they own the dispatch, not just the tokenization. We need a tokenizer we can layer the cobra runtime on top of, so we write our own.

The vipvot port lives in TypeScript and made the same call (see vipvot's `04-parser.md` for the full rationale against `util.parseArgs`). zobra's parser is a direct mechanical translation of vipvot's, with Zig idioms substituted: tagged unions for tokens, error sets + Diagnostic for failures, slices instead of arrays, `[]const u8` instead of `string`.

## Token alphabet

The parser emits a stream of tokens, not a structured result. Higher layers consume the stream:

```zig
pub const Token = union(enum) {
    long: Long,                 // --foo, --foo=bar, --foo bar
    short: Short,               // -f, -fbar (when -f takes a value)
    short_group: ShortGroup,    // -abc (boolean group)
    negated: Negated,           // --no-foo
    positional: Positional,     // anything not starting with -
    terminator,                 // --
    passthrough: []const u8,    // emitted only after a terminator

    pub const Long = struct {
        name: []const u8,        // "foo"
        value: ?[]const u8,      // null if --foo with no value
        raw: []const u8,         // "--foo=bar" — for error wording
    };
    pub const Short = struct {
        name: u8,                // 'f'
        value: ?[]const u8,
        raw: []const u8,
    };
    pub const ShortGroup = struct {
        names: []const u8,       // "abc" (each char is a flag)
        raw: []const u8,
    };
    pub const Negated = struct {
        name: []const u8,        // "foo" for --no-foo
        raw: []const u8,
    };
    pub const Positional = struct {
        value: []const u8,
    };
};
```

Crucially, the parser is **schema-aware**: it must know which short flags are value-taking to disambiguate `-fbar` (= `-f bar`) from `-fbar` (= `-f -b -a -r`). The parser takes a `FlagSchema` parameter alongside argv.

```zig
pub const FlagSchema = struct {
    is_value_taking_short: *const fn (c: u8) bool,
    is_count_short: *const fn (c: u8) bool,
    is_known_long: *const fn (name: []const u8) bool,
    /// Returns true when `name` (with the `no-` prefix stripped) refers to a
    /// boolean long flag. zobra makes every boolean negatable (deliberate
    /// divergence from pflag — see 09-zobra-divergences.md), so this drives
    /// `--no-foo` recognition directly.
    is_boolean_long: *const fn (name: []const u8) bool,
};
```

The function-pointer shape lets the command runtime build a schema view that already accounts for inherited persistent flags, without the parser knowing anything about command trees.

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
- `---name` — pflag rejects with `bad flag syntax: ---name`. The parser emits a `long` token with `name = "-name"` so the flag layer can detect the leading-dash and produce the matching error. (differential)
- `--=value` — pflag rejects with `bad flag syntax: --=value`. Parser emits `long` with empty name; flag layer rejects. (differential)

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
