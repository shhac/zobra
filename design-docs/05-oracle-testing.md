# 05 — Oracle testing

## The problem

Cobra has a decade of accumulated edge-case behaviour. Reproducing it from documentation alone is unreliable: docs cover the headline features, not the corner cases. A test suite asserting "this is what cobra does" is only as good as the author's recall.

## The solution

We compile a small Go program built on **real cobra**. We feed it a comprehensive matrix of inputs. We capture its `stdout`, `stderr`, and exit code into JSON fixtures. The zobra test suite reads those fixtures and asserts zobra produces identical output for the same inputs.

The Go cobra binary is the **oracle**: an authority for what "correct" means. It cannot be wrong about cobra's behaviour because it *is* cobra.

## Source-of-truth precedence (when implementing)

When porting a behaviour to zobra, the precedence — strongest to weakest — is:

1. **The differential fixtures** (`test/fixtures/oracle.json`). They are the captured behaviour of the oracle binary. If the fixture says X, zobra must produce X. No fixture-vs-implementation tie-breaking is needed because the fixture was produced by a real cobra binary.
2. **The Go source** of `spf13/pflag` and `spf13/cobra`. When the fixture is silent on an edge case, read the Go source — it is the canonical implementation. The algorithm in pflag's `flag.go` (≈300 lines for the parse path) is small and unambiguous.
3. **The [vipvot](https://github.com/shhac/vipvot) TypeScript port**. Useful as a parallel-port reference and sanity check — vipvot has already had to make many of the same Zig-specific decisions (modulo language). **Not authoritative.** If vipvot disagrees with pflag, pflag wins. Treating vipvot as the source would let any vipvot bug propagate into zobra unchecked.

The single point of authority is "the oracle is what real cobra does." Everything else is implementation reference.

## Sister project: shared oracle with vipvot

[vipvot](https://github.com/shhac/vipvot) is the TypeScript port of cobra by the same author. zobra and vipvot **share the oracle**: same `oracle/main.go`, same JSON fixtures. One source of truth governs both ports.

### How sharing works

**The oracle source (`oracle/main.go`, `go.mod`, `go.sum`) is copied verbatim from vipvot into zobra.** Both repos contain identical files; a sync script keeps them in lockstep.

```
vipvot/oracle/main.go ──── (canonical) ────────┐
                                                │ rsync
zobra/oracle/main.go  ◄────── kept identical ───┘
```

```
vipvot/test/fixtures/oracle.json ──── (canonical) ───┐
                                                      │ rsync
zobra/test/fixtures/oracle.json  ◄── kept identical ──┘
```

### Why copy, not submodule, not relative-path?

Three options were considered. The decision matrix:

| Approach | Pro | Con | Verdict |
|---|---|---|---|
| **Submodule** | Single source of truth at the file level. | Submodules add friction for cloners; the user actively dislikes them. | Rejected. |
| **Relative path** (zobra reads `../vipvot/oracle/`) | Trivial to set up. | Breaks for anyone cloning zobra without vipvot; opaque dependency on a sibling directory. | Rejected. |
| **Copy verbatim + sync script** | Both repos self-contained; clones work standalone; CI can verify lockstep. | Duplication; risk of drift if sync script isn't run. | **Chosen.** |

The risk of drift is mitigated by:
1. `scripts/oracle-sync.sh` does the rsync in one direction — vipvot is the canonical source.
2. CI runs a checksum check (`scripts/oracle-check.sh`) that diffs `oracle/main.go` and `oracle/go.{mod,sum}` against the upstream vipvot copy. If they differ, the build fails until either both repos update or the sync script is run.
3. The fixtures (`test/fixtures/`) are committed; they're the actual ground truth. The oracle source is just the *generator*. As long as both repos can produce the same fixtures from the same source, the contract holds.

### When the oracle changes

The flow when vipvot adds a new behaviour to the oracle:

1. Edit `vipvot/oracle/main.go` to exercise the new behaviour.
2. Run `bun run oracle:capture` in vipvot to regenerate fixtures.
3. Run `scripts/oracle-sync.sh` in zobra to pull both source and fixtures.
4. Commit in both repos.

When zobra needs a behaviour that vipvot doesn't yet exercise:

1. Edit `zobra/oracle/main.go`.
2. Run `scripts/oracle-capture.sh` in zobra.
3. **Mirror the change back into vipvot** so the canonical source moves forward — `cp zobra/oracle/main.go vipvot/oracle/main.go` and rerun vipvot's capture.
4. Commit in both repos.

The contract is "vipvot is canonical, zobra mirrors." If that becomes burdensome, we revisit (e.g. moving the oracle to its own repo); not worth it for the bootstrap.

## The pieces

```
oracle/
├── main.go               # Go program with a kitchen-sink command tree (copied from vipvot)
├── go.mod
├── go.sum
└── bin/cobra-oracle      # compiled binary (gitignored)

test/
├── differential/
│   ├── matrix.zig        # input cases — argv arrays + metadata
│   ├── runner.zig        # runs cases through zobra, compares to fixtures
│   └── cases/            # one file per category (parsing, hooks, groups, errors, …)
└── fixtures/
    └── oracle.json       # captured oracle outputs (committed)

scripts/
├── oracle-build.sh       # `cd oracle && go build -o bin/cobra-oracle .`
├── oracle-capture.sh     # runs the binary across the matrix → writes fixtures
├── oracle-sync.sh        # rsyncs oracle/ + test/fixtures/ from ../vipvot
└── oracle-check.sh       # CI: verifies our oracle/ matches ../vipvot/oracle/ (when present)
```

## Why fixtures (not live oracle invocation in CI)

Two reasons:

1. **CI portability.** Zig CI doesn't need a Go toolchain.
2. **Determinism.** Cobra's output is mostly deterministic, but live invocation introduces process-spawn flakiness. Snapshot fixtures are pure data.

The trade-off: if cobra changes behaviour upstream, our fixtures lag. We mitigate by pinning cobra's version in `go.mod` and rebuilding fixtures only when we deliberately upgrade.

## The oracle program

`oracle/main.go` is a single-file Go program that defines a maximal command tree exercising every cobra surface we care about — persistent and local flags of every type, two levels of subcommands, command groups, all five hook stages, flag groups (mutex / required-together / one-required), required/hidden/deprecated flags, slice / map / duration / network / bytes types, subcommand aliases, custom Args validators.

The full list lives in vipvot's [05-oracle-testing.md](https://github.com/shhac/vipvot/blob/main/design-docs/05-oracle-testing.md); zobra inherits whatever vipvot has.

## The matrix

`test/differential/matrix.zig` defines every test case as a struct:

```zig
pub const Case = struct {
    id: []const u8,           // "flags-short-attached-value"
    args: []const []const u8, // .{"root","sub","-fvalue"}
    // expectations are captured into fixtures, not asserted inline
};
```

Cases are grouped into files by category for navigability:

- `cases/parsing-long.zig` — long-flag forms
- `cases/parsing-short.zig` — short-flag combinations, attached values, groups
- `cases/parsing-negation.zig` — `--no-`
- `cases/parsing-counted.zig` — `-vvv`, `--verbose=3`
- `cases/parsing-slices.zig` — split vs no-split, repeated
- `cases/parsing-terminator.zig` — `--` behaviour
- `cases/dispatch.zig` — subcommand resolution, aliases, ambiguity
- `cases/hooks.zig` — hook firing order, inherited persistent hooks
- `cases/help.zig` — `--help`, `help <cmd>`, group ordering, hidden flags
- `cases/groups-mutex.zig` — flag group violations
- `cases/groups-required-together.zig`
- `cases/errors.zig` — unknown flag, unknown command, missing value, suggestion output

Target: >200 cases, mirroring vipvot.

## The differential test

```zig
const fixtures = @import("../fixtures/oracle.zig").entries; // generated from oracle.json
const matrix = @import("matrix.zig").cases;

test "differential: all cases" {
    for (matrix) |c| {
        const expected = fixtures.get(c.id) orelse continue;
        const actual = try runZobra(c.args);
        try std.testing.expectEqualStrings(expected.stdout, actual.stdout);
        try std.testing.expectEqualStrings(expected.stderr, actual.stderr);
        try std.testing.expectEqual(expected.exit_code, actual.exit_code);
    }
}
```

(Whether we generate a Zig source from the JSON or parse the JSON at test time is a Phase-1 implementation choice. Generated source is faster; JSON parsing is simpler. We start with JSON parsing.)

## Normalisation

Some cobra output is environment-sensitive:

- Help output may include a binary name; we configure both binaries to use the same `Use` / `name`.
- Cobra's "did you mean" suggestion uses Levenshtein with a fixed threshold; we replicate the algorithm.
- Error message wording is occasionally version-sensitive; we pin cobra in `go.mod`.

### Project-neutral oracle wording

The oracle's user-facing strings (`Use`, `Short`, `Long`, `Example`) must be **project-neutral** — no mentions of "vipvot," "zobra," or any port-specific name — because those strings appear verbatim in `--help` fixtures, and any port-specific reference makes the fixtures non-portable across ports.

Currently `vipvot/oracle/main.go` mentions `vipvot` in its `Short` and `Long` lines (e.g. `"used to differential-test vipvot"`). The first joint maintenance task is to rewrite those to neutral wording (`"used to differential-test cobra ports"` or similar) upstream in vipvot, then sync into zobra. Until that lands, zobra's fixture comparison must either tolerate the mention or strip it; we strip in the runner.

When a difference is **deliberate** (e.g. a Zig idiom that requires diverging from cobra's wording), the case is removed from the differential matrix and lives in a separate "zobra-extensions" suite. Each such divergence gets a row in [09-zobra-divergences.md](09-zobra-divergences.md).

## Acceptance bar

A zobra release is gated on:

1. All differential cases passing.
2. Parser test suite green; >95% of the case enumeration in [04-parser.md](04-parser.md) covered.
3. No `dependencies` in `build.zig.zon`.
4. `oracle-check.sh` passes — our oracle matches vipvot's.

The first is the product; the others are how we keep it that way.
