//! Tests for the map flag types: stringToString, stringToInt,
//! stringToInt64. Mirrors pflag's stringToString family — input shape
//! is `--header key1=v1,key2=v2`, comma-separated items, each split on
//! the first `=`.
//!
//! Memory model: the user pre-creates an empty
//! StringHashMapUnmanaged; FlagSet appends entries on apply. FlagSet
//! owns the map's allocation; it deinit's on FlagSet teardown.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const FlagSet = zobra.FlagSet;
const Diagnostic = zobra.Diagnostic;

test "stringToString: parses key=value pairs" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var headers: std.StringHashMapUnmanaged([]const u8) = .{};
    try fs.stringToStringVarP(&headers, "header", 'H', "");

    try fs.set("header", "Content-Type=application/json,Accept=*/*", null);
    try testing.expectEqual(@as(u32, 2), headers.count());
    try testing.expectEqualStrings("application/json", headers.get("Content-Type").?);
    try testing.expectEqualStrings("*/*", headers.get("Accept").?);
}

test "stringToString: repeated --header appends + overwrites duplicates" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var headers: std.StringHashMapUnmanaged([]const u8) = .{};
    try fs.stringToStringVarP(&headers, "header", 0, "");

    try fs.set("header", "Authorization=Bearer abc", null);
    try fs.set("header", "Content-Length=42,Authorization=Bearer xyz", null);
    try testing.expectEqual(@as(u32, 2), headers.count());
    try testing.expectEqualStrings("Bearer xyz", headers.get("Authorization").?);
    try testing.expectEqualStrings("42", headers.get("Content-Length").?);
}

test "stringToString: missing = errors with TypeCoercionFailed" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var headers: std.StringHashMapUnmanaged([]const u8) = .{};
    try fs.stringToStringVarP(&headers, "header", 0, "");

    try testing.expectError(error.TypeCoercionFailed, fs.set("header", "no-equals-sign", null));
}

test "stringToInt: parses + stores typed values" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var metrics: std.StringHashMapUnmanaged(i32) = .{};
    try fs.stringToIntVarP(&metrics, "metric", 'm', "");

    try fs.set("metric", "count=10,errors=3", null);
    try testing.expectEqual(@as(i32, 10), metrics.get("count").?);
    try testing.expectEqual(@as(i32, 3), metrics.get("errors").?);
}

test "stringToInt: bad value renders strconv wording" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var metrics: std.StringHashMapUnmanaged(i32) = .{};
    try fs.stringToIntVarP(&metrics, "metric", 0, "");
    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("metric", "count=abc", &d));
    try testing.expect(std.mem.indexOf(u8, d.message.?, "strconv.ParseInt: parsing \"abc\": invalid syntax") != null);
}

test "stringToInt64: handles large i64 values" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var ledger: std.StringHashMapUnmanaged(i64) = .{};
    try fs.stringToInt64VarP(&ledger, "ledger", 0, "");

    try fs.set("ledger", "balance=9999999999,debt=-1234567890", null);
    try testing.expectEqual(@as(i64, 9999999999), ledger.get("balance").?);
    try testing.expectEqual(@as(i64, -1234567890), ledger.get("debt").?);
}
