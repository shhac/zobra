//! Medium-priority coverage from Lens 5: traverse-mode hook chain,
//! disable_flag_parsing + args validator, underscore-divergence
//! regression pin.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const Command = zobra.Command;
const Diagnostic = zobra.Diagnostic;
const args_mod = zobra.args;
const coerce = zobra.flag.coerce;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

// ---- disable_flag_parsing + args validator -----------------------------

test "disable_flag_parsing + exactN(2) accepts 2 positionals" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "proxy",
        .disable_flag_parsing = true,
        .args = args_mod.exactN(2),
        .run_e = noopRun,
    });
    defer root.deinit();
    // With disable_flag_parsing, --flag and x both count as positionals.
    try root.execute(&.{ "--flag", "x" }, null);
}

test "disable_flag_parsing + exactN(2) rejects 1 positional" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "proxy",
        .disable_flag_parsing = true,
        .args = args_mod.exactN(2),
        .run_e = noopRun,
    });
    defer root.deinit();
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.ArgsValidationFailed, root.execute(&.{"--flag"}, &diag));
    try testing.expectEqualStrings("accepts 2 arg(s), received 1", diag.message.?);
}

// ---- underscore-divergence regression pin ------------------------------

test "regression: parseSignedInt accepts \"1_000\" (Zig std div from Go strconv)" {
    // Documented in design-docs/09-zobra-divergences.md § 3.5.
    // Zig's std.fmt.parseInt accepts `_` as a digit separator; Go's
    // strconv.ParseInt rejects it. zobra inherits Zig's behaviour.
    // If this test ever fails, a Zig std change has flipped the
    // behaviour and we need to revisit the divergence note.
    const v = try coerce.parseSignedInt(i64, "1_000");
    try testing.expectEqual(@as(i64, 1000), v);
}

test "regression: legacy leading-zero octal parses as octal (matches Go strconv)" {
    // Documented divergence path: zobra explicitly handles "0664" as
    // octal because Go's strconv.ParseInt(s, 0, ...) does. Zig std
    // alone would reject (requires `0o` prefix).
    const v = try coerce.parseSignedInt(i64, "0664");
    try testing.expectEqual(@as(i64, 0o664), v);
}

// ---- hook.zig direct unit tests ----------------------------------------
//
// FOLLOW-UP: hook.zig is comptime-generic over CommandT, but exercising
// it against a stub from the test module hits a "file exists in modules
// 'zobra' and 'root'" boundary because the test/ module reaches into
// src/core/ via a relative @import. Resolving requires either exposing
// hook.run via the public zobra surface, or putting the hook stub tests
// inline in src/core/command/hook.zig. Currently the dispatch is
// covered end-to-end by Command-level tests in test/command/command.zig
// (hook chain order, first-found-wins persistent ancestor).

// ---- traverse-mode hooks -----------------------------------------------
//
// hook.zig's traverse=true path is currently unused — Command.execute
// always passes false. The capability exists for cobra's
// EnableTraverseRunHooks toggle but no Command option wires it in yet.
// Marking as a deliberate gap, with a comment for the next person:
//
// FOLLOW-UP: when Command grows an `enable_traverse_run_hooks` option
// (or a per-command override), add tests asserting that with
// traverse=true, root.persistent_pre_run AND child.persistent_pre_run
// both fire (root first, child last), matching cobra's
// EnableTraverseRunHooks semantics in command.go:974-983.
