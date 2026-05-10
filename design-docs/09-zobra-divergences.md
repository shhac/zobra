# 09 — zobra divergences from cobra

This document lists every place zobra **deliberately** differs from cobra, separated into:

1. **Idiom adaptations** — mechanical rewrites forced by Zig's language. Same observable behaviour, different syntax.
2. **Behavioural divergences** — observably different output / semantics. These are removed from the differential fixtures and live in a separate `zobra-extensions` test suite.
3. **Deliberate non-goals** — features cobra has that zobra won't ship.

## 1. Idiom adaptations (same behaviour, different syntax)

| Cobra | zobra | Reason |
|---|---|---|
| `&cobra.Command{Use: "x", ...}` | `try Command.init(allocator, .{ .use = "x", ... })` | Zig has no global init-side-effect registration; allocators are explicit. |
| PascalCase fields (`Use`, `RunE`) | snake_case fields (`use`, `run_e`) | Zig field convention. |
| Pointer args `&v` to `*VarP` | Same `&v` (native Zig pointer) | No shim needed; Zig already has `*T`. |
| `RunE func(...) error` | `run_e: ?*const fn(...) anyerror!void` | Zig function-pointer + error-union shape. |
| Closures-with-captures in hooks | Top-level `fn` or comptime-captured `struct { fn run … }.run` | Zig has no closures. See [02-cobra-mapping.md § Closures and captures](02-cobra-mapping.md#closures-and-captures). |
| `cobra.MinimumNArgs(...)` | `zobra.args.minimumN(...)` | Namespace-qualified, snake_case function. The `Args` suffix drops because the namespace already says it. |
| `MarkFlagsMutuallyExclusive("a", "b")` (variadic) | `markFlagsMutuallyExclusive(&.{ "a", "b" })` (slice) | Zig has no variadic-args-of-T; we take a slice. |
| `fmt.Errorf("%w: …", err, …)` | `error.X` + `*Diagnostic` out-parameter | Zig errors are flat tags. See [07-error-model.md](07-error-model.md). |
| `cmd.Use` (string field, freely returned) | `cmd.use` (`[]const u8`, borrow-only) + `cmd.useString(allocator)` if derivation needed | Allocators are explicit. See [08-allocator-conventions.md](08-allocator-conventions.md). |

## 2. Behavioural divergences (different observable output)

Each row is a deliberate non-parity decision. These cases are excluded from the differential fixture suite and live under `test/extensions/`.

| Behaviour | Cobra | zobra | Reason |
|---|---|---|---|
| `--no-foo` for booleans | requires per-flag `NoOptDefVal` opt-in | universal for all booleans | Cobra users widely expect `--no-foo` to work everywhere; pflag's opt-in is a footgun. Same divergence as vipvot. |
| Error messages composed via `%w` chain | multi-line wrapping | flattened into Diagnostic | Zig's error ergonomics push against chains; flat is more idiomatic. Wording matches cobra's; only the *structure* of the error value differs. |
| Async hooks | unsupported in cobra | unsupported in zobra | (Same — kept here for documentation completeness.) |
| Lifecycle: `init()` global side effects | normal in Go | unavailable in Zig | Tree wiring is explicit; this is a property of the platform, not a choice. |

If new divergences are introduced, add them here first, then the test suite.

## 3. Deliberate non-goals

These cobra features won't ship in zobra. Each has a workaround.

| Cobra feature | Why deferred / dropped | Workaround |
|---|---|---|
| `SetUsageTemplate` / `SetHelpTemplate` (`text/template`) | Go's `text/template` is ~hundreds of lines to port; no Zig equivalent in stdlib. The function variants (`setHelpFunc`, `setUsageFunc`) cover most use cases. | Pass a custom `*const fn (cmd: *Command, w: *Io.Writer) !void` via `setHelpFunc`. |
| `pflag.Value` interface as nominal interface | Zig has no nominal interfaces. | `FlagValue.custom` tagged-union variant carries a vtable (`set_fn`, `string_fn`, `type_name`). Same expressive power, different shape. |
| `BashCompletionFunction` | Legacy bash custom-completion blocks; superseded by `valid_args_function`. | Use `valid_args_function`. |
| `completionV1` (legacy bash V1 protocol) | New tools should use V2; not ported. | Use `zobra-completion` Phase-9 generators. |
| Plugin discovery | No cobra equivalent in core; would be a zobra extension. | Out of scope. |
| `Command.SetContext` / `Command.Context` | Go's `context.Context` doesn't have a Zig analogue. | `cmd.bindContext(*anyopaque)` + retrieve from hooks (Phase ≥3). |
| `Command.TraverseChildren` | Already covered by persistent-flag inheritance in zobra. | No-op; the behaviour comes for free. |

## 4. The "stricter than cobra" set

These are places zobra is *more strict* than cobra, with the cobra behaviour considered a quirk we choose not to inherit:

- **No silent overflow on sized-int flags.** If `--i8=200` is passed, zobra returns `error.TypeCoercionFailed` with a Diagnostic message matching pflag's `strconv.ParseInt: parsing "200": value out of range`. Cobra/pflag agree here, but it's worth flagging.
- **No partial parsing on flag-set error.** Cobra/pflag stop at the first parse error and zobra matches that — but we don't accept partial state. The Command is left in a clean (pre-execute) state on error; the caller can re-execute with corrected argv.

## 5. The "less strict than cobra" set

Currently empty. If we ever loosen a cobra constraint, document it here.

## When to add a row

- **A user reports** zobra behaves differently from cobra and you want to either fix the divergence or document it intentionally — add a row.
- **The oracle fixture diverges** because of a Zig idiom — add a row to the behavioural-divergences table and remove the case from differential, moving it to `test/extensions/`.
- **You write a workaround** for something cobra has — add a row to the non-goals table noting the workaround.
