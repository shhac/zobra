# 06 — Roadmap

Status of record. Each phase has an explicit acceptance bar; we don't move forward until the previous bar is met.

## Status (as of last update)

Phases 0 through 6 plus the vipvot-parity push are **landed and pushed**.
**215 tests** pass under `zig build test`; format clean. The example
exe exercises the full pipeline end-to-end including the auto-print
error path. zobra ships **34 flag types** (full pflag parity) plus
the CustomFlag vtable for user-defined types.

See [COMPARISON.md](../COMPARISON.md) for the cobra-vs-zobra feature
matrix.

| Phase | Status | Highlights |
|---|---|---|
| 0 — Scaffold | done | Build files, design docs, oracle synced from vipvot |
| 1 — Parser | done | pflag-faithful tokenizer, schema-aware short-group splitter |
| 2 — Flag registry | done | 16 scalar `*VarP` types, strconv wording, modifiers |
| 3 — Command + hooks + args | done | Tree, dispatch, 5-stage hook chain, args validators |
| 4 — Help renderer | done | cobra-byte-aligned columns, --help / -h auto-injection |
| 5a — Slice flags | done (subset) | stringSlice/Array/intSlice — pattern established |
| 5b — Negation + count | verified | Already worked from Phases 1+2; explicit tests |
| 5c — Flag groups | done | mutex / required-together / one-required, cobra wording |
| 6 — UX surface | done | Levenshtein suggestions, --version, disable_flag_parsing, allow_unknown_flags |
| 7 — Comptime path | deferred | Stretch goal; runtime path is the spec |
| 8 — `zobra-doc` | deferred | Markdown/yaml/man generators |
| 9 — `zobra-completion` | deferred | bash/zsh/fish/pwsh shell completion |

Pending follow-ups (small, mechanical):
- The remaining slice/map/network/bytes flag types (most of pflag's
  alphabet beyond scalars + the three slice variants we shipped).
- Command groups in help (`addGroup` + `groupId`).
- CustomFlag vtable (the pflag.Value escape hatch).
- Differential-test runner (the oracle binary builds; the
  `oracle-capture.sh` and matrix-runner are still placeholders).

## Phase 0 — Scaffold (current)

**Goal**: empty project that builds, tests, and formats cleanly.

- `build.zig` exposes `zobra` module + a `zobra-example` executable.
- `build.zig.zon` declares `name = .zobra`, `minimum_zig_version = "0.16.0"`.
- `src/root.zig` with one passing smoke test.
- `test/` skeleton with a placeholder integration test.
- `oracle/` copied verbatim from vipvot; binary gitignored.
- All design docs (00–10) written.
- README, CLAUDE.md, LICENSE in place.
- `zig build` succeeds.
- `zig build test` runs and passes.
- `zig fmt --check` passes on all `.zig` and `.zon` files.

## Phase 1 — Parser

**Goal**: pure-function tokenizer matching every case in [04-parser.md](04-parser.md).

- `src/core/parser/parser.zig` — `parse(allocator, argv, schema, diag) -> []const Token`.
- `src/core/parser/long.zig`, `short.zig` — split per the design doc.
- Token alphabet: `long`, `short`, `short_group`, `negated`, `positional`, `terminator`, `passthrough`.
- Schema-aware short-group splitter (`-fbar` vs `-abc` disambiguation).
- `test/parser/` with a table test per edge-case in [04-parser.md](04-parser.md).
- No dependence on flag types — the parser is type-blind.

**Acceptance**: every case in the parser edge-case catalogue has a passing test. No allocations leak under `std.testing.allocator`.

## Phase 2 — Flag registry (scalars)

**Goal**: `FlagSet` type with the 16 scalar flag types from [02-cobra-mapping.md](02-cobra-mapping.md).

- `src/core/flag.zig` — `FlagSet` type, `addFlag` core, all 16 scalar `*VarP` registration methods.
- `src/core/flag/value.zig` — `FlagValue` tagged union.
- `src/core/flag/coerce.zig` — string→typed parsers (decimal, hex, octal, scientific where pflag accepts).
- `src/core/flag/duration.zig` — Go `time.ParseDuration` parity.
- `src/core/flag/modifiers.zig` — `markRequired`, `markHidden`, `markDeprecated`.
- `test/flag/` table tests per type, including pflag's exact error wording.

**Acceptance**: every scalar type matches pflag wording byte-for-byte (verified via fixture comparison).

## Phase 3 — Command tree, hooks, args validators

**Goal**: full command runtime — registration, dispatch, the five-stage hook chain.

- `src/core/command.zig` — `Command.init`, `addCommand`, `execute`, runtime dispatch.
- `src/core/hook.zig` — five-stage chain with parent-walk for persistent stages.
- `src/core/args.zig` — `minimumN`, `maximumN`, `exactN`, `range`, `onlyValid`, `noArgs`, `arbitrary`, `matchAll`.
- Persistent flags (inherited).
- Aliases.
- `test/command/` integration tests.

**Acceptance**: `cmd.execute(allocator, argv)` dispatches to the right command, runs hooks in cobra order, returns the right exit code.

## Phase 4 — Help renderer

**Goal**: `--help` and `help <cmd>` produce cobra-byte-identical output.

- `src/core/help.zig` — section order: Long → Usage → Aliases → Examples → Available Commands → Flags → Global Flags → Footer.
- `src/core/usage.zig` — shared usage block for help + error path.
- Auto-injected `--help` / `-h`.
- Auto-injected `help [path]` subcommand.
- `setHelpFunc` / `setUsageFunc` overrides.
- Snapshot tests against committed fixtures.

**Acceptance**: every `--help` invocation in the differential matrix produces byte-identical output to the oracle.

## Phase 5 — The rest of the flag alphabet (split into 5a / 5b / 5c)

Phase 5 was originally one chunk; it has too many independent surfaces to land safely in a single block. Split:

### Phase 5a — Slice / map / network / bytes flags

- Slice flags (string-slice, string-array, int-slice, int32-slice, int64-slice, float32/64-slice, bool-slice, duration-slice).
- Map flags (string-to-string, string-to-int, string-to-int64).
- Network flags (ip, ip-mask, ip-net).
- Bytes flags (hex, base64).

**Acceptance**: pflag-error-wording fixtures for these types pass.

### Phase 5b — `--no-foo` and counted shorts

- `--no-foo` boolean negation (universal, per zobra's divergence — see [09-zobra-divergences.md](09-zobra-divergences.md)).
- Counted shorts (`count` flag type) — `-vvv` → 3, `--verbose=3` → 3.

**Acceptance**: differential cases for negation and counted shorts pass.

### Phase 5c — Flag groups + custom Value

- Flag groups: required-together, mutually-exclusive, one-required.
- `CustomFlag` vtable as the pflag.Value escape hatch (per [02-cobra-mapping.md](02-cobra-mapping.md)).
- `markFlagRequired`, `markHidden`, `markDeprecated` exhaustive tests.

**Acceptance**: differential cases for group violations + a worked custom-type example.

## Phase 6 — Suggestions, version, command surface

**Goal**: cobra's UX touches.

- Levenshtein-based "did you mean?" on unknown subcommand / flag.
- `--version` / `-v` auto-injection from `Command.version`.
- Command-level options: `disable_flag_parsing`, `disable_flags_in_use_line`, `suggest_for`, `disable_suggestions`, `suggestions_minimum_distance`.
- `f_parse_err_whitelist.unknown_flags` for proxy commands.
- Command groups in help (`add_group`, `group_id`).

**Acceptance**: differential cases for unknown-command/-flag, version, group rendering all pass.

## Phase 7 — Comptime declarative form (optional)

**Goal**: a comptime alternative to runtime registration. See [10-comptime-vs-runtime.md](10-comptime-vs-runtime.md).

- `comptime const root = zobra.declare(.{ ... });` — comptime resolution of a struct-literal command tree.
- Generates the same runtime structures under the hood; no allocator needed for the tree itself.
- Side-by-side with the runtime path; user picks whichever suits.

**Acceptance**: `examples/todo` ports to the comptime form with no behavioural change.

## Phase 8 — Documentation generators (deferred)

**Goal**: `zobra-doc` module — markdown / yaml / rest / man output.

- Separate Zig module exposed via `b.addModule("zobra-doc", ...)`.
- Same output as cobra's `cobra/doc` package.
- Snapshot fixtures captured from the oracle.

## Phase 9 — Shell completion (deferred)

**Goal**: `zobra-completion` module — bash / zsh / fish / pwsh script generation.

- Separate Zig module.
- `valid_args_function`, `register_flag_completion_func`, `ShellCompDirective*` constants.
- Match cobra's generated scripts byte-for-byte.

## Out of scope

- Plugin system
- Internationalisation
- Scaffolder
- Async/await runtime (revisit when Zig stabilises async)
- `Command.SetContext` — pending until a port surfaces a real need
- `SetUsageTemplate` / `SetHelpTemplate` (Go `text/template`) — function variants cover real use cases
