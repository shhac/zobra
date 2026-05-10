//! Argv parser. Pure tokenizer — no I/O, no command-tree awareness, no flag
//! binding. Schema-aware: takes a `FlagSchema` so it can disambiguate
//! `-fbar` (= `-f bar`) from `-fbar` (= `-f -b -a -r`).
//!
//! Source of truth: spf13/pflag's `flag.go` (`parseArgs`, `parseLongArg`,
//! `parseShortArg`, `parseSingleShortArg`). See design-docs/04-parser.md.

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const fillDiag = @import("../diagnostic.zig").fill;

pub const Token = @import("token.zig").Token;
const long_mod = @import("long.zig");
const short_mod = @import("short.zig");

/// Schema view the parser uses to disambiguate value-taking flags from
/// boolean / count flags. The flag layer is responsible for building a
/// schema that already accounts for inherited persistent flags.
pub const FlagSchema = struct {
    is_value_taking_short: *const fn (c: u8) bool,
    is_value_taking_long: *const fn (name: []const u8) bool,
    is_known_long: *const fn (name: []const u8) bool,
    is_boolean_long: *const fn (name: []const u8) bool,

    /// Schema where every flag is unknown — handy for the flag-layerless
    /// smoke tests. With this schema the parser still emits tokens; the
    /// flag layer would reject unknowns.
    pub const empty: FlagSchema = .{
        .is_value_taking_short = noShort,
        .is_value_taking_long = noLong,
        .is_known_long = noLong,
        .is_boolean_long = noLong,
    };

    fn noShort(_: u8) bool {
        return false;
    }
    fn noLong(_: []const u8) bool {
        return false;
    }
};

/// Parse argv into a slice of tokens. Caller owns the slice and frees with
/// the passed-in allocator. Sets `diag` on failure when it's non-null.
pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    schema: FlagSchema,
    diag: ?*Diagnostic,
) errors.ParserError![]Token {
    var out: std.ArrayList(Token) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var terminated = false;

    while (i < argv.len) {
        const s = argv[i];

        if (terminated) {
            try out.append(allocator, .{ .passthrough = s });
            i += 1;
            continue;
        }

        // Bare positional: empty, or doesn't start with '-', or is just "-".
        if (s.len == 0 or s[0] != '-' or s.len == 1) {
            try out.append(allocator, .{ .positional = .{ .value = s } });
            i += 1;
            continue;
        }

        // Either "--", "--name…", or "-name…".
        if (s[1] == '-') {
            if (s.len == 2) {
                try out.append(allocator, .terminator);
                terminated = true;
                i += 1;
                continue;
            }
            try long_mod.parseLong(allocator, &out, argv, &i, schema, diag);
        } else {
            try short_mod.parseShort(allocator, &out, argv, &i, schema, diag);
        }
    }

    return out.toOwnedSlice(allocator);
}

test "parse: empty argv yields no tokens" {
    const gpa = std.testing.allocator;
    const tokens = try parse(gpa, &.{}, FlagSchema.empty, null);
    defer gpa.free(tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "parse: single positional" {
    const gpa = std.testing.allocator;
    const tokens = try parse(gpa, &.{"hello"}, FlagSchema.empty, null);
    defer gpa.free(tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("hello", tokens[0].positional.value);
}

test "parse: bare hyphen is positional (stdio convention)" {
    const gpa = std.testing.allocator;
    const tokens = try parse(gpa, &.{"-"}, FlagSchema.empty, null);
    defer gpa.free(tokens);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("-", tokens[0].positional.value);
}

test "parse: terminator switches to passthrough" {
    const gpa = std.testing.allocator;
    const tokens = try parse(gpa, &.{ "a", "--", "--b", "-c" }, FlagSchema.empty, null);
    defer gpa.free(tokens);
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("a", tokens[0].positional.value);
    try std.testing.expect(tokens[1] == .terminator);
    try std.testing.expectEqualStrings("--b", tokens[2].passthrough);
    try std.testing.expectEqualStrings("-c", tokens[3].passthrough);
}
