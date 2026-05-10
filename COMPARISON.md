# zobra vs cobra — feature comparison

A landing page for "what does zobra have today, and where does it diverge from cobra?" Distilled from `design-docs/02-cobra-mapping.md`, `design-docs/06-roadmap.md`, and `design-docs/09-zobra-divergences.md`. Treat those as canonical.

zobra mirrors cobra's surface so a port reads as a mechanical rewrite. The translation is:

| Concept | Cobra (Go) | zobra (Zig) |
|---|---|---|
| Construct a command | `&cobra.Command{Use: "x", ...}` | `try Command.init(allocator, .{ .use = "x", ... })` |
| Field/method casing | PascalCase (`Run`, `RunE`, `PreRun`) | snake_case (`run`, `run_e`, `pre_run`) |
| Pointer-to-variable | `var v string; cmd.Flags().StringVar(&v, …)` | `var v: []const u8 = ""; cmd.flags().stringVarP(&v, …)` (native `*T`) |
| Import root | `import "github.com/spf13/cobra"` | `@import("zobra")` |
| Doc generators | `import "github.com/spf13/cobra/doc"` | `@import("zobra-doc")` (✓) |
| Completion generators | bundled in cobra core | `@import("zobra-completion")` (✓) |

## Side-by-side: a small command

**Cobra (Go):**

```go
var name string
var verbose int

var rootCmd = &cobra.Command{
    Use:   "myapp",
    Short: "my CLI",
    RunE: func(cmd *cobra.Command, args []string) error {
        fmt.Printf("hello, %s\n", name)
        return nil
    },
}

func init() {
    rootCmd.PersistentFlags().StringVarP(&name, "name", "n", "world", "who to greet")
    rootCmd.PersistentFlags().CountVarP(&verbose, "verbose", "v", "verbose level")
    rootCmd.MarkFlagRequired("name")
}
```

**zobra (Zig):**

```zig
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var name: []const u8 = "world";
    var verbose: i32 = 0;

    const root = try zobra.Command.init(arena, .{
        .use = "myapp",
        .short = "my CLI",
        .run_e = greet,
    });
    defer root.deinit();

    try root.persistentFlags().stringVarP(&name, "name", 'n', "world", "who to greet");
    try root.persistentFlags().countVarP(&verbose, "verbose", 'v', "verbose level");
    try root.markFlagRequired("name");

    try root.executeAndPrint(try init.minimal.args.toSlice(arena));
}

fn greet(cmd: *zobra.Command, args: []const []const u8) anyerror!void {
    _ = args;
    std.debug.print("hello, world\n", .{});
}
```

## Command tree

| Capability | Cobra | zobra |
|---|:---:|:---:|
| Tree of commands, `addCommand` | ✓ | ✓ |
| Subcommand resolution by name + alias | ✓ | ✓ |
| Persistent flags (inherited) | ✓ | ✓ |
| `disable_flag_parsing` for proxy commands | ✓ | ✓ |
| `allow_unknown_flags` (`fParseErrWhitelist.unknownFlags`) | ✓ | ✓ |
| `--help` / `-h` auto-injection (collision-safe) | ✓ | ✓ |
| `<cmd> help [path]` subcommand | ✓ | ✓ |
| `--version` auto-injection | ✓ | ✓ (long-only; `-v` not auto-bound to avoid count-collision) |
| Aliases | ✓ | ✓ |
| Hidden / deprecated commands | ✓ | partial (field stored, runtime warning deferred — see § Divergences) |
| Suggestions on unknown subcommand | ✓ | ✓ |

## Hooks

The five-stage chain (`persistent_pre_run` → `pre_run` → `run` → `post_run` → `persistent_post_run`) with cobra's parent-walk semantics for persistent stages (first-found-wins by default).

| Capability | Cobra | zobra |
|---|:---:|:---:|
| `*Run` / `*RunE` non-error vs error variants | ✓ | ✓ |
| Parent-walk for persistent hooks | ✓ | ✓ |
| `EnableTraverseRunHooks` (root-down all-fire) | ✓ | implemented in hook.zig (no Command toggle yet) |

## Flag types — full pflag parity (33)

zobra ships **34 flag types** vs vipvot's 26 + 7-deferred-from-pflag and pflag's 33.

| Family | Types | Status |
|---|---|:---:|
| Scalars (16) | `string`, `bool`, `int`, `int8/16/32/64`, `uint/8/16/32/64`, `float32/64`, `count`, `duration` | ✓ |
| Slices (9) | `stringSlice`, `stringArray`, `intSlice`, `int32Slice`, `int64Slice`, `float32Slice`, `float64Slice`, `boolSlice`, `durationSlice` | ✓ |
| Maps (3) | `stringToString`, `stringToInt`, `stringToInt64` | ✓ |
| Network (3) | `ip`, `ipMask`, `ipNet` (CIDR) | ✓ |
| Bytes (2) | `bytesHex`, `bytesBase64` | ✓ |
| Custom (1) | `CustomFlag` vtable (the pflag.Value escape hatch) | ✓ |

Error wording for bad inputs is byte-for-byte from pflag's `strconv.Parse{Bool,Int,Uint,Float}` / `Atoi` / `time.ParseDuration` family. Pinned by `test/coverage/wording.zig` and the per-type tests under `test/flag/`.

zobra-specific mappings:
- `int` → `*i64`, `uint` → `*u64` (Go's `int` is 64-bit on dominant target; matching for fixture parity rather than `*i32`/`*u32`).
- `duration` → `*i64` nanoseconds (matches Go's `time.Duration`).

## Flag modifiers

| Capability | Cobra | zobra |
|---|:---:|:---:|
| `MarkFlagRequired` | ✓ | ✓ |
| `Flags().MarkHidden` | ✓ | ✓ |
| `Flags().MarkDeprecated` | ✓ | ✓ (warning emission deferred — see § Divergences) |
| `Flags().Changed(name)` accessor | ✓ | ✓ (`fs.changed(name)`) |
| `Flags().Set(name, value)` | ✓ | ✓ |

## Flag groups

```zig
try cmd.markFlagsMutuallyExclusive(&.{ "file", "url" });
try cmd.markFlagsRequiredTogether(&.{ "user", "password" });
try cmd.markFlagsOneRequired(&.{ "json", "yaml" });
```

All three error wordings are byte-identical to cobra (verified in `test/command/command.zig`).

## Args validators

```zig
cmd.args = zobra.args.minimumN(1);
cmd.args = zobra.args.matchAll(&.{ zobra.args.minimumN(1), zobra.args.onlyValid });
```

| Validator | Cobra | zobra |
|---|:---:|:---:|
| `MinimumNArgs`, `MaximumNArgs`, `ExactArgs`, `RangeArgs` | ✓ | ✓ |
| `OnlyValidArgs`, `NoArgs`, `ArbitraryArgs`, `MatchAll` | ✓ | ✓ |
| `cmd.valid_args` runtime acceptance for OnlyValidArgs | ✓ | ✓ |
| Wording with command-path qualifier (`"X" for "tool greet"`) | ✓ | ✓ |
| Diagnostic `valid_values` populated on OnlyValidArgs failure | n/a | ✓ (zobra extension) |

## Help & usage

| Capability | Cobra | zobra |
|---|:---:|:---:|
| Help format byte-identical | n/a | ✓ |
| `--help` / `-h` auto-injection | ✓ | ✓ (collision-safe) |
| `<cmd> help [path]` auto-dispatch | ✓ | ✓ |
| `setOut` / `setErr` writers (parent-chain inherit) | ✓ | ✓ |
| `setHelpFunc` / `setUsageFunc` (function-form) | ✓ | ✓ |
| Auto-print `Error: <msg>` + usage on parse error | ✓ | ✓ (`executeAndPrint`) |
| `silenceErrors` / `silenceUsage` toggles | ✓ | ✓ |
| Levenshtein "did you mean?" | ✓ | ✓ |
| `SetUsageTemplate` / `SetHelpTemplate` (Go text/template) | ✓ | ✗ (deliberate non-goal — function-form covers) |

## Errors

| Capability | Cobra | zobra |
|---|:---:|:---:|
| Byte-identical pflag error wording | n/a | ✓ |
| Structured error with `category` / `code` / `suggestion` / `valid_values` | n/a | ✓ (`Diagnostic`) |
| Multi-error surfacing | first-error-bails | first-error-bails |
| Diagnostic out-parameter (vs error wrapping) | n/a | zobra-only (Zig idiom) |

## Doc generators (`zobra-doc` subpath)

**Status: Phase 8 — deferred.** vipvot ships markdown / yaml / rest / man generators; zobra will land them as a satellite module (`b.addModule("zobra-doc", ...)`) rather than bundling. No part of doc generation is implemented yet.

| Generator | Cobra | zobra |
|---|:---:|:---:|
| `genMarkdown` / `genMarkdownTree` | ✓ | deferred |
| `genYaml` / `genYamlTree` | ✓ | deferred |
| `genReST` / `genReSTTree` | ✓ | deferred |
| `genMan` / `genManTree` (roff) | ✓ | deferred |

## Shell completion (`zobra-completion` subpath)

**Status: ✓ shipped (MVP).** Satellite module wired through `b.addModule("zobra-completion", ...)`. Wire protocol (`value\tdesc\n...:directive\n`) matches cobra's exactly so the existing shell completion ecosystem composes cleanly. Scripts are functional but simplified vs cobra's vendored byte-identical copy — if a fixture forces byte-for-byte parity, the templates can be replaced without touching the runtime.

| Capability | Cobra | zobra |
|---|:---:|:---:|
| `genBashCompletion` (V2) | ✓ | ✓ |
| `genZshCompletion`, `genFishCompletion`, `genPowerShellCompletion` | ✓ | ✓ |
| `__complete` runtime callback | ✓ | ✓ (auto-registered hidden subcommand) |
| `ShellCompDirective*` constants | ✓ | ✓ (`Default`, `Error`, `NoSpace`, `NoFileComp`, `FilterFileExt`, `FilterDirs`, `KeepOrder`) |
| `CompletionOptions` (toggles) | ✓ | ✓ (`disable_default_cmd`, `hidden_default_cmd` wired) |
| Auto-registered `completion` subcommand | ✓ | ✓ (`installCompletionCommand`) |
| Static `valid_args` candidate filtering | ✓ | ✓ |
| Long-flag candidate completion (`--…`) | ✓ | ✓ |
| `validArgsFunction` (dynamic per-command callback) | ✓ | deferred (Cobra's static `validArgs` covers most use cases; dynamic callback adds a Command field — see § Divergences) |
| `registerFlagCompletionFunc` (per-flag dynamic) | ✓ | deferred (FlagSet field — see § Divergences) |
| Shorthand-flag candidates (`-x`) | ✓ | deferred (single-char candidates rarely render usefully) |

## Packaging

| Concern | Cobra | zobra |
|---|---|---|
| Import root | one Go pkg | `@import("zobra")` |
| Doc generators | `cobra/doc` (separate Go pkg) | `zobra-doc` (deferred) |
| Completion templates | bundled in core | `zobra-completion` (deferred) |
| Runtime dependencies | Go stdlib + spf13/pflag | none |

## Deliberate non-goals (won't ship)

| Cobra feature | Why not | Workaround |
|---|---|---|
| `SetUsageTemplate` / `SetHelpTemplate` (Go `text/template`) | ~hundreds of lines for `{{if}}` / `{{range}}` / `{{.Field}}` parsing; Zig has no stdlib equivalent. | `setHelpFunc` / `setUsageFunc` (function-form). |
| `BashCompletionFunction` legacy blocks | Predates cobra's `__complete` runtime; superseded. | `valid_args_function` (when Phase 9 lands). |
| `completionV1` legacy bash protocol | Backwards-compat for old shell scripts isn't worth the maintenance. | `genBashCompletion` (V2) when Phase 9 lands. |

## Divergences (per design-docs/09)

| Behaviour | Cobra | zobra | Reason |
|---|---|---|---|
| `--no-foo` for booleans | requires per-flag `NoOptDefVal` opt-in | universal for all booleans | Cobra users widely expect `--no-foo` to work everywhere; pflag's opt-in is a footgun. |
| `intSlice` element bases | decimal-only (Atoi) | accepts hex/octal | zobra reuses the scalar int parser; minor divergence. |
| Underscore digit separator | rejected | accepted | Zig std accepts; documented divergence. |
| Deprecated-flag warnings | printed to stderr on use | silent | The Diagnostic.Code variant + Flag.deprecated fields are in place; emission is deferred until a later pass. |
| `addCommand` already-parented / self-parent | absorbed into Go's GC | rejected with explicit error | Memory-safety hazard zobra cannot tolerate. |

## Where to look next

- **Per-symbol concordance** — [`design-docs/02-cobra-mapping.md`](design-docs/02-cobra-mapping.md).
- **Divergences with rationale and workarounds** — [`design-docs/09-zobra-divergences.md`](design-docs/09-zobra-divergences.md).
- **Phased status of record** — [`design-docs/06-roadmap.md`](design-docs/06-roadmap.md).
