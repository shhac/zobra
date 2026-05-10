//! Pure argv-slice helpers used by Command.findRec to peel a
//! flag-or-flag-value off the argv when probing for a sub-command past
//! it. Kept separate from the Command struct (no command state) so the
//! helpers stay independently testable against hand-built token slices.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parser_mod = @import("../parser/parser.zig");

pub const Token = parser_mod.Token;

/// Return the argv index of the first positional token in `tokens`.
/// Returns null when the token stream has no positional before the
/// first terminator/passthrough (which happens when argv is all flags
/// or the user invoked `--` early). Pure function — testable in
/// isolation against a hand-built token stream.
///
/// Note: this is *not* the same as the position of the first positional
/// token in the token slice. Long/short tokens with a separate-argv
/// value consume two argv slots, so the mapping from token-index to
/// argv-index isn't 1:1. The byte-pointer aliasing in `argvUsedByToken`
/// reconstructs it.
pub fn firstPositionalArgvIndex(tokens: []const Token, argv: []const []const u8) ?usize {
    var pi: usize = 0;
    for (tokens) |t| switch (t) {
        .positional => return pi,
        .terminator, .passthrough => return null,
        .long, .short, .negated => {
            pi += argvUsedByToken(t, argv, pi);
            if (pi > argv.len) return null;
        },
    };
    return null;
}

/// argv slots consumed by a single token at `pi`. Long/short with a
/// SEPARATE-argv value consume 2 (e.g. `--name alice` is two argv
/// slots); attached values (`--name=alice`, `-nalice`) and value-less
/// boolean/count tokens consume 1.
fn argvUsedByToken(t: Token, argv: []const []const u8, pi: usize) usize {
    switch (t) {
        .long => |l| {
            if (l.value) |v| {
                if (pi + 1 < argv.len and slicesAlias(v, argv[pi + 1])) return 2;
            }
            return 1;
        },
        .short => |s| {
            if (s.value) |v| {
                if (pi + 1 < argv.len and slicesAlias(v, argv[pi + 1])) return 2;
            }
            return 1;
        },
        .negated, .positional, .terminator, .passthrough => return 1,
    }
}

/// True iff slice `a` is a sub-range of slice `b` by byte address.
/// Used to detect "did this token's value come from the next argv
/// element?" — if v aliases argv[pi+1], the parser consumed it.
fn slicesAlias(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const b_end = b_start + b.len;
    return a_start >= b_start and a_start < b_end;
}

/// Allocate a fresh argv slice equal to `argv` minus the element at
/// `idx`. Caller frees with the same allocator.
pub fn argvWithout(allocator: Allocator, argv: []const []const u8, idx: usize) ![]const []const u8 {
    std.debug.assert(idx < argv.len);
    const out = try allocator.alloc([]const u8, argv.len - 1);
    var j: usize = 0;
    for (argv, 0..) |a, i| {
        if (i == idx) continue;
        out[j] = a;
        j += 1;
    }
    return out;
}

const testing = std.testing;

test "firstPositionalArgvIndex: empty argv returns null" {
    const tokens: []const Token = &.{};
    try testing.expect(firstPositionalArgvIndex(tokens, &.{}) == null);
}

test "firstPositionalArgvIndex: leading positional" {
    const tokens: []const Token = &.{.{ .positional = .{ .value = "x" } }};
    try testing.expectEqual(@as(?usize, 0), firstPositionalArgvIndex(tokens, &.{"x"}));
}

test "firstPositionalArgvIndex: long with attached value, then positional" {
    const argv: []const []const u8 = &.{ "--name=alice", "greet" };
    const tokens: []const Token = &.{
        .{ .long = .{ .name = "name", .value = argv[0][7..], .raw = argv[0] } },
        .{ .positional = .{ .value = argv[1] } },
    };
    try testing.expectEqual(@as(?usize, 1), firstPositionalArgvIndex(tokens, argv));
}

test "firstPositionalArgvIndex: long with separate-argv value consumes 2 slots" {
    const argv: []const []const u8 = &.{ "--name", "alice", "greet" };
    const tokens: []const Token = &.{
        .{ .long = .{ .name = "name", .value = argv[1], .raw = argv[0] } },
        .{ .positional = .{ .value = argv[2] } },
    };
    try testing.expectEqual(@as(?usize, 2), firstPositionalArgvIndex(tokens, argv));
}

test "firstPositionalArgvIndex: terminator stops the search" {
    const argv: []const []const u8 = &.{ "--", "x" };
    const tokens: []const Token = &.{
        .terminator,
        .{ .passthrough = "x" },
    };
    try testing.expect(firstPositionalArgvIndex(tokens, argv) == null);
}

test "argvWithout: drops the indexed element" {
    const gpa = testing.allocator;
    const argv: []const []const u8 = &.{ "a", "b", "c" };
    const out = try argvWithout(gpa, argv, 1);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("c", out[1]);
}
