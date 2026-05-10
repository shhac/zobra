//! Five-stage lifecycle hook chain dispatcher.
//!
//! cobra's hook order (command.go:905+): for the resolved command `c`,
//!   1. Walk parents from `c` up to root, fire the FIRST `PersistentPreRun`
//!      found (unless EnableTraverseRunHooks, then fire all from root down).
//!   2. Fire `c.PreRun` if defined.
//!   3. Fire `c.Run` (or its `RunE` variant).
//!   4. Fire `c.PostRun`.
//!   5. Walk parents from `c` up to root, fire the FIRST `PersistentPostRun`.
//!
//! zobra mirrors this exactly. Both forms (`*_run` non-error and `*_run_e`
//! error-returning) are accepted; the `_e` form takes precedence when both
//! are set on the same command.

const std = @import("std");

pub fn HookFn(comptime CommandT: type) type {
    return *const fn (cmd: *CommandT, args: []const []const u8) void;
}

pub fn HookFnE(comptime CommandT: type) type {
    return *const fn (cmd: *CommandT, args: []const []const u8) anyerror!void;
}

/// Runs the persistent_pre_run / pre_run / run / post_run /
/// persistent_post_run chain on `cmd`. Bails on first error.
/// `traverse` matches cobra's EnableTraverseRunHooks toggle: when true,
/// every persistent hook on every ancestor fires; when false, only the
/// first one found does.
pub fn run(
    comptime CommandT: type,
    cmd: *CommandT,
    args: []const []const u8,
    traverse: bool,
) anyerror!void {
    // Persistent pre-run: walk parents from c up to root.
    if (traverse) {
        // Collect parents top-down so root fires first.
        var stack: [32]*CommandT = undefined;
        var depth: usize = 0;
        var p: ?*CommandT = cmd;
        while (p) |c| : (p = c.parent) {
            stack[depth] = c;
            depth += 1;
            if (depth == stack.len) break;
        }
        var i = depth;
        while (i > 0) {
            i -= 1;
            try runPersistentPre(CommandT, stack[i], cmd, args);
        }
    } else {
        var p: ?*CommandT = cmd;
        while (p) |c| : (p = c.parent) {
            if (c.persistent_pre_run_e != null or c.persistent_pre_run != null) {
                try runPersistentPre(CommandT, c, cmd, args);
                break;
            }
        }
    }

    // Own pre-run.
    if (cmd.pre_run_e) |fn_e| {
        try fn_e(cmd, args);
    } else if (cmd.pre_run) |fn_v| {
        fn_v(cmd, args);
    }

    // Own run.
    if (cmd.run_e) |fn_e| {
        try fn_e(cmd, args);
    } else if (cmd.run) |fn_v| {
        fn_v(cmd, args);
    }

    // Own post-run.
    if (cmd.post_run_e) |fn_e| {
        try fn_e(cmd, args);
    } else if (cmd.post_run) |fn_v| {
        fn_v(cmd, args);
    }

    // Persistent post-run: walk parents from c up to root.
    if (traverse) {
        var p: ?*CommandT = cmd;
        while (p) |c| : (p = c.parent) {
            try runPersistentPost(CommandT, c, cmd, args);
        }
    } else {
        var p: ?*CommandT = cmd;
        while (p) |c| : (p = c.parent) {
            if (c.persistent_post_run_e != null or c.persistent_post_run != null) {
                try runPersistentPost(CommandT, c, cmd, args);
                break;
            }
        }
    }
}

fn runPersistentPre(comptime CommandT: type, host: *CommandT, target: *CommandT, args: []const []const u8) anyerror!void {
    if (host.persistent_pre_run_e) |fn_e| {
        try fn_e(target, args);
    } else if (host.persistent_pre_run) |fn_v| {
        fn_v(target, args);
    }
}

fn runPersistentPost(comptime CommandT: type, host: *CommandT, target: *CommandT, args: []const []const u8) anyerror!void {
    if (host.persistent_post_run_e) |fn_e| {
        try fn_e(target, args);
    } else if (host.persistent_post_run) |fn_v| {
        fn_v(target, args);
    }
}
