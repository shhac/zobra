//! Apply loop — drives parser tokens into Flag storage.
//!
//! Two callers need this:
//! 1. `FlagSet.apply` — own-flags lookup only.
//! 2. `Command.applyTokens` — own + inherited persistent flags via a
//!    tree-walking lookup.
//!
//! Both paths share `applyTokensWith`; the per-token-kind handlers
//! (`applyLong`, `applyShort`, `applyNegated`) call back through the
//! caller-supplied `LookupLongFn` / `LookupShortFn` so this module
//! doesn't depend on FlagSet's internal layout.
//!
//! Source of truth: pflag's `FlagSet.parseLongArg` / `parseSingleShortArg`.

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const fillDiag = @import("../diagnostic.zig").fill;
const Token = @import("../parser/token.zig").Token;

const flag_mod = @import("flag.zig");
const Flag = flag_mod.Flag;
const FlagSet = flag_mod.FlagSet;
const bind = @import("bind.zig");

/// Flag-lookup callback. Lets `applyTokensWith` drive both
/// `FlagSet.apply` (flat lookup) and `Command.applyTokens` (own +
/// inherited persistent lookup).
pub const LookupLongFn = *const fn (ctx: *const anyopaque, name: []const u8) ?*Flag;
pub const LookupShortFn = *const fn (ctx: *const anyopaque, c: u8) ?*Flag;

/// Shared apply loop. `args_host` provides the storage for positionals
/// (`args`, `args_len_at_dash`) and the allocator. `ctx` + `lookup_long`
/// + `lookup_short` parameterise how a flag is resolved.
pub fn applyTokensWith(
    args_host: *FlagSet,
    ctx: *const anyopaque,
    lookup_long: LookupLongFn,
    lookup_short: LookupShortFn,
    tokens: []const Token,
    diag: ?*Diagnostic,
) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
    const allocator = args_host.allocator;
    for (tokens) |tok| switch (tok) {
        .long => |l| try applyLong(allocator, ctx, lookup_long, l, diag),
        .short => |s| try applyShort(allocator, ctx, lookup_short, s, diag),
        .negated => |n| try applyNegated(allocator, ctx, lookup_long, n),
        .positional => |p| try args_host.args.append(allocator, p.value),
        .terminator => args_host.args_len_at_dash = args_host.args.items.len,
        .passthrough => |v| try args_host.args.append(allocator, v),
    };
}

fn applyLong(
    allocator: std.mem.Allocator,
    ctx: *const anyopaque,
    lookup_long: LookupLongFn,
    l: Token.Long,
    diag: ?*Diagnostic,
) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
    const flag = lookup_long(ctx, l.name) orelse {
        fillDiag(diag, .parse, .unknown_flag);
        if (diag) |d| {
            d.flag_name = l.name;
            d.raw = l.raw;
        }
        return error.UnknownFlag;
    };
    const v = l.value orelse blk: {
        if (flag.no_opt_def_val.len > 0) break :blk flag.no_opt_def_val;
        fillDiag(diag, .parse, .missing_value);
        if (diag) |d| {
            d.flag_name = l.name;
            d.raw = l.raw;
        }
        return error.MissingValue;
    };
    try bind.setStored(allocator, flag, v, diag);
    flag.changed = true;
}

fn applyShort(
    allocator: std.mem.Allocator,
    ctx: *const anyopaque,
    lookup_short: LookupShortFn,
    s: Token.Short,
    diag: ?*Diagnostic,
) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
    const flag = lookup_short(ctx, s.name) orelse {
        fillDiag(diag, .parse, .unknown_flag);
        if (diag) |d| {
            d.flag_name = sliceContainingChar(s.raw, s.name);
            d.raw = s.raw;
            d.short_group = shortGroupSuffixOf(s.raw, s.name);
        }
        return error.UnknownFlag;
    };
    const v = s.value orelse blk: {
        if (flag.no_opt_def_val.len > 0) break :blk flag.no_opt_def_val;
        fillDiag(diag, .parse, .missing_value);
        if (diag) |d| {
            d.flag_name = sliceContainingChar(s.raw, s.name);
            d.raw = s.raw;
            d.short_group = shortGroupSuffixOf(s.raw, s.name);
        }
        return error.MissingValue;
    };
    try bind.setStored(allocator, flag, v, diag);
    flag.changed = true;
}

fn applyNegated(
    allocator: std.mem.Allocator,
    ctx: *const anyopaque,
    lookup_long: LookupLongFn,
    n: Token.Negated,
) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
    // Parser only emits `negated` when the schema confirmed it's a
    // boolean. If the flag has since been removed, fall back to the
    // unknown-flag path.
    const flag = lookup_long(ctx, n.name) orelse return error.UnknownFlag;
    try bind.setStored(allocator, flag, "false", null);
    flag.changed = true;
}

fn sliceContainingChar(raw: []const u8, c: u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, raw, c) orelse return raw[0..0];
    return raw[idx .. idx + 1];
}

/// pflag's `specifiedShorthands` — the remaining shorthand chars from
/// the point of error, without the leading `-`.
fn shortGroupSuffixOf(raw: []const u8, c: u8) []const u8 {
    if (raw.len < 2) return raw;
    const body = raw[1..];
    const idx = std.mem.indexOfScalar(u8, body, c) orelse return body;
    return body[idx..];
}
