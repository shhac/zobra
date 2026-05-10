//! Zsh completion script generator. Same wire-protocol shape as
//! bash.zig — calls `__complete` and parses the response.

const std = @import("std");
const zobra = @import("zobra");

pub fn genZshCompletion(
    allocator: std.mem.Allocator,
    root: *const zobra.Command,
    w: *std.Io.Writer,
) !void {
    _ = allocator;
    const name = root.commandName();
    try w.print(template, .{ .name = name });
}

const template =
    \\#compdef {[name]s}
    \\compdef _{[name]s} {[name]s}
    \\
    \\_{[name]s}() {{
    \\    local args
    \\    args=("${{words[@]:1:$CURRENT-1}}")
    \\    if [[ -z "${{words[$CURRENT]}}" ]]; then
    \\        args+=("")
    \\    else
    \\        args+=("${{words[$CURRENT]}}")
    \\    fi
    \\    local response
    \\    response=("${{(@f)$(${{words[1]}} __complete "${{args[@]}}" 2>/dev/null)}}")
    \\    local directive
    \\    directive="${{response[-1]##*:}}"
    \\    response[-1]="${{response[-1]%:*}}"
    \\    local -a cands
    \\    for line in "${{response[@]}}"; do
    \\        [[ -z "$line" ]] && continue
    \\        local val="${{line%%$'\t'*}}"
    \\        local desc="${{line##*$'\t'}}"
    \\        if [[ "$val" == "$desc" ]]; then
    \\            cands+=("$val")
    \\        else
    \\            cands+=("$val:$desc")
    \\        fi
    \\    done
    \\    _describe 'completions' cands
    \\}}
    \\
;

const testing = std.testing;

test "genZshCompletion: produces valid compdef header" {
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "mytool" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genZshCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "#compdef mytool") != null);
    try testing.expect(std.mem.indexOf(u8, out, "compdef _mytool mytool") != null);
}
