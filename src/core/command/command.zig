//! Command — the cobra-equivalent tree node. Holds configuration, hook
//! function pointers, args validator, child commands, and two FlagSets
//! (own + persistent). `execute` resolves the target subcommand from
//! argv, parses flags with the target's effective schema (own +
//! inherited persistent), validates positionals, and runs the
//! five-stage hook chain.
//!
//! Source of truth: spf13/cobra's command.go — particularly Find
//! (line 757), execute (line 905), and the hook ordering. See
//! design-docs/02-cobra-mapping.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("../diagnostic.zig").Diagnostic;
const fillDiag = @import("../diagnostic.zig").fill;
const errors = @import("../errors.zig");
const flag_mod = @import("../flag/flag.zig");
const parser_mod = @import("../parser/parser.zig");
const args_mod = @import("args.zig");
const hook_mod = @import("hook.zig");

pub const FlagSet = flag_mod.FlagSet;
pub const Token = parser_mod.Token;
pub const FlagSchema = parser_mod.FlagSchema;
pub const ArgsValidator = args_mod.ArgsValidator;

pub const HookFn = *const fn (cmd: *Command, args: []const []const u8) void;
pub const HookFnE = *const fn (cmd: *Command, args: []const []const u8) anyerror!void;

pub const Options = struct {
    use: []const u8,
    short: []const u8 = "",
    long: []const u8 = "",
    example: []const u8 = "",
    deprecated: []const u8 = "",
    aliases: []const []const u8 = &.{},
    valid_args: []const []const u8 = &.{},
    hidden: bool = false,
    silence_usage: bool = false,
    silence_errors: bool = false,
    args: ?ArgsValidator = null,

    persistent_pre_run: ?HookFn = null,
    persistent_pre_run_e: ?HookFnE = null,
    pre_run: ?HookFn = null,
    pre_run_e: ?HookFnE = null,
    run: ?HookFn = null,
    run_e: ?HookFnE = null,
    post_run: ?HookFn = null,
    post_run_e: ?HookFnE = null,
    persistent_post_run: ?HookFn = null,
    persistent_post_run_e: ?HookFnE = null,
};

pub const Command = struct {
    allocator: Allocator,

    use: []const u8,
    short: []const u8,
    long: []const u8,
    example: []const u8,
    deprecated: []const u8,
    aliases: []const []const u8,
    valid_args: []const []const u8,
    hidden: bool,
    silence_usage: bool,
    silence_errors: bool,
    args: ?ArgsValidator,

    persistent_pre_run: ?HookFn,
    persistent_pre_run_e: ?HookFnE,
    pre_run: ?HookFn,
    pre_run_e: ?HookFnE,
    run: ?HookFn,
    run_e: ?HookFnE,
    post_run: ?HookFn,
    post_run_e: ?HookFnE,
    persistent_post_run: ?HookFn,
    persistent_post_run_e: ?HookFnE,

    parent: ?*Command,
    children: std.ArrayListUnmanaged(*Command),

    flags_set: FlagSet,
    persistent_flags_set: FlagSet,

    /// Caller-bindable context pointer (analogue to cobra's SetContext).
    /// Used by hooks to retrieve user state. Borrow-only; the user owns
    /// whatever it points to.
    context: ?*anyopaque,

    pub fn init(allocator: Allocator, opts: Options) !*Command {
        const cmd = try allocator.create(Command);
        errdefer allocator.destroy(cmd);
        cmd.* = .{
            .allocator = allocator,
            .use = opts.use,
            .short = opts.short,
            .long = opts.long,
            .example = opts.example,
            .deprecated = opts.deprecated,
            .aliases = opts.aliases,
            .valid_args = opts.valid_args,
            .hidden = opts.hidden,
            .silence_usage = opts.silence_usage,
            .silence_errors = opts.silence_errors,
            .args = opts.args,

            .persistent_pre_run = opts.persistent_pre_run,
            .persistent_pre_run_e = opts.persistent_pre_run_e,
            .pre_run = opts.pre_run,
            .pre_run_e = opts.pre_run_e,
            .run = opts.run,
            .run_e = opts.run_e,
            .post_run = opts.post_run,
            .post_run_e = opts.post_run_e,
            .persistent_post_run = opts.persistent_post_run,
            .persistent_post_run_e = opts.persistent_post_run_e,

            .parent = null,
            .children = .empty,
            .flags_set = FlagSet.init(allocator),
            .persistent_flags_set = FlagSet.init(allocator),
            .context = null,
        };
        return cmd;
    }

    /// Recursively frees this command's children, both flag sets, the
    /// children list, and the Command itself.
    pub fn deinit(self: *Command) void {
        for (self.children.items) |child| child.deinit();
        self.children.deinit(self.allocator);
        self.flags_set.deinit();
        self.persistent_flags_set.deinit();
        self.allocator.destroy(self);
    }

    pub fn flags(self: *Command) *FlagSet {
        return &self.flags_set;
    }

    pub fn persistentFlags(self: *Command) *FlagSet {
        return &self.persistent_flags_set;
    }

    /// Pin a context pointer the hooks will see via `cmd.context`.
    /// Borrow-only.
    pub fn bindContext(self: *Command, ctx: *anyopaque) void {
        self.context = ctx;
    }

    /// Add a child. **Ownership of `child` transfers to `self`** —
    /// `self.deinit()` will free it; callers must not also call
    /// `child.deinit()`.
    pub fn addCommand(self: *Command, child: *Command) !void {
        try self.children.append(self.allocator, child);
        child.parent = self;
    }

    pub fn markFlagRequired(self: *Command, name: []const u8) !void {
        // Look up across own flags first, then persistent. cobra exposes
        // `MarkFlagRequired` and `MarkPersistentFlagRequired`; we collapse
        // because the user's storage tells us where the flag lives.
        if (self.flags_set.lookup(name) != null) {
            try self.flags_set.markRequired(name);
            return;
        }
        try self.persistent_flags_set.markRequired(name);
    }

    // ---- effective lookup (own + inherited persistent) ----------------

    pub fn lookupLong(self: *const Command, name: []const u8) ?*flag_mod.Flag {
        if (self.flags_set.lookup(name)) |f| return f;
        var p = self.parent;
        while (p) |up| : (p = up.parent) {
            if (up.persistent_flags_set.lookup(name)) |f| return f;
        }
        return null;
    }

    pub fn lookupShort(self: *const Command, c: u8) ?*flag_mod.Flag {
        if (self.flags_set.shorthandLookup(c)) |f| return f;
        var p = self.parent;
        while (p) |up| : (p = up.parent) {
            if (up.persistent_flags_set.shorthandLookup(c)) |f| return f;
        }
        return null;
    }

    /// Schema view for the parser combining own flags + inherited
    /// persistent flags.
    pub fn effectiveFlagSchema(self: *const Command) FlagSchema {
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
            const cmd: *const Command = @ptrCast(@alignCast(ctx));
            const f = cmd.lookupShort(c) orelse return false;
            return f.no_opt_def_val.len == 0;
        }
        fn valueTakingLong(ctx: *const anyopaque, name: []const u8) bool {
            const cmd: *const Command = @ptrCast(@alignCast(ctx));
            const f = cmd.lookupLong(name) orelse return false;
            return f.no_opt_def_val.len == 0;
        }
        fn knownLong(ctx: *const anyopaque, name: []const u8) bool {
            const cmd: *const Command = @ptrCast(@alignCast(ctx));
            return cmd.lookupLong(name) != null;
        }
        fn booleanLong(ctx: *const anyopaque, name: []const u8) bool {
            const cmd: *const Command = @ptrCast(@alignCast(ctx));
            const f = cmd.lookupLong(name) orelse return false;
            return f.value_type == .bool;
        }
    };

    // ---- subcommand resolution ----------------------------------------

    pub const FoundCommand = struct {
        cmd: *Command,
        /// Argv slice owned by `findCommand`'s allocator. Caller frees.
        remaining: []const []const u8,
    };

    /// Walk the command tree, consuming positional argv elements that
    /// match child names/aliases. Returns the deepest match plus the
    /// remaining argv (with consumed names stripped). The returned
    /// `remaining` slice is freshly allocated; caller frees with the same
    /// allocator. (Even if no subcommand resolves, `remaining` is a fresh
    /// slice for a uniform free contract.)
    pub fn findCommand(self: *Command, allocator: Allocator, argv: []const []const u8) !FoundCommand {
        return findRec(self, allocator, argv);
    }

    fn findRec(cmd: *Command, allocator: Allocator, argv: []const []const u8) !FoundCommand {
        const schema = cmd.effectiveFlagSchema();
        const tokens = try parser_mod.parse(allocator, argv, schema, null);
        defer allocator.free(tokens);

        // Find the first POSITIONAL token (not passthrough — passthrough
        // means we already saw `--` and the user explicitly opted out of
        // subcommand resolution past that point).
        var first_positional: ?[]const u8 = null;
        for (tokens) |t| switch (t) {
            .positional => |p| {
                first_positional = p.value;
                break;
            },
            .terminator, .passthrough => break,
            else => {},
        };

        if (first_positional == null) {
            const dup = try allocator.dupe([]const u8, argv);
            return .{ .cmd = cmd, .remaining = dup };
        }

        const child = cmd.findChildByNameOrAlias(first_positional.?) orelse {
            const dup = try allocator.dupe([]const u8, argv);
            return .{ .cmd = cmd, .remaining = dup };
        };

        // Strip the FIRST occurrence of the candidate from argv. (The
        // first positional token is always the first argv element that
        // matches the candidate, since the parser visits argv in order
        // and emits positionals in source order.)
        const stripped = try allocator.alloc([]const u8, argv.len - 1);
        var j: usize = 0;
        var stripped_one = false;
        for (argv) |a| {
            if (!stripped_one and std.mem.eql(u8, a, first_positional.?)) {
                stripped_one = true;
                continue;
            }
            stripped[j] = a;
            j += 1;
        }
        const result = findRec(child, allocator, stripped) catch |err| {
            allocator.free(stripped);
            return err;
        };
        allocator.free(stripped);
        return result;
    }

    pub fn findChildByNameOrAlias(self: *const Command, name: []const u8) ?*Command {
        for (self.children.items) |c| {
            if (std.mem.eql(u8, c.commandName(), name)) return c;
            for (c.aliases) |a| if (std.mem.eql(u8, a, name)) return c;
        }
        return null;
    }

    /// First whitespace-delimited word of `use` — cobra's Command.Name().
    pub fn commandName(self: *const Command) []const u8 {
        const idx = std.mem.indexOfScalar(u8, self.use, ' ') orelse return self.use;
        return self.use[0..idx];
    }

    // ---- execute ------------------------------------------------------

    /// Resolve subcommand, parse flags, validate args, run hook chain.
    /// `argv` should NOT include the program name (cobra's convention).
    pub fn execute(self: *Command, argv: []const []const u8, diag: ?*Diagnostic) !void {
        const allocator = self.allocator;

        const found = try self.findCommand(allocator, argv);
        defer allocator.free(found.remaining);
        const cmd = found.cmd;
        const sub_argv = found.remaining;

        // Parse with the resolved command's effective schema.
        const tokens = try parser_mod.parse(allocator, sub_argv, cmd.effectiveFlagSchema(), diag);
        defer allocator.free(tokens);

        // Apply tokens against own + inherited persistent flag sets.
        try cmd.applyTokens(tokens, diag);

        const positionals = cmd.flags_set.args.items;

        // Validate args.
        if (cmd.args) |validator| {
            try validator.validate(cmd.valid_args, positionals, allocator, diag);
        }

        // Validate required flags (own + each inherited persistent set).
        try cmd.validateRequiredFlags(diag);

        // Run hook chain.
        try hook_mod.run(Command, cmd, positionals, false);
    }

    fn applyTokens(
        self: *Command,
        tokens: []const Token,
        diag: ?*Diagnostic,
    ) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
        for (tokens) |tok| switch (tok) {
            .long => |l| try self.applyLong(l, diag),
            .short => |s| try self.applyShort(s, diag),
            .negated => |n| try self.applyNegated(n, diag),
            .positional => |p| try self.flags_set.args.append(self.allocator, p.value),
            .terminator => self.flags_set.args_len_at_dash = self.flags_set.args.items.len,
            .passthrough => |v| try self.flags_set.args.append(self.allocator, v),
        };
    }

    fn applyLong(self: *Command, l: Token.Long, diag: ?*Diagnostic) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
        const flag = self.lookupLong(l.name) orelse {
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
        try setStored(self.allocator, flag, v, diag);
        flag.changed = true;
    }

    fn applyShort(self: *Command, s: Token.Short, diag: ?*Diagnostic) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
        const flag = self.lookupShort(s.name) orelse {
            fillDiag(diag, .parse, .unknown_flag);
            if (diag) |d| {
                d.flag_name = findCharSlice(s.raw, s.name);
                d.raw = s.raw;
            }
            return error.UnknownFlag;
        };
        const v = s.value orelse blk: {
            if (flag.no_opt_def_val.len > 0) break :blk flag.no_opt_def_val;
            fillDiag(diag, .parse, .missing_value);
            if (diag) |d| {
                d.flag_name = findCharSlice(s.raw, s.name);
                d.raw = s.raw;
            }
            return error.MissingValue;
        };
        try setStored(self.allocator, flag, v, diag);
        flag.changed = true;
    }

    fn applyNegated(self: *Command, n: Token.Negated, _: ?*Diagnostic) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
        const flag = self.lookupLong(n.name) orelse return error.UnknownFlag;
        try setStored(self.allocator, flag, "false", null);
        flag.changed = true;
    }

    fn validateRequiredFlags(self: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
        // Own flags first.
        for (self.flags_set.ordered.items) |flag| {
            if (flag.required and !flag.changed) {
                fillDiag(diag, .flag, .required_flag_missing);
                if (diag) |d| d.flag_name = flag.name;
                return error.RequiredFlagMissing;
            }
        }
        // Inherited persistent flags from each ancestor.
        var p = self.parent;
        while (p) |up| : (p = up.parent) {
            for (up.persistent_flags_set.ordered.items) |flag| {
                if (flag.required and !flag.changed) {
                    fillDiag(diag, .flag, .required_flag_missing);
                    if (diag) |d| d.flag_name = flag.name;
                    return error.RequiredFlagMissing;
                }
            }
        }
    }
};

// ---- private helpers ----------------------------------------------------

fn findCharSlice(raw: []const u8, c: u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, raw, c) orelse return raw[0..0];
    return raw[idx .. idx + 1];
}

/// Coerce `value` and store through `flag.value_ptr`. Mirrors the helper
/// in flag.zig — duplicated here because Command's apply path uses the
/// effective lookup (across own + inherited) rather than a single FlagSet.
fn setStored(
    allocator: Allocator,
    flag: *flag_mod.Flag,
    value: []const u8,
    diag: ?*Diagnostic,
) errors.FlagError!void {
    return flag_mod.setStoredExternal(allocator, flag, value, diag);
}

// ---- tests --------------------------------------------------------------

const testing = std.testing;

fn noopRun(_: *Command, _: []const []const u8) anyerror!void {}

test "Command: init/deinit roundtrip" {
    const gpa = testing.allocator;
    const cmd = try Command.init(gpa, .{ .use = "myapp", .short = "test app" });
    defer cmd.deinit();
    try testing.expectEqualStrings("myapp", cmd.use);
    try testing.expectEqualStrings("myapp", cmd.commandName());
}

test "Command: addCommand transfers ownership" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    const child = try Command.init(gpa, .{ .use = "child" });
    try root.addCommand(child);
    try testing.expectEqual(@as(usize, 1), root.children.items.len);
    try testing.expect(child.parent == root);
}

test "Command: findCommand resolves children by name" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet [target]" }));

    const found = try root.findCommand(gpa, &.{ "greet", "alice" });
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("greet", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 1), found.remaining.len);
    try testing.expectEqualStrings("alice", found.remaining[0]);
}

test "Command: findCommand resolves by alias" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .aliases = &.{ "ls", "l" } }));

    const found = try root.findCommand(gpa, &.{"ls"});
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("list", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 0), found.remaining.len);
}

test "Command: findCommand falls back to self when no child matches" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet" }));

    const found = try root.findCommand(gpa, &.{ "stranger", "alice" });
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("root", found.cmd.commandName());
    // remaining still includes both elements because no child matched.
    try testing.expectEqual(@as(usize, 2), found.remaining.len);
}

test "Command: persistent flag is visible to a child" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    var name: []const u8 = "world";
    try root.persistentFlags().stringVarP(&name, "name", 'n', "world", "");

    const child = try Command.init(gpa, .{ .use = "greet", .run_e = noopRun });
    try root.addCommand(child);

    try root.execute(&.{ "greet", "--name", "alice" }, null);
    try testing.expectEqualStrings("alice", name);
}

test "Command: hook chain fires in cobra order" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "root",
        .persistent_pre_run_e = recordHook("rootPersistentPre"),
        .persistent_post_run_e = recordHook("rootPersistentPost"),
    });
    defer root.deinit();

    const child = try Command.init(gpa, .{
        .use = "child",
        .pre_run_e = recordHook("childPre"),
        .run_e = recordHook("childRun"),
        .post_run_e = recordHook("childPost"),
    });
    try root.addCommand(child);

    captured_hooks = .empty;
    defer captured_hooks.deinit(gpa);
    captured_allocator = gpa;
    try root.execute(&.{"child"}, null);

    const expected = [_][]const u8{
        "rootPersistentPre",
        "childPre",
        "childRun",
        "childPost",
        "rootPersistentPost",
    };
    try testing.expectEqual(expected.len, captured_hooks.items.len);
    for (expected, 0..) |want, i| {
        try testing.expectEqualStrings(want, captured_hooks.items[i]);
    }
}

test "Command: args validator rejects too few" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "root",
        .args = args_mod.minimumN(1),
        .run_e = noopRun,
    });
    defer root.deinit();

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.ArgsValidationFailed, root.execute(&.{}, &diag));
    try testing.expectEqualStrings("requires at least 1 arg(s), only received 0", diag.message.?);
}

test "Command: required flag enforcement" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root", .run_e = noopRun });
    defer root.deinit();
    var name: []const u8 = "";
    try root.flags().stringVarP(&name, "name", 'n', "", "");
    try root.markFlagRequired("name");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.RequiredFlagMissing, root.execute(&.{}, &diag));

    try root.execute(&.{ "--name", "alice" }, null);
    try testing.expectEqualStrings("alice", name);
}

// ---- shared test fixtures -----------------------------------------------

var captured_hooks: std.ArrayListUnmanaged([]const u8) = .empty;
var captured_allocator: std.mem.Allocator = undefined;

fn recordHook(comptime label: []const u8) HookFnE {
    return struct {
        fn run(_: *Command, _: []const []const u8) anyerror!void {
            try captured_hooks.append(captured_allocator, label);
        }
    }.run;
}
