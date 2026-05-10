//! zobra-doc — documentation generators for zobra Command trees.
//!
//! Mirrors `cobra/doc` (github.com/spf13/cobra/doc): markdown, yaml,
//! reStructuredText, and man-page (roff) generation. Lives behind a
//! separate import so consumers who don't need it pay nothing.
//!
//! Source of truth: cobra's md_docs.go, yaml_docs.go, rest_docs.go,
//! man_docs.go.

const std = @import("std");
const zobra = @import("zobra");

const md = @import("markdown.zig");
const yaml_mod = @import("yaml.zig");
const rest = @import("rest.zig");
const man = @import("man.zig");

pub const Command = zobra.Command;

// Markdown
pub const genMarkdown = md.genMarkdown;
pub const genMarkdownTree = md.genMarkdownTree;

// YAML
pub const genYaml = yaml_mod.genYaml;
pub const genYamlTree = yaml_mod.genYamlTree;

// reStructuredText
pub const genReST = rest.genReST;
pub const genReSTTree = rest.genReSTTree;

// Man pages (roff)
pub const ManHeader = man.ManHeader;
pub const genMan = man.genMan;
pub const genManTree = man.genManTree;

test {
    _ = md;
    _ = yaml_mod;
    _ = rest;
    _ = man;
    _ = @import("util.zig");
}
