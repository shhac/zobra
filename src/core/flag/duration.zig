//! Go time.ParseDuration parity. Source: src/time/format.go in Go 1.26.
//!
//! Format: optional sign, then one or more (numeric, optional fraction,
//! unit) groups. Units: ns, us, µs, μs, ms, s, m, h. Special case: "0" alone
//! is the zero duration. Returns nanoseconds as i64 (same wire width as
//! Go's time.Duration).
//!
//! The three error wordings produced — verbatim with Go:
//!   time: invalid duration "X"
//!   time: missing unit in duration "X"
//!   time: unknown unit "U" in duration "X"
//! Caller frees the returned message slice with the same allocator.

const std = @import("std");

pub const ParseError = error{InvalidDuration};

pub const Result = union(enum) {
    ok: i64,
    err: Err,

    pub const Err = struct {
        kind: Kind,
        unit: ?[]const u8 = null,

        pub const Kind = enum {
            invalid_duration,
            missing_unit,
            unknown_unit,
        };
    };
};

const Nanosecond: u64 = 1;
const Microsecond: u64 = 1000 * Nanosecond;
const Millisecond: u64 = 1000 * Microsecond;
const Second: u64 = 1000 * Millisecond;
const Minute: u64 = 60 * Second;
const Hour: u64 = 60 * Minute;

const max_int64_p1: u64 = 1 << 63;

fn unitFor(u: []const u8) ?u64 {
    if (std.mem.eql(u8, u, "ns")) return Nanosecond;
    if (std.mem.eql(u8, u, "us")) return Microsecond;
    if (std.mem.eql(u8, u, "µs")) return Microsecond; // U+00B5
    if (std.mem.eql(u8, u, "μs")) return Microsecond; // U+03BC
    if (std.mem.eql(u8, u, "ms")) return Millisecond;
    if (std.mem.eql(u8, u, "s")) return Second;
    if (std.mem.eql(u8, u, "m")) return Minute;
    if (std.mem.eql(u8, u, "h")) return Hour;
    return null;
}

/// Parse a Go-style duration. Returns either the ok value (nanoseconds, may
/// be negative) or a structured Err describing which wording to render.
pub fn parse(s_in: []const u8) Result {
    var s = s_in;
    var neg = false;

    // Consume [-+]?
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }

    // Special case: "0" alone.
    if (std.mem.eql(u8, s, "0")) return .{ .ok = 0 };
    if (s.len == 0) return .{ .err = .{ .kind = .invalid_duration } };

    var d: u64 = 0;

    while (s.len > 0) {
        // Next char must be '.' or [0-9].
        if (!(s[0] == '.' or (s[0] >= '0' and s[0] <= '9'))) {
            return .{ .err = .{ .kind = .invalid_duration } };
        }

        // Consume integer part.
        const before_int = s.len;
        const li = leadingInt(s) orelse return .{ .err = .{ .kind = .invalid_duration } };
        var v = li.value;
        s = li.rest;
        const had_int = before_int != s.len;

        // Consume optional fraction.
        var f: u64 = 0;
        var scale: f64 = 1;
        var had_frac = false;
        if (s.len > 0 and s[0] == '.') {
            s = s[1..];
            const before_frac = s.len;
            const lf = leadingFraction(s);
            f = lf.value;
            scale = lf.scale;
            s = lf.rest;
            had_frac = before_frac != s.len;
        }

        if (!had_int and !had_frac) {
            return .{ .err = .{ .kind = .invalid_duration } };
        }

        // Consume unit (longest run of non-digit, non-dot bytes).
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '.' or (c >= '0' and c <= '9')) break;
        }
        if (i == 0) return .{ .err = .{ .kind = .missing_unit } };

        const u = s[0..i];
        s = s[i..];
        const unit = unitFor(u) orelse return .{ .err = .{ .kind = .unknown_unit, .unit = u } };

        // Multiply v by unit, with overflow detection (Go uses 1<<63/unit).
        if (v > max_int64_p1 / unit) {
            return .{ .err = .{ .kind = .invalid_duration } };
        }
        v *= unit;

        if (f > 0) {
            // f*unit/scale is bounded by max-unit (h = 3.6e12 ns), so float
            // is precise enough.
            v +%= @intFromFloat(@as(f64, @floatFromInt(f)) * (@as(f64, @floatFromInt(unit)) / scale));
            if (v > max_int64_p1) {
                return .{ .err = .{ .kind = .invalid_duration } };
            }
        }

        d +%= v;
        if (d > max_int64_p1) {
            return .{ .err = .{ .kind = .invalid_duration } };
        }
    }

    if (neg) {
        // -1<<63 is representable but we have d as u64 so cast carefully.
        if (d == max_int64_p1) return .{ .ok = std.math.minInt(i64) };
        return .{ .ok = -@as(i64, @intCast(d)) };
    }
    if (d > std.math.maxInt(i64)) return .{ .err = .{ .kind = .invalid_duration } };
    return .{ .ok = @intCast(d) };
}

const LeadingInt = struct { value: u64, rest: []const u8 };
const LeadingFraction = struct { value: u64, scale: f64, rest: []const u8 };

fn leadingInt(s: []const u8) ?LeadingInt {
    var x: u64 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') break;
        if (x > max_int64_p1 / 10) return null;
        x = x * 10 + (c - '0');
        if (x > max_int64_p1) return null;
    }
    return .{ .value = x, .rest = s[i..] };
}

fn leadingFraction(s: []const u8) LeadingFraction {
    var x: u64 = 0;
    var scale: f64 = 1;
    var overflow = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') break;
        if (overflow) continue;
        if (x > std.math.maxInt(u64) / 10) {
            overflow = true;
            continue;
        }
        const y = x * 10 + (c - '0');
        if (y > max_int64_p1) {
            overflow = true;
            continue;
        }
        x = y;
        scale *= 10;
    }
    return .{ .value = x, .scale = scale, .rest = s[i..] };
}

/// Render the time-package error wording. Caller owns the returned slice.
pub fn renderError(allocator: std.mem.Allocator, err: Result.Err, original: []const u8) ![]u8 {
    return switch (err.kind) {
        .invalid_duration => std.fmt.allocPrint(
            allocator,
            "time: invalid duration \"{s}\"",
            .{original},
        ),
        .missing_unit => std.fmt.allocPrint(
            allocator,
            "time: missing unit in duration \"{s}\"",
            .{original},
        ),
        .unknown_unit => std.fmt.allocPrint(
            allocator,
            "time: unknown unit \"{s}\" in duration \"{s}\"",
            .{ err.unit.?, original },
        ),
    };
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

test "parse: zero forms" {
    try testing.expectEqual(@as(i64, 0), parse("0").ok);
    try testing.expectEqual(@as(i64, 0), parse("0s").ok);
    try testing.expectEqual(@as(i64, 0), parse("-0").ok);
}

test "parse: simple units" {
    try testing.expectEqual(@as(i64, 300_000_000), parse("300ms").ok);
    try testing.expectEqual(@as(i64, 5_000_000_000), parse("5s").ok);
    try testing.expectEqual(@as(i64, 60_000_000_000), parse("1m").ok);
    try testing.expectEqual(@as(i64, 3_600_000_000_000), parse("1h").ok);
    try testing.expectEqual(@as(i64, 1_500), parse("1500ns").ok);
    try testing.expectEqual(@as(i64, 1_000), parse("1us").ok);
    try testing.expectEqual(@as(i64, 1_000), parse("1µs").ok);
    try testing.expectEqual(@as(i64, 1_000), parse("1μs").ok);
}

test "parse: multi-component" {
    // 2h45m = 2*3600s + 45*60s = 9900s = 9.9e12 ns
    try testing.expectEqual(@as(i64, 9_900_000_000_000), parse("2h45m").ok);
    // 1h30m45s
    const expected = 1 * 3600 + 30 * 60 + 45;
    try testing.expectEqual(@as(i64, expected * 1_000_000_000), parse("1h30m45s").ok);
}

test "parse: fractions" {
    try testing.expectEqual(@as(i64, 1_500_000_000), parse("1.5s").ok);
    // 1.5h = 1.5 * 3600 * 1e9 ns = 5400 * 1e9 ns
    try testing.expectEqual(@as(i64, 5_400_000_000_000), parse("1.5h").ok);
    try testing.expectEqual(@as(i64, 500_000_000), parse(".5s").ok);
}

test "parse: negative" {
    try testing.expectEqual(@as(i64, -30_000_000_000), parse("-30s").ok);
    try testing.expectEqual(@as(i64, -300_000_000), parse("-300ms").ok);
}

test "parse: invalid forms" {
    try testing.expect(parse("").err.kind == .invalid_duration);
    try testing.expect(parse("foo").err.kind == .invalid_duration);
    try testing.expect(parse(".").err.kind == .invalid_duration);
    try testing.expect(parse(".s").err.kind == .invalid_duration);
}

test "parse: missing unit" {
    try testing.expect(parse("5").err.kind == .missing_unit);
    try testing.expect(parse("5.5").err.kind == .missing_unit);
}

test "parse: unknown unit" {
    const r = parse("5x");
    try testing.expect(r.err.kind == .unknown_unit);
    try testing.expectEqualStrings("x", r.err.unit.?);
}

test "renderError: produces verbatim Go time-package wording" {
    const gpa = testing.allocator;

    const inv = try renderError(gpa, .{ .kind = .invalid_duration }, "junk");
    defer gpa.free(inv);
    try testing.expectEqualStrings("time: invalid duration \"junk\"", inv);

    const miss = try renderError(gpa, .{ .kind = .missing_unit }, "5");
    defer gpa.free(miss);
    try testing.expectEqualStrings("time: missing unit in duration \"5\"", miss);

    const unk = try renderError(gpa, .{ .kind = .unknown_unit, .unit = "x" }, "5x");
    defer gpa.free(unk);
    try testing.expectEqualStrings("time: unknown unit \"x\" in duration \"5x\"", unk);
}
