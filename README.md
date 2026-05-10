# zobra

A zero-dependency Zig port of [spf13/cobra](https://github.com/spf13/cobra) — the Go CLI framework that powers `kubectl`, `gh`, `hugo`, and most of the Go CLI ecosystem. Targets **Zig 0.16+**.

> _zobra_ — `z` (Zig) + `(c)obra`. A different snake. Same library, ported.

## Status: v0.1.0 — cobra-feature-complete

286 tests (277 unit/integration + 9 E2E smoke), format clean. See [`CHANGELOG.md`](CHANGELOG.md) for v0.1.0 release notes. The library ships **34 flag types** (full pflag parity), persistent flags + the five-stage hook chain, flag groups, args validators, byte-aligned help / usage rendering, `--help` / `-h` / `--version` auto-injection, the `help [path]` subcommand, suggestions on unknown flags / commands, `setOut` / `setErr` / `setHelpFunc` / `setUsageFunc`, the auto-print `Error: …` + usage path on parse errors (`executeAndPrint`), and the `CustomFlag` vtable for user-defined flag types.

**Doc generators** (`zobra-doc`) ship markdown / yaml / rest / man (+tree-walkers). **Shell completion** (`zobra-completion`) ships bash V2 / zsh / fish / powershell + the `__complete` runtime + the auto-installed `completion [shell]` subcommand.

See [`COMPARISON.md`](COMPARISON.md) for the full cobra-vs-zobra feature matrix and [`design-docs/06-roadmap.md`](design-docs/06-roadmap.md) for the phased status of record.

## Why

[Cobra](https://github.com/spf13/cobra) is the de-facto CLI framework for Go (Kubernetes, Hugo, gh, docker, GitHub CLI). The Zig ecosystem has good *parsers* — `yazap`, `zli`, `zig-clap`, `zig-flags` — but none ship the **cobra mental model**: a tree of commands with persistent (inherited) flags, the five-stage lifecycle hook chain, declarative flag-group constraints (mutex / required-together / one-required), command groups in help, suggestions on unknown commands, and templated help. zobra fills that gap.

The deliverable is a Zig module. Other projects pull it in via `build.zig.zon`:

```zig
.dependencies = .{
    .zobra = .{
        .url = "https://github.com/shhac/zobra/archive/refs/tags/v0.1.0.tar.gz",
        // .hash filled in by `zig fetch --save`
    },
},
```

…and import it with `@import("zobra")`. For a runnable demo + porting recipes, see [`examples/`](examples/README.md). For the full release history, see [`CHANGELOG.md`](CHANGELOG.md).

## Differential testing against real cobra

Behavioural parity is verified, not aspirational. zobra and [vipvot](https://github.com/shhac/vipvot) (the TypeScript port) **share a single oracle**: a Go program built on real cobra (`oracle/main.go`) whose stdout / stderr / exit code is captured into JSON fixtures (`test/fixtures/`). Both ports assert byte-for-byte parity against the same fixtures.

See [`design-docs/05-oracle-testing.md`](design-docs/05-oracle-testing.md) for the full strategy and the oracle-sharing approach (vipvot is canonical; zobra mirrors via `scripts/oracle-sync.sh`).

## Design docs

Every load-bearing decision is written down. Read these before changing the corresponding subsystem.

- [`00-vision.md`](design-docs/00-vision.md) — what zobra is, what it isn't, success criteria
- [`01-name.md`](design-docs/01-name.md) — etymology and the name sweep
- [`02-cobra-mapping.md`](design-docs/02-cobra-mapping.md) — the headline doc; every cobra concept and its Zig equivalent
- [`03-architecture.md`](design-docs/03-architecture.md) — five-layer stack, source layout
- [`04-parser.md`](design-docs/04-parser.md) — argv tokenizer design and edge-case catalogue
- [`05-oracle-testing.md`](design-docs/05-oracle-testing.md) — differential strategy + oracle reuse with vipvot
- [`06-roadmap.md`](design-docs/06-roadmap.md) — phased status of record
- [`07-error-model.md`](design-docs/07-error-model.md) — Diagnostic out-parameter pattern, error sets
- [`08-allocator-conventions.md`](design-docs/08-allocator-conventions.md) — when zobra takes an allocator, who owns returned slices
- [`09-zobra-divergences.md`](design-docs/09-zobra-divergences.md) — places we deliberately diverge from cobra
- [`10-comptime-vs-runtime.md`](design-docs/10-comptime-vs-runtime.md) — when comptime, when runtime, why
- [`11-public-surface.md`](design-docs/11-public-surface.md) — what's `pub`, semver policy, build.zig consumer wiring

## Quick taste (Phase 1+ — not yet implemented)

A glimpse of the target API. None of this builds today; it's the destination.

```zig
const std = @import("std");
const zobra = @import("zobra");

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

    try root.persistentFlags().stringVarP(&name, "name", "n", "world", "who to greet");
    try root.persistentFlags().countVarP(&verbose, "verbose", "v", "verbose level");
    try root.markFlagRequired("name");

    try root.execute(arena, try init.minimal.args.toSlice(arena));
}

fn greet(cmd: *zobra.Command, args: []const []const u8) anyerror!void {
    _ = cmd; _ = args;
    std.debug.print("hello, world\n", .{});
}
```

## Development

```bash
zig build              # build everything
zig build run          # run the example
zig build test         # full test suite
zig fmt --check .      # format check
```

To regenerate oracle fixtures (requires Go and a sibling vipvot checkout):

```bash
scripts/oracle-sync.sh    # pull oracle source + fixtures from vipvot
scripts/oracle-build.sh   # compile oracle/bin/cobra-oracle
scripts/oracle-capture.sh # capture fixtures (Phase 1+)
```

## License

MIT — see [LICENSE](LICENSE).

The cobra reference binary in `oracle/` is built against [spf13/cobra](https://github.com/spf13/cobra) and [spf13/pflag](https://github.com/spf13/pflag), which are Apache-2.0 licensed. The oracle binary is a build-time test artefact, not a published part of zobra.

## Sister project

[vipvot](https://github.com/shhac/vipvot) — the TypeScript port, by the same author. Same surface, same oracle, same differential-testing approach. The two ports are mechanical translations of each other; bugs in one usually mean bugs in the other.
