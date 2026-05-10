# 11 — Public surface and stability

## What's public, what's internal

The public surface lives in `src/root.zig`. Anything imported through `@import("zobra")` is part of the contract; everything else is internal and may change without notice.

Concretely, what's exposed (as phases land):

| Phase | Public symbols (in `root.zig`) |
|---|---|
| 0 | `version`, `hello` (placeholder; goes away in Phase 1) |
| 1 | `Token`, `parser.parse`, `Diagnostic`, `ParseError`, `ParserError` |
| 2 | `FlagSet`, `CustomFlag`, `FlagError` |
| 3 | `Command`, `args` namespace (`minimumN`, `exactN`, `range`, `onlyValid`, `noArgs`, `arbitrary`, `matchAll`), `CommandError` |
| 4+ | help/usage helpers as needed; doc/completion only via separate modules |

What's **not public** even though it's `pub` inside its module:

- Anything under `src/core/parser/` other than `parser.parse` and `Token`.
- Anything under `src/core/flag/` other than the registered `FlagSet` methods.
- Anything under `src/core/command/` other than `Command` and `args`.
- The `help/` subtree — users render help via `cmd.helpString(allocator)` or `cmd.printHelp(writer)`, not by reaching into the renderer.

If a downstream consumer needs internals, they file an issue and we either expose it formally or suggest a different shape.

## Versioning

- **0.0.x — bootstrap.** Anything can change. No stability promises. The differential-test suite is the only thing that's stable.
- **0.x — pre-1.0.** The cobra-port shape is settling. Breaking changes are minor-version bumps; a changelog entry per break.
- **1.0+ — stable.** Semver. Breaking changes are major-version bumps. The cobra-mapping table in `02-cobra-mapping.md` is the contract; if it would change, we go to 2.0.

We don't promise `1.0` until:

- Phases 1–6 have shipped and been used by at least one external consumer.
- The differential-test suite has > 200 cases passing against pinned cobra.
- The diagnostic out-parameter pattern has been validated by a real port (TypeScript users using vipvot don't count here — Zig users using zobra do).

## Module identity

zobra ships as one Zig package (`name = .zobra` in `build.zig.zon`) exposing one primary module (`@import("zobra")`) and, in later phases, satellite modules:

| Module | Phase | Status |
|---|---|---|
| `zobra` | 0+ | Phase 0 stub; grows per the table above. |
| `zobra-doc` | 8 | Deferred. Will ship as `b.addModule("zobra-doc", ...)`. |
| `zobra-completion` | 9 | Deferred. Same shape. |

A consumer adds satellite modules selectively — a CLI that doesn't need shell completion never imports `zobra-completion`, and the unused module isn't built into their executable.

## Build.zig consumer wiring

Downstream `build.zig.zon` adds zobra as a dependency:

```zig
.dependencies = .{
    .zobra = .{
        .url = "git+https://github.com/shhac/zobra#<rev>",
        .hash = "...",
    },
},
```

Downstream `build.zig` resolves and imports it:

```zig
const zobra_dep = b.dependency("zobra", .{
    .target = target,
    .optimize = optimize,
});
const zobra_mod = zobra_dep.module("zobra");

const exe = b.addExecutable(.{
    .name = "myapp",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "zobra", .module = zobra_mod } },
    }),
});
```

The `b.dependency(name, .{...}).module("zobra")` call is what resolves the `b.addModule("zobra", ...)` call in our own `build.zig`. The names match — that's the only contract between our `build.zig` and consumers.

## Source-only distribution

zobra is distributed as Zig source. We don't ship pre-compiled artefacts. The fingerprint in `build.zig.zon` is the package-identity primitive (consumers see it via `zig fetch --save`); we never change it.
