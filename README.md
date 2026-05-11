# zobra

A zero-dependency Zig port of [spf13/cobra](https://github.com/spf13/cobra) — the Go CLI framework that powers `kubectl`, `gh`, `hugo`, and most of the Go CLI ecosystem. Targets **Zig 0.16+**.

> _zobra_ — `z` (Zig) + `(c)obra`. A different snake. Same library, ported.

## Status

- **Per-feature support:** [`COMPARISON.md`](COMPARISON.md) — full cobra-vs-zobra matrix; what works, what diverges deliberately, what's deferred.
- **Per-release notes:** [`CHANGELOG.md`](CHANGELOG.md).
- **Roadmap / phased status:** [`design-docs/06-roadmap.md`](design-docs/06-roadmap.md).

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

## Quick taste

```zig
const zobra = @import("zobra");

var name: []const u8 = "world";

fn greet(cmd: *zobra.Command, _: []const []const u8) anyerror!void {
    const w = cmd.outWriter() orelse return;
    try w.print("hello, {s}\n", .{name});
}

// inside main():
const root = try zobra.Command.init(arena, .{ .use = "tool", .run_e = greet });
defer root.deinit();
try root.persistentFlags().stringVarP(&name, "name", 'n', "world", "who to greet");
root.setOut(stdout);
try root.executeAndPrint(argv);
```

The full runnable demo (with subcommands, the `-vv` count flag, an args validator, and explicit-IO plumbing) is in [`examples/hello/main.zig`](examples/hello/main.zig) — invoke via `zig build run -- greet --name=alice`. Side-by-side cobra↔zobra ports and porting recipes are in [`examples/`](examples/README.md) and [`COMPARISON.md`](COMPARISON.md).

## Development

```bash
zig build                                    # build everything
zig build run -- greet                       # run the example
zig build test                               # unit + integration suite (277 tests)
zig build test-e2e                           # E2E smoke tests (spawns the demo binary)
zig fmt --check src test build.zig examples  # format check
```

To regenerate oracle fixtures (requires Go and a sibling vipvot checkout):

```bash
scripts/oracle-sync.sh     # pull oracle source + fixtures from vipvot
scripts/oracle-build.sh    # compile oracle/bin/cobra-oracle
scripts/oracle-capture.sh  # run the binary against the matrix → update fixtures
```

## License

MIT — see [LICENSE](LICENSE).

The cobra reference binary in `oracle/` is built against [spf13/cobra](https://github.com/spf13/cobra) and [spf13/pflag](https://github.com/spf13/pflag), which are Apache-2.0 licensed. The oracle binary is a build-time test artefact, not a published part of zobra.

## Sister project

[vipvot](https://github.com/shhac/vipvot) — the TypeScript port, by the same author. Same surface, same oracle, same differential-testing approach. The two ports are mechanical translations of each other; bugs in one usually mean bugs in the other.
