//! FlagSet — registry of flag definitions, plus the `apply` loop that
//! binds parser tokens into the user's `*T` storage.
//!
//! Source of truth: pflag's `FlagSet` in flag.go. The shape mirrors pflag
//! (formal/shorthand maps, Flag record with NoOptDefVal / Changed / Hidden
//! / Deprecated / DefValue) with two Zig adaptations:
//!   1. The `Value` interface becomes a `ValueType` enum + `*anyopaque`
//!      pointer to the user's typed storage (Zig has no nominal interfaces).
//!   2. Allocation is explicit. The FlagSet owns its internal maps and the
//!      rendered default-value strings; user-supplied name/shorthand/usage
//!      are borrow-only (per design-docs/08-allocator-conventions.md).
//!
//! See design-docs/02-cobra-mapping.md for the per-type flag table and
//! design-docs/07-error-model.md for the Diagnostic-out-parameter contract.

const std = @import("std");
const errors = @import("../errors.zig");
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const fillDiag = @import("../diagnostic.zig").fill;
const coerce = @import("coerce.zig");
const duration = @import("duration.zig");
const parser_mod = @import("../parser/parser.zig");
const Token = @import("../parser/token.zig").Token;

pub const FlagSchema = parser_mod.FlagSchema;

/// All scalar + slice value types zobra's *VarP methods bind. The
/// CustomFlag vtable (Phase 5c) will land as another variant.
pub const ValueType = enum {
    string,
    bool,
    int, // *i64 — matches Go's int width on 64-bit platforms
    int8,
    int16,
    int32,
    int64,
    uint, // *u64 — matches Go's uint width on 64-bit platforms
    uint8,
    uint16,
    uint32,
    uint64,
    float32,
    float64,
    count, // *i32 — increments on each occurrence; matches pflag's count
    duration, // *i64 — nanoseconds, matches Go's time.Duration
    string_slice, // *[]const []const u8 — CSV-split, append-on-repeat
    string_array, // *[]const []const u8 — no split, append-on-repeat
    int_slice, // *[]const i64 — Atoi (pflag's intSlice)
    int32_slice, // *[]const i32 — Atoi
    int64_slice, // *[]const i64 — ParseInt(base=0)
    float32_slice, // *[]const f32 — ParseFloat
    float64_slice, // *[]const f64 — ParseFloat
    bool_slice, // *[]const bool — ParseBool
    duration_slice, // *[]const i64 — time.ParseDuration, ns

    pub fn isBoolean(self: ValueType) bool {
        return self == .bool;
    }

    pub fn isCount(self: ValueType) bool {
        return self == .count;
    }

    pub fn isSliceLike(self: ValueType) bool {
        return switch (self) {
            .string_slice, .string_array, .int_slice, .int32_slice, .int64_slice, .float32_slice, .float64_slice, .bool_slice, .duration_slice => true,
            else => false,
        };
    }
};

pub const Flag = struct {
    name: []const u8,
    shorthand: u8, // 0 means no shorthand
    usage: []const u8,
    value_type: ValueType,
    value_ptr: *anyopaque,
    /// Default rendered as a string for help. Owned by the FlagSet.
    default_value_string: []const u8,
    /// Empty for value-taking flags. "true" for bools, "+1" for counts.
    no_opt_def_val: []const u8,
    changed: bool,
    hidden: bool,
    required: bool,
    /// "" if not deprecated; otherwise the user-supplied replacement message.
    /// Borrowed.
    deprecated: []const u8,
    /// Whether the FlagSet owns `default_value_string` and should free it.
    owns_default: bool,
    /// For slice / map types: the FlagSet owns the slice/map storage that
    /// `value_ptr` points at, and frees it on deinit.
    owns_value_storage: bool,
};

pub const FlagSet = struct {
    allocator: std.mem.Allocator,
    formal: std.StringHashMapUnmanaged(*Flag),
    shorthands: [256]?*Flag,
    ordered: std.ArrayListUnmanaged(*Flag),
    /// Positional arguments collected during `apply` (after subtracting
    /// flag tokens). `args_len_at_dash` records `args.len` at the point
    /// `--` was seen, mirroring pflag's `argsLenAtDash`.
    args: std.ArrayListUnmanaged([]const u8),
    args_len_at_dash: ?usize,

    pub fn init(allocator: std.mem.Allocator) FlagSet {
        return .{
            .allocator = allocator,
            .formal = .empty,
            .shorthands = @splat(null),
            .ordered = .empty,
            .args = .empty,
            .args_len_at_dash = null,
        };
    }

    pub fn deinit(self: *FlagSet) void {
        for (self.ordered.items) |flag| {
            if (flag.owns_default) self.allocator.free(flag.default_value_string);
            if (flag.owns_value_storage) freeSliceStorage(self.allocator, flag);
            self.allocator.destroy(flag);
        }
        self.formal.deinit(self.allocator);
        self.ordered.deinit(self.allocator);
        self.args.deinit(self.allocator);
    }

    // ---- registration ---------------------------------------------------

    pub const RegisterError = error{
        FlagRedefined,
        ShorthandRedefined,
        ShorthandTooLong,
    } || std.mem.Allocator.Error;

    fn addFlag(
        self: *FlagSet,
        spec: struct {
            name: []const u8,
            shorthand: u8 = 0,
            usage: []const u8,
            value_type: ValueType,
            value_ptr: *anyopaque,
            default_value_string: []const u8,
            owns_default: bool,
            owns_value_storage: bool = false,
            no_opt_def_val: []const u8,
        },
    ) RegisterError!*Flag {
        if (self.formal.contains(spec.name)) return error.FlagRedefined;
        if (spec.shorthand != 0 and self.shorthands[spec.shorthand] != null) {
            return error.ShorthandRedefined;
        }

        const flag = try self.allocator.create(Flag);
        errdefer self.allocator.destroy(flag);
        flag.* = .{
            .name = spec.name,
            .shorthand = spec.shorthand,
            .usage = spec.usage,
            .value_type = spec.value_type,
            .value_ptr = spec.value_ptr,
            .default_value_string = spec.default_value_string,
            .owns_default = spec.owns_default,
            .owns_value_storage = spec.owns_value_storage,
            .no_opt_def_val = spec.no_opt_def_val,
            .changed = false,
            .hidden = false,
            .required = false,
            .deprecated = "",
        };

        try self.formal.put(self.allocator, spec.name, flag);
        errdefer _ = self.formal.remove(spec.name);

        try self.ordered.append(self.allocator, flag);
        errdefer _ = self.ordered.pop();

        if (spec.shorthand != 0) self.shorthands[spec.shorthand] = flag;
        return flag;
    }

    // ---- typed *VarP entry points --------------------------------------

    pub fn stringVarP(
        self: *FlagSet,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        ptr.* = default;
        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = .string,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = default,
            .owns_default = false,
            .no_opt_def_val = "",
        });
    }

    pub fn boolVarP(
        self: *FlagSet,
        ptr: *bool,
        name: []const u8,
        shorthand: u8,
        default: bool,
        usage: []const u8,
    ) !void {
        ptr.* = default;
        const ds = try self.allocator.dupe(u8, if (default) "true" else "false");
        errdefer self.allocator.free(ds);
        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = .bool,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = ds,
            .owns_default = true,
            .no_opt_def_val = "true",
        });
    }

    pub fn countVarP(
        self: *FlagSet,
        ptr: *i32,
        name: []const u8,
        shorthand: u8,
        usage: []const u8,
    ) !void {
        ptr.* = 0;
        const ds = try self.allocator.dupe(u8, "0");
        errdefer self.allocator.free(ds);
        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = .count,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = ds,
            .owns_default = true,
            .no_opt_def_val = "+1",
        });
    }

    pub fn durationVarP(
        self: *FlagSet,
        ptr: *i64,
        name: []const u8,
        shorthand: u8,
        default: i64,
        usage: []const u8,
    ) !void {
        ptr.* = default;
        const ds = try std.fmt.allocPrint(self.allocator, "{d}", .{default});
        errdefer self.allocator.free(ds);
        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = .duration,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = ds,
            .owns_default = true,
            .no_opt_def_val = "",
        });
    }

    /// Generic numeric *VarP — used internally; the public wrappers below
    /// pin the exact (T, ValueType) pair so call sites are type-checked.
    fn registerNumeric(
        self: *FlagSet,
        comptime T: type,
        comptime tag: ValueType,
        ptr: *T,
        name: []const u8,
        shorthand: u8,
        default: T,
        usage: []const u8,
    ) !void {
        ptr.* = default;
        const ds = try std.fmt.allocPrint(self.allocator, "{d}", .{default});
        errdefer self.allocator.free(ds);
        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = tag,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = ds,
            .owns_default = true,
            .no_opt_def_val = "",
        });
    }

    pub fn intVarP(self: *FlagSet, ptr: *i64, name: []const u8, shorthand: u8, default: i64, usage: []const u8) !void {
        return self.registerNumeric(i64, .int, ptr, name, shorthand, default, usage);
    }
    pub fn int8VarP(self: *FlagSet, ptr: *i8, name: []const u8, shorthand: u8, default: i8, usage: []const u8) !void {
        return self.registerNumeric(i8, .int8, ptr, name, shorthand, default, usage);
    }
    pub fn int16VarP(self: *FlagSet, ptr: *i16, name: []const u8, shorthand: u8, default: i16, usage: []const u8) !void {
        return self.registerNumeric(i16, .int16, ptr, name, shorthand, default, usage);
    }
    pub fn int32VarP(self: *FlagSet, ptr: *i32, name: []const u8, shorthand: u8, default: i32, usage: []const u8) !void {
        return self.registerNumeric(i32, .int32, ptr, name, shorthand, default, usage);
    }
    pub fn int64VarP(self: *FlagSet, ptr: *i64, name: []const u8, shorthand: u8, default: i64, usage: []const u8) !void {
        return self.registerNumeric(i64, .int64, ptr, name, shorthand, default, usage);
    }
    pub fn uintVarP(self: *FlagSet, ptr: *u64, name: []const u8, shorthand: u8, default: u64, usage: []const u8) !void {
        return self.registerNumeric(u64, .uint, ptr, name, shorthand, default, usage);
    }
    pub fn uint8VarP(self: *FlagSet, ptr: *u8, name: []const u8, shorthand: u8, default: u8, usage: []const u8) !void {
        return self.registerNumeric(u8, .uint8, ptr, name, shorthand, default, usage);
    }
    pub fn uint16VarP(self: *FlagSet, ptr: *u16, name: []const u8, shorthand: u8, default: u16, usage: []const u8) !void {
        return self.registerNumeric(u16, .uint16, ptr, name, shorthand, default, usage);
    }
    pub fn uint32VarP(self: *FlagSet, ptr: *u32, name: []const u8, shorthand: u8, default: u32, usage: []const u8) !void {
        return self.registerNumeric(u32, .uint32, ptr, name, shorthand, default, usage);
    }
    pub fn uint64VarP(self: *FlagSet, ptr: *u64, name: []const u8, shorthand: u8, default: u64, usage: []const u8) !void {
        return self.registerNumeric(u64, .uint64, ptr, name, shorthand, default, usage);
    }
    pub fn float32VarP(self: *FlagSet, ptr: *f32, name: []const u8, shorthand: u8, default: f32, usage: []const u8) !void {
        return self.registerNumeric(f32, .float32, ptr, name, shorthand, default, usage);
    }
    pub fn float64VarP(self: *FlagSet, ptr: *f64, name: []const u8, shorthand: u8, default: f64, usage: []const u8) !void {
        return self.registerNumeric(f64, .float64, ptr, name, shorthand, default, usage);
    }

    pub fn stringSliceVarP(
        self: *FlagSet,
        ptr: *[]const []const u8,
        name: []const u8,
        shorthand: u8,
        default: []const []const u8,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike([]const u8, .string_slice, ptr, name, shorthand, default, usage);
    }

    pub fn stringArrayVarP(
        self: *FlagSet,
        ptr: *[]const []const u8,
        name: []const u8,
        shorthand: u8,
        default: []const []const u8,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike([]const u8, .string_array, ptr, name, shorthand, default, usage);
    }

    pub fn intSliceVarP(
        self: *FlagSet,
        ptr: *[]const i64,
        name: []const u8,
        shorthand: u8,
        default: []const i64,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(i64, .int_slice, ptr, name, shorthand, default, usage);
    }

    pub fn int32SliceVarP(
        self: *FlagSet,
        ptr: *[]const i32,
        name: []const u8,
        shorthand: u8,
        default: []const i32,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(i32, .int32_slice, ptr, name, shorthand, default, usage);
    }

    pub fn int64SliceVarP(
        self: *FlagSet,
        ptr: *[]const i64,
        name: []const u8,
        shorthand: u8,
        default: []const i64,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(i64, .int64_slice, ptr, name, shorthand, default, usage);
    }

    pub fn float32SliceVarP(
        self: *FlagSet,
        ptr: *[]const f32,
        name: []const u8,
        shorthand: u8,
        default: []const f32,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(f32, .float32_slice, ptr, name, shorthand, default, usage);
    }

    pub fn float64SliceVarP(
        self: *FlagSet,
        ptr: *[]const f64,
        name: []const u8,
        shorthand: u8,
        default: []const f64,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(f64, .float64_slice, ptr, name, shorthand, default, usage);
    }

    pub fn boolSliceVarP(
        self: *FlagSet,
        ptr: *[]const bool,
        name: []const u8,
        shorthand: u8,
        default: []const bool,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(bool, .bool_slice, ptr, name, shorthand, default, usage);
    }

    pub fn durationSliceVarP(
        self: *FlagSet,
        ptr: *[]const i64,
        name: []const u8,
        shorthand: u8,
        default: []const i64,
        usage: []const u8,
    ) !void {
        try self.registerSliceLike(i64, .duration_slice, ptr, name, shorthand, default, usage);
    }

    fn registerSliceLike(
        self: *FlagSet,
        comptime Elem: type,
        comptime tag: ValueType,
        ptr: *[]const Elem,
        name: []const u8,
        shorthand: u8,
        default: []const Elem,
        usage: []const u8,
    ) !void {
        // Copy the user's default into FlagSet-owned storage so the user
        // doesn't need to manage its lifetime (they typically pass `&.{}`
        // or a literal; both go out of scope before the FlagSet does).
        // Order matters: we don't write `ptr.*` until addFlag has
        // succeeded, so a mid-OOM failure leaves the user's pointer
        // pointing at its original (untouched) value. The errdefers
        // free the FlagSet-allocated storage on any early return.
        const owned = try self.allocator.dupe(Elem, default);
        errdefer self.allocator.free(owned);

        const ds = try renderSliceDefault(Elem, self.allocator, default);
        errdefer self.allocator.free(ds);

        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = tag,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = ds,
            .owns_default = true,
            .owns_value_storage = true,
            .no_opt_def_val = "",
        });

        // addFlag succeeded — FlagSet owns owned + ds via the
        // owns_value_storage / owns_default flags. Commit the binding.
        ptr.* = owned;
    }

    // ---- lookup ---------------------------------------------------------

    pub fn lookup(self: *const FlagSet, name: []const u8) ?*Flag {
        return self.formal.get(name);
    }

    pub fn shorthandLookup(self: *const FlagSet, c: u8) ?*Flag {
        return self.shorthands[c];
    }

    // ---- modifiers ------------------------------------------------------

    pub fn markRequired(self: *FlagSet, name: []const u8) error{FlagNotFound}!void {
        const flag = self.lookup(name) orelse return error.FlagNotFound;
        flag.required = true;
    }

    pub fn markHidden(self: *FlagSet, name: []const u8) error{FlagNotFound}!void {
        const flag = self.lookup(name) orelse return error.FlagNotFound;
        flag.hidden = true;
    }

    pub fn markDeprecated(self: *FlagSet, name: []const u8, message: []const u8) error{ FlagNotFound, EmptyDeprecationMessage }!void {
        if (message.len == 0) return error.EmptyDeprecationMessage;
        const flag = self.lookup(name) orelse return error.FlagNotFound;
        flag.deprecated = message;
        flag.hidden = true; // pflag also auto-hides deprecated flags
    }

    // ---- set / apply ----------------------------------------------------

    /// Set a flag programmatically by name (mirrors pflag's FlagSet.Set).
    /// Used by both apply() and external callers.
    pub fn set(
        self: *FlagSet,
        name: []const u8,
        value: []const u8,
        diag: ?*Diagnostic,
    ) (errors.FlagError || std.mem.Allocator.Error)!void {
        const flag = self.lookup(name) orelse {
            fillDiag(diag, .flag, .no_such_flag);
            if (diag) |d| d.flag_name = name;
            return error.NoSuchFlag;
        };
        try setStored(self.allocator, flag, value, diag);
        flag.changed = true;
    }

    /// Walk a token stream from the parser and bind every flag/value into
    /// the user's storage. Returns at the first error (matching pflag's
    /// "stop on first error" behaviour). Positionals (and passthrough
    /// tokens after `--`) accumulate into `self.args`.
    pub fn apply(
        self: *FlagSet,
        tokens: []const Token,
        diag: ?*Diagnostic,
    ) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
        return applyTokensWith(self, self, SelfApplyCallbacks.lookupLong, SelfApplyCallbacks.lookupShort, tokens, diag);
    }

    const SelfApplyCallbacks = struct {
        fn lookupLong(ctx: *const anyopaque, name: []const u8) ?*Flag {
            const fs: *const FlagSet = @ptrCast(@alignCast(ctx));
            return fs.formal.get(name);
        }
        fn lookupShort(ctx: *const anyopaque, c: u8) ?*Flag {
            const fs: *const FlagSet = @ptrCast(@alignCast(ctx));
            return fs.shorthands[c];
        }
    };

    // ---- schema view for the parser ------------------------------------

    pub fn flagSchema(self: *const FlagSet) FlagSchema {
        return .{
            .ctx = self,
            .is_value_taking_short = SchemaCallbacks.valueTakingShort,
            .is_value_taking_long = SchemaCallbacks.valueTakingLong,
            .is_known_long = SchemaCallbacks.knownLong,
            .is_boolean_long = SchemaCallbacks.booleanLong,
        };
    }

    const SchemaCallbacks = struct {
        fn valueTakingShort(ctx: *const anyopaque, c: u8) bool {
            const fs: *const FlagSet = @ptrCast(@alignCast(ctx));
            const flag = fs.shorthands[c] orelse return false;
            return flag.no_opt_def_val.len == 0;
        }
        fn valueTakingLong(ctx: *const anyopaque, name: []const u8) bool {
            const fs: *const FlagSet = @ptrCast(@alignCast(ctx));
            const flag = fs.formal.get(name) orelse return false;
            return flag.no_opt_def_val.len == 0;
        }
        fn knownLong(ctx: *const anyopaque, name: []const u8) bool {
            const fs: *const FlagSet = @ptrCast(@alignCast(ctx));
            return fs.formal.contains(name);
        }
        fn booleanLong(ctx: *const anyopaque, name: []const u8) bool {
            const fs: *const FlagSet = @ptrCast(@alignCast(ctx));
            const flag = fs.formal.get(name) orelse return false;
            return flag.value_type == .bool;
        }
    };
};

// ---- private helpers -----------------------------------------------------

fn findCharSlice(raw: []const u8, c: u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, raw, c) orelse return raw[0..0];
    return raw[idx .. idx + 1];
}

/// Type of a flag-lookup callback. Used by `applyTokensWith` so the same
/// dispatch loop can drive both `FlagSet.apply` (own-flags lookup) and
/// `Command.applyTokens` (own + inherited persistent lookup).
pub const LookupLongFn = *const fn (ctx: *const anyopaque, name: []const u8) ?*Flag;
pub const LookupShortFn = *const fn (ctx: *const anyopaque, c: u8) ?*Flag;

/// Shared apply loop. `args_host` provides the storage for positionals
/// (`args`, `args_len_at_dash`) and the allocator. `ctx` + `lookup_long`
/// + `lookup_short` parameterise how a flag is resolved — pass FlagSet's
/// flat lookup or Command's tree-walking lookup as needed.
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
        .long => |l| try applyLongShared(allocator, ctx, lookup_long, l, diag),
        .short => |s| try applyShortShared(allocator, ctx, lookup_short, s, diag),
        .negated => |n| try applyNegatedShared(allocator, ctx, lookup_long, n),
        .positional => |p| try args_host.args.append(allocator, p.value),
        .terminator => args_host.args_len_at_dash = args_host.args.items.len,
        .passthrough => |v| try args_host.args.append(allocator, v),
    };
}

fn applyLongShared(
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
    try setStored(allocator, flag, v, diag);
    flag.changed = true;
}

fn applyShortShared(
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
    try setStored(allocator, flag, v, diag);
    flag.changed = true;
}

fn applyNegatedShared(
    allocator: std.mem.Allocator,
    ctx: *const anyopaque,
    lookup_long: LookupLongFn,
    n: Token.Negated,
) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
    // Parser only emits `negated` when the schema confirmed it's a
    // boolean. If the flag has since been removed, fall back to the
    // unknown-flag path.
    const flag = lookup_long(ctx, n.name) orelse return error.UnknownFlag;
    try setStored(allocator, flag, "false", null);
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

/// Coerce `value` according to `flag.value_type` and write through
/// `flag.value_ptr`. On failure, fills diag with the strconv-style cause
/// and the flag context.
fn setStored(
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
    };
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
    // Comma-split (no CSV quoting yet — defer until a fixture forces it).
    const ptr: *[]const []const u8 = @ptrCast(@alignCast(flag.value_ptr));
    const old = ptr.*;
    var pieces: std.ArrayListUnmanaged([]const u8) = .empty;
    defer pieces.deinit(allocator);

    // pflag's stringSliceValue replaces on first set, appends on
    // subsequent. Use flag.changed for the same semantics.
    if (flag.changed) {
        try pieces.appendSlice(allocator, old);
    }

    if (value.len > 0) {
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |s| try pieces.append(allocator, s);
    }

    const owned = try pieces.toOwnedSlice(allocator);
    // The previous storage was either the FlagSet-allocated default
    // (first set) or the FlagSet-allocated previous result (subsequent).
    // Both are owned by us via owns_value_storage; free unconditionally.
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

fn freeSliceStorage(allocator: std.mem.Allocator, flag: *Flag) void {
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
        else => {},
    }
}

fn renderSliceDefault(comptime Elem: type, allocator: std.mem.Allocator, slice: []const Elem) ![]u8 {
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
        // The "+1" sentinel comes from the no_opt_def_val path.
        p.* +%= 1;
        return;
    }
    // Explicit numeric value (e.g. --verbose=3) overrides the count.
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

// Tests live in test/flag/flagset.zig. The internal helpers above
// (setStored, bind*, applyTokensWith) are exercised through the public
// FlagSet API there.
