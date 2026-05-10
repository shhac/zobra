//! Flag-group validation — required-together, one-required, mutex.
//!
//! Each Command stores group memberships (`required_together_groups`,
//! `one_required_groups`, `mutex_groups`) as `[][]const u8`. This module
//! evaluates those memberships against the command's own + inherited
//! flag state and renders cobra-byte-identical violation messages onto
//! the optional Diagnostic.
//!
//! Source of truth: cobra's `command.go::ValidateFlagGroups` plus the
//! `validateRequiredFlagGroups` / `validateOneRequiredFlagGroups` /
//! `validateExclusiveFlagGroups` helpers in flag_groups.go.

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const command_mod = @import("command.zig");
const Allocator = std.mem.Allocator;

const Command = command_mod.Command;

/// Validate all three flag-group constraints on `cmd`. Returns the
/// first violation; later groups aren't checked (matches cobra).
pub fn validate(cmd: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
    try validateRequiredTogether(cmd, diag);
    try validateOneRequired(cmd, diag);
    try validateMutex(cmd, diag);
}

fn flagChanged(cmd: *const Command, name: []const u8) bool {
    const f = cmd.lookupLong(name) orelse return false;
    return f.changed;
}

fn validateRequiredTogether(cmd: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
    for (cmd.required_together_groups.items) |group| {
        var unset: std.ArrayListUnmanaged([]const u8) = .empty;
        defer unset.deinit(cmd.allocator);
        var set_count: usize = 0;
        for (group) |name| {
            if (flagChanged(cmd, name)) {
                set_count += 1;
            } else {
                unset.append(cmd.allocator, name) catch return error.FlagGroupViolation;
            }
        }
        if (set_count == 0 or unset.items.len == 0) continue;
        return failGroup(
            cmd.allocator,
            diag,
            "if any flags in the group [{group}] are set they must all be set; missing [{names}]",
            group,
            unset.items,
        );
    }
}

fn validateOneRequired(cmd: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
    for (cmd.one_required_groups.items) |group| {
        var any_set = false;
        for (group) |name| if (flagChanged(cmd, name)) {
            any_set = true;
            break;
        };
        if (any_set) continue;
        return failGroup(
            cmd.allocator,
            diag,
            "at least one of the flags in the group [{group}] is required",
            group,
            &.{},
        );
    }
}

fn validateMutex(cmd: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
    for (cmd.mutex_groups.items) |group| {
        var set: std.ArrayListUnmanaged([]const u8) = .empty;
        defer set.deinit(cmd.allocator);
        for (group) |name| if (flagChanged(cmd, name)) {
            set.append(cmd.allocator, name) catch return error.FlagGroupViolation;
        };
        if (set.items.len <= 1) continue;
        return failGroup(
            cmd.allocator,
            diag,
            "if any flags in the group [{group}] are set none of the others can be; [{names}] were all set",
            group,
            set.items,
        );
    }
}

fn failGroup(
    allocator: Allocator,
    diag: ?*Diagnostic,
    template: []const u8,
    group: []const []const u8,
    names: []const []const u8,
) errors.FlagError {
    const group_str = joinSpaceSeparated(allocator, group) catch return error.FlagGroupViolation;
    defer allocator.free(group_str);
    const names_str = joinSpaceSeparated(allocator, names) catch return error.FlagGroupViolation;
    defer allocator.free(names_str);

    const rendered = renderTemplate(allocator, template, group_str, names_str) catch return error.FlagGroupViolation;

    if (diag) |d| {
        d.category = .flag;
        d.code = .flag_group_violation;
        d.setOwnedMessage(allocator, rendered);
    } else {
        allocator.free(rendered);
    }
    return error.FlagGroupViolation;
}

fn joinSpaceSeparated(allocator: Allocator, names: []const []const u8) ![]u8 {
    if (names.len == 0) return allocator.dupe(u8, "");

    const sorted = try allocator.dupe([]const u8, names);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    for (sorted, 0..) |n, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(n);
    }
    return aw.toOwnedSlice();
}

fn renderTemplate(allocator: Allocator, template: []const u8, group: []const u8, names: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    var i: usize = 0;
    while (i < template.len) {
        if (i + 7 <= template.len and std.mem.eql(u8, template[i .. i + 7], "{group}")) {
            try w.writeAll(group);
            i += 7;
        } else if (i + 7 <= template.len and std.mem.eql(u8, template[i .. i + 7], "{names}")) {
            try w.writeAll(names);
            i += 7;
        } else {
            try w.writeByte(template[i]);
            i += 1;
        }
    }
    return aw.toOwnedSlice();
}
