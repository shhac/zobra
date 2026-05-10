//! string → typed coercions for the 16 scalar flag types.
//!
//! Source of truth: pflag's per-type Set methods, which delegate to Go's
//! strconv.ParseBool / ParseInt / ParseUint / ParseFloat. The error wording
//! we emit on failure (`strconv.Parse…: parsing "X": …`) is byte-for-byte
//! identical to what pflag prints because pflag wraps the strconv error
//! verbatim into its InvalidValueError.
//!
//! Two minor divergences from Go strconv (documented in
//! design-docs/09-zobra-divergences.md):
//!   1. `_` as digit separator is accepted (Zig std accepts; Go strconv
//!      rejects). Won't surface unless a CLI explicitly tests it.
//!   2. Leading-zero octal (`0664`) is handled here to match Go strconv;
//!      Zig std's parseInt requires a `0o` prefix.

const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const errors = @import("../errors.zig");

pub const Cause = enum { invalid_syntax, value_out_of_range };

/// pflag/strconv-shaped error message. Caller owns the returned slice.
/// Format mirrors Go's strconv.NumError.Error():
///   strconv.ParseInt: parsing "X": invalid syntax
///   strconv.ParseInt: parsing "X": value out of range
pub fn renderNumError(
    allocator: std.mem.Allocator,
    func: []const u8,
    raw: []const u8,
    cause: Cause,
) ![]u8 {
    const cause_text = switch (cause) {
        .invalid_syntax => "invalid syntax",
        .value_out_of_range => "value out of range",
    };
    return std.fmt.allocPrint(
        allocator,
        "strconv.{s}: parsing \"{s}\": {s}",
        .{ func, raw, cause_text },
    );
}

/// strconv.ParseBool — accepts: "1", "t", "T", "TRUE", "true", "True",
/// "0", "f", "F", "FALSE", "false", "False". Any other input is
/// invalid_syntax.
pub fn parseBool(s: []const u8) !bool {
    // Match the exact set Go's strconv.ParseBool recognises.
    if (s.len == 1) switch (s[0]) {
        '1', 't', 'T' => return true,
        '0', 'f', 'F' => return false,
        else => return error.InvalidSyntax,
    };
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "True")) return true;
    if (std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "FALSE") or std.mem.eql(u8, s, "False")) return false;
    return error.InvalidSyntax;
}

/// strconv.ParseInt(s, 0, bitSize) — auto-detect base. Accepts:
///   1234         → decimal
///   0x1234       → hex
///   0o1234       → octal (Go 1.13+)
///   0b1010       → binary (Go 1.13+)
///   0664         → octal (legacy leading-zero form, still accepted)
///   may be negative.
pub fn parseSignedInt(comptime T: type, s: []const u8) !T {
    return parseGoStyleInt(T, s, .signed);
}

pub fn parseUnsignedInt(comptime T: type, s: []const u8) !T {
    return parseGoStyleInt(T, s, .unsigned);
}

const Sign = enum { signed, unsigned };

fn parseGoStyleInt(comptime T: type, s: []const u8, sign: Sign) !T {
    if (s.len == 0) return error.InvalidSyntax;

    // Detect optional leading sign.
    const sign_len: usize = if (s[0] == '+' or s[0] == '-') 1 else 0;
    if (sign == .unsigned and sign_len == 1 and s[0] == '-') {
        // Even "-0" succeeds in Zig's parseInt for unsigned; Go's
        // strconv.ParseUint rejects any sign. Match Go.
        return error.InvalidSyntax;
    }
    if (sign == .unsigned and sign_len == 1 and s[0] == '+') {
        // Go's strconv.ParseUint also rejects '+' on unsigned. Match.
        return error.InvalidSyntax;
    }

    const body = s[sign_len..];
    if (body.len == 0) return error.InvalidSyntax;

    // Legacy leading-zero octal: "0NN" where N are octal digits and the
    // second char isn't a base-prefix ('x'/'X'/'o'/'O'/'b'/'B').
    if (body.len >= 2 and body[0] == '0') {
        const c1 = body[1];
        const is_prefix = c1 == 'x' or c1 == 'X' or c1 == 'o' or c1 == 'O' or c1 == 'b' or c1 == 'B';
        if (!is_prefix and isOctalDigit(c1)) {
            return parseWithExplicitBase(T, s[0..sign_len], body, 8);
        }
    }

    return mapIntError(std.fmt.parseInt(T, s, 0));
}

fn parseWithExplicitBase(comptime T: type, sign_slice: []const u8, body: []const u8, base: u8) !T {
    // Verify every char in body is a valid base-N digit. Reject "_"
    // (digit separator) to match Go strconv's stricter behaviour.
    for (body) |c| {
        if (c == '_') return error.InvalidSyntax;
        if (!isDigitForBase(c, base)) return error.InvalidSyntax;
    }
    if (sign_slice.len == 1) {
        var buf: [128]u8 = undefined;
        if (sign_slice.len + body.len > buf.len) return error.InvalidSyntax;
        std.mem.copyForwards(u8, buf[0..sign_slice.len], sign_slice);
        std.mem.copyForwards(u8, buf[sign_slice.len..][0..body.len], body);
        return mapIntError(std.fmt.parseInt(T, buf[0 .. sign_slice.len + body.len], base));
    }
    return mapIntError(std.fmt.parseInt(T, body, base));
}

fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isDigitForBase(c: u8, base: u8) bool {
    return switch (base) {
        2 => c == '0' or c == '1',
        8 => c >= '0' and c <= '7',
        10 => c >= '0' and c <= '9',
        16 => (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'),
        else => false,
    };
}

fn mapIntError(r: anytype) @TypeOf(r) {
    // Pass-through; the caller switches on error.InvalidCharacter / Overflow
    // and translates into our Cause enum at the Set boundary.
    return r;
}

/// Translate a Zig parseInt error to our Cause.
pub fn intCause(err: anyerror) Cause {
    return switch (err) {
        error.Overflow => .value_out_of_range,
        else => .invalid_syntax,
    };
}

/// strconv.ParseFloat(s, 64). Defers to Zig's parseFloat which accepts the
/// same lexical shapes (decimal, scientific, hex floats).
pub fn parseFloat(comptime T: type, s: []const u8) !T {
    if (s.len == 0) return error.InvalidSyntax;
    return std.fmt.parseFloat(T, s) catch |err| switch (err) {
        error.InvalidCharacter => error.InvalidSyntax,
    };
}

/// Float coercion error map.
pub fn floatCause(err: anyerror) Cause {
    return switch (err) {
        error.Overflow => .value_out_of_range,
        else => .invalid_syntax,
    };
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

test "parseBool: every accepted form" {
    const truthy = [_][]const u8{ "1", "t", "T", "true", "TRUE", "True" };
    const falsy = [_][]const u8{ "0", "f", "F", "false", "FALSE", "False" };
    for (truthy) |s| try testing.expect(try parseBool(s));
    for (falsy) |s| try testing.expect(!(try parseBool(s)));
}

test "parseBool: rejects junk" {
    try testing.expectError(error.InvalidSyntax, parseBool(""));
    try testing.expectError(error.InvalidSyntax, parseBool("yes"));
    try testing.expectError(error.InvalidSyntax, parseBool("no"));
    try testing.expectError(error.InvalidSyntax, parseBool("2"));
    try testing.expectError(error.InvalidSyntax, parseBool("True "));
}

test "parseSignedInt: decimal, hex, octal-with-prefix, binary, leading-zero-octal" {
    try testing.expectEqual(@as(i64, 1234), try parseSignedInt(i64, "1234"));
    try testing.expectEqual(@as(i64, 4660), try parseSignedInt(i64, "0x1234"));
    try testing.expectEqual(@as(i64, 4660), try parseSignedInt(i64, "0X1234"));
    try testing.expectEqual(@as(i64, 83), try parseSignedInt(i64, "0o123"));
    try testing.expectEqual(@as(i64, 10), try parseSignedInt(i64, "0b1010"));
    // Legacy leading-zero octal form (matches Go strconv.ParseInt with base=0).
    try testing.expectEqual(@as(i64, 0o664), try parseSignedInt(i64, "0664"));
    try testing.expectEqual(@as(i64, -7), try parseSignedInt(i64, "-7"));
    try testing.expectEqual(@as(i64, -0o664), try parseSignedInt(i64, "-0664"));
}

test "parseSignedInt: overflow on small types" {
    try testing.expectError(error.Overflow, parseSignedInt(i8, "200"));
    try testing.expectError(error.Overflow, parseSignedInt(i32, "9999999999999"));
}

test "parseSignedInt: junk is invalid syntax" {
    // The exact error tag is implementation-detail (InvalidCharacter from
    // Zig std, InvalidSyntax from our prefix-handling). What matters is
    // `intCause` maps either to .invalid_syntax for the rendered wording.
    if (parseSignedInt(i64, "foo")) |_| {
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(Cause.invalid_syntax, intCause(err));
    }
    if (parseSignedInt(i64, "")) |_| {
        try testing.expect(false);
    } else |err| {
        try testing.expectEqual(Cause.invalid_syntax, intCause(err));
    }
}

test "parseUnsignedInt: signs are rejected" {
    try testing.expectError(error.InvalidSyntax, parseUnsignedInt(u32, "+5"));
    try testing.expectError(error.InvalidSyntax, parseUnsignedInt(u32, "-5"));
    try testing.expectEqual(@as(u32, 5), try parseUnsignedInt(u32, "5"));
}

test "parseUnsignedInt: overflow on u8" {
    try testing.expectError(error.Overflow, parseUnsignedInt(u8, "256"));
    try testing.expectEqual(@as(u8, 255), try parseUnsignedInt(u8, "255"));
}

test "parseFloat: scientific and decimal" {
    try testing.expectApproxEqAbs(@as(f64, 3.14), try parseFloat(f64, "3.14"), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1e6), try parseFloat(f64, "1e6"), 0.001);
    try testing.expectError(error.InvalidSyntax, parseFloat(f64, ""));
    try testing.expectError(error.InvalidSyntax, parseFloat(f64, "junk"));
}

test "renderNumError: pflag-style wording" {
    const gpa = testing.allocator;
    const a = try renderNumError(gpa, "ParseInt", "foo", .invalid_syntax);
    defer gpa.free(a);
    try testing.expectEqualStrings("strconv.ParseInt: parsing \"foo\": invalid syntax", a);

    const b = try renderNumError(gpa, "ParseUint", "999999999999", .value_out_of_range);
    defer gpa.free(b);
    try testing.expectEqualStrings("strconv.ParseUint: parsing \"999999999999\": value out of range", b);
}
