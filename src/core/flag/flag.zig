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
const bind = @import("bind.zig");
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
    string_to_string, // *std.StringHashMapUnmanaged([]const u8)
    string_to_int, // *std.StringHashMapUnmanaged(i32)
    string_to_int64, // *std.StringHashMapUnmanaged(i64)
    ip, // *[]const u8 — IPv4 or IPv6 literal (validated)
    ip_mask, // *[]const u8 — hex IP mask
    ip_net, // *[]const u8 — CIDR (e.g. 192.168.1.0/24)
    bytes_hex, // *[]const u8 — decoded bytes (FlagSet-owned)
    bytes_base64, // *[]const u8 — decoded bytes (FlagSet-owned)
    custom, // CustomFlag vtable — the pflag.Value escape hatch

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

    pub fn isMapLike(self: ValueType) bool {
        return self == .string_to_string or self == .string_to_int or self == .string_to_int64;
    }
};

/// User-supplied vtable for the `custom` flag type — the pflag.Value
/// escape hatch. Lets a CLI register a flag whose Set / String / Type
/// behaviours are user-defined. Mirrors pflag's `Value` interface.
pub const CustomFlag = struct {
    /// Opaque pointer to user storage. Passed to set_fn / string_fn.
    ptr: *anyopaque,
    /// Type label for help (e.g. "ip-cidr-list", "json-config").
    type_name: []const u8,
    /// Coerce a string into the user's storage. Errors propagate.
    set_fn: *const fn (ptr: *anyopaque, value: []const u8) anyerror!void,
    /// Render the current value to a string (for help / defaults).
    /// Caller frees the returned slice with the same allocator.
    string_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
};

pub const Flag = struct {
    name: []const u8,
    shorthand: u8, // 0 means no shorthand
    usage: []const u8,
    value_type: ValueType,
    /// For non-`custom` types: opaque pointer to the user's storage.
    /// For `custom` type: ignored; see `custom` field below.
    value_ptr: *anyopaque,
    /// Set when value_type == .custom; the vtable + ptr the user passed.
    custom: ?CustomFlag = null,
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
    /// For slice types: the FlagSet owns the slice storage that
    /// `value_ptr` points at, and frees it on deinit.
    owns_value_storage: bool,
    /// For map types: the FlagSet owns the map ENTRIES (keys/values are
    /// borrowed from argv; the entry slots are heap-allocated by the
    /// HashMap and need deinit). Distinct from owns_value_storage so the
    /// per-type free dispatch doesn't conflate the two.
    owns_map_storage: bool = false,

    /// True when `default_value_string` represents the zero value for the
    /// flag's type. Mirrors pflag.defaultIsZeroValue. The help renderer
    /// and doc generators consult this to decide whether to emit a
    /// `(default ...)` annotation.
    pub fn isZeroDefault(self: *const Flag) bool {
        return switch (self.value_type) {
            .bool => std.mem.eql(u8, self.default_value_string, "false") or self.default_value_string.len == 0,
            .duration => std.mem.eql(u8, self.default_value_string, "0") or std.mem.eql(u8, self.default_value_string, "0s"),
            .int, .int8, .int16, .int32, .int64, .uint, .uint8, .uint16, .uint32, .uint64, .count, .float32, .float64 => std.mem.eql(u8, self.default_value_string, "0"),
            .string => self.default_value_string.len == 0,
            .string_slice, .string_array, .int_slice, .int32_slice, .int64_slice, .float32_slice, .float64_slice, .bool_slice, .duration_slice, .string_to_string, .string_to_int, .string_to_int64, .bytes_hex, .bytes_base64 => std.mem.eql(u8, self.default_value_string, "[]"),
            .ip, .ip_mask, .ip_net => self.default_value_string.len == 0,
            .custom => self.default_value_string.len == 0,
        };
    }

    /// Cobra/pflag-style display name for this flag's type. Used by the
    /// help renderer and doc generators when emitting the type column.
    /// Custom flags consult their vtable's `type_name`.
    pub fn typeName(self: *const Flag) []const u8 {
        return switch (self.value_type) {
            .bool => "",
            .string => "string",
            .duration => "duration",
            .int => "int",
            .int8 => "int8",
            .int16 => "int16",
            .int32 => "int32",
            .int64 => "int",
            .uint => "uint",
            .uint8 => "uint8",
            .uint16 => "uint16",
            .uint32 => "uint32",
            .uint64 => "uint",
            .float32 => "float32",
            .float64 => "float",
            .count => "count",
            .string_slice => "strings",
            .string_array => "stringArray",
            .int_slice => "ints",
            .int32_slice => "int32Slice",
            .int64_slice => "int64Slice",
            .float32_slice => "float32Slice",
            .float64_slice => "float64Slice",
            .bool_slice => "bools",
            .duration_slice => "durationSlice",
            .string_to_string => "stringToString",
            .string_to_int => "stringToInt",
            .string_to_int64 => "stringToInt64",
            .bytes_hex => "bytesHex",
            .bytes_base64 => "bytesBase64",
            .ip => "ip",
            .ip_mask => "ipMask",
            .ip_net => "ipNet",
            .custom => if (self.custom) |c| c.type_name else "",
        };
    }
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
            if (flag.owns_value_storage) bind.freeSliceStorage(self.allocator, flag);
            if (flag.owns_map_storage) bind.freeMapStorage(self.allocator, flag);
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

    pub fn stringToStringVarP(
        self: *FlagSet,
        ptr: *std.StringHashMapUnmanaged([]const u8),
        name: []const u8,
        shorthand: u8,
        usage: []const u8,
    ) !void {
        try self.registerMapLike(.string_to_string, @ptrCast(ptr), name, shorthand, usage);
    }

    pub fn stringToIntVarP(
        self: *FlagSet,
        ptr: *std.StringHashMapUnmanaged(i32),
        name: []const u8,
        shorthand: u8,
        usage: []const u8,
    ) !void {
        try self.registerMapLike(.string_to_int, @ptrCast(ptr), name, shorthand, usage);
    }

    pub fn stringToInt64VarP(
        self: *FlagSet,
        ptr: *std.StringHashMapUnmanaged(i64),
        name: []const u8,
        shorthand: u8,
        usage: []const u8,
    ) !void {
        try self.registerMapLike(.string_to_int64, @ptrCast(ptr), name, shorthand, usage);
    }

    pub fn ipVarP(
        self: *FlagSet,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        try self.registerStringFlag(.ip, ptr, name, shorthand, default, usage);
    }

    pub fn ipMaskVarP(
        self: *FlagSet,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        try self.registerStringFlag(.ip_mask, ptr, name, shorthand, default, usage);
    }

    pub fn ipNetVarP(
        self: *FlagSet,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        try self.registerStringFlag(.ip_net, ptr, name, shorthand, default, usage);
    }

    pub fn bytesHexVarP(
        self: *FlagSet,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        try self.registerBytesFlag(.bytes_hex, ptr, name, shorthand, default, usage);
    }

    pub fn bytesBase64VarP(
        self: *FlagSet,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        try self.registerBytesFlag(.bytes_base64, ptr, name, shorthand, default, usage);
    }

    /// Register an "IP-shape" flag — stores the validated input string
    /// directly (borrowed from argv). No allocation.
    fn registerStringFlag(
        self: *FlagSet,
        comptime tag: ValueType,
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
            .value_type = tag,
            .value_ptr = @ptrCast(ptr),
            .default_value_string = default,
            .owns_default = false,
            .owns_value_storage = false,
            .no_opt_def_val = "",
        });
    }

    /// Register a "bytes" flag — stores the DECODED bytes as owned
    /// storage; deinit frees it. Default value is treated as an
    /// already-decoded byte slice (typical use: `&.{}`).
    fn registerBytesFlag(
        self: *FlagSet,
        comptime tag: ValueType,
        ptr: *[]const u8,
        name: []const u8,
        shorthand: u8,
        default: []const u8,
        usage: []const u8,
    ) !void {
        const owned = try self.allocator.dupe(u8, default);
        errdefer self.allocator.free(owned);

        const ds = try self.allocator.dupe(u8, "[]");
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
        ptr.* = owned;
    }

    fn registerMapLike(
        self: *FlagSet,
        comptime tag: ValueType,
        ptr: *anyopaque,
        name: []const u8,
        shorthand: u8,
        usage: []const u8,
    ) !void {
        // Maps default-render as "[]" per pflag (GetStringToString returns
        // an empty map, and the "default …" suffix is suppressed).
        const ds = try self.allocator.dupe(u8, "[]");
        errdefer self.allocator.free(ds);

        _ = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = tag,
            .value_ptr = ptr,
            .default_value_string = ds,
            .owns_default = true,
            // Maps don't allocate their backbone in `addFlag` — the user
            // supplied a pre-existing empty `StringHashMapUnmanaged`.
            // `owns_value_storage` controls slice-storage freeing only;
            // map entries are freed in `freeMapStorage` below via
            // `owns_map_storage`.
            .owns_value_storage = false,
            .no_opt_def_val = "",
        });
        // Mark the flag as owning its map storage. Maps are tracked via
        // a separate flag because the slice path uses owns_value_storage
        // and we don't want the slice-free dispatch firing for maps.
        const flag = self.lookup(name).?;
        flag.owns_map_storage = true;
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

        const ds = try bind.renderSliceDefault(Elem, self.allocator, default);
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

    /// pflag's `Flags().Changed(name)`: returns whether the flag was
    /// actually set on the command line / via Set. Returns false for
    /// unregistered names (matches pflag).
    pub fn changed(self: *const FlagSet, name: []const u8) bool {
        const f = self.lookup(name) orelse return false;
        return f.changed;
    }

    /// Register a custom-typed flag (the pflag.Value escape hatch).
    /// `cf.ptr` is the user's storage — opaque to the FlagSet; only the
    /// `set_fn` / `string_fn` callbacks know how to read or write it.
    pub fn varP(
        self: *FlagSet,
        cf: CustomFlag,
        name: []const u8,
        shorthand: u8,
        usage: []const u8,
    ) !void {
        // Render the initial default by asking the vtable for the
        // current string representation, then take ownership.
        const ds = try cf.string_fn(cf.ptr, self.allocator);
        errdefer self.allocator.free(ds);

        const flag = try self.addFlag(.{
            .name = name,
            .shorthand = shorthand,
            .usage = usage,
            .value_type = .custom,
            .value_ptr = cf.ptr,
            .default_value_string = ds,
            .owns_default = true,
            .owns_value_storage = false,
            .no_opt_def_val = "",
        });
        flag.custom = cf;
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
        try bind.setStored(self.allocator, flag, value, diag);
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
    try bind.setStored(allocator, flag, v, diag);
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
    try bind.setStored(allocator, flag, v, diag);
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

// The type-coercion / storage-binding helpers (setStored, bind*,
// free*, failCoerce, renderSliceDefault) live in bind.zig and are
// reached through `bind.*`. Tests for the apply path are in
// test/flag/flagset.zig.
