//! Long-flag handling. Mirrors pflag's parseLongArg (flag.go:980).

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const fillDiag = @import("../diagnostic.zig").fill;
const Token = @import("token.zig").Token;
const FlagSchema = @import("parser.zig").FlagSchema;

const no_prefix = "no-";

/// Process argv[i.*], which is a `--…` element. Advances `i` to the next
/// unconsumed argv index (one or two depending on whether the value was
/// attached or consumed from the next slot).
pub fn parseLong(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Token),
    argv: []const []const u8,
    i: *usize,
    schema: FlagSchema,
    diag: ?*Diagnostic,
) errors.ParserError!void {
    const s = argv[i.*];
    std.debug.assert(s.len >= 2 and s[0] == '-' and s[1] == '-');

    const tail = s[2..];

    // pflag rejects ---name and --=value as bad syntax.
    if (tail.len == 0 or tail[0] == '-' or tail[0] == '=') {
        fillDiag(diag, .parse, .bad_flag_syntax);
        if (diag) |d| {
            d.raw = s;
            d.position = i.*;
        }
        return error.BadFlagSyntax;
    }

    const eq_idx = std.mem.indexOfScalar(u8, tail, '=');
    const name = if (eq_idx) |idx| tail[0..idx] else tail;
    const attached: ?[]const u8 = if (eq_idx) |idx| tail[idx + 1 ..] else null;

    // Negation handling. zobra divergence: any boolean flag is universally
    // negatable via --no-foo, even though pflag requires NoOptDefVal opt-in.
    // A flag literally registered as "no-foo" wins over the negation reading.
    if (attached == null and isNoPrefixed(name) and !schema.is_known_long(schema.ctx, name)) {
        const stripped = name[no_prefix.len..];
        if (stripped.len > 0 and schema.is_boolean_long(schema.ctx, stripped)) {
            try out.append(allocator, .{ .negated = .{ .name = stripped, .raw = s } });
            i.* += 1;
            return;
        }
    }

    // Value resolution (mirrors pflag flag.go:1012-1031):
    //   1. attached `--foo=bar`               → value = bar (always wins)
    //   2. value-taking and next argv exists  → consume next argv
    //   3. value-taking but no more argv      → emit standalone; flag layer raises MissingValue
    //   4. non-value-taking standalone        → emit standalone (boolean / count)
    if (attached) |v| {
        try out.append(allocator, .{ .long = .{ .name = name, .value = v, .raw = s } });
        i.* += 1;
        return;
    }

    if (schema.is_value_taking_long(schema.ctx, name)) {
        if (i.* + 1 < argv.len) {
            const value = argv[i.* + 1];
            try out.append(allocator, .{ .long = .{ .name = name, .value = value, .raw = s } });
            i.* += 2;
            return;
        }
        // No following arg — emit value=null. The flag layer raises
        // MissingValue with the proper wording.
        try out.append(allocator, .{ .long = .{ .name = name, .value = null, .raw = s } });
        i.* += 1;
        return;
    }

    // Non-value-taking (or unknown): emit standalone. Flag layer rejects
    // unknowns; counts/booleans bind from NoOptDefVal-equivalent.
    try out.append(allocator, .{ .long = .{ .name = name, .value = null, .raw = s } });
    i.* += 1;
}

fn isNoPrefixed(name: []const u8) bool {
    return std.mem.startsWith(u8, name, no_prefix);
}

// ---- inline tests --------------------------------------------------------

const testing = std.testing;

var dummy_ctx: u8 = 0;

const stringFalse = struct {
    fn f(_: *const anyopaque, _: []const u8) bool {
        return false;
    }
}.f;

const stringEqlFactory = struct {
    fn make(comptime want: []const u8) *const fn (*const anyopaque, []const u8) bool {
        return struct {
            fn f(_: *const anyopaque, name: []const u8) bool {
                return std.mem.eql(u8, name, want);
            }
        }.f;
    }
};

fn schemaWithBoolean(comptime name: []const u8) FlagSchema {
    return .{
        .ctx = &dummy_ctx,
        .is_value_taking_short = struct {
            fn f(_: *const anyopaque, _: u8) bool {
                return false;
            }
        }.f,
        .is_value_taking_long = stringFalse,
        .is_known_long = stringEqlFactory.make(name),
        .is_boolean_long = stringEqlFactory.make(name),
    };
}

fn schemaWithValueLong(comptime name: []const u8) FlagSchema {
    return .{
        .ctx = &dummy_ctx,
        .is_value_taking_short = struct {
            fn f(_: *const anyopaque, _: u8) bool {
                return false;
            }
        }.f,
        .is_value_taking_long = stringEqlFactory.make(name),
        .is_known_long = stringEqlFactory.make(name),
        .is_boolean_long = stringFalse,
    };
}

fn parseOne(allocator: std.mem.Allocator, argv: []const []const u8, schema: FlagSchema) !struct { tokens: []Token, advanced: usize } {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    try parseLong(allocator, &list, argv, &i, schema, null);
    return .{ .tokens = try list.toOwnedSlice(allocator), .advanced = i };
}

test "parseLong: --foo with attached value" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--foo=bar"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqualStrings("foo", r.tokens[0].long.name);
    try testing.expectEqualStrings("bar", r.tokens[0].long.value.?);
    try testing.expectEqual(@as(usize, 1), r.advanced);
}

test "parseLong: --foo= with empty attached value" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--foo="}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqualStrings("", r.tokens[0].long.value.?);
}

test "parseLong: --foo=bar=baz preserves only the first =" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--foo=bar=baz"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqualStrings("bar=baz", r.tokens[0].long.value.?);
}

test "parseLong: --foo standalone, non-value-taking" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--foo"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expect(r.tokens[0].long.value == null);
    try testing.expectEqual(@as(usize, 1), r.advanced);
}

test "parseLong: --foo bar with value-taking schema consumes next argv" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{ "--foo", "bar" }, schemaWithValueLong("foo"));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expectEqualStrings("bar", r.tokens[0].long.value.?);
    try testing.expectEqual(@as(usize, 2), r.advanced);
}

test "parseLong: --foo with value-taking schema but no next argv emits null" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--foo"}, schemaWithValueLong("foo"));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expect(r.tokens[0].long.value == null);
}

test "parseLong: ---name is bad flag syntax" {
    const gpa = testing.allocator;
    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    var list: std.ArrayList(Token) = .empty;
    defer list.deinit(gpa);
    var i: usize = 0;
    const argv: []const []const u8 = &.{"---name"};
    try testing.expectError(error.BadFlagSyntax, parseLong(gpa, &list, argv, &i, FlagSchema.empty, &d));
    try testing.expectEqual(Diagnostic.Code.bad_flag_syntax, d.code.?);
    try testing.expectEqualStrings("---name", d.raw.?);
}

test "parseLong: --=value is bad flag syntax" {
    const gpa = testing.allocator;
    var list: std.ArrayList(Token) = .empty;
    defer list.deinit(gpa);
    var i: usize = 0;
    const argv: []const []const u8 = &.{"--=value"};
    try testing.expectError(error.BadFlagSyntax, parseLong(gpa, &list, argv, &i, FlagSchema.empty, null));
}

test "parseLong: --no-debug emits negated when debug is boolean" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--no-debug"}, schemaWithBoolean("debug"));
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expect(r.tokens[0] == .negated);
    try testing.expectEqualStrings("debug", r.tokens[0].negated.name);
    try testing.expectEqualStrings("--no-debug", r.tokens[0].negated.raw);
}

test "parseLong: --no-foo without boolean foo emits regular long" {
    const gpa = testing.allocator;
    const r = try parseOne(gpa, &.{"--no-foo"}, FlagSchema.empty);
    defer gpa.free(r.tokens);
    try testing.expectEqual(@as(usize, 1), r.tokens.len);
    try testing.expect(r.tokens[0] == .long);
    try testing.expectEqualStrings("no-foo", r.tokens[0].long.name);
}

test "parseLong: literal --no-foo flag wins over negation" {
    const gpa = testing.allocator;
    const schema: FlagSchema = .{
        .ctx = &dummy_ctx,
        .is_value_taking_short = struct {
            fn f(_: *const anyopaque, _: u8) bool {
                return false;
            }
        }.f,
        .is_value_taking_long = stringFalse,
        .is_known_long = stringEqlFactory.make("no-foo"),
        .is_boolean_long = stringEqlFactory.make("foo"),
    };
    const r = try parseOne(gpa, &.{"--no-foo"}, schema);
    defer gpa.free(r.tokens);
    try testing.expect(r.tokens[0] == .long);
    try testing.expectEqualStrings("no-foo", r.tokens[0].long.name);
}

test "parseLong: --no-debug=value is always a regular long, never negation" {
    const gpa = testing.allocator;
    // Schema marks `debug` as a boolean long; without the attached value
    // this would emit `negated{debug}`. With the attached value, it must be
    // treated as a long flag named "no-debug" — an attached value wins.
    const r = try parseOne(gpa, &.{"--no-debug=value"}, schemaWithBoolean("debug"));
    defer gpa.free(r.tokens);
    try testing.expect(r.tokens[0] == .long);
    try testing.expectEqualStrings("no-debug", r.tokens[0].long.name);
    try testing.expectEqualStrings("value", r.tokens[0].long.value.?);
}

test "parseLong: --no- with empty stripped name falls through to long" {
    const gpa = testing.allocator;
    // `--no-` with no following name: stripped is "" so the negation
    // branch is skipped; emit a long token named "no-".
    const r = try parseOne(gpa, &.{"--no-"}, schemaWithBoolean("debug"));
    defer gpa.free(r.tokens);
    try testing.expect(r.tokens[0] == .long);
    try testing.expectEqualStrings("no-", r.tokens[0].long.name);
}
