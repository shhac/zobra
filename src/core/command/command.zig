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
const suggest_mod = @import("suggest.zig");
const groups_mod = @import("groups.zig");
const defaults_mod = @import("defaults.zig");
const argv_mod = @import("argv.zig");
const parse_diag = @import("parse_diag.zig");
const help_mod = @import("../help/help.zig");

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
    suggest_for: []const []const u8 = &.{},
    disable_suggestions: bool = false,
    suggestions_minimum_distance: usize = 2,
    /// Auto-injects `--version` (long-only; no shorthand auto-binding).
    /// Empty means no version flag.
    version: []const u8 = "",
    /// Skip flag parsing entirely; pass argv to the command verbatim.
    /// Used for proxy commands.
    disable_flag_parsing: bool = false,
    /// Allow unknown flags through without raising UnknownFlag. The flag
    /// (and its value, if value-looking) is silently dropped from
    /// post-apply positionals.
    allow_unknown_flags: bool = false,
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
    suggest_for: []const []const u8,
    disable_suggestions: bool,
    suggestions_minimum_distance: usize,
    version: []const u8,
    disable_flag_parsing: bool,
    allow_unknown_flags: bool,
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

    /// Flag groups, validated post-apply. Each group is a list of flag
    /// names; the list slice itself is owned by the Command (duped on
    /// registration), but each name inside is borrowed from the caller.
    required_together_groups: std.ArrayListUnmanaged([]const []const u8),
    one_required_groups: std.ArrayListUnmanaged([]const []const u8),
    mutex_groups: std.ArrayListUnmanaged([]const []const u8),

    /// Caller-bindable context pointer (analogue to cobra's SetContext).
    /// Used by hooks to retrieve user state. Borrow-only; the user owns
    /// whatever it points to.
    context: ?*anyopaque,

    /// Default writers (cobra's SetOut / SetErr). When `executeAndPrint`
    /// catches an error or the help/version path needs to render, the
    /// effective writers are looked up via outWriter() / errWriter()
    /// which walk the parent chain. Default behaviour with both null:
    /// help goes to opts.out_writer (per executeWith); errors via
    /// executeAndPrint propagate without printing. Setting at root is
    /// the typical pattern.
    out_writer: ?*std.Io.Writer,
    err_writer: ?*std.Io.Writer,

    /// Optional override for help / usage rendering. When set, replaces
    /// the procedural composer in src/core/help/help.zig. Mirrors
    /// cobra's SetHelpFunc / SetUsageFunc (function-form, not the Go
    /// text/template form which we don't ship).
    help_fn: ?*const fn (cmd: *const Command, w: *std.Io.Writer) anyerror!void,
    usage_fn: ?*const fn (cmd: *const Command, w: *std.Io.Writer) anyerror!void,

    /// Marker: the auto-injected `help` subcommand that lazy-registers
    /// at executeAndPrint time. Tracked so we don't re-register and so
    /// the auto-help command doesn't recurse if a user manually adds one.
    help_subcommand_initialised: bool,

    /// Storage for the auto-injected --help flag's value. Per-command;
    /// cobra calls this lazily in execute (`InitDefaultHelpFlag`). We do
    /// the same in `execute()`. False until the user passes --help / -h.
    help_flag_value: bool,
    help_flag_initialised: bool,
    /// Storage for the auto-injected --version flag (set when version is
    /// non-empty). Lazily registered on first execute, like cobra.
    version_flag_value: bool,
    version_flag_initialised: bool,
    /// Owned strings the auto-help machinery had to allocate (e.g. the
    /// `help for X` usage string). Freed on deinit.
    help_owned_strings: std.ArrayListUnmanaged([]const u8),

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
            .suggest_for = opts.suggest_for,
            .disable_suggestions = opts.disable_suggestions,
            .suggestions_minimum_distance = opts.suggestions_minimum_distance,
            .version = opts.version,
            .disable_flag_parsing = opts.disable_flag_parsing,
            .allow_unknown_flags = opts.allow_unknown_flags,
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
            .required_together_groups = .empty,
            .one_required_groups = .empty,
            .mutex_groups = .empty,
            .context = null,
            .out_writer = null,
            .err_writer = null,
            .help_fn = null,
            .usage_fn = null,
            .help_subcommand_initialised = false,
            .help_flag_value = false,
            .help_flag_initialised = false,
            .version_flag_value = false,
            .version_flag_initialised = false,
            .help_owned_strings = .empty,
        };
        return cmd;
    }

    // Lazy auto-init for the cobra-default `--help` flag, `--version`
    // flag, and `help [command]` subcommand lives in `defaults.zig`.
    // The `executeWith` path calls `defaults_mod.init*` directly.

    /// Recursively frees this command's children, both flag sets, the
    /// children list, and the Command itself.
    pub fn deinit(self: *Command) void {
        for (self.children.items) |child| child.deinit();
        self.children.deinit(self.allocator);
        for (self.help_owned_strings.items) |s| self.allocator.free(s);
        self.help_owned_strings.deinit(self.allocator);
        for (self.required_together_groups.items) |g| self.allocator.free(g);
        self.required_together_groups.deinit(self.allocator);
        for (self.one_required_groups.items) |g| self.allocator.free(g);
        self.one_required_groups.deinit(self.allocator);
        for (self.mutex_groups.items) |g| self.allocator.free(g);
        self.mutex_groups.deinit(self.allocator);
        self.flags_set.deinit();
        self.persistent_flags_set.deinit();
        self.allocator.destroy(self);
    }

    /// Render this command's help block into an owned slice. Caller frees.
    pub fn helpString(self: *const Command, allocator: Allocator) ![]u8 {
        if (self.help_fn) |fn_ptr| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try fn_ptr(self, &aw.writer);
            return aw.toOwnedSlice();
        }
        return help_mod.helpString(allocator, self);
    }

    /// Render the usage block (no Long description) into an owned slice.
    pub fn usageString(self: *const Command, allocator: Allocator) ![]u8 {
        if (self.usage_fn) |fn_ptr| {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            try fn_ptr(self, &aw.writer);
            return aw.toOwnedSlice();
        }
        return help_mod.usageString(allocator, self);
    }

    /// Render help straight to the writer.
    pub fn printHelp(self: *const Command, allocator: Allocator, writer: *std.Io.Writer) !void {
        if (self.help_fn) |fn_ptr| return fn_ptr(self, writer);
        const text = try help_mod.helpString(allocator, self);
        defer allocator.free(text);
        try writer.writeAll(text);
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

    /// cobra's Command.SetOut — store the writer that help / version
    /// output goes to when executeWith doesn't override via opts. Borrow-
    /// only; the user owns the writer's lifetime.
    pub fn setOut(self: *Command, w: *std.Io.Writer) void {
        self.out_writer = w;
    }

    /// cobra's Command.SetErr — store the writer that auto-printed
    /// errors go to from `executeAndPrint`. Borrow-only.
    pub fn setErr(self: *Command, w: *std.Io.Writer) void {
        self.err_writer = w;
    }

    /// Walk the parent chain for the first non-null `out_writer`. Cobra
    /// users typically setOut at root only; descendants inherit.
    pub fn outWriter(self: *const Command) ?*std.Io.Writer {
        var p: ?*const Command = self;
        while (p) |c| : (p = c.parent) {
            if (c.out_writer) |w| return w;
        }
        return null;
    }

    pub fn errWriter(self: *const Command) ?*std.Io.Writer {
        var p: ?*const Command = self;
        while (p) |c| : (p = c.parent) {
            if (c.err_writer) |w| return w;
        }
        return null;
    }

    /// cobra's Command.SetHelpFunc — install a function-form help
    /// renderer that overrides the default composer. The fn receives
    /// the command being help'd and a writer to drive.
    pub fn setHelpFunc(self: *Command, fn_ptr: *const fn (cmd: *const Command, w: *std.Io.Writer) anyerror!void) void {
        self.help_fn = fn_ptr;
    }

    pub fn setUsageFunc(self: *Command, fn_ptr: *const fn (cmd: *const Command, w: *std.Io.Writer) anyerror!void) void {
        self.usage_fn = fn_ptr;
    }

    pub const AddCommandError = error{
        AlreadyParented,
        SelfParent,
    } || std.mem.Allocator.Error;

    /// Add a child. **Ownership of `child` transfers to `self`** —
    /// `self.deinit()` will free it; callers must not also call
    /// `child.deinit()`. Rejects two memory-safety hazards cobra-Go
    /// happens to absorb via GC:
    ///   - `child.parent != null` (already in another tree) — would
    ///     cause double-free on deinit.
    ///   - `child == self` — would create a cycle and infinite-loop the
    ///     deinit walk.
    pub fn addCommand(self: *Command, child: *Command) AddCommandError!void {
        if (child == self) return error.SelfParent;
        if (child.parent != null) return error.AlreadyParented;
        try self.children.append(self.allocator, child);
        child.parent = self;
    }

    /// Mark a set of flags as required-together. cobra raises an error if
    /// the user passes some but not all of them.
    pub fn markFlagsRequiredTogether(self: *Command, names: []const []const u8) !void {
        try self.assertAllRegistered(names);
        const dup = try self.allocator.dupe([]const u8, names);
        errdefer self.allocator.free(dup);
        try self.required_together_groups.append(self.allocator, dup);
    }

    /// Mark a set of flags so that at least one must be set.
    pub fn markFlagsOneRequired(self: *Command, names: []const []const u8) !void {
        try self.assertAllRegistered(names);
        const dup = try self.allocator.dupe([]const u8, names);
        errdefer self.allocator.free(dup);
        try self.one_required_groups.append(self.allocator, dup);
    }

    /// Mark a set of flags as mutually exclusive — at most one may be set.
    pub fn markFlagsMutuallyExclusive(self: *Command, names: []const []const u8) !void {
        try self.assertAllRegistered(names);
        const dup = try self.allocator.dupe([]const u8, names);
        errdefer self.allocator.free(dup);
        try self.mutex_groups.append(self.allocator, dup);
    }

    fn assertAllRegistered(self: *const Command, names: []const []const u8) error{FlagNotFound}!void {
        for (names) |n| {
            if (self.lookupLong(n) == null) return error.FlagNotFound;
        }
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
    pub fn findCommand(self: *Command, allocator: Allocator, argv: []const []const u8, diag: ?*Diagnostic) !FoundCommand {
        return findRec(self, allocator, argv, diag);
    }

    fn findRec(cmd: *Command, allocator: Allocator, argv: []const []const u8, diag: ?*Diagnostic) !FoundCommand {
        const tokens = try parser_mod.parse(allocator, argv, cmd.effectiveFlagSchema(), diag);
        defer allocator.free(tokens);

        const pi = argv_mod.firstPositionalArgvIndex(tokens, argv) orelse {
            const dup = try allocator.dupe([]const u8, argv);
            return .{ .cmd = cmd, .remaining = dup };
        };

        const candidate = argv[pi];
        const child = cmd.findChildByNameOrAlias(candidate) orelse {
            const dup = try allocator.dupe([]const u8, argv);
            return .{ .cmd = cmd, .remaining = dup };
        };

        const stripped = try argv_mod.argvWithout(allocator, argv, pi);
        defer allocator.free(stripped);
        return findRec(child, allocator, stripped, diag);
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

    /// Public accessor for `flags_set.args_len_at_dash` — cobra's
    /// `Command.ArgsLenAtDash`. Returns the number of positional args
    /// before the `--` terminator, or null if no `--` was seen. Used by
    /// hooks that want to distinguish positionals-before-`--` from
    /// passthrough-after for forwarding patterns like `tool args -- subcmd-args`.
    pub fn argsLenAtDash(self: *const Command) ?usize {
        return self.flags_set.args_len_at_dash;
    }

    /// Render the command's full path (root → ... → self) as a
    /// space-separated string — cobra's Command.CommandPath(). Caller
    /// frees with the same allocator. Asserts depth < 32; pathological
    /// trees are rejected loudly rather than silently truncated.
    pub fn commandPathString(self: *const Command, allocator: Allocator) ![]u8 {
        var stack: [32]*const Command = undefined;
        var depth: usize = 0;
        var p: ?*const Command = self;
        while (p) |c| : (p = c.parent) {
            std.debug.assert(depth < stack.len);
            stack[depth] = c;
            depth += 1;
        }
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        var i = depth;
        var first = true;
        while (i > 0) {
            i -= 1;
            if (!first) try aw.writer.writeByte(' ');
            try aw.writer.writeAll(stack[i].commandName());
            first = false;
        }
        return aw.toOwnedSlice();
    }

    // ---- execute ------------------------------------------------------

    pub const ExecuteOptions = struct {
        diag: ?*Diagnostic = null,
        /// Optional writer for help output. When --help is parsed (or the
        /// command isn't runnable) execute writes the help block here and
        /// returns successfully. When null, execute returns
        /// `error.HelpRequested` instead, leaving rendering to the caller.
        out_writer: ?*std.Io.Writer = null,
    };

    /// Resolve subcommand, parse flags, validate args, run hook chain.
    /// `argv` should NOT include the program name (cobra's convention).
    /// Convenience wrapper for the common "I just want to run with a
    /// diagnostic" call.
    pub fn execute(self: *Command, argv: []const []const u8, diag: ?*Diagnostic) !void {
        return self.executeWith(argv, .{ .diag = diag });
    }

    /// cobra's Command.Execute — wraps `executeWith` with the
    /// auto-print-on-error behaviour: when execution fails AND
    /// silence_errors is false, prints `Error: <msg>\n` to err_writer;
    /// when silence_usage is also false, prints the resolved command's
    /// usage block. Returns the error (the caller decides whether to
    /// exit non-zero).
    ///
    /// Mirrors cobra's `*FlagSet.errorHandling = ContinueOnError`
    /// behaviour where the error-propagation is decoupled from the
    /// printing — zobra always returns errors; auto-print is what
    /// distinguishes executeAndPrint from execute / executeWith.
    pub fn executeAndPrint(self: *Command, argv: []const []const u8) !void {
        var diag: Diagnostic = .{};
        defer diag.deinit(self.allocator);

        self.executeWith(argv, .{
            .diag = &diag,
            .out_writer = self.outWriter(),
        }) catch |err| {
            if (err == error.HelpRequested or err == error.VersionRequested) return err;
            try self.printErrorAndUsage(err, &diag);
            return err;
        };
    }

    fn printErrorAndUsage(self: *Command, err: anyerror, diag: *Diagnostic) !void {
        const w = self.errWriter() orelse return;
        if (!self.silence_errors) {
            const msg = if (diag.message) |m| m else @errorName(err);
            try w.print("Error: {s}\n", .{msg});
        }
        if (!self.silence_usage) {
            // Find the command that the error happened at so we print
            // its usage (not the root's, if a deeper failure).
            const usage_target = if (self.findCommand(self.allocator, &.{}, null)) |found| blk: {
                self.allocator.free(found.remaining);
                break :blk found.cmd;
            } else |_| self;
            const usage = try usage_target.usageString(self.allocator);
            defer self.allocator.free(usage);
            try w.writeAll(usage);
        }
    }

    pub fn executeWith(self: *Command, argv: []const []const u8, opts: ExecuteOptions) !void {
        const allocator = self.allocator;
        const diag = opts.diag;

        // Register the lazy `help [command]` subcommand BEFORE
        // findCommand so the help-path resolves correctly.
        try defaults_mod.initHelpCommand(self);

        const found = self.findCommand(allocator, argv, diag) catch |err| {
            if (diag) |d| try parse_diag.render(allocator, d);
            return err;
        };
        defer allocator.free(found.remaining);
        const cmd = found.cmd;
        const sub_argv = found.remaining;

        try defaults_mod.initHelpFlag(cmd);
        try defaults_mod.initVersionFlag(cmd);

        if (cmd.disable_flag_parsing) return cmd.runDisabledFlagParsing(sub_argv, opts);

        try cmd.parseAndApply(sub_argv, diag);

        if (try cmd.dispatchTerminalFlags(opts)) return;
        try cmd.runValidatedHookChain(diag);
    }

    /// `disable_flag_parsing` short-circuit: pass argv to args validators
    /// + Run hooks verbatim (no flag parsing). Mirrors cobra's
    /// DisableFlagParsing branch in command.go:964.
    fn runDisabledFlagParsing(self: *Command, sub_argv: []const []const u8, opts: ExecuteOptions) !void {
        const allocator = self.allocator;
        for (sub_argv) |s| try self.flags_set.args.append(allocator, s);
        const positionals = self.flags_set.args.items;
        if (self.args) |validator| {
            const path = try self.commandPathString(allocator);
            defer allocator.free(path);
            try validator.validate(self.valid_args, positionals, path, allocator, opts.diag);
        }
        try hook_mod.run(Command, self, positionals, false);
    }

    /// Parse argv into tokens and apply them to the effective flag set.
    /// Renders pflag-byte-identical wording onto `diag` for any failure
    /// in the parse or apply layer. `allow_unknown_flags` swallows
    /// UnknownFlag errors; everything else propagates after rendering.
    fn parseAndApply(self: *Command, sub_argv: []const []const u8, diag: ?*Diagnostic) !void {
        const allocator = self.allocator;
        const tokens = parser_mod.parse(allocator, sub_argv, self.effectiveFlagSchema(), diag) catch |err| {
            if (diag) |d| try parse_diag.render(allocator, d);
            return err;
        };
        defer allocator.free(tokens);

        self.applyTokens(tokens, diag) catch |err| switch (err) {
            error.UnknownFlag => {
                if (self.allow_unknown_flags) {
                    parse_diag.swallow(diag);
                } else {
                    if (!self.disable_suggestions) {
                        if (diag) |d| if (d.flag_name) |name| {
                            try self.attachFlagSuggestion(d, name);
                        };
                    }
                    if (diag) |d| try parse_diag.render(allocator, d);
                    return err;
                }
            },
            error.MissingValue, error.BadFlagSyntax => {
                if (diag) |d| try parse_diag.render(allocator, d);
                return err;
            },
            else => return err,
        };
    }

    /// `--version` and `--help` dispatch. Returns true when one fired
    /// (caller should stop); returns false otherwise.
    fn dispatchTerminalFlags(self: *Command, opts: ExecuteOptions) !bool {
        if (self.version_flag_value and self.version.len > 0) {
            if (opts.out_writer) |w| {
                try w.print("{s} version {s}\n", .{ self.commandName(), self.version });
                return true;
            }
            return error.VersionRequested;
        }
        if (self.help_flag_value or (self.run_e == null and self.run == null)) {
            if (opts.out_writer) |w| {
                try self.printHelp(self.allocator, w);
                return true;
            }
            return error.HelpRequested;
        }
        return false;
    }

    /// Tail of the happy-path: validate args, validate required flags,
    /// validate flag groups, run the hook chain.
    fn runValidatedHookChain(self: *Command, diag: ?*Diagnostic) !void {
        const allocator = self.allocator;
        const positionals = self.flags_set.args.items;
        if (self.args) |validator| {
            const path = try self.commandPathString(allocator);
            defer allocator.free(path);
            try validator.validate(self.valid_args, positionals, path, allocator, diag);
        }
        try self.validateRequiredFlags(diag);
        try self.validateFlagGroups(diag);
        try hook_mod.run(Command, self, positionals, false);
    }

    /// Compute "did you mean?" suggestions for an unknown subcommand name.
    /// Walks own children plus their `suggest_for` aliases. Returns an
    /// owned slice of names (caller frees).
    pub fn suggestionsForCommand(self: *const Command, allocator: Allocator, typed: []const u8) ![]const []const u8 {
        if (self.disable_suggestions) return allocator.alloc([]const u8, 0);
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer out.deinit(allocator);

        for (self.children.items) |c| {
            if (c.hidden) continue;
            const d = try suggest_mod.distance(allocator, typed, c.commandName(), true);
            const by_lev = d <= self.suggestions_minimum_distance;
            const by_prefix = std.ascii.startsWithIgnoreCase(c.commandName(), typed);
            if (by_lev or by_prefix) {
                try out.append(allocator, c.commandName());
                continue;
            }
            for (c.suggest_for) |alias| {
                if (std.ascii.eqlIgnoreCase(alias, typed)) {
                    try out.append(allocator, c.commandName());
                    break;
                }
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn attachFlagSuggestion(self: *const Command, diag: *Diagnostic, typed: []const u8) !void {
        var best: ?[]const u8 = null;
        var best_d: usize = self.suggestions_minimum_distance + 1;
        const allocator = self.allocator;
        try walkFlagsForSuggestion(self, allocator, typed, &best, &best_d);
        if (best) |b| {
            const owned = try std.fmt.allocPrint(allocator, "did you mean --{s}?", .{b});
            diag.setOwnedSuggestion(allocator, owned);
        }
    }

    fn validateFlagGroups(self: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
        return groups_mod.validate(self, diag);
    }

    fn applyTokens(
        self: *Command,
        tokens: []const Token,
        diag: ?*Diagnostic,
    ) (errors.ParseError || errors.FlagError || std.mem.Allocator.Error)!void {
        return flag_mod.applyTokensWith(
            &self.flags_set,
            self,
            EffectiveApplyCallbacks.lookupLong,
            EffectiveApplyCallbacks.lookupShort,
            tokens,
            diag,
        );
    }

    /// Lookup callbacks used by the shared apply loop. The Command path
    /// walks own flags + inherited persistent flags via lookupLong /
    /// lookupShort.
    const EffectiveApplyCallbacks = struct {
        fn lookupLong(ctx: *const anyopaque, name: []const u8) ?*flag_mod.Flag {
            const cmd: *const Command = @ptrCast(@alignCast(ctx));
            return cmd.lookupLong(name);
        }
        fn lookupShort(ctx: *const anyopaque, c: u8) ?*flag_mod.Flag {
            const cmd: *const Command = @ptrCast(@alignCast(ctx));
            return cmd.lookupShort(c);
        }
    };

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

fn walkFlagsForSuggestion(
    cmd: *const Command,
    allocator: Allocator,
    typed: []const u8,
    best: *?[]const u8,
    best_d: *usize,
) !void {
    for (cmd.flags_set.ordered.items) |flag| {
        const d = try suggest_mod.distance(allocator, typed, flag.name, true);
        if (d < best_d.*) {
            best_d.* = d;
            best.* = flag.name;
        }
    }
    var p = cmd.parent;
    while (p) |up| : (p = up.parent) {
        for (up.persistent_flags_set.ordered.items) |flag| {
            const d = try suggest_mod.distance(allocator, typed, flag.name, true);
            if (d < best_d.*) {
                best_d.* = d;
                best.* = flag.name;
            }
        }
    }
}
