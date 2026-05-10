//! Integration tests for the parser driver — mixed argv shapes that exercise
//! the interleaving of long, short, positional, terminator, and passthrough.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const FlagSchema = zobra.parser.FlagSchema;
const parse = zobra.parser.parse;

fn schemaWith(
    comptime value_short: u8,
    comptime value_long: []const u8,
    comptime bool_long: []const u8,
) FlagSchema {
    return .{
        .is_value_taking_short = struct {
            fn f(c: u8) bool {
                return c == value_short;
            }
        }.f,
        .is_value_taking_long = struct {
            fn f(name: []const u8) bool {
                return std.mem.eql(u8, name, value_long);
            }
        }.f,
        .is_known_long = struct {
            fn f(name: []const u8) bool {
                return std.mem.eql(u8, name, value_long) or std.mem.eql(u8, name, bool_long);
            }
        }.f,
        .is_boolean_long = struct {
            fn f(name: []const u8) bool {
                return std.mem.eql(u8, name, bool_long);
            }
        }.f,
    };
}

test "interspersed: cmd a --foo b" {
    const gpa = testing.allocator;
    const tokens = try parse(gpa, &.{ "cmd", "a", "--foo", "b" }, FlagSchema.empty, null);
    defer gpa.free(tokens);
    try testing.expectEqual(@as(usize, 4), tokens.len);
    try testing.expectEqualStrings("cmd", tokens[0].positional.value);
    try testing.expectEqualStrings("a", tokens[1].positional.value);
    try testing.expect(tokens[2] == .long);
    try testing.expectEqualStrings("foo", tokens[2].long.name);
    try testing.expectEqualStrings("b", tokens[3].positional.value);
}

test "interspersed value-taking: cmd --name alice greet" {
    const gpa = testing.allocator;
    const schema = schemaWith(0, "name", "");
    const tokens = try parse(gpa, &.{ "cmd", "--name", "alice", "greet" }, schema, null);
    defer gpa.free(tokens);
    // The schema marks --name as value-taking, so "alice" is consumed.
    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqualStrings("cmd", tokens[0].positional.value);
    try testing.expectEqualStrings("name", tokens[1].long.name);
    try testing.expectEqualStrings("alice", tokens[1].long.value.?);
    try testing.expectEqualStrings("greet", tokens[2].positional.value);
}

test "long + short + positional + terminator + passthrough" {
    const gpa = testing.allocator;
    const schema = schemaWith('o', "name", "verbose");
    const tokens = try parse(
        gpa,
        &.{ "cmd", "--name=alice", "-vvo", "out.txt", "pos1", "--", "--literal", "-x" },
        schema,
        null,
    );
    defer gpa.free(tokens);

    // cmd                   → positional
    // --name=alice          → long{name=alice}
    // -vvo out.txt          → short(v), short(v), short(o, value=out.txt)
    // pos1                  → positional
    // --                    → terminator
    // --literal             → passthrough
    // -x                    → passthrough
    try testing.expectEqual(@as(usize, 9), tokens.len);
    try testing.expectEqualStrings("cmd", tokens[0].positional.value);

    try testing.expect(tokens[1] == .long);
    try testing.expectEqualStrings("name", tokens[1].long.name);
    try testing.expectEqualStrings("alice", tokens[1].long.value.?);

    try testing.expect(tokens[2] == .short);
    try testing.expectEqual(@as(u8, 'v'), tokens[2].short.name);
    try testing.expect(tokens[2].short.value == null);
    try testing.expect(tokens[3] == .short);
    try testing.expectEqual(@as(u8, 'v'), tokens[3].short.name);
    try testing.expect(tokens[4] == .short);
    try testing.expectEqual(@as(u8, 'o'), tokens[4].short.name);
    try testing.expectEqualStrings("out.txt", tokens[4].short.value.?);

    try testing.expectEqualStrings("pos1", tokens[5].positional.value);
    try testing.expect(tokens[6] == .terminator);
    try testing.expectEqualStrings("--literal", tokens[7].passthrough);
    try testing.expectEqualStrings("-x", tokens[8].passthrough);
}

test "no leak when an early arg fails parse" {
    const gpa = testing.allocator;
    var d: zobra.Diagnostic = .{};
    defer d.deinit(gpa);
    const result = parse(gpa, &.{ "cmd", "--ok", "---bad" }, FlagSchema.empty, &d);
    try testing.expectError(error.BadFlagSyntax, result);
    // No leak assertion — the testing allocator catches it on tear-down.
}

test "unknown flag is emitted, not errored, by the parser" {
    const gpa = testing.allocator;
    const tokens = try parse(gpa, &.{"--definitely-unknown"}, FlagSchema.empty, null);
    defer gpa.free(tokens);
    try testing.expectEqual(@as(usize, 1), tokens.len);
    try testing.expect(tokens[0] == .long);
    try testing.expectEqualStrings("definitely-unknown", tokens[0].long.name);
}
