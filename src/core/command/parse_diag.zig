//! Parse-error wording: pflag-byte-identical rendering for the
//! parse-layer error codes. Lives in the command layer so the
//! parser/flag layers stay layering-clean — they write only structured
//! fields (`flag_name`, `raw`, `short_group`, `code`) to the Diagnostic,
//! and this helper composes the human-readable string on the way out.
//!
//! Source of truth: pflag's flag.go::parseLongArg / parseSingleShortArg
//! error wording (errors.go for the format strings).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// Reset the parse-layer fields on a Diagnostic. Used by
/// `allow_unknown_flags`: the apply layer filled the diagnostic before
/// raising UnknownFlag; the swallow path needs to clear it so a
/// downstream check (validateRequiredFlags, etc.) doesn't see stale
/// state.
pub fn swallow(diag: ?*Diagnostic) void {
    if (diag) |d| {
        d.category = null;
        d.code = null;
        d.flag_name = null;
        d.raw = null;
        d.short_group = null;
    }
}

/// Render pflag-byte-identical wording for parse-layer errors.
///
/// Wordings (matching pflag):
///   unknown flag: --foo
///   unknown shorthand flag: "X" in -group
///   flag needs an argument: --foo
///   flag needs an argument: "X" in -group
///   bad flag syntax: <full argv element>
pub fn render(allocator: Allocator, diag: *Diagnostic) !void {
    if (diag.message != null) return;
    const code = diag.code orelse return;
    const rendered: []u8 = switch (code) {
        .unknown_flag => blk: {
            const name = diag.flag_name orelse return;
            if (diag.short_group) |group| {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "unknown shorthand flag: \"{s}\" in -{s}",
                    .{ name, group },
                );
            }
            break :blk try std.fmt.allocPrint(allocator, "unknown flag: --{s}", .{name});
        },
        .missing_value => blk: {
            const name = diag.flag_name orelse return;
            if (diag.short_group) |group| {
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "flag needs an argument: \"{s}\" in -{s}",
                    .{ name, group },
                );
            }
            break :blk try std.fmt.allocPrint(allocator, "flag needs an argument: --{s}", .{name});
        },
        .bad_flag_syntax => blk: {
            const raw = diag.raw orelse return;
            break :blk try std.fmt.allocPrint(allocator, "bad flag syntax: {s}", .{raw});
        },
        else => return,
    };
    diag.setOwnedMessage(allocator, rendered);
}
