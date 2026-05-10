//! Type-coercion and storage-binding helpers for FlagSet.
//!
//! `flag.zig` owns the FlagSet struct, registration (`*VarP`), lookup,
//! and the apply loop. The actual "parse a token's value and write it
//! into the user's `*T` storage" logic lives here — one bind function
//! per flag type, the central `setStored` dispatch that picks the right
//! one, and the cobra/pflag-byte-identical error renderer (`failCoerce`).
//!
//! Source of truth: pflag's `*Value` types. Each `bind*` mirrors a
//! single `Set` method (e.g. `bindIp` ↔ `pflag.ipValue.Set`).

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const coerce = @import("coerce.zig");
const duration = @import("duration.zig");

const flag_mod = @import("flag.zig");
const Flag = flag_mod.Flag;

/// Dispatch by `flag.value_type` to the matching `bind*` function.
/// Called by `FlagSet.set` and the parser apply path.
pub fn setStored(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    return switch (flag.value_type) {
        .string => {
            const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
            p.* = value;
        },
        .bool => {
            const b = coerce.parseBool(value) catch return failCoerce(allocator, flag, value, diag, "ParseBool", .invalid_syntax);
            const p: *bool = @ptrCast(@alignCast(flag.value_ptr));
            p.* = b;
        },
        .int => bindSignedInt(allocator, i64, flag, value, diag, "ParseInt"),
        .int8 => bindSignedInt(allocator, i8, flag, value, diag, "ParseInt"),
        .int16 => bindSignedInt(allocator, i16, flag, value, diag, "ParseInt"),
        .int32 => bindSignedInt(allocator, i32, flag, value, diag, "ParseInt"),
        .int64 => bindSignedInt(allocator, i64, flag, value, diag, "ParseInt"),
        .uint => bindUnsignedInt(allocator, u64, flag, value, diag, "ParseUint"),
        .uint8 => bindUnsignedInt(allocator, u8, flag, value, diag, "ParseUint"),
        .uint16 => bindUnsignedInt(allocator, u16, flag, value, diag, "ParseUint"),
        .uint32 => bindUnsignedInt(allocator, u32, flag, value, diag, "ParseUint"),
        .uint64 => bindUnsignedInt(allocator, u64, flag, value, diag, "ParseUint"),
        .float32 => bindFloat(allocator, f32, flag, value, diag),
        .float64 => bindFloat(allocator, f64, flag, value, diag),
        .count => bindCount(allocator, flag, value, diag),
        .duration => bindDuration(allocator, flag, value, diag),
        .string_slice => bindStringSlice(allocator, flag, value, diag),
        .string_array => bindStringArray(allocator, flag, value, diag),
        .int_slice => bindIntSlice(allocator, flag, value, diag),
        .int32_slice => bindNumericSlice(allocator, i32, flag, value, diag, .signed, "Atoi"),
        .int64_slice => bindNumericSlice(allocator, i64, flag, value, diag, .signed, "ParseInt"),
        .float32_slice => bindNumericSlice(allocator, f32, flag, value, diag, .float, "ParseFloat"),
        .float64_slice => bindNumericSlice(allocator, f64, flag, value, diag, .float, "ParseFloat"),
        .bool_slice => bindBoolSlice(allocator, flag, value, diag),
        .duration_slice => bindDurationSlice(allocator, flag, value, diag),
        .string_to_string => bindStringToString(allocator, flag, value, diag),
        .string_to_int => bindStringToInt(allocator, i32, flag, value, diag, "ParseInt"),
        .string_to_int64 => bindStringToInt(allocator, i64, flag, value, diag, "ParseInt"),
        .ip => bindIp(allocator, flag, value, diag),
        .ip_mask => bindIpMask(allocator, flag, value, diag),
        .ip_net => bindIpNet(allocator, flag, value, diag),
        .bytes_hex => bindBytesHex(allocator, flag, value, diag),
        .bytes_base64 => bindBytesBase64(allocator, flag, value, diag),
        .custom => bindCustom(allocator, flag, value, diag),
    };
}

fn bindCustom(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) errors.FlagError!void {
    const cf = flag.custom orelse return error.TypeCoercionFailed;
    cf.set_fn(cf.ptr, value) catch {
        const cause = std.fmt.allocPrint(allocator, "invalid value for {s}: {s}", .{ cf.type_name, value }) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
}

fn bindIp(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    _ = std.Io.net.IpAddress.parse(value, 0) catch {
        const cause = std.fmt.allocPrint(allocator, "invalid IP address: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
    p.* = value;
}

fn bindIpMask(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    const valid_len = value.len == 8 or value.len == 32;
    var all_hex = true;
    for (value) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_hex) {
            all_hex = false;
            break;
        }
    }
    if (!(valid_len and all_hex)) {
        const cause = std.fmt.allocPrint(allocator, "invalid IP mask: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    }
    const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
    p.* = value;
}

fn bindIpNet(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse {
        const cause = std.fmt.allocPrint(allocator, "invalid CIDR address: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    const ip_part = value[0..slash];
    const prefix_part = value[slash + 1 ..];
    _ = std.Io.net.IpAddress.parse(ip_part, 0) catch {
        const cause = std.fmt.allocPrint(allocator, "invalid CIDR address: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    _ = std.fmt.parseInt(u8, prefix_part, 10) catch {
        const cause = std.fmt.allocPrint(allocator, "invalid CIDR address: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
    p.* = value;
}

fn bindBytesHex(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    if (value.len % 2 != 0) {
        const cause = std.fmt.allocPrint(allocator, "encoding/hex: odd length hex string", .{}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    }
    const out = try allocator.alloc(u8, value.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, value) catch {
        const cause = std.fmt.allocPrint(allocator, "encoding/hex: invalid byte: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
    if (flag.owns_value_storage) allocator.free(p.*);
    p.* = out;
}

fn bindBytesBase64(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(value) catch {
        const cause = std.fmt.allocPrint(allocator, "illegal base64 data: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    const out = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(out);
    decoder.decode(out, value) catch {
        const cause = std.fmt.allocPrint(allocator, "illegal base64 data: {s}", .{value}) catch return error.TypeCoercionFailed;
        defer allocator.free(cause);
        return failCoerceWithRendered(allocator, flag, value, diag, cause);
    };
    const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
    if (flag.owns_value_storage) allocator.free(p.*);
    p.* = out;
}

fn bindStringToString(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    _ = diag;
    const map: *std.StringHashMapUnmanaged([]const u8) = @ptrCast(@alignCast(flag.value_ptr));
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse {
            return error.TypeCoercionFailed;
        };
        try map.put(allocator, item[0..eq], item[eq + 1 ..]);
    }
}

fn bindStringToInt(
    allocator: std.mem.Allocator,
    comptime T: type,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
    comptime func_name: []const u8,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    const map: *std.StringHashMapUnmanaged(T) = @ptrCast(@alignCast(flag.value_ptr));
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |item| {
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse {
            return error.TypeCoercionFailed;
        };
        const key = item[0..eq];
        const raw_val = item[eq + 1 ..];
        const n = coerce.parseSignedInt(T, raw_val) catch |err| {
            return failCoerce(allocator, flag, raw_val, diag, func_name, coerce.intCause(err));
        };
        try map.put(allocator, key, n);
    }
}

pub fn freeMapStorage(allocator: std.mem.Allocator, flag: *Flag) void {
    switch (flag.value_type) {
        .string_to_string => {
            const m: *std.StringHashMapUnmanaged([]const u8) = @ptrCast(@alignCast(flag.value_ptr));
            m.deinit(allocator);
        },
        .string_to_int => {
            const m: *std.StringHashMapUnmanaged(i32) = @ptrCast(@alignCast(flag.value_ptr));
            m.deinit(allocator);
        },
        .string_to_int64 => {
            const m: *std.StringHashMapUnmanaged(i64) = @ptrCast(@alignCast(flag.value_ptr));
            m.deinit(allocator);
        },
        else => {},
    }
}

const SliceParseKind = enum { signed, float };

fn bindNumericSlice(
    allocator: std.mem.Allocator,
    comptime T: type,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
    comptime kind: SliceParseKind,
    comptime func_name: []const u8,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    var pieces: std.ArrayListUnmanaged(T) = .empty;
    defer pieces.deinit(allocator);

    const ptr: *[]const T = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    if (flag.changed) try pieces.appendSlice(allocator, old);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |s| {
        const n: T = switch (kind) {
            .signed => coerce.parseSignedInt(T, s) catch |err| {
                return failCoerce(allocator, flag, s, diag, func_name, coerce.intCause(err));
            },
            .float => coerce.parseFloat(T, s) catch |err| {
                return failCoerce(allocator, flag, s, diag, func_name, coerce.floatCause(err));
            },
        };
        try pieces.append(allocator, n);
    }

    const owned = try pieces.toOwnedSlice(allocator);
    if (flag.owns_value_storage) allocator.free(old);
    ptr.* = owned;
}

fn bindBoolSlice(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    var pieces: std.ArrayListUnmanaged(bool) = .empty;
    defer pieces.deinit(allocator);

    const ptr: *[]const bool = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    if (flag.changed) try pieces.appendSlice(allocator, old);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |s| {
        const b = coerce.parseBool(s) catch return failCoerce(allocator, flag, s, diag, "ParseBool", .invalid_syntax);
        try pieces.append(allocator, b);
    }

    const owned = try pieces.toOwnedSlice(allocator);
    if (flag.owns_value_storage) allocator.free(old);
    ptr.* = owned;
}

fn bindDurationSlice(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    var pieces: std.ArrayListUnmanaged(i64) = .empty;
    defer pieces.deinit(allocator);

    const ptr: *[]const i64 = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    if (flag.changed) try pieces.appendSlice(allocator, old);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |s| {
        const r = duration.parse(s);
        switch (r) {
            .ok => |ns| try pieces.append(allocator, ns),
            .err => |e| {
                const msg = duration.renderError(allocator, e, s) catch return error.TypeCoercionFailed;
                defer allocator.free(msg);
                return failCoerceWithRendered(allocator, flag, s, diag, msg);
            },
        }
    }

    const owned = try pieces.toOwnedSlice(allocator);
    if (flag.owns_value_storage) allocator.free(old);
    ptr.* = owned;
}

fn bindStringSlice(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    _ = diag;
    const ptr: *[]const []const u8 = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    var pieces: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pieces.deinit(allocator);

    if (flag.changed) {
        try pieces.appendSlice(allocator, old);
    }

    if (value.len > 0) {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |s| try pieces.append(allocator, s);
    }

    const owned = try pieces.toOwnedSlice(allocator);
    if (flag.owns_value_storage) allocator.free(old);
    ptr.* = owned;
}

fn bindStringArray(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    _ = diag;
    const ptr: *[]const []const u8 = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    const new_len = if (flag.changed) old.len + 1 else 1;
    const owned = try allocator.alloc([]const u8, new_len);
    if (flag.changed) {
        std.mem.copyForwards([]const u8, owned[0..old.len], old);
        owned[old.len] = value;
    } else {
        owned[0] = value;
    }
    if (flag.owns_value_storage) allocator.free(old);
    ptr.* = owned;
}

fn bindIntSlice(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) (errors.FlagError || std.mem.Allocator.Error)!void {
    // pflag's intSlice uses Atoi (decimal only). We reuse parseSignedInt
    // with i64 — which accepts hex/octal/binary too, a documented
    // divergence (see design-docs/09-zobra-divergences.md § 3.5).
    var pieces: std.ArrayListUnmanaged(i64) = .empty;
    defer pieces.deinit(allocator);

    const ptr: *[]const i64 = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    if (flag.changed) try pieces.appendSlice(allocator, old);

    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |s| {
        const n = coerce.parseSignedInt(i64, s) catch |err| {
            return failCoerce(allocator, flag, s, diag, "Atoi", coerce.intCause(err));
        };
        try pieces.append(allocator, n);
    }

    const owned = try pieces.toOwnedSlice(allocator);
    if (flag.owns_value_storage) allocator.free(old);
    ptr.* = owned;
}

pub fn freeSliceStorage(allocator: std.mem.Allocator, flag: *Flag) void {
    switch (flag.value_type) {
        .string_slice, .string_array => {
            const p: *[]const []const u8 = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        .int_slice, .int64_slice, .duration_slice => {
            const p: *[]const i64 = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        .int32_slice => {
            const p: *[]const i32 = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        .float32_slice => {
            const p: *[]const f32 = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        .float64_slice => {
            const p: *[]const f64 = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        .bool_slice => {
            const p: *[]const bool = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        .bytes_hex, .bytes_base64 => {
            const p: *[]const u8 = @ptrCast(@alignCast(flag.value_ptr));
            allocator.free(p.*);
        },
        else => {},
    }
}

pub fn renderSliceDefault(comptime Elem: type, allocator: std.mem.Allocator, slice: []const Elem) ![]u8 {
    if (slice.len == 0) return allocator.dupe(u8, "[]");
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    for (slice, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        if (Elem == []const u8) {
            try w.writeAll(item);
        } else if (Elem == bool) {
            try w.writeAll(if (item) "true" else "false");
        } else {
            try w.print("{d}", .{item});
        }
    }
    try w.writeByte(']');
    return aw.toOwnedSlice();
}

fn bindSignedInt(
    allocator: std.mem.Allocator,
    comptime T: type,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
    func: []const u8,
) errors.FlagError!void {
    const v = coerce.parseSignedInt(T, value) catch |err| {
        return failCoerce(allocator, flag, value, diag, func, coerce.intCause(err));
    };
    const p: *T = @ptrCast(@alignCast(flag.value_ptr));
    p.* = v;
}

fn bindUnsignedInt(
    allocator: std.mem.Allocator,
    comptime T: type,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
    func: []const u8,
) errors.FlagError!void {
    const v = coerce.parseUnsignedInt(T, value) catch |err| {
        return failCoerce(allocator, flag, value, diag, func, coerce.intCause(err));
    };
    const p: *T = @ptrCast(@alignCast(flag.value_ptr));
    p.* = v;
}

fn bindFloat(
    allocator: std.mem.Allocator,
    comptime T: type,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) errors.FlagError!void {
    const v = coerce.parseFloat(T, value) catch |err| {
        return failCoerce(allocator, flag, value, diag, "ParseFloat", coerce.floatCause(err));
    };
    const p: *T = @ptrCast(@alignCast(flag.value_ptr));
    p.* = v;
}

fn bindCount(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) errors.FlagError!void {
    const p: *i32 = @ptrCast(@alignCast(flag.value_ptr));
    if (std.mem.eql(u8, value, "+1")) {
        p.* +%= 1;
        return;
    }
    const v = coerce.parseSignedInt(i32, value) catch |err| {
        return failCoerce(allocator, flag, value, diag, "ParseInt", coerce.intCause(err));
    };
    p.* = v;
}

fn bindDuration(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) errors.FlagError!void {
    const r = duration.parse(value);
    switch (r) {
        .ok => |ns| {
            const p: *i64 = @ptrCast(@alignCast(flag.value_ptr));
            p.* = ns;
        },
        .err => |e| {
            const msg = duration.renderError(allocator, e, value) catch return error.TypeCoercionFailed;
            defer allocator.free(msg);
            return failCoerceWithRendered(allocator, flag, value, diag, msg);
        },
    }
}

fn failCoerce(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
    func: []const u8,
    cause: coerce.Cause,
) errors.FlagError {
    const cause_msg = coerce.renderNumError(allocator, func, value, cause) catch {
        return error.TypeCoercionFailed;
    };
    defer allocator.free(cause_msg);
    return failCoerceWithRendered(allocator, flag, value, diag, cause_msg);
}

fn failCoerceWithRendered(
    allocator: std.mem.Allocator,
    flag: *Flag,
    value: []const u8,
    diag: ?*Diagnostic,
    cause_msg: []const u8,
) errors.FlagError {
    if (diag) |d| {
        d.category = .flag;
        d.code = .type_coercion_failed;
        d.flag_name = flag.name;
        d.raw_value = value;
        // pflag's InvalidValueError wording (errors.go:108-117):
        //   invalid argument "X" for "--foo" flag: <cause>          (no shorthand)
        //   invalid argument "X" for "-f, --foo" flag: <cause>      (with shorthand, non-deprecated)
        const rendered = if (flag.shorthand != 0 and flag.deprecated.len == 0)
            std.fmt.allocPrint(
                allocator,
                "invalid argument \"{s}\" for \"-{c}, --{s}\" flag: {s}",
                .{ value, flag.shorthand, flag.name, cause_msg },
            ) catch return error.TypeCoercionFailed
        else
            std.fmt.allocPrint(
                allocator,
                "invalid argument \"{s}\" for \"--{s}\" flag: {s}",
                .{ value, flag.name, cause_msg },
            ) catch return error.TypeCoercionFailed;
        d.setOwnedMessage(allocator, rendered);
    }
    return error.TypeCoercionFailed;
}
