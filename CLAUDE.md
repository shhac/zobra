# CLAUDE.md — agent guide

Maintainer-facing notes for AI agents working on this repo. Mirrors vipvot's CLAUDE.md in shape; Zig-specific in content.

## What zobra is

A zero-dependency Zig port of [spf13/cobra](https://github.com/spf13/cobra). Targets Zig 0.16+. The library is exposed as a single `zobra` module via `build.zig.zon`. A small example executable lives under `src/examples/` so the usage shape is self-evident and we have something to dogfood.

The full picture lives in `design-docs/`. Read those before substantive changes.

## Where things live

```
zobra/
├── build.zig                # exposes `zobra` module + zobra-example exe
├── build.zig.zon            # name = .zobra, minimum_zig_version = "0.16.0"
├── src/
│   ├── root.zig             # public API (re-exports + smoke tests)
│   ├── core/                # implementation, by layer (Phase 1+)
│   │   ├── parser/          # tokenizer
│   │   ├── flag/            # flag registry + per-type modules
│   │   ├── command.zig      # command tree, dispatch, hooks
│   │   ├── help.zig         # help renderer
│   │   ├── usage.zig        # usage block (shared by help + error path)
│   │   ├── args.zig         # args validators
│   │   ├── hook.zig         # five-stage hook chain
│   │   ├── suggest.zig      # Levenshtein "did you mean?"
│   │   ├── diagnostic.zig   # Diagnostic struct
│   │   └── errors.zig       # error sets
│   └── examples/
│       └── hello/main.zig   # the demo executable
├── test/
│   ├── all.zig              # integration test entry
│   ├── parser/              # pure unit tests
│   ├── flag/
│   ├── command/
│   ├── differential/        # zobra vs oracle fixtures
│   └── fixtures/            # committed oracle outputs
├── oracle/                  # cobra reference binary (copied from vipvot)
├── scripts/                 # oracle build / capture / sync / check
└── design-docs/             # checked-in design notes
```

## Processes

### Day-to-day

```bash
zig build              # builds the example exe and the lib module
zig build run          # runs the example, forwarding `-- args`
zig build test         # full test suite
zig fmt --check .      # format check (CI gate)
zig fmt .              # apply formatting
```

`zig build test --summary all` for verbose output. `--fuzz` enables the std.testing.fuzz path on tests that opt in.

No automatic pre-commit hooks. Lint and format are explicit, manual steps; CI is the gate.

### Refreshing oracle fixtures (only when oracle changes)

The differential test suite reads committed JSON fixtures (`test/fixtures/`) captured from the Go cobra binary.

```bash
scripts/oracle-sync.sh     # pull oracle source + fixtures from sibling vipvot/
scripts/oracle-build.sh    # compile oracle/bin/cobra-oracle (requires Go)
scripts/oracle-capture.sh  # run the binary against the matrix → update fixtures (Phase 1+)
git diff test/fixtures/    # review behavioural diff before committing
```

Contributors without Go installed can run `zig build test` against the existing fixtures.

`scripts/oracle-check.sh` verifies our oracle source matches vipvot's canonical copy. Runs in CI; fails the build on drift.

### Adding a behaviour

1. Confirm the behaviour exists in `vipvot/oracle/main.go`. If not, add it there first (vipvot is the canonical source for the oracle).
2. `scripts/oracle-sync.sh` to pull the new oracle source.
3. Add the test matrix entry under `test/differential/cases/`.
4. `scripts/oracle-build.sh && scripts/oracle-capture.sh` to record the canonical output.
5. Implement in `src/`. Iterate until `zig build test` is green.
6. Update the docs that reference the area you touched. At minimum: the relevant row in `design-docs/02-cobra-mapping.md`, the phase entry in `design-docs/06-roadmap.md`, and (if the behaviour is a divergence or the closing of one) `design-docs/09-zobra-divergences.md`.
7. Code and docs land in the same commit/PR — drift between them is the failure mode this step exists to prevent.

### Releasing

Don't publish from this machine yet. The first release will go out from a CI workflow under the project identity. Until then, `zig build` produces a tarball under `zig-out/` for local consumption.

## Conventions

- **Zig 0.16+ only.** Don't write 0.13/0.14/0.15-era patterns. Specifically: `std.ArrayList(T) = .empty;` (allocator passed at each op); `*std.Io.Writer` for write interfaces; `b.addModule` for exposed modules, `b.createModule` for internal; `addExecutable({ .root_module = ... })`.
- **Allocators are explicit.** Every fallible function that allocates takes an allocator. Caller owns returned slices unless the function name says otherwise. See `design-docs/08-allocator-conventions.md`.
- **Errors are flat tags + Diagnostic.** Don't fall back to `anyerror` blanket returns; declare the precise error set. Pass `?*Diagnostic` for structured context. See `design-docs/07-error-model.md`.
- **Always `const`.** If something needs `var`, restructure (extract a function, use `comptime`). The exception is loop counters and accumulators where `var` is unavoidable.
- **Early returns over nested conditionals.**
- **Self-documenting code.** No comments explaining *what* or *how*. Only *why*, when non-obvious.
- **One file = one concept.** Soft cap ~400 lines. Hard cap is "this should be split."
- **Tests next to what they test in spirit, but in a parallel `test/` tree** for cleanliness.
- **No `as` casts or anytype-shrugs.** Use `@as(...)`, `@intCast`, `@ptrCast` deliberately. Document non-obvious casts.

## What NOT to do

- Don't add runtime dependencies. Zero is the rule. Dev-only Zig tooling is fine.
- Don't depend on Zig stdlib features that aren't in 0.16. We pin via `minimum_zig_version`.
- Don't introduce abstractions before the second use case. The cobra surface is large; we'll find the right abstractions by implementing concrete behaviours, not by speculation.
- Don't break the layering. Parser doesn't import flag; flag doesn't import command. If a layer needs to call up, factor the shared type into a lower module.
- Don't add features in `design-docs/06-roadmap.md` to a phase out of order without a note. The phases are gates, not suggestions.

## Out of scope (for now)

- Shell completion generation (deferred — Phase 9)
- Man-page generation (deferred — Phase 8 `zobra-doc`)
- A scaffolder à la `cobra-cli`
- A plugin system
- Internationalisation
- Async/await (revisit when Zig stabilises async)

## Related

- [vipvot](https://github.com/shhac/vipvot) — the TypeScript port, by the same author. Same surface, shared oracle. When in doubt about cobra-parity behaviour, check what vipvot does first; if vipvot has solved the equivalent question, follow its lead.
