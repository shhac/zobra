# zobra examples

User-facing recipes for porting cobra CLIs to zobra. Lives outside `src/` so the example sources don't ship to consumers via `build.zig.zon`'s `paths`.

For maintainer-facing design memos, see [`design-docs/`](../design-docs/). For per-symbol cobra-to-zobra mapping, see [`design-docs/02-cobra-mapping.md`](../design-docs/02-cobra-mapping.md).

## Reading order

If you're porting a cobra app, skim the recipes below in order. If you're hunting a specific symbol, the per-symbol concordance is more direct.

## Runnable demos

The `hello/` directory ships a small demo CLI that exercises the full Command tree, persistent flags, the args validator, and `executeAndPrint`'s auto-print error path:

```sh
zig build run -- greet          # → hello, world
zig build run -- --name=alice greet
zig build run -- greet bob      # positional overrides --name
zig build run -- -vv greet      # count flag clustered
zig build run -- --help
```

The same binary is the target of the E2E smoke tests at [`hello/test_e2e.zig`](hello/test_e2e.zig) — run with `zig build test-e2e`.

## Recipes

| File | Pattern | Why interesting |
| --- | --- | --- |
| [01-persistent-flags.md](01-persistent-flags.md) | `persistentFlags().stringVarP(...)` | Inheritance shape; how leaf commands see ancestor flags |
| [02-args-validators.md](02-args-validators.md) | `zobra.args.maximumN(1)`, `minimumN`, `exactN`, `range`, `noArgs` | The five-validator family + how to compose |
| [03-flag-types.md](03-flag-types.md) | All 34 flag types (scalar / slice / map / IP / bytes / custom) | What to use for what |
| [04-hooks.md](04-hooks.md) | The five-stage hook chain (persistent_pre → pre → run → post → persistent_post) | Ordering, first-found-wins parent walk, error short-circuit |
| [05-flag-groups.md](05-flag-groups.md) | `markFlagsMutuallyExclusive`, `markFlagsRequiredTogether`, `markFlagsOneRequired` | Declarative cross-flag constraints |
| [06-custom-flag.md](06-custom-flag.md) | `CustomFlag` vtable — pflag's `Value` interface escape hatch | When the 33 built-in types don't fit |
| [07-stdio-and-errors.md](07-stdio-and-errors.md) | `setOut` / `setErr` / `executeAndPrint` / `Diagnostic` | Explicit-IO patterns; auto-print vs. structured-error paths |
| [08-completion.md](08-completion.md) | `zobra-completion`: scripts + auto-installed `completion` subcommand | The bash / zsh / fish / powershell wire-up |
| [09-doc-generators.md](09-doc-generators.md) | `zobra-doc`: markdown / yaml / rest / man | How to ship docs alongside your binary |

Conventions:
- cobra blocks tagged ` ```go `, zobra blocks tagged ` ```zig `.
- Both kept structurally aligned line-by-line where possible — the diff is the mechanical port.
- "Subtlety" notes call out behaviour that doesn't survive the mechanical rewrite (e.g. an extra explicit-IO line in the Zig form, or `*T` instead of `&var`).

## Per-recipe stub

Each recipe file follows this shape:

```
# NN — <pattern>

## Cobra (Go)
```go
…
```

## zobra (Zig)
```zig
…
```

## Notes
- Mechanical mappings: `RunE: func(…)` → `.run_e = fn(…)`, `Args: cobra.X` → `.args = zobra.args.X`, etc.
- Subtleties: where the port can't be 1:1 (e.g. `pflag.Value` → `CustomFlag` vtable struct).
```

The recipe files are written iteratively as users hit each pattern. PRs welcome.
