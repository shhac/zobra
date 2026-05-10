# 02 — Cobra mapping

This document is the structured concordance between cobra (Go) and zobra (Zig).

**Design goal**: a developer fluent in cobra Go should be able to port code to zobra by mechanical rewrite. Identifiers, struct-field semantics, method names, and call shapes are kept identical except where Zig's syntax or idioms force a change.

The forced changes are documented up front so they aren't surprising:

| Cobra (Go) | zobra (Zig) | Why |
|---|---|---|
| `&cobra.Command{Use: "x", ...}` | `Command.init(allocator, .{ .use = "x", ... })` | Zig has no global `init()` registration; allocation is explicit. |
| `Use`, `RunE`, `PersistentPreRun` | `use`, `run_e`, `persistent_pre_run` | snake_case is the Zig field-name convention. PascalCase is types only. |
| `var v string; cmd.Flags().StringVar(&v, …)` | `var v: []const u8 = ""; try cmd.flags().stringVar(&v, …)` | Zig has native `*T`; no `Ref<T>` shim is needed. |
| `RunE func(cmd *cobra.Command, args []string) error` | `run_e: ?*const fn (cmd: *Command, args: []const []const u8) anyerror!void` | Function pointer, error union return. |
| `fmt.Errorf("%w: …", err, …)` | `error{...}` + `*Diagnostic` out-parameter | Zig errors are flat tags. Rich context goes through a diagnostic struct (the pattern `std.json` uses). See [07-error-model.md](07-error-model.md). |
| `cmd.UseLine()` returning a derived string | `try cmd.useLine(allocator)` | Anywhere cobra returns a heap-backed slice or string, zobra takes an allocator and the caller owns the result. The configured fields (`use`, `short`, etc.) are still accessible directly as borrow-only slices; the `*Line(allocator)` shape is for derivations that allocate. See [08-allocator-conventions.md](08-allocator-conventions.md). |
| `init()` function side-effect-registers commands | `Command.init` returns a value; you wire trees explicitly | No global registration; comptime is offered as an alternative declarative form. See [10-comptime-vs-runtime.md](10-comptime-vs-runtime.md). |

Everything else is the same shape as cobra.

## Command struct → Command type

Go (cobra):

```go
var rootCmd = &cobra.Command{
    Use:           "myapp",
    Short:         "my CLI",
    Long:          "longer description",
    Example:       "myapp greet alice",
    Aliases:       []string{"app"},
    Hidden:        false,
    Deprecated:    "",
    SilenceUsage:  false,
    SilenceErrors: false,
    Args:          cobra.MinimumNArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error { return nil },
}
```

Zig (zobra):

```zig
var root_cmd = try zobra.Command.init(allocator, .{
    .use            = "myapp",
    .short          = "my CLI",
    .long           = "longer description",
    .example        = "myapp greet alice",
    .aliases        = &.{"app"},
    .hidden         = false,
    .deprecated     = "",
    .silence_usage  = false,
    .silence_errors = false,
    .args           = zobra.args.minimumN(1),
    .run_e          = struct {
        fn run(cmd: *zobra.Command, args: []const []const u8) anyerror!void {
            _ = cmd; _ = args;
        }
    }.run,
});
defer root_cmd.deinit();
```

Notes on the cluster of Zig idioms in that block:

- `Command.init` is the explicit factory; it allocates internal buffers (children list, flag set, hook table) using the allocator. There is no global `init()` and no zero-cost default Command.
- `defer root_cmd.deinit()` — the caller owns the tree. `deinit` recursively frees children.
- `run_e` is a raw function pointer. The Zig idiom for "named anonymous function" is the `struct { fn run … }.run` extraction; users may also pass a top-level `fn` directly. Closures-with-captures aren't a Zig thing — see "Closures and captures" below.
- The `args` field takes an args validator. Validators are values (not free functions on a `cobra.` namespace), so they're constructed: `zobra.args.minimumN(1)`, `zobra.args.exactN(2)`, `zobra.args.matchAll(.{...})`.

## Hook fields

All five cobra hook fields exist by the same names (snake-cased):

| Cobra | zobra |
|---|---|
| `PersistentPreRunE` | `persistent_pre_run_e` |
| `PreRunE` | `pre_run_e` |
| `RunE` | `run_e` |
| `PostRunE` | `post_run_e` |
| `PersistentPostRunE` | `persistent_post_run_e` |

Cobra also exposes non-`E` variants (`PreRun`, `Run`, etc.) that don't return errors. zobra mirrors them as `pre_run`, `run`, `post_run`, `persistent_pre_run`, `persistent_post_run`. Both forms accept Zig function pointers; the non-`E` form returns `void`, the `E` form returns `anyerror!void`.

Inheritance rules match cobra: `persistent_pre_run_e` defined on an ancestor fires for descendants unless an intermediate ancestor defines its own.

## Subcommand registration

```go
parent.AddCommand(child)
```

```zig
try parent.addCommand(child);
```

Identical shape. Returns an error union because Zig's `ArrayList.append` may fail to allocate; the `try` is the only forced addition.

## Flag binding

Cobra uses pointer arguments to bind flags into local variables:

```go
var name string
var verbose int
var tags []string

rootCmd.PersistentFlags().StringVarP(&name, "name", "n", "world", "who to greet")
rootCmd.PersistentFlags().CountVarP(&verbose, "verbose", "v", "verbose level")
rootCmd.PersistentFlags().StringSliceVarP(&tags, "tag", "t", nil, "tags")
```

Zig has `*T` natively, so the call is identical in shape:

```zig
var name: []const u8 = "world";
var verbose: i32 = 0;
var tags: []const []const u8 = &.{};

try root_cmd.persistentFlags().stringVarP(&name, "name", "n", "world", "who to greet");
try root_cmd.persistentFlags().countVarP(&verbose, "verbose", "v", "verbose level");
try root_cmd.persistentFlags().stringSliceVarP(&tags, "tag", "t", &.{}, "tags");
```

The non-`Var` variants (return-the-pointer style) are also mirrored, but the Zig idiom is to bind to your own variable, so we treat the `*Var*` family as the primary path. We expose the non-`Var` form for porting symmetry, but it has to allocate internal storage to back the returned pointer; if that's a concern, use the `*VarP` form.

## Flag types

Same alphabet as cobra/pflag, with Zig representations:

### Scalars

| Cobra | zobra | Zig type |
|---|---|---|
| `StringVarP` | `stringVarP` | `*[]const u8` |
| `BoolVarP` | `boolVarP` | `*bool` |
| `IntVarP` | `intVarP` | `*i64` (matches Go's `int` on 64-bit; the dominant target) |
| `Int8VarP` | `int8VarP` | `*i8` |
| `Int16VarP` | `int16VarP` | `*i16` |
| `Int32VarP` | `int32VarP` | `*i32` |
| `Int64VarP` | `int64VarP` | `*i64` |
| `UintVarP` | `uintVarP` | `*u64` (matches Go's `uint` on 64-bit) |
| `Uint8VarP` | `uint8VarP` | `*u8` |
| `Uint16VarP` | `uint16VarP` | `*u16` |
| `Uint32VarP` | `uint32VarP` | `*u32` |
| `Uint64VarP` | `uint64VarP` | `*u64` |
| `Float32VarP` | `float32VarP` | `*f32` |
| `Float64VarP` | `float64VarP` | `*f64` |
| `CountVarP` | `countVarP` | `*i32` (counts in practice are small; keeping this slim) |
| `DurationVarP` | `durationVarP` | `*i64` (nanoseconds, like Go's `time.Duration`) |

### Slices

Backed by `[]const T` populated via `ArrayList(T)` internally; the binding returns ownership to the user via the allocator passed at flag-set creation.

| Cobra | zobra | Zig type |
|---|---|---|
| `StringSliceVarP` | `stringSliceVarP` | `*[]const []const u8` |
| `StringArrayVarP` | `stringArrayVarP` | `*[]const []const u8` (no comma-split) |
| `IntSliceVarP` | `intSliceVarP` | `*[]const i32` |
| `Int32SliceVarP` | `int32SliceVarP` | `*[]const i32` |
| `Int64SliceVarP` | `int64SliceVarP` | `*[]const i64` |
| `Float32SliceVarP` | `float32SliceVarP` | `*[]const f32` |
| `Float64SliceVarP` | `float64SliceVarP` | `*[]const f64` |
| `BoolSliceVarP` | `boolSliceVarP` | `*[]const bool` |
| `DurationSliceVarP` | `durationSliceVarP` | `*[]const i64` |

### Maps

| Cobra | zobra | Zig type |
|---|---|---|
| `StringToStringVarP` | `stringToStringVarP` | `*std.StringHashMap([]const u8)` |
| `StringToIntVarP` | `stringToIntVarP` | `*std.StringHashMap(i32)` |
| `StringToInt64VarP` | `stringToInt64VarP` | `*std.StringHashMap(i64)` |

(Map flags own their key/value memory; the flag set's allocator owns it. Drop the map by dropping the flag set or calling `cmd.deinit()`.)

### Network and bytes

| Cobra | zobra | Zig type |
|---|---|---|
| `IPVarP` | `ipVarP` | `*[]const u8` (canonicalised IP literal) |
| `IPMaskVarP` | `ipMaskVarP` | `*[]const u8` |
| `IPNetVarP` | `ipNetVarP` | `*[]const u8` (CIDR string) |
| `BytesHexVarP` | `bytesHexVarP` | `*[]const u8` |
| `BytesBase64VarP` | `bytesBase64VarP` | `*[]const u8` |

### `pflag.Value` interface — `CustomFlag` vtable

Cobra/pflag exposes a `Value` interface with `String() string`, `Set(string) error`, `Type() string`. Zig has no runtime interfaces, so we use an **explicit vtable struct**:

```zig
pub const CustomFlag = struct {
    ptr: *anyopaque,
    type_name: []const u8,
    /// Parses `value` and stores it through `ptr`.
    set_fn: *const fn (ptr: *anyopaque, value: []const u8) anyerror!void,
    /// Renders the current value to a string for help/defaults.
    /// **Caller frees the returned slice with the same allocator passed in.**
    string_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
};
```

Built-in scalar / slice / map types are registered through their typed `*VarP` methods (which know the static type at the call site); they don't go through `CustomFlag`. `CustomFlag` is purely the escape hatch for user-defined types — the equivalent of pflag's `cmd.Flags().Var(myValue, …)`.

We expose:

```zig
try cmd.flags().varP(.{
    .ptr = &my_value,
    .type_name = "ip-cidr-list",
    .set_fn = MyValue.set,
    .string_fn = MyValue.string,
}, "subnets", "s", "comma-separated CIDR blocks");
```

The rationale is in [10-comptime-vs-runtime.md](10-comptime-vs-runtime.md).

## Flag modifiers

```go
rootCmd.MarkFlagRequired("name")
rootCmd.PersistentFlags().MarkHidden("debug")
rootCmd.Flags().MarkDeprecated("old", "use --new instead")
```

```zig
try root_cmd.markFlagRequired("name");
try root_cmd.persistentFlags().markHidden("debug");
try root_cmd.flags().markDeprecated("old", "use --new instead");
```

## Flag groups

```go
cmd.MarkFlagsRequiredTogether("a", "b")
cmd.MarkFlagsMutuallyExclusive("a", "b")
cmd.MarkFlagsOneRequired("a", "b")
```

```zig
try cmd.markFlagsRequiredTogether(&.{ "a", "b" });
try cmd.markFlagsMutuallyExclusive(&.{ "a", "b" });
try cmd.markFlagsOneRequired(&.{ "a", "b" });
```

(Zig doesn't have variadic args of homogeneous strings, so we take a slice. Same shape, one extra `&.{}`.)

## Args validators

cobra's built-in validators all exist with the same names, namespaced under `zobra.args`:

```go
cmd.Args = cobra.MinimumNArgs(1)
cmd.Args = cobra.ExactArgs(2)
cmd.Args = cobra.MatchAll(cobra.MinimumNArgs(1), cobra.OnlyValidArgs)
```

```zig
cmd.args = zobra.args.minimumN(1);
cmd.args = zobra.args.exactN(2);
cmd.args = zobra.args.matchAll(.{ zobra.args.minimumN(1), zobra.args.onlyValid });
```

The PascalCase `MinimumNArgs` becomes `minimumN` (camelCase function on a namespace; the redundant `Args` suffix drops because the namespace already says it).

## Help & usage

| Cobra | zobra | Notes |
|---|---|---|
| `cmd.SetOut(w)` / `cmd.SetErr(w)` | `cmd.setOut(*std.Io.Writer)` / `cmd.setErr(*std.Io.Writer)` | Uses Zig 0.16's `std.Io.Writer` interface. |
| `--help` / `-h` auto-injection | same | |
| `<cmd> help [path]` real subcommand | same | |
| `cmd.SetHelpFunc(fn)` | `cmd.setHelpFunc(fn)` | Function pointer. |
| `cmd.SetUsageFunc(fn)` | `cmd.setUsageFunc(fn)` | Function pointer. |
| `cmd.SetUsageTemplate(...)` (text/template) | _deferred_ | Cobra uses Go's `text/template`; Zig has no equivalent stdlib package. The function variants cover most use cases; revisit if porting code uses string templates. |
| `cmd.SetHelpTemplate(...)` (text/template) | _deferred_ | Same reasoning. |
| `cmd.SetHelpCommand(c)` | `cmd.setHelpCommand(c)` | |
| `cmd.AddGroup(&cobra.Group{ID:"a",Title:"…"})` | `try cmd.addGroup(.{ .id = "a", .title = "…" })` | |

## Command surface (other than flags / hooks / args)

| Cobra | zobra |
|---|---|
| `Command.Annotations map[string]string` | `cmd.annotations: std.StringHashMap([]const u8)` |
| `Command.DisableFlagParsing` | `disable_flag_parsing` option |
| `Command.DisableFlagsInUseLine` | `disable_flags_in_use_line` option |
| `Command.SuggestFor []string` | `suggest_for: []const []const u8` |
| `Command.DisableSuggestions` | `disable_suggestions` option |
| `Command.SuggestionsMinimumDistance` | `suggestions_minimum_distance` (default 2) |
| `Command.SilenceUsage` | `silence_usage` option |
| `Command.SilenceErrors` | `silence_errors` option |
| `Command.Hidden` | `hidden` option |
| `Command.Deprecated` | `deprecated` option |
| `Command.Aliases []string` | `aliases: []const []const u8` |
| `Command.Example string` | `example: []const u8` |
| `Command.ValidArgs []string` | `valid_args: []const []const u8` |
| `Command.ArgAliases []string` | `arg_aliases: []const []const u8` |
| `Command.Version` | `version: []const u8` (auto-injects `--version`; `-v` short is **not** auto-bound to avoid colliding with the conventional `-v` count for `verbose` — the user can opt in by setting `version_short: u8 = 'V'` or similar) |
| `Command.SetContext` / `Command.Context` | _deferred_ — Go's `context.Context` doesn't have a direct Zig analogue; revisit when a port needs cancellation. |
| `Command.TraverseChildren` | covered by persistent-flag inheritance |
| `Command.FParseErrWhitelist` | `f_parse_err_whitelist: struct { unknown_flags: bool = false }` |
| `cobra.EnableTraverseRunHooks` (module-level) | `zobra.setEnableTraverseRunHooks(true)` |

## Errors and exit codes

Cobra's defaults: print usage on parse errors, just-the-error on Run errors, exit 1 on any failure. zobra matches exactly; `silence_usage` and `silence_errors` work the same way.

**Error wording** is byte-for-byte identical to pflag's, captured from a real cobra binary and pinned by the differential fixtures.

**Multi-error surfacing**: pflag returns at the first parse error; subsequent flags are not bound. zobra matches this — `FlagSet.apply` walks tokens and returns at the first error, leaving any later valid flags unbound.

**Error returns from hooks**: Go uses `error` returns. Zig uses error unions (`anyerror!void`). The `*_e` hooks return `anyerror!void`; the non-`*_e` hooks return `void`. Mechanically equivalent; see [07-error-model.md](07-error-model.md).

**Diagnostic out-parameter**: cobra's `fmt.Errorf("%w: parsing flag %q: %s", ErrFlagParse, name, raw)` flattens to a `Diagnostic` struct in zobra. The error tag stays minimal (`error.FlagParseFailed`); the structured context (flag name, raw value, position, suggestion) lives in a `Diagnostic` the caller passes in. Pattern lifted from `std.json.parseFromSlice(T, allocator, slice, .{ .diagnostics = &diag })`. Full details in [07-error-model.md](07-error-model.md).

## Path mapping (multi-module package)

zobra ships as one Zig package with multiple importable modules, mirroring cobra's directory-as-Go-package layout:

| Cobra import | zobra import | Status |
|---|---|---|
| `github.com/spf13/cobra` | `@import("zobra")` | Phase 1 |
| `github.com/spf13/cobra/doc` | `@import("zobra-doc")` | deferred |
| _(in cobra core)_ | `@import("zobra-completion")` | deferred |

Each module is exposed via `b.addModule(...)` in our `build.zig`; downstream consumers reference them by name in their own `build.zig.zon` dependency.

## Closures and captures

Zig has no closures. Cobra's hooks are `func(cmd *cobra.Command, args []string) error` — typically defined as inline anonymous functions that capture variables from the surrounding scope. In zobra they're function pointers without captures. Two patterns cover the gap:

- **Pass state through the command.** `cmd.context`-style — store a `*anyopaque` on the command and read it in the hook. (Available; see "deferred" note above on `SetContext`. Until that lands, package-level `var` works for application bootstrap.)
- **Closure-style via comptime.** When the captured state is comptime-known, define the hook inside a `struct { fn run … }` block that closes over the comptime values. This is the equivalent of a closure in Zig and is genuinely zero-cost.

A `cmd.bindContext(ptr)` helper (Phase ≥3) bridges the runtime case.

## Deferred / not yet implemented

Tracked here so they aren't lost. None block the cobra-port use case.

- `pflag.Value` interface for custom flag types — covered by `FlagValue.custom` once Phase 5 lands.
- `SetUsageTemplate` / `SetHelpTemplate` — Go `text/template`; function variants cover most real use cases.
- `BashCompletionFunction` — legacy bash custom-completion blocks; superseded by `valid_args_function`.
- `completionV1` (legacy bash V1 protocol).
- `Command.Context()` / `SetContext()` — pending until a port needs cancellation semantics.
- Plugin discovery — no cobra equivalent; would be a zobra extension.

When extending, add a row to one of the tables above first, then implement.

## Porting recipe

For a Go-cobra to zobra port:

1. struct literals `&cobra.Command{...}` → `try Command.init(allocator, .{...})` with snake_case keys.
2. Globals `var v string` → `var v: []const u8 = ""` (or whatever Zig type matches the flag type table above).
3. `&variable` arguments to `*VarP` setters → same `&variable`. Native Zig pointers; no `Ref` shim.
4. Method calls — PascalCase to camelCase, otherwise verbatim. Most calls become `try cmd.xyz(...)` because they may allocate.
5. `cobra.MinimumNArgs(...)` → `zobra.args.minimumN(...)`.
6. `func(cmd *cobra.Command, args []string) error { ... }` → top-level `fn` or `struct { fn run … }.run` taking `*Command, []const []const u8` and returning `anyerror!void`.
7. `import "github.com/spf13/cobra/doc"` → `@import("zobra-doc")` (deferred).

That's the whole transformation. No re-architecting beyond "replace global state with explicit allocator passing."
