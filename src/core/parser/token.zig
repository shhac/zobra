//! Token alphabet emitted by the parser. See design-docs/04-parser.md.
//!
//! There is intentionally no `short_group` kind — pflag processes each
//! shorthand char independently, so we mirror that and emit one `short`
//! token per char, each carrying the original `raw` argv element so error
//! wording can cite the full group (e.g. `-abc`).

const std = @import("std");

pub const Token = union(enum) {
    long: Long,
    short: Short,
    negated: Negated,
    positional: Positional,
    terminator,
    passthrough: []const u8,

    pub const Long = struct {
        /// Flag name without the leading `--`. Borrowed from argv.
        name: []const u8,
        /// Attached value (`--foo=bar` → "bar", `--foo=` → "") or the next
        /// argv element consumed because the flag is value-taking. Null when
        /// the flag was standalone and either not value-taking or missing
        /// its value (the flag layer raises MissingValue in the latter
        /// case using `raw` for wording).
        value: ?[]const u8,
        /// Original argv element. Borrowed from argv.
        raw: []const u8,
    };

    pub const Short = struct {
        /// Single-character shorthand.
        name: u8,
        /// Attached value (`-fbar`, `-f=bar`, `-f bar`) or null for
        /// standalone non-value-taking shorts (boolean / count).
        value: ?[]const u8,
        /// Original argv element ("-fbar", "-abc"). Borrowed from argv.
        raw: []const u8,
    };

    pub const Negated = struct {
        /// Name with the `no-` prefix already stripped (so `--no-debug`
        /// becomes `name = "debug"`). Borrowed from argv.
        name: []const u8,
        raw: []const u8,
    };

    pub const Positional = struct {
        value: []const u8,
    };
};

test "Token: long with attached value" {
    const t: Token = .{ .long = .{ .name = "foo", .value = "bar", .raw = "--foo=bar" } };
    try std.testing.expectEqualStrings("foo", t.long.name);
    try std.testing.expectEqualStrings("bar", t.long.value.?);
}

test "Token: long standalone has null value" {
    const t: Token = .{ .long = .{ .name = "foo", .value = null, .raw = "--foo" } };
    try std.testing.expect(t.long.value == null);
}

test "Token: short carries the source group as raw" {
    const t: Token = .{ .short = .{ .name = 'b', .value = null, .raw = "-abc" } };
    try std.testing.expectEqual(@as(u8, 'b'), t.short.name);
    try std.testing.expectEqualStrings("-abc", t.short.raw);
}

test "Token: negated strips the no- prefix" {
    const t: Token = .{ .negated = .{ .name = "debug", .raw = "--no-debug" } };
    try std.testing.expectEqualStrings("debug", t.negated.name);
}

test "Token: terminator is a payload-less tag" {
    const t: Token = .terminator;
    try std.testing.expect(t == .terminator);
}

test "Token: passthrough carries the raw value" {
    const t: Token = .{ .passthrough = "after-dashdash" };
    switch (t) {
        .passthrough => |v| try std.testing.expectEqualStrings("after-dashdash", v),
        else => unreachable,
    }
}
