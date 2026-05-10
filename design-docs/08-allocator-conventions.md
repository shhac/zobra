# 08 — Allocator conventions

## The principle

zobra is idiomatic Zig: **allocators are explicit, ownership is explicit, and every allocation has a known free path.** No hidden global allocators, no GC, no "we'll free it later."

This means the public API differs from cobra's in shape: cobra returns `string` and `[]string` freely; zobra takes an `Allocator` and returns slices the caller frees.

## Where allocators are passed

### Constructor pattern

`Command.init` takes an allocator. The Command owns:

- The flag set (one `FlagSet` per command).
- The children list (`std.ArrayList(*Command)`).
- The hook table (function pointers; no allocation, but the flag set's modifier table does allocate).
- Any internal string-interning for flag names.

```zig
const root = try zobra.Command.init(allocator, .{ .use = "myapp" });
defer root.deinit();  // recursively frees children and the flag set
```

### Per-call pattern

Methods that *return* a derived value take the allocator at the call site, not from the Command:

```zig
const help_text = try cmd.helpString(allocator);  // caller frees
defer allocator.free(help_text);
```

Why not use the Command's allocator? Two reasons:

1. **Locality.** A user might want help text in a temporary `arena`; the Command might live in a long-lived `gpa`. Mixing them is a footgun.
2. **Testability.** Per-call allocators let tests use `std.testing.allocator` for the call only, while the Command lives in a different allocator scope.

### Per-call pattern, alternative — pass a `Writer`

For methods that emit text rather than return it, the canonical Zig 0.16 idiom is to take a `*std.Io.Writer`:

```zig
try cmd.printHelp(out_writer);  // no allocation visible to the caller
```

We expose both shapes — `helpString` returns a slice (handy for tests, embedding); `printHelp` writes to a writer (the runtime path, no intermediate buffer).

## Ownership rules

These rules are **invariants**. Every public function must respect one of them, and the rule must be in the doc comment.

### Rule 1: caller-owns-input

The function reads its input arguments but does not retain them past the call. The caller can free their input as soon as the function returns.

```zig
/// Parses argv into tokens. argv is borrowed; tokens contain slices into argv,
/// so argv must outlive the returned tokens.
pub fn parse(allocator: Allocator, argv: []const []const u8, ...) ParseError![]const Token { ... }
```

### Rule 2: caller-owns-output

The function returns a slice (or a struct containing slices) that the caller is responsible for freeing.

```zig
/// Returns the help text for this command. Caller owns the returned slice.
pub fn helpString(self: *Command, allocator: Allocator) ![]const u8 { ... }
```

The caller frees with the same allocator they passed in. **Functions never have implicit "use the right allocator" expectations** — the doc comment names which allocator frees the result.

### Rule 3: function-owns

The function allocates internal state owned by some Self that has a `deinit`. The caller calls `Self.deinit(...)` to free.

```zig
const cmd = try Command.init(allocator, .{ ... });
defer cmd.deinit();   // frees everything the cmd allocated
```

`deinit` recursively frees owned children. If a Command is added as a child via `parent.addCommand(child)`, **ownership transfers** — the child's `deinit` is called by the parent's `deinit`. Callers must not also call `child.deinit()`.

### Rule 4: borrow-only

Some fields hold references the caller continues to own. These are documented in the field's doc comment.

```zig
pub const Command = struct {
    /// `use` is borrowed; the caller's storage must outlive this Command.
    use: []const u8,
    /// `aliases` is borrowed; same lifetime rule.
    aliases: []const []const u8 = &.{},
    /// `children` is owned; freed by `deinit`.
    children: std.ArrayList(*Command) = .empty,
    ...
};
```

The default for "user-supplied configuration strings" is **borrow-only**. Static string literals have program lifetime; that's the common case and we don't allocate to copy them. If the user wants the Command to take ownership, they can pre-allocate and the borrow rule still holds (Command doesn't free; user's deinit does).

**When borrow-only is unsafe.** If a Command field is initialised from a slice that won't live as long as the Command — e.g. a slice into argv inside a function that returns the Command — the caller must `dupe` first:

```zig
const use_owned = try allocator.dupe(u8, argv[1]);
const cmd = try Command.init(allocator, .{ .use = use_owned });
// caller is responsible for freeing use_owned after cmd.deinit()
```

The most common cases (literals, top-level constants, arena-backed strings) are safe by construction. The footgun is short-lived stack slices or heap slices the caller frees too early; the borrow rule pushes that responsibility on the caller, who has the lifetime context. If a real port surfaces this as a recurring error, we revisit (likely an `init` flag that asks Command to dupe everything).

## What gets allocated

| Layer | Allocates | Owner |
|---|---|---|
| Parser | The token slice | Caller (per-call allocator) |
| Parser | Diagnostic.message | Caller's Diagnostic owns; freed by `Diagnostic.deinit` |
| FlagSet | Flag-name interning | FlagSet → Command → caller's `init` allocator |
| FlagSet | Slice/map flag value backing storage | Same |
| Command | Children list | Command → caller's `init` allocator |
| Command | Group definitions | Same |
| Help renderer | Output slice (or none if writer-based) | Caller (per-call allocator) |
| Suggest | The "did you mean" string | Diagnostic owns; freed by `Diagnostic.deinit` |

## Failure modes

When an allocation fails mid-call, we use Zig's `errdefer` to roll back partial state:

```zig
pub fn addCommand(self: *Command, child: *Command) !void {
    try self.children.append(self.allocator, child);
    errdefer _ = self.children.pop();
    child.parent = self;
}
```

The pattern is:

1. `try` the allocation that might fail.
2. `errdefer` rolls back state mutations made *after* the allocation.
3. State mutations made *before* the allocation are caller-visible regardless.

We try not to leave Commands in a half-initialised state on `init` failure. On error, the partial Command is freed before the function returns; the caller never sees a broken handle.

## Arena vs general-purpose

zobra does not require a particular allocator. Common patterns:

- **Single-shot CLI**: `var arena = std.heap.ArenaAllocator.init(gpa);` — pass `arena.allocator()` to `Command.init` and to every per-call method. Free everything at once at the end with `arena.deinit()`. Zero deinit calls in user code.
- **Long-lived embedded use**: `gpa` for `Command.init`, scratch arena for per-call methods. Two allocators in flight; explicit deinit on the Command.
- **Tests**: `std.testing.allocator` everywhere, explicit deinit, leak detection on.

zobra documents the recommended pattern as `arena` for CLI bootstrap (because `defer arena.deinit()` is the Zig idiom for "free at end of program"), but doesn't enforce it.

## Why this is intentional drift from cobra

Cobra hides allocations behind a runtime that has GC. zobra can't, and shouldn't try to: a port that pretends Zig has GC produces footguns where users assume slices have indefinite lifetime. The explicit-allocator rule prevents that class of bug at the cost of the ergonomic cost — three or four extra `try`s and one `defer arena.deinit()` per CLI bootstrap.

That trade is the idiomatic Zig answer. We document it; we don't apologise for it.
