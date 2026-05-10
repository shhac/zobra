//! Tests for the FlagSet.changed accessor and the CustomFlag vtable
//! escape hatch (the pflag.Value equivalent).

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const FlagSet = zobra.FlagSet;
const CustomFlag = zobra.flag.CustomFlag;

test "changed: returns false until set, true after" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var name: []const u8 = "world";
    try fs.stringVarP(&name, "name", 0, "world", "");
    try testing.expect(!fs.changed("name"));
    try fs.set("name", "alice", null);
    try testing.expect(fs.changed("name"));
}

test "changed: false for unregistered name (matches pflag)" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    try testing.expect(!fs.changed("never-registered"));
}

// ---- CustomFlag vtable: a CSV-list user type --------------------------

const CsvList = struct {
    items: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    fn setFn(ptr: *anyopaque, value: []const u8) anyerror!void {
        const self: *CsvList = @ptrCast(@alignCast(ptr));
        self.items.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |s| try self.items.append(self.allocator, s);
    }

    fn stringFn(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
        const self: *CsvList = @ptrCast(@alignCast(ptr));
        if (self.items.items.len == 0) return allocator.dupe(u8, "");
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        for (self.items.items, 0..) |s, i| {
            if (i > 0) try aw.writer.writeByte(',');
            try aw.writer.writeAll(s);
        }
        return aw.toOwnedSlice();
    }
};

test "CustomFlag: user-defined CSV list type" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var list: CsvList = .{ .allocator = gpa };
    defer list.items.deinit(gpa);

    try fs.varP(.{
        .ptr = &list,
        .type_name = "csv-list",
        .set_fn = CsvList.setFn,
        .string_fn = CsvList.stringFn,
    }, "items", 'i', "comma-separated items");

    try fs.set("items", "alpha,beta,gamma", null);
    try testing.expectEqual(@as(usize, 3), list.items.items.len);
    try testing.expectEqualStrings("alpha", list.items.items[0]);
    try testing.expectEqualStrings("beta", list.items.items[1]);
    try testing.expectEqualStrings("gamma", list.items.items[2]);
}

test "CustomFlag: invalid value error renders rich wording" {
    const gpa = testing.allocator;

    const Strict = struct {
        fn setFn(_: *anyopaque, value: []const u8) anyerror!void {
            // Reject anything not equal to "ok".
            if (!std.mem.eql(u8, value, "ok")) return error.RejectedValue;
        }
        fn stringFn(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
            return allocator.dupe(u8, "");
        }
    };

    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var dummy: u8 = 0;
    try fs.varP(.{
        .ptr = &dummy,
        .type_name = "strict-token",
        .set_fn = Strict.setFn,
        .string_fn = Strict.stringFn,
    }, "tok", 0, "");

    var d: zobra.Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("tok", "bad", &d));
    try testing.expect(std.mem.indexOf(u8, d.message.?, "invalid value for strict-token: bad") != null);
}
