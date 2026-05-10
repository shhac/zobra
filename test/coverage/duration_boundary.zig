//! Duration boundary tests for Lens 5 finding #10 — the `-1<<63`
//! special-case in duration.zig:139, the most subtle integer-handling
//! line in the codebase. Plus the multi-component-overflow detection.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const duration = zobra.flag.duration;

test "duration: -1<<63 ns boundary (minimum i64) is representable" {
    const r = duration.parse("-9223372036854775808ns");
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), r.ok);
}

test "duration: maxInt(i64) ns is representable" {
    const r = duration.parse("9223372036854775807ns");
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), r.ok);
}

test "duration: 1 over maxInt(i64) overflows" {
    // 9223372036854775808 ns is one past max. leadingInt's inner
    // overflow check (x > 1<<63 / 10 then x*10 > 1<<63) fires, so the
    // parse returns invalid_duration before the unit is read.
    const r = duration.parse("9223372036854775808ns");
    try testing.expect(r == .err);
}

test "duration: multi-component sum overflow rejected" {
    // i64 max ~= 9.22e18 ns. 1h = 3.6e12 ns. 2_000_000h = 7.2e18 ns —
    // each individual component fits, but two of them sum to 1.44e19,
    // which overflows. The accumulator overflow check `d > max_int64_p1`
    // catches this between components.
    const r = duration.parse("2000000h2000000h");
    try testing.expect(r == .err);
}

test "duration: mixed-sign components" {
    // Go's time.ParseDuration handles only one leading sign; mixed
    // signs in components aren't valid.
    const r = duration.parse("1h-30m");
    try testing.expect(r == .err);
}

test "duration: fractional precision near unit edges" {
    // 0.5h = 30 minutes = 1800 seconds = 1.8e12 ns
    const r = duration.parse("0.5h");
    try testing.expectEqual(@as(i64, 1_800_000_000_000), r.ok);
}
