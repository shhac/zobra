//! Network (ip / ipMask / ipNet) and bytes (bytesHex / bytesBase64)
//! flag types — closing the last vipvot-parity flag-type gap.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const FlagSet = zobra.FlagSet;
const Diagnostic = zobra.Diagnostic;

test "ip: accepts IPv4 literal" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var addr: []const u8 = "";
    try fs.ipVarP(&addr, "addr", 0, "", "");
    try fs.set("addr", "192.168.1.1", null);
    try testing.expectEqualStrings("192.168.1.1", addr);
}

test "ip: accepts IPv6 literal" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var addr: []const u8 = "";
    try fs.ipVarP(&addr, "addr", 0, "", "");
    try fs.set("addr", "::1", null);
    try testing.expectEqualStrings("::1", addr);
}

test "ip: rejects non-IP" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var addr: []const u8 = "";
    try fs.ipVarP(&addr, "addr", 0, "", "");
    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("addr", "not-an-ip", &d));
    try testing.expect(std.mem.indexOf(u8, d.message.?, "invalid IP address") != null);
}

test "ipMask: accepts 8-char hex (IPv4)" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var mask: []const u8 = "";
    try fs.ipMaskVarP(&mask, "mask", 0, "", "");
    try fs.set("mask", "ffffff00", null);
    try testing.expectEqualStrings("ffffff00", mask);
}

test "ipMask: rejects bad length" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var mask: []const u8 = "";
    try fs.ipMaskVarP(&mask, "mask", 0, "", "");
    try testing.expectError(error.TypeCoercionFailed, fs.set("mask", "fffff", null));
}

test "ipNet: accepts CIDR" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var net_val: []const u8 = "";
    try fs.ipNetVarP(&net_val, "net", 0, "", "");
    try fs.set("net", "10.0.0.0/8", null);
    try testing.expectEqualStrings("10.0.0.0/8", net_val);
}

test "ipNet: rejects missing slash" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var net_val: []const u8 = "";
    try fs.ipNetVarP(&net_val, "net", 0, "", "");
    try testing.expectError(error.TypeCoercionFailed, fs.set("net", "10.0.0.0", null));
}

test "bytesHex: decodes" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var bytes: []const u8 = "";
    try fs.bytesHexVarP(&bytes, "bx", 0, "", "");
    try fs.set("bx", "deadbeef", null);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, bytes);
}

test "bytesHex: rejects odd length" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var bytes: []const u8 = "";
    try fs.bytesHexVarP(&bytes, "bx", 0, "", "");
    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("bx", "abc", &d));
    try testing.expect(std.mem.indexOf(u8, d.message.?, "odd length") != null);
}

test "bytesBase64: decodes" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var bytes: []const u8 = "";
    try fs.bytesBase64VarP(&bytes, "b64", 0, "", "");
    try fs.set("b64", "aGVsbG8=", null); // "hello"
    try testing.expectEqualStrings("hello", bytes);
}

test "bytesBase64: rejects illegal data" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();
    var bytes: []const u8 = "";
    try fs.bytesBase64VarP(&bytes, "b64", 0, "", "");
    try testing.expectError(error.TypeCoercionFailed, fs.set("b64", "not!base64!", null));
}
