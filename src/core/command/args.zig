//! Args validators. Mirror cobra's PositionalArgs functions in args.go,
//! with snake_case constructor names under the `zobra.args` namespace
//! (per design-docs/02-cobra-mapping.md).
//!
//! Each validator is a value (a tagged-union variant) that the Command
//! holds in its `args` field. Combining is done via `match_all`, which
//! takes a slice of further validators.

const std = @import("std");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const fillDiag = @import("../diagnostic.zig").fill;
const errors = @import("../errors.zig");

pub const ArgsValidator = union(enum) {
    no_args,
    arbitrary,
    minimum_n: usize,
    maximum_n: usize,
    exact_n: usize,
    range: Range,
    /// Only the values listed in cmd.valid_args are accepted. cmd is
    /// borrowed only at validate time; nothing is captured here.
    only_valid,
    /// Combine multiple validators — runs each in order; first failure
    /// wins. Slice is borrowed; caller owns its storage.
    match_all: []const ArgsValidator,

    pub const Range = struct { min: usize, max: usize };

    /// Validate `args` against this rule. Fills diag with cobra-style
    /// wording on failure. `command_path` and `valid_args` are passed in
    /// (the validator itself is stateless) — cobra's wording for `noArgs`
    /// and `onlyValid` includes the command path:
    ///   `unknown command "X" for "tool greet"`
    ///   `invalid argument "X" for "tool greet"`
    /// When command_path is empty (e.g. unit test calling validate
    /// directly) we elide the `for "…"` clause.
    pub fn validate(
        self: ArgsValidator,
        valid_args: []const []const u8,
        args: []const []const u8,
        command_path: []const u8,
        allocator: std.mem.Allocator,
        diag: ?*Diagnostic,
    ) errors.CommandError!void {
        return switch (self) {
            .no_args => if (args.len > 0) failWithCmd(allocator, diag, "unknown command \"{s}\"", .{args[0]}, command_path),
            .arbitrary => {},
            .minimum_n => |n| if (args.len < n) failWith(
                allocator,
                diag,
                "requires at least {d} arg(s), only received {d}",
                .{ n, args.len },
            ),
            .maximum_n => |n| if (args.len > n) failWith(
                allocator,
                diag,
                "accepts at most {d} arg(s), received {d}",
                .{ n, args.len },
            ),
            .exact_n => |n| if (args.len != n) failWith(
                allocator,
                diag,
                "accepts {d} arg(s), received {d}",
                .{ n, args.len },
            ),
            .range => |r| if (args.len < r.min or args.len > r.max) failWith(
                allocator,
                diag,
                "accepts between {d} and {d} arg(s), received {d}",
                .{ r.min, r.max, args.len },
            ),
            .only_valid => for (args) |a| {
                if (!stringInSlice(a, valid_args)) {
                    if (diag) |d| d.valid_values = valid_args;
                    return failWithCmd(allocator, diag, "invalid argument \"{s}\"", .{a}, command_path);
                }
            },
            .match_all => |list| for (list) |v| {
                try v.validate(valid_args, args, command_path, allocator, diag);
            },
        };
    }
};

fn stringInSlice(s: []const u8, slice: []const []const u8) bool {
    for (slice) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

fn failWith(
    allocator: std.mem.Allocator,
    diag: ?*Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
) errors.CommandError {
    if (diag) |d| {
        d.category = .command;
        d.code = .args_validation_failed;
        const msg = std.fmt.allocPrint(allocator, fmt, args) catch return error.ArgsValidationFailed;
        d.setOwnedMessage(allocator, msg);
    }
    return error.ArgsValidationFailed;
}

fn failWithCmd(
    allocator: std.mem.Allocator,
    diag: ?*Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
    command_path: []const u8,
) errors.CommandError {
    if (diag) |d| {
        d.category = .command;
        d.code = .args_validation_failed;
        const base = std.fmt.allocPrint(allocator, fmt, args) catch return error.ArgsValidationFailed;
        defer allocator.free(base);
        const msg = if (command_path.len > 0)
            std.fmt.allocPrint(allocator, "{s} for \"{s}\"", .{ base, command_path }) catch return error.ArgsValidationFailed
        else
            allocator.dupe(u8, base) catch return error.ArgsValidationFailed;
        d.setOwnedMessage(allocator, msg);
    }
    return error.ArgsValidationFailed;
}

// ---- ergonomic constructors --------------------------------------------

pub const noArgs: ArgsValidator = .no_args;
pub const arbitrary: ArgsValidator = .arbitrary;
pub const onlyValid: ArgsValidator = .only_valid;

pub fn minimumN(n: usize) ArgsValidator {
    return .{ .minimum_n = n };
}
pub fn maximumN(n: usize) ArgsValidator {
    return .{ .maximum_n = n };
}
pub fn exactN(n: usize) ArgsValidator {
    return .{ .exact_n = n };
}
pub fn range(min: usize, max: usize) ArgsValidator {
    return .{ .range = .{ .min = min, .max = max } };
}
pub fn matchAll(list: []const ArgsValidator) ArgsValidator {
    return .{ .match_all = list };
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

fn validate(v: ArgsValidator, valid: []const []const u8, args: []const []const u8) !struct { msg: ?[]const u8, gpa: std.mem.Allocator } {
    const gpa = testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    v.validate(valid, args, "", gpa, &diag) catch {
        // Move ownership of diag.message to the caller for inspection.
        const m = diag.message;
        diag.message = null;
        diag.owns_message = false;
        return .{ .msg = m, .gpa = gpa };
    };
    return .{ .msg = null, .gpa = gpa };
}

test "noArgs: empty ok, non-empty rejected" {
    const r1 = try validate(noArgs, &.{}, &.{});
    try testing.expect(r1.msg == null);
    const r2 = try validate(noArgs, &.{}, &.{"extra"});
    defer if (r2.msg) |m| r2.gpa.free(m);
    try testing.expectEqualStrings("unknown command \"extra\"", r2.msg.?);
}

test "minimumN: exact and over ok, under fails" {
    const v = minimumN(2);
    const ok1 = try validate(v, &.{}, &.{ "a", "b" });
    try testing.expect(ok1.msg == null);
    const ok2 = try validate(v, &.{}, &.{ "a", "b", "c" });
    try testing.expect(ok2.msg == null);
    const fail = try validate(v, &.{}, &.{"a"});
    defer if (fail.msg) |m| fail.gpa.free(m);
    try testing.expectEqualStrings("requires at least 2 arg(s), only received 1", fail.msg.?);
}

test "maximumN: under and exact ok, over fails" {
    const v = maximumN(1);
    const ok = try validate(v, &.{}, &.{"a"});
    try testing.expect(ok.msg == null);
    const fail = try validate(v, &.{}, &.{ "a", "b" });
    defer if (fail.msg) |m| fail.gpa.free(m);
    try testing.expectEqualStrings("accepts at most 1 arg(s), received 2", fail.msg.?);
}

test "exactN: exactly N" {
    const v = exactN(2);
    const fail1 = try validate(v, &.{}, &.{"a"});
    defer if (fail1.msg) |m| fail1.gpa.free(m);
    try testing.expectEqualStrings("accepts 2 arg(s), received 1", fail1.msg.?);

    const ok = try validate(v, &.{}, &.{ "a", "b" });
    try testing.expect(ok.msg == null);

    const fail2 = try validate(v, &.{}, &.{ "a", "b", "c" });
    defer if (fail2.msg) |m| fail2.gpa.free(m);
    try testing.expectEqualStrings("accepts 2 arg(s), received 3", fail2.msg.?);
}

test "range: bounds inclusive" {
    const v = range(1, 3);
    const ok = try validate(v, &.{}, &.{ "a", "b" });
    try testing.expect(ok.msg == null);
    const fail = try validate(v, &.{}, &.{});
    defer if (fail.msg) |m| fail.gpa.free(m);
    try testing.expectEqualStrings("accepts between 1 and 3 arg(s), received 0", fail.msg.?);
}

test "onlyValid: rejects values not in cmd.valid_args" {
    const valid: []const []const u8 = &.{ "alpha", "beta" };
    const ok = try validate(onlyValid, valid, &.{ "alpha", "beta" });
    try testing.expect(ok.msg == null);
    const fail = try validate(onlyValid, valid, &.{"gamma"});
    defer if (fail.msg) |m| fail.gpa.free(m);
    try testing.expectEqualStrings("invalid argument \"gamma\"", fail.msg.?);
}

test "matchAll: chains until first failure" {
    const inner = [_]ArgsValidator{ minimumN(1), onlyValid };
    const v = matchAll(&inner);
    const valid: []const []const u8 = &.{ "alpha", "beta" };

    const ok = try validate(v, valid, &.{"alpha"});
    try testing.expect(ok.msg == null);

    // Fails on minimumN.
    const fail1 = try validate(v, valid, &.{});
    defer if (fail1.msg) |m| fail1.gpa.free(m);
    try testing.expectEqualStrings("requires at least 1 arg(s), only received 0", fail1.msg.?);

    // Fails on onlyValid.
    const fail2 = try validate(v, valid, &.{"gamma"});
    defer if (fail2.msg) |m| fail2.gpa.free(m);
    try testing.expectEqualStrings("invalid argument \"gamma\"", fail2.msg.?);
}
