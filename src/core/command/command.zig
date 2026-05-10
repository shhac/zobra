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
            .help_flag_value = false,
            .help_flag_initialised = false,
            .version_flag_value = false,
            .version_flag_initialised = false,
            .help_owned_strings = .empty,
        };
        return cmd;
    }

    /// Lazy --help / -h registration. Called at the start of execute on
    /// the resolved command, mirroring cobra's InitDefaultHelpFlag.
    /// Sets `help_flag_initialised` only after every step succeeds, so a
    /// mid-OOM call leaves the command re-tryable next time.
    fn initDefaultHelpFlag(self: *Command) !void {
        if (self.help_flag_initialised) return;
        if (self.flags_set.lookup("help") != null) {
            self.help_flag_initialised = true;
            return;
        }

        var help_msg_buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&help_msg_buf, "help for {s}", .{self.commandName()});

        const owned_msg = try self.allocator.dupe(u8, msg);
        errdefer self.allocator.free(owned_msg);

        // Append to the owned-strings list FIRST so the list takes the
        // free responsibility. If boolVarP then fails, the errdefer-pop
        // detaches the entry and the outer errdefer frees `owned_msg`.
        try self.help_owned_strings.append(self.allocator, owned_msg);
        errdefer _ = self.help_owned_strings.pop();

        const shorthand: u8 = if (self.flags_set.shorthandLookup('h') == null) 'h' else 0;
        try self.flags_set.boolVarP(&self.help_flag_value, "help", shorthand, false, owned_msg);

        self.help_flag_initialised = true;
    }

    /// Lazy --version registration (only when Command.version is non-empty).
    /// cobra binds long-only by default. zobra matches.
    fn initDefaultVersionFlag(self: *Command) !void {
        if (self.version_flag_initialised) return;
        if (self.version.len == 0) {
            self.version_flag_initialised = true;
            return;
        }
        if (self.flags_set.lookup("version") != null) {
            self.version_flag_initialised = true;
            return;
        }

        var buf: [256]u8 = undefined;
        const usage = try std.fmt.bufPrint(&buf, "version for {s}", .{self.commandName()});
        const owned_usage = try self.allocator.dupe(u8, usage);
        errdefer self.allocator.free(owned_usage);

        try self.help_owned_strings.append(self.allocator, owned_usage);
        errdefer _ = self.help_owned_strings.pop();

        try self.flags_set.boolVarP(&self.version_flag_value, "version", 0, false, owned_usage);

        self.version_flag_initialised = true;
    }

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
        return help_mod.helpString(allocator, self);
    }

    /// Render the usage block (no Long description) into an owned slice.
    pub fn usageString(self: *const Command, allocator: Allocator) ![]u8 {
        return help_mod.usageString(allocator, self);
    }

    /// Render help straight to the writer.
    pub fn printHelp(self: *const Command, allocator: Allocator, writer: *std.Io.Writer) !void {
        const text = try self.helpString(allocator);
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

    /// Add a child. **Ownership of `child` transfers to `self`** —
    /// `self.deinit()` will free it; callers must not also call
    /// `child.deinit()`.
    pub fn addCommand(self: *Command, child: *Command) !void {
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

        const pi = firstPositionalArgvIndex(tokens, argv) orelse {
            const dup = try allocator.dupe([]const u8, argv);
            return .{ .cmd = cmd, .remaining = dup };
        };

        const candidate = argv[pi];
        const child = cmd.findChildByNameOrAlias(candidate) orelse {
            const dup = try allocator.dupe([]const u8, argv);
            return .{ .cmd = cmd, .remaining = dup };
        };

        const stripped = try argvWithout(allocator, argv, pi);
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

    /// Render the command's full path (root → ... → self) as a
    /// space-separated string — cobra's Command.CommandPath(). Caller
    /// frees with the same allocator.
    pub fn commandPathString(self: *const Command, allocator: Allocator) ![]u8 {
        var stack: [32]*const Command = undefined;
        var depth: usize = 0;
        var p: ?*const Command = self;
        while (p) |c| : (p = c.parent) {
            stack[depth] = c;
            depth += 1;
            if (depth == stack.len) break;
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

    pub fn executeWith(self: *Command, argv: []const []const u8, opts: ExecuteOptions) !void {
        const allocator = self.allocator;
        const diag = opts.diag;

        const found = self.findCommand(allocator, argv, diag) catch |err| {
            if (diag) |d| try renderParseDiag(allocator, d);
            return err;
        };
        defer allocator.free(found.remaining);
        const cmd = found.cmd;
        const sub_argv = found.remaining;

        try cmd.initDefaultHelpFlag();
        try cmd.initDefaultVersionFlag();

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
            if (diag) |d| try renderParseDiag(allocator, d);
            return err;
        };
        defer allocator.free(tokens);

        self.applyTokens(tokens, diag) catch |err| switch (err) {
            error.UnknownFlag => {
                if (self.allow_unknown_flags) {
                    swallowParseDiag(diag);
                } else {
                    if (!self.disable_suggestions) {
                        if (diag) |d| if (d.flag_name) |name| {
                            try self.attachFlagSuggestion(d, name);
                        };
                    }
                    if (diag) |d| try renderParseDiag(allocator, d);
                    return err;
                }
            },
            error.MissingValue, error.BadFlagSyntax => {
                if (diag) |d| try renderParseDiag(allocator, d);
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
        try self.validateRequiredTogether(diag);
        try self.validateOneRequired(diag);
        try self.validateMutex(diag);
    }

    fn flagChanged(self: *const Command, name: []const u8) bool {
        const f = self.lookupLong(name) orelse return false;
        return f.changed;
    }

    fn validateRequiredTogether(self: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
        for (self.required_together_groups.items) |group| {
            var unset: std.ArrayListUnmanaged([]const u8) = .empty;
            defer unset.deinit(self.allocator);
            var set_count: usize = 0;
            for (group) |name| {
                if (self.flagChanged(name)) {
                    set_count += 1;
                } else {
                    unset.append(self.allocator, name) catch return error.FlagGroupViolation;
                }
            }
            if (set_count == 0 or unset.items.len == 0) continue;
            return failGroup(
                self.allocator,
                diag,
                "if any flags in the group [{group}] are set they must all be set; missing [{names}]",
                group,
                unset.items,
            );
        }
    }

    fn validateOneRequired(self: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
        for (self.one_required_groups.items) |group| {
            var any_set = false;
            for (group) |name| if (self.flagChanged(name)) {
                any_set = true;
                break;
            };
            if (any_set) continue;
            return failGroup(
                self.allocator,
                diag,
                "at least one of the flags in the group [{group}] is required",
                group,
                &.{},
            );
        }
    }

    fn validateMutex(self: *const Command, diag: ?*Diagnostic) errors.FlagError!void {
        for (self.mutex_groups.items) |group| {
            var set: std.ArrayListUnmanaged([]const u8) = .empty;
            defer set.deinit(self.allocator);
            for (group) |name| if (self.flagChanged(name)) {
                set.append(self.allocator, name) catch return error.FlagGroupViolation;
            };
            if (set.items.len <= 1) continue;
            return failGroup(
                self.allocator,
                diag,
                "if any flags in the group [{group}] are set none of the others can be; [{names}] were all set",
                group,
                set.items,
            );
        }
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

/// Return the argv index of the first positional token in `tokens`.
/// Returns null when the token stream has no positional before the
/// first terminator/passthrough (which happens when argv is all flags
/// or the user invoked `--` early). Pure function — testable in
/// isolation against a hand-built token stream.
///
/// Note: this is *not* the same as the position of the first positional
/// token in the token slice. Long/short tokens with a separate-argv
/// value consume two argv slots, so the mapping from token-index to
/// argv-index isn't 1:1. The byte-pointer aliasing in `argvUsedByToken`
/// reconstructs it.
pub fn firstPositionalArgvIndex(tokens: []const Token, argv: []const []const u8) ?usize {
    var pi: usize = 0;
    for (tokens) |t| switch (t) {
        .positional => return pi,
        .terminator, .passthrough => return null,
        .long, .short, .negated => {
            pi += argvUsedByToken(t, argv, pi);
            if (pi > argv.len) return null;
        },
    };
    return null;
}

/// argv slots consumed by a single token at `pi`. Long/short with a
/// SEPARATE-argv value consume 2 (e.g. `--name alice` is two argv
/// slots); attached values (`--name=alice`, `-nalice`) and value-less
/// boolean/count tokens consume 1.
fn argvUsedByToken(t: Token, argv: []const []const u8, pi: usize) usize {
    switch (t) {
        .long => |l| {
            if (l.value) |v| {
                if (pi + 1 < argv.len and slicesAlias(v, argv[pi + 1])) return 2;
            }
            return 1;
        },
        .short => |s| {
            if (s.value) |v| {
                if (pi + 1 < argv.len and slicesAlias(v, argv[pi + 1])) return 2;
            }
            return 1;
        },
        .negated, .positional, .terminator, .passthrough => return 1,
    }
}

/// True iff slice `a` is a sub-range of slice `b` by byte address.
/// Used to detect "did this token's value come from the next argv
/// element?" — if v aliases argv[pi+1], the parser consumed it.
fn slicesAlias(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    const b_end = b_start + b.len;
    return a_start >= b_start and a_start < b_end;
}

/// Allocate a fresh argv slice equal to `argv` minus the element at
/// `idx`. Caller frees with the same allocator.
fn argvWithout(allocator: Allocator, argv: []const []const u8, idx: usize) ![]const []const u8 {
    std.debug.assert(idx < argv.len);
    const out = try allocator.alloc([]const u8, argv.len - 1);
    var j: usize = 0;
    for (argv, 0..) |a, i| {
        if (i == idx) continue;
        out[j] = a;
        j += 1;
    }
    return out;
}

/// Reset the parse-layer fields on a Diagnostic. Used by
/// `allow_unknown_flags`: the apply layer filled the diagnostic before
/// raising UnknownFlag; the swallow path needs to clear it so a
/// downstream check (validateRequiredFlags, etc.) doesn't see stale
/// state.
fn swallowParseDiag(diag: ?*Diagnostic) void {
    if (diag) |d| {
        d.category = null;
        d.code = null;
        d.flag_name = null;
        d.raw = null;
        d.short_group = null;
    }
}

/// Render pflag-byte-identical wording for parse-layer errors. The
/// design (07-error-model.md) puts this in command.zig deliberately —
/// the parser/flag layers stay layering-clean and write only the
/// structured fields (flag_name, raw, code) to the diagnostic; this
/// helper composes the human-readable rendering on the way out.
///
/// Wordings (matching pflag):
///   unknown flag: --foo
///   unknown shorthand flag: "X" in -group
///   flag needs an argument: --foo
///   flag needs an argument: "X" in -group
///   bad flag syntax: <full argv element>
fn renderParseDiag(allocator: Allocator, diag: *Diagnostic) !void {
    if (diag.message != null) return;
    const code = diag.code orelse return;
    const rendered: []u8 = switch (code) {
        .unknown_flag => blk: {
            if (diag.short_group) |group| {
                const name = diag.flag_name orelse return;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "unknown shorthand flag: \"{s}\" in -{s}",
                    .{ name, group },
                );
            }
            const name = diag.flag_name orelse return;
            break :blk try std.fmt.allocPrint(allocator, "unknown flag: --{s}", .{name});
        },
        .missing_value => blk: {
            if (diag.short_group) |group| {
                const name = diag.flag_name orelse return;
                break :blk try std.fmt.allocPrint(
                    allocator,
                    "flag needs an argument: \"{s}\" in -{s}",
                    .{ name, group },
                );
            }
            const name = diag.flag_name orelse return;
            break :blk try std.fmt.allocPrint(allocator, "flag needs an argument: --{s}", .{name});
        },
        .bad_flag_syntax => blk: {
            const raw = diag.raw orelse return;
            break :blk try std.fmt.allocPrint(allocator, "bad flag syntax: {s}", .{raw});
        },
        else => return,
    };
    diag.message = rendered;
    diag.owns_message = true;
}

// ---- private helpers ----------------------------------------------------

/// Render a flag-group violation message and stash it on the diagnostic.
/// Format mirrors cobra's `[a b c]` (space-separated, square-bracketed).
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

    // Sort for deterministic output (cobra also sorts).
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
    // Tiny one-pass replace of {group} and {names}.
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

    const found = try root.findCommand(gpa, &.{ "greet", "alice" }, null);
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

    const found = try root.findCommand(gpa, &.{"ls"}, null);
    defer gpa.free(found.remaining);
    try testing.expectEqualStrings("list", found.cmd.commandName());
    try testing.expectEqual(@as(usize, 0), found.remaining.len);
}

test "Command: findCommand falls back to self when no child matches" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "root" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet" }));

    const found = try root.findCommand(gpa, &.{ "stranger", "alice" }, null);
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

test "Command: noArgs at depth includes command path in wording" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    const child = try Command.init(gpa, .{
        .use = "greet",
        .args = args_mod.noArgs,
        .run_e = noopRun,
    });
    try root.addCommand(child);

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.ArgsValidationFailed, root.execute(&.{ "greet", "extra" }, &diag));
    try testing.expectEqualStrings("unknown command \"extra\" for \"tool greet\"", diag.message.?);
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

test "Command: --help prints help to provided writer" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "tool",
        .short = "a tool",
        .run_e = noopRun,
    });
    defer root.deinit();
    var name: []const u8 = "world";
    try root.flags().stringVarP(&name, "name", 'n', "world", "who to greet");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{"--help"}, .{ .out_writer = &aw.writer });

    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "Usage:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "  -n, --name string") != null);
    // run shouldn't have fired (name still default).
    try testing.expectEqualStrings("world", name);
}

test "Command: --help with no out_writer returns HelpRequested" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    try testing.expectError(error.HelpRequested, root.execute(&.{"--help"}, null));
}

test "Command: -h shorthand triggers help" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{"-h"}, .{ .out_writer = &aw.writer });
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "Usage:") != null);
}

test "Command: markFlagsMutuallyExclusive errors if both set" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var a: bool = false;
    var b: bool = false;
    try root.flags().boolVarP(&a, "json", 0, false, "");
    try root.flags().boolVarP(&b, "yaml", 0, false, "");
    try root.markFlagsMutuallyExclusive(&.{ "json", "yaml" });

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.FlagGroupViolation, root.execute(&.{ "--json", "--yaml" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "if any flags in the group [json yaml] are set none of the others can be") != null);

    // Setting just one is fine.
    var a2: bool = false;
    var b2: bool = false;
    const root2 = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root2.deinit();
    try root2.flags().boolVarP(&a2, "json", 0, false, "");
    try root2.flags().boolVarP(&b2, "yaml", 0, false, "");
    try root2.markFlagsMutuallyExclusive(&.{ "json", "yaml" });
    try root2.execute(&.{"--json"}, null);
}

test "Command: markFlagsRequiredTogether errors on partial set" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var u: []const u8 = "";
    var p: []const u8 = "";
    try root.flags().stringVarP(&u, "user", 0, "", "");
    try root.flags().stringVarP(&p, "password", 0, "", "");
    try root.markFlagsRequiredTogether(&.{ "user", "password" });

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.FlagGroupViolation, root.execute(&.{ "--user", "alice" }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "if any flags in the group [password user] are set they must all be set; missing [password]") != null);

    // Both set is fine.
    const root2 = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root2.deinit();
    var user2: []const u8 = "";
    var pass2: []const u8 = "";
    try root2.flags().stringVarP(&user2, "user", 0, "", "");
    try root2.flags().stringVarP(&pass2, "password", 0, "", "");
    try root2.markFlagsRequiredTogether(&.{ "user", "password" });
    try root2.execute(&.{ "--user", "alice", "--password", "secret" }, null);
}

test "Command: markFlagsOneRequired errors when none set" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();

    var a: bool = false;
    var b: bool = false;
    try root.flags().boolVarP(&a, "json", 0, false, "");
    try root.flags().boolVarP(&b, "yaml", 0, false, "");
    try root.markFlagsOneRequired(&.{ "json", "yaml" });

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.FlagGroupViolation, root.execute(&.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "at least one of the flags in the group [json yaml] is required") != null);
}

test "Command: --version prints version banner" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .version = "1.2.3", .run_e = noopRun });
    defer root.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{"--version"}, .{ .out_writer = &aw.writer });
    try testing.expectEqualStrings("tool version 1.2.3\n", aw.writer.buffered());
}

test "Command: --version with no out_writer returns VersionRequested" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .version = "9.9", .run_e = noopRun });
    defer root.deinit();
    try testing.expectError(error.VersionRequested, root.execute(&.{"--version"}, null));
}

test "Command: disable_flag_parsing passes argv through verbatim" {
    const gpa = testing.allocator;
    const RunCtx = struct {
        var captured_args: ?[]const []const u8 = null;
        fn run(_: *Command, args: []const []const u8) anyerror!void {
            captured_args = args;
        }
    };

    const root = try Command.init(gpa, .{
        .use = "proxy",
        .disable_flag_parsing = true,
        .run_e = RunCtx.run,
    });
    defer root.deinit();
    try root.execute(&.{ "--unknown=foo", "-x", "--bar" }, null);
    try testing.expect(RunCtx.captured_args.?.len == 3);
    try testing.expectEqualStrings("--unknown=foo", RunCtx.captured_args.?[0]);
}

test "Command: allow_unknown_flags swallows unknowns" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{
        .use = "tool",
        .allow_unknown_flags = true,
        .run_e = noopRun,
    });
    defer root.deinit();
    var n: i64 = 0;
    try root.flags().intVarP(&n, "count", 0, 0, "");
    try root.execute(&.{ "--count=5", "--mystery=zzz" }, null);
    try testing.expectEqual(@as(i64, 5), n);
}

test "firstPositionalArgvIndex: empty argv returns null" {
    const tokens: []const Token = &.{};
    try testing.expect(firstPositionalArgvIndex(tokens, &.{}) == null);
}

test "firstPositionalArgvIndex: leading positional" {
    const tokens: []const Token = &.{.{ .positional = .{ .value = "x" } }};
    try testing.expectEqual(@as(?usize, 0), firstPositionalArgvIndex(tokens, &.{"x"}));
}

test "firstPositionalArgvIndex: long with attached value, then positional" {
    // argv: ["--name=alice", "greet"] → tokens: long(name="alice"), positional("greet")
    // attached value, so long consumes 1 argv slot. positional is at idx 1.
    const argv: []const []const u8 = &.{ "--name=alice", "greet" };
    const tokens: []const Token = &.{
        .{ .long = .{ .name = "name", .value = argv[0][7..], .raw = argv[0] } },
        .{ .positional = .{ .value = argv[1] } },
    };
    try testing.expectEqual(@as(?usize, 1), firstPositionalArgvIndex(tokens, argv));
}

test "firstPositionalArgvIndex: long with separate-argv value consumes 2 slots" {
    // argv: ["--name", "alice", "greet"] → tokens: long(value=argv[1]), positional(argv[2])
    const argv: []const []const u8 = &.{ "--name", "alice", "greet" };
    const tokens: []const Token = &.{
        .{ .long = .{ .name = "name", .value = argv[1], .raw = argv[0] } },
        .{ .positional = .{ .value = argv[2] } },
    };
    try testing.expectEqual(@as(?usize, 2), firstPositionalArgvIndex(tokens, argv));
}

test "firstPositionalArgvIndex: terminator stops the search" {
    const argv: []const []const u8 = &.{ "--", "x" };
    const tokens: []const Token = &.{
        .terminator,
        .{ .passthrough = "x" },
    };
    try testing.expect(firstPositionalArgvIndex(tokens, argv) == null);
}

test "argvWithout: drops the indexed element" {
    const gpa = testing.allocator;
    const argv: []const []const u8 = &.{ "a", "b", "c" };
    const out = try argvWithout(gpa, argv, 1);
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("c", out[1]);
}

test "Command: did-you-mean suggestion on close-by flag" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var name: []const u8 = "";
    try root.flags().stringVarP(&name, "name", 'n', "", "");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.UnknownFlag, root.execute(&.{ "--nmae", "x" }, &diag));
    try testing.expect(diag.suggestion != null);
    try testing.expectEqualStrings("did you mean --name?", diag.suggestion.?);
    // pflag-style wording is now rendered automatically.
    try testing.expectEqualStrings("unknown flag: --nmae", diag.message.?);
}

test "Command: unknown shorthand renders pflag wording with the group suffix" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
    defer root.deinit();
    var a: bool = false;
    try root.flags().boolVarP(&a, "alpha", 'a', false, "");

    var d: Diagnostic = .{};
    defer d.deinit(gpa);
    // -axyz: 'a' binds, then 'x' is unknown. cobra's wording uses the
    // remaining shorthands ("xyz") with the leading dash.
    try testing.expectError(error.UnknownFlag, root.execute(&.{"-axyz"}, &d));
    try testing.expectEqualStrings("unknown shorthand flag: \"x\" in -xyz", d.message.?);
}

test "Command: hook chain — first persistent ancestor wins (non-traverse)" {
    // Validator finding #14: regression coverage. With BOTH root and
    // child setting persistent_pre_run_e, only the child's fires under
    // the default (non-traverse) mode.
    const gpa = testing.allocator;
    const Hooks = struct {
        var fires: std.ArrayListUnmanaged([]const u8) = .empty;
        var alloc: std.mem.Allocator = undefined;
        fn rootHook(_: *Command, _: []const []const u8) anyerror!void {
            try fires.append(alloc, "root");
        }
        fn childHook(_: *Command, _: []const []const u8) anyerror!void {
            try fires.append(alloc, "child");
        }
    };
    Hooks.fires = .empty;
    Hooks.alloc = gpa;
    defer Hooks.fires.deinit(gpa);

    const root = try Command.init(gpa, .{ .use = "root", .persistent_pre_run_e = Hooks.rootHook });
    defer root.deinit();
    const child = try Command.init(gpa, .{
        .use = "child",
        .persistent_pre_run_e = Hooks.childHook,
        .run_e = noopRun,
    });
    try root.addCommand(child);
    try root.execute(&.{"child"}, null);

    try testing.expectEqual(@as(usize, 1), Hooks.fires.items.len);
    try testing.expectEqualStrings("child", Hooks.fires.items[0]);
}

test "Command: parse error wordings render onto diag.message" {
    const gpa = testing.allocator;

    {
        const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
        defer root.deinit();
        var n: i64 = 0;
        try root.flags().intVarP(&n, "retries", 0, 0, "");
        var d: Diagnostic = .{};
        defer d.deinit(gpa);
        try testing.expectError(error.MissingValue, root.execute(&.{"--retries"}, &d));
        try testing.expectEqualStrings("flag needs an argument: --retries", d.message.?);
    }

    {
        const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
        defer root.deinit();
        var d: Diagnostic = .{};
        defer d.deinit(gpa);
        try testing.expectError(error.BadFlagSyntax, root.execute(&.{"---bad"}, &d));
        try testing.expectEqualStrings("bad flag syntax: ---bad", d.message.?);
    }

    // Type-coercion error wording now includes the shorthand prefix.
    {
        const root = try Command.init(gpa, .{ .use = "tool", .run_e = noopRun });
        defer root.deinit();
        var n: i64 = 0;
        try root.flags().intVarP(&n, "retries", 'r', 0, "");
        var d: Diagnostic = .{};
        defer d.deinit(gpa);
        try testing.expectError(error.TypeCoercionFailed, root.execute(&.{"--retries=foo"}, &d));
        try testing.expectEqualStrings(
            "invalid argument \"foo\" for \"-r, --retries\" flag: strconv.ParseInt: parsing \"foo\": invalid syntax",
            d.message.?,
        );
    }
}

test "Command: suggestionsForCommand returns close subcommands" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool" });
    defer root.deinit();
    try root.addCommand(try Command.init(gpa, .{ .use = "greet", .run_e = noopRun }));
    try root.addCommand(try Command.init(gpa, .{ .use = "list", .run_e = noopRun }));

    const out = try root.suggestionsForCommand(gpa, "lst");
    defer gpa.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("list", out[0]);
}

test "Command: command without run prints help even without --help" {
    const gpa = testing.allocator;
    const root = try Command.init(gpa, .{ .use = "tool", .short = "no run defined" });
    defer root.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.executeWith(&.{}, .{ .out_writer = &aw.writer });
    try testing.expect(std.mem.indexOf(u8, aw.writer.buffered(), "Usage:") != null);
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
