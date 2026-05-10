//! Short-flag handling. Mirrors pflag's parseShortArg + parseSingleShortArg
//! (flag.go:1040, 1116). pflag processes a `-abc` group character-by-character;
//! we emit one `short` token per character, each carrying the source group as
//! `raw` for error wording.

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const Token = @import("token.zig").Token;
const FlagSchema = @import("parser.zig").FlagSchema;

pub fn parseShort(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Token),
    argv: []const []const u8,
    i: *usize,
    schema: FlagSchema,
    diag: ?*Diagnostic,
) errors.ParserError!void {
    const s = argv[i.*];
    std.debug.assert(s.len >= 2 and s[0] == '-' and s[1] != '-');

    var shorthands = s[1..];
    var consumed_next = false;

    while (shorthands.len > 0) {
        const c = shorthands[0];
        const rest = shorthands[1..];

        // `-f=arg` form — the `=` always splits, regardless of value-taking.
        if (rest.len > 0 and rest[0] == '=') {
            const v = rest[1..];
            try out.append(allocator, .{ .short = .{ .name = c, .value = v, .raw = s } });
            shorthands = "";
            break;
        }

        if (schema.is_value_taking_short(c)) {
            if (rest.len > 0) {
                // `-farg` — rest is the value.
                try out.append(allocator, .{ .short = .{ .name = c, .value = rest, .raw = s } });
                shorthands = "";
                break;
            }
            // `-f` followed by separate arg — consume the next argv if present.
            if (i.* + 1 < argv.len) {
                const value = argv[i.* + 1];
                try out.append(allocator, .{ .short = .{ .name = c, .value = value, .raw = s } });
                consumed_next = true;
                shorthands = "";
                break;
            }
            // No value available; flag layer raises MissingValue.
            try out.append(allocator, .{ .short = .{ .name = c, .value = null, .raw = s } });
            shorthands = "";
            break;
        }

        // Non-value-taking (boolean / count / unknown): emit standalone, recurse.
        try out.append(allocator, .{ .short = .{ .name = c, .value = null, .raw = s } });
        shorthands = rest;
    }

    _ = diag; // reserved for future error-path enrichment
    i.* += if (consumed_next) 2 else 1;
}

// ---- inline tests --------------------------------------------------------

const testing = std.testing;

const valueTakingFactory = struct {
    fn make(comptime ch: u8) *const fn (u8) bool {
        return struct {
            fn f(c: u8) bool {
                return c == ch;
            }
        }.f;
    }
};

fn schemaShortValue(comptime ch: u8) FlagSchema {
    return .{
        .is_value_taking_short = valueTakingFactory.make(ch),
        .is_value_taking_long = struct {
            fn f(_: []const u8) bool {
                return false;
            }
        }.f,
        .is_known_long = struct {
            fn f(_: []const u8) bool {
                return false;
            }
        }.f,
        .is_boolean_long = struct {
            fn f(_: []const u8) bool {
                return false;
            }
        }.f,
    };
}

fn parseOne(allocator: std.mem.Allocator, argv: []const []const u8, schema: FlagSchema) !struct { tokens: []Token, advanced: usize } {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    try parseShort(allocator, &list, argv, &i, schema, null);
    return .{ .tokens = try list.toOwnedSlice(allocator), .advanced = i };
}

test "parseShort: -f standalone (non-value-taking)" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-f"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqual(@as(u8, 'f'), r.tokens[0].short.name);
    try testing.expect(r.tokens[0].short.value == null);
}

test "parseShort: -abc emits three standalone shorts (boolean group)" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-abc"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 3), r.tokens.len);
    try testing.expectEqual(@as(u8, 'a'), r.tokens[0].short.name);
    try testing.expectEqual(@as(u8, 'b'), r.tokens[1].short.name);
    try testing.expectEqual(@as(u8, 'c'), r.tokens[2].short.name);
    // raw should be the same source group on every token
    try testing.expectEqualStrings("-abc", r.tokens[0].short.raw);
    try testing.expectEqualStrings("-abc", r.tokens[1].short.raw);
    try testing.expectEqualStrings("-abc", r.tokens[2].short.raw);
}

test "parseShort: -fbar with value-taking f attaches the rest" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-fbar"}, schemaShortValue('f'));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqual(@as(u8, 'f'), r.tokens[0].short.name);
    try testing.expectEqualStrings("bar", r.tokens[0].short.value.?);
    try testing.expectEqual(@as(usize, 1), r.advanced);
}

test "parseShort: -f bar consumes next argv" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{ "-f", "bar" }, schemaShortValue('f'));
    defer gpa.free(r.tokens);
    try testing.expectEqualStrings("bar", r.tokens[0].short.value.?);
    try testing.expectEqual(@as(usize, 2), r.advanced);
}

test "parseShort: -abc where a is value-taking treats bc as a's value" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-abc"}, schemaShortValue('a'));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqualStrings("bc", r.tokens[0].short.value.?);
}

test "parseShort: -abc where b is value-taking but a is not" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-abc"}, schemaShortValue('b'));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 2), r.tokens.len);
    try testing.expectEqual(@as(u8, 'a'), r.tokens[0].short.name);
    try testing.expect(r.tokens[0].short.value == null);
    try testing.expectEqual(@as(u8, 'b'), r.tokens[1].short.name);
    try testing.expectEqualStrings("c", r.tokens[1].short.value.?);
}

test "parseShort: -f=bar always splits on = even for non-value-taking" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-f=bar"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqualStrings("bar", r.tokens[0].short.value.?);
}

test "parseShort: -f=true on boolean schema" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-f=true"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqualStrings("true", r.tokens[0].short.value.?);
}

test "parseShort: -vvv emits three count tokens" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-vvv"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 3), r.tokens.len);
    for (r.tokens) |t| {
        try testing.expectEqual(@as(u8, 'v'), t.short.name);
        try testing.expect(t.short.value == null);
    }
}

test "parseShort: -f without a following arg emits null value" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-f"}, schemaShortValue('f'));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expect(r.tokens[0].short.value == null);
}

test "parseShort: -f= emits empty attached value (matches pflag)" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-f="}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqual(@as(u8, 'f'), r.tokens[0].short.name);
    try testing.expectEqualStrings("", r.tokens[0].short.value.?);
}

test "parseShort: -= treats = as an unknown shorthand char" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"-="}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    // pflag has no special-case for `=` as the first shorthand char; it
    // becomes a one-char shorthand that the flag layer rejects as unknown.
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqual(@as(u8, '='), r.tokens[0].short.name);
}
