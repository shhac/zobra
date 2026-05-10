//! Tests for the slice flag types added during the vipvot-parity push:
//! int32Slice, int64Slice, float32Slice, float64Slice, boolSlice,
//! durationSlice. The intSlice / stringSlice / stringArray paths have
//! their own tests in test/flag/flagset.zig.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const FlagSet = zobra.FlagSet;
const Diagnostic = zobra.Diagnostic;

test "int32Slice: parses comma-separated, appends on repeat" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var nums: []const i32 = &.{};
    try fs.int32SliceVarP(&nums, "ns", 0, &.{}, "");
    try fs.set("ns", "1,2,3", null);
    try fs.set("ns", "4", null);
    try testing.expectEqual(@as(usize, 4), nums.len);
    try testing.expectEqual(@as(i32, 4), nums[3]);
}

test "int32Slice: overflow yields strconv-style wording" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var nums: []const i32 = &.{};
    try fs.int32SliceVarP(&nums, "ns", 0, &.{}, "");
    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("ns", "9999999999", &d));
    try testing.expect(std.mem.indexOf(u8, d.message.?, "value out of range") != null);
}

test "int64Slice: parses with base auto-detect" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var nums: []const i64 = &.{};
    try fs.int64SliceVarP(&nums, "ns", 0, &.{}, "");
    try fs.set("ns", "10,0xff,0o17", null);
    try testing.expectEqualSlices(i64, &.{ 10, 0xff, 0o17 }, nums);
}

test "float32Slice: rounds via f32" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var nums: []const f32 = &.{};
    try fs.float32SliceVarP(&nums, "ns", 0, &.{}, "");
    try fs.set("ns", "1.5,2.25,0.125", null);
    try testing.expectEqual(@as(usize, 3), nums.len);
    try testing.expectApproxEqAbs(@as(f32, 1.5), nums[0], 0.001);
}

test "float64Slice: scientific notation" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var nums: []const f64 = &.{};
    try fs.float64SliceVarP(&nums, "ns", 0, &.{}, "");
    try fs.set("ns", "1e6,3.14,0.5", null);
    try testing.expectApproxEqAbs(@as(f64, 1e6), nums[0], 0.001);
}

test "boolSlice: every accepted form" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var bs: []const bool = &.{};
    try fs.boolSliceVarP(&bs, "bs", 0, &.{}, "");
    try fs.set("bs", "true,false,1,0,T,F", null);
    try testing.expectEqualSlices(bool, &.{ true, false, true, false, true, false }, bs);
}

test "durationSlice: each element is parsed independently" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var ds: []const i64 = &.{};
    try fs.durationSliceVarP(&ds, "ds", 0, &.{}, "");
    try fs.set("ds", "300ms,5s,1h", null);
    try testing.expectEqual(@as(usize, 3), ds.len);
    try testing.expectEqual(@as(i64, 300_000_000), ds[0]);
    try testing.expectEqual(@as(i64, 5_000_000_000), ds[1]);
    try testing.expectEqual(@as(i64, 3_600_000_000_000), ds[2]);
}

test "durationSlice: bad element renders Go time-package wording" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var ds: []const i64 = &.{};
    try fs.durationSliceVarP(&ds, "ds", 0, &.{}, "");
    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("ds", "5s,bad", &d));
    try testing.expect(std.mem.indexOf(u8, d.message.?, "time: invalid duration \"bad\"") != null);
}
