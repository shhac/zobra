//! Fish completion script generator. fish's completion API is
//! different from bash/zsh — it uses `complete` with `-c <cmd>` per
//! candidate. We use the dynamic `__fish_complete_for_zobra` function
//! that calls back to `__complete`.

const std = @import("std");
const zobra = @import("zobra");

pub fn genFishCompletion(
    allocator: std.mem.Allocator,
    root: *const zobra.Command,
    w: *std.Io.Writer,
) !void {
    _ = allocator;
    const name = root.commandName();
    try w.print(template, .{ .name = name });
}

const template =
    \\function __{[name]s}_complete
    \\    set -l args (commandline -opc)
    \\    set -l cur (commandline -ct)
    \\    set -l args_with_cur $args[2..-1] $cur
    \\    set -l response ($args[1] __complete $args_with_cur 2>/dev/null)
    \\    if test (count $response) -eq 0
    \\        return
    \\    end
    \\    set -l last $response[-1]
    \\    set -l response $response[1..-2]
    \\    if string match -qr ':\d+$' -- $last
    \\        # last is :directive
    \\    else
    \\        set response $response $last
    \\    end
    \\    for line in $response
    \\        echo $line
    \\    end
    \\end
    \\
    \\complete -c {[name]s} -f -a "(__{[name]s}_complete)"
    \\
;

const testing = std.testing;

test "genFishCompletion: registers a complete -c handler" {
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "mytool" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genFishCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "complete -c mytool") != null);
    try testing.expect(std.mem.indexOf(u8, out, "function __mytool_complete") != null);
}
