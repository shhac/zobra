//! Bash completion script generator (V2 protocol). Renders a script
//! that the user evaluates in their shell:
//!
//!     eval "$(mytool completion bash)"
//!
//! The script registers a completion handler for `mytool`. When the
//! user TABs, bash invokes `mytool __complete <args>...` and parses
//! the result (one `value\tdesc` per line, trailing `:directive`).
//!
//! This is the minimum-viable form — it handles common cases (subcmd
//! and flag completion, NoFileComp / NoSpace directives). Extending
//! to byte-identical-to-cobra is a follow-up; the wire protocol is
//! already correct.

const std = @import("std");
const zobra = @import("zobra");

pub fn genBashCompletion(
    allocator: std.mem.Allocator,
    root: *const zobra.Command,
    w: *std.Io.Writer,
) !void {
    _ = allocator;
    const name = root.commandName();
    try w.print(template, .{ .name = name });
}

const template_text =
    \\# bash completion V2 for {[name]s}
    \\
    \\__{[name]s}_get_completions() {{
    \\    local args response
    \\    args=("${{COMP_WORDS[@]:1:$COMP_CWORD}}")
    \\    if [[ -z "${{COMP_WORDS[$COMP_CWORD]}}" ]]; then
    \\        args+=("")
    \\    fi
    \\    response=$("${{COMP_WORDS[0]}}" __complete "${{args[@]}}" 2>/dev/null)
    \\    local directive
    \\    directive="${{response##*:}}"
    \\    response="${{response%:*}}"
    \\    local IFS=$'\n'
    \\    local cands=()
    \\    while IFS= read -r line; do
    \\        [[ -z "$line" ]] && continue
    \\        cands+=("${{line%%$'\t'*}}")
    \\    done <<< "$response"
    \\    local cur="${{COMP_WORDS[$COMP_CWORD]}}"
    \\    COMPREPLY=( $(compgen -W "${{cands[*]}}" -- "$cur") )
    \\    if (( directive & 4 )); then
    \\        compopt -o nospace 2>/dev/null
    \\        :
    \\    fi
    \\}}
    \\
    \\complete -F __{[name]s}_get_completions {[name]s}
    \\
;

const template = template_text;

const testing = std.testing;

test "genBashCompletion: contains the program name and __complete invocation" {
    const gpa = testing.allocator;
    const root = try zobra.Command.init(gpa, .{ .use = "mytool" });
    defer root.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try genBashCompletion(gpa, root, &aw.writer);
    const out = aw.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "complete -F __mytool_get_completions mytool") != null);
    try testing.expect(std.mem.indexOf(u8, out, "__complete") != null);
}
