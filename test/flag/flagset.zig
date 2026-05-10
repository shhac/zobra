//! FlagSet tests — moved out of inline blocks in src/core/flag/flag.zig
//! per the file-decomposition pass. Public-API surface only.

const std = @import("std");
const testing = std.testing;
const zobra = @import("zobra");
const FlagSet = zobra.FlagSet;
const ValueType = zobra.flag.ValueType;
const Diagnostic = zobra.Diagnostic;

test "FlagSet: register and lookup string" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var name: []const u8 = "world";
    try fs.stringVarP(&name, "name", 'n', "world", "who to greet");

    const flag = fs.lookup("name").?;
    try testing.expectEqualStrings("name", flag.name);
    try testing.expectEqual(@as(u8, 'n'), flag.shorthand);
    try testing.expectEqual(ValueType.string, flag.value_type);
    try testing.expectEqualStrings("world", flag.default_value_string);
    try testing.expect(fs.shorthandLookup('n') == flag);
}

test "FlagSet: redefined name errors" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var a: []const u8 = "";
    try fs.stringVarP(&a, "name", 0, "", "");
    var b: []const u8 = "";
    try testing.expectError(error.FlagRedefined, fs.stringVarP(&b, "name", 0, "", ""));
}

test "FlagSet: redefined shorthand errors" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var a: bool = false;
    try fs.boolVarP(&a, "alpha", 'a', false, "");
    var b: bool = false;
    try testing.expectError(error.ShorthandRedefined, fs.boolVarP(&b, "another", 'a', false, ""));
}

test "FlagSet: set bool through public api" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var b: bool = false;
    try fs.boolVarP(&b, "verbose", 'v', false, "");
    try fs.set("verbose", "true", null);
    try testing.expect(b);
    try testing.expect(fs.lookup("verbose").?.changed);
}

test "FlagSet: int coercion writes through pointer" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var n: i64 = 0;
    try fs.intVarP(&n, "retries", 'r', 0, "");
    try fs.set("retries", "42", null);
    try testing.expectEqual(@as(i64, 42), n);
    try fs.set("retries", "0664", null); // legacy octal
    try testing.expectEqual(@as(i64, 0o664), n);
}

test "FlagSet: int coercion error renders pflag wording" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var n: i64 = 0;
    try fs.intVarP(&n, "retries", 0, 0, "");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);

    try testing.expectError(error.TypeCoercionFailed, fs.set("retries", "foo", &diag));
    try testing.expectEqual(Diagnostic.Code.type_coercion_failed, diag.code.?);
    try testing.expectEqualStrings(
        "invalid argument \"foo\" for \"--retries\" flag: strconv.ParseInt: parsing \"foo\": invalid syntax",
        diag.message.?,
    );
}

test "FlagSet: count flag increments on +1 sentinel" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var v: i32 = 0;
    try fs.countVarP(&v, "verbose", 'v', "");
    try fs.set("verbose", "+1", null);
    try fs.set("verbose", "+1", null);
    try fs.set("verbose", "+1", null);
    try testing.expectEqual(@as(i32, 3), v);

    try fs.set("verbose", "10", null);
    try testing.expectEqual(@as(i32, 10), v);
}

test "FlagSet: duration parses and stores ns" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var d: i64 = 0;
    try fs.durationVarP(&d, "timeout", 't', 0, "");
    try fs.set("timeout", "300ms", null);
    try testing.expectEqual(@as(i64, 300_000_000), d);
    try fs.set("timeout", "2h45m", null);
    try testing.expectEqual(@as(i64, 9_900_000_000_000), d);
}

test "FlagSet: duration error renders Go time-package wording" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var d: i64 = 0;
    try fs.durationVarP(&d, "timeout", 0, 0, "");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);

    try testing.expectError(error.TypeCoercionFailed, fs.set("timeout", "5x", &diag));
    try testing.expectEqualStrings(
        "invalid argument \"5x\" for \"--timeout\" flag: time: unknown unit \"x\" in duration \"5x\"",
        diag.message.?,
    );
}

test "FlagSet: markRequired / markHidden / markDeprecated" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var s: []const u8 = "";
    try fs.stringVarP(&s, "input", 0, "", "");
    try fs.markRequired("input");
    try testing.expect(fs.lookup("input").?.required);

    try fs.stringVarP(&s, "secret", 0, "", "");
    try fs.markHidden("secret");
    try testing.expect(fs.lookup("secret").?.hidden);

    try fs.stringVarP(&s, "old", 0, "", "");
    try fs.markDeprecated("old", "use --new instead");
    try testing.expectEqualStrings("use --new instead", fs.lookup("old").?.deprecated);
    try testing.expect(fs.lookup("old").?.hidden);

    try testing.expectError(error.FlagNotFound, fs.markRequired("nonexistent"));
    try testing.expectError(error.EmptyDeprecationMessage, fs.markDeprecated("input", ""));
}

test "FlagSet: apply binds tokens from parser" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var name: []const u8 = "world";
    var verbose: i32 = 0;
    var dry_run: bool = false;
    var retries: i64 = 0;

    try fs.stringVarP(&name, "name", 'n', "world", "");
    try fs.countVarP(&verbose, "verbose", 'v', "");
    try fs.boolVarP(&dry_run, "dry-run", 'd', false, "");
    try fs.intVarP(&retries, "retries", 'r', 0, "");

    const tokens = try zobra.parser.parse(gpa, &.{ "--name=alice", "-vvv", "-d", "--retries", "5", "leftover" }, fs.flagSchema(), null);
    defer gpa.free(tokens);

    try fs.apply(tokens, null);

    try testing.expectEqualStrings("alice", name);
    try testing.expectEqual(@as(i32, 3), verbose);
    try testing.expect(dry_run);
    try testing.expectEqual(@as(i64, 5), retries);
    try testing.expectEqual(@as(usize, 1), fs.args.items.len);
    try testing.expectEqualStrings("leftover", fs.args.items[0]);
}

test "FlagSet: --no-foo binds boolean to false" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var dry_run: bool = true;
    try fs.boolVarP(&dry_run, "dry-run", 'd', true, "");

    const tokens = try zobra.parser.parse(gpa, &.{"--no-dry-run"}, fs.flagSchema(), null);
    defer gpa.free(tokens);
    try fs.apply(tokens, null);
    try testing.expect(!dry_run);
}

test "FlagSet: terminator records argsLenAtDash" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    const tokens = try zobra.parser.parse(gpa, &.{ "a", "b", "--", "c", "d" }, fs.flagSchema(), null);
    defer gpa.free(tokens);
    try fs.apply(tokens, null);

    try testing.expectEqual(@as(?usize, 2), fs.args_len_at_dash);
    try testing.expectEqual(@as(usize, 4), fs.args.items.len);
    try testing.expectEqualStrings("a", fs.args.items[0]);
    try testing.expectEqualStrings("b", fs.args.items[1]);
    try testing.expectEqualStrings("c", fs.args.items[2]);
    try testing.expectEqualStrings("d", fs.args.items[3]);
}

test "FlagSet: unknown flag fills diagnostic" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    const tokens = try zobra.parser.parse(gpa, &.{"--unknown"}, fs.flagSchema(), null);
    defer gpa.free(tokens);

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.UnknownFlag, fs.apply(tokens, &diag));
    try testing.expectEqualStrings("unknown", diag.flag_name.?);
    try testing.expectEqualStrings("--unknown", diag.raw.?);
}

test "FlagSet: stringSlice splits on comma and appends on repeat" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var tags: []const []const u8 = &.{};
    try fs.stringSliceVarP(&tags, "tag", 't', &.{}, "");

    try fs.set("tag", "a,b,c", null);
    try testing.expectEqual(@as(usize, 3), tags.len);
    try testing.expectEqualStrings("a", tags[0]);
    try testing.expectEqualStrings("b", tags[1]);
    try testing.expectEqualStrings("c", tags[2]);

    try fs.set("tag", "d,e", null);
    try testing.expectEqual(@as(usize, 5), tags.len);
    try testing.expectEqualStrings("e", tags[4]);
}

test "FlagSet: stringSlice with non-empty default doesn't leak" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var tags: []const []const u8 = &.{};
    try fs.stringSliceVarP(&tags, "tag", 0, &.{ "default-a", "default-b" }, "");
    try fs.set("tag", "x,y", null);
    try testing.expectEqual(@as(usize, 2), tags.len);
    try testing.expectEqualStrings("x", tags[0]);
    try testing.expectEqualStrings("y", tags[1]);
}

test "FlagSet: stringArray does not split on comma" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var labels: []const []const u8 = &.{};
    try fs.stringArrayVarP(&labels, "label", 0, &.{}, "");

    try fs.set("label", "a,b", null);
    try testing.expectEqual(@as(usize, 1), labels.len);
    try testing.expectEqualStrings("a,b", labels[0]);

    try fs.set("label", "c", null);
    try testing.expectEqual(@as(usize, 2), labels.len);
    try testing.expectEqualStrings("c", labels[1]);
}

test "FlagSet: intSlice parses + appends" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var nums: []const i64 = &.{};
    try fs.intSliceVarP(&nums, "ints", 0, &.{}, "");

    try fs.set("ints", "1,2,3", null);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, nums);
    try fs.set("ints", "4", null);
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4 }, nums);
}

test "FlagSet: intSlice with non-numeric fails with strconv wording" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var nums: []const i64 = &.{};
    try fs.intSliceVarP(&nums, "ints", 0, &.{}, "");

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.TypeCoercionFailed, fs.set("ints", "1,foo,3", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "strconv.Atoi: parsing \"foo\": invalid syntax") != null);
}

test "Flag.isZeroDefault: covers every ValueType variant" {
    const gpa = std.testing.allocator;
    var fs = zobra.flag.FlagSet.init(gpa);
    defer fs.deinit();

    var b: bool = false;
    var s: []const u8 = "";
    var i: i64 = 0;
    var u: u64 = 0;
    var f: f64 = 0;
    var c: i32 = 0;
    var d: i64 = 0;
    try fs.boolVarP(&b, "z_bool", 0, false, "");
    try fs.stringVarP(&s, "z_string", 0, "", "");
    try fs.intVarP(&i, "z_int", 0, 0, "");
    try fs.uintVarP(&u, "z_uint", 0, 0, "");
    try fs.float64VarP(&f, "z_float", 0, 0, "");
    try fs.countVarP(&c, "z_count", 0, "");
    try fs.durationVarP(&d, "z_dur", 0, 0, "");

    try std.testing.expect(fs.lookup("z_bool").?.isZeroDefault());
    try std.testing.expect(fs.lookup("z_string").?.isZeroDefault());
    try std.testing.expect(fs.lookup("z_int").?.isZeroDefault());
    try std.testing.expect(fs.lookup("z_uint").?.isZeroDefault());
    try std.testing.expect(fs.lookup("z_float").?.isZeroDefault());
    try std.testing.expect(fs.lookup("z_count").?.isZeroDefault());
    try std.testing.expect(fs.lookup("z_dur").?.isZeroDefault());

    var b2: bool = true;
    var nzi: i64 = 5;
    var s2: []const u8 = "hi";
    try fs.boolVarP(&b2, "nz_bool", 0, true, "");
    try fs.intVarP(&nzi, "nz_int", 0, 5, "");
    try fs.stringVarP(&s2, "nz_string", 0, "hi", "");

    try std.testing.expect(!fs.lookup("nz_bool").?.isZeroDefault());
    try std.testing.expect(!fs.lookup("nz_int").?.isZeroDefault());
    try std.testing.expect(!fs.lookup("nz_string").?.isZeroDefault());

    var ss: []const []const u8 = &.{};
    try fs.stringSliceVarP(&ss, "z_strs", 0, &.{}, "");
    try std.testing.expect(fs.lookup("z_strs").?.isZeroDefault());
}

test "Flag.isZeroDefault: exotic-type arms (slice/map/ip/bytes/custom)" {
    const gpa = std.testing.allocator;
    var fs = zobra.flag.FlagSet.init(gpa);
    defer fs.deinit();

    var ss: []const []const u8 = &.{};
    try fs.stringSliceVarP(&ss, "z_strs", 0, &.{}, "");
    var sa: []const []const u8 = &.{};
    try fs.stringArrayVarP(&sa, "z_strarr", 0, &.{}, "");
    var ints: []const i64 = &.{};
    try fs.intSliceVarP(&ints, "z_ints", 0, &.{}, "");
    var i32s: []const i32 = &.{};
    try fs.int32SliceVarP(&i32s, "z_i32s", 0, &.{}, "");
    var i64s: []const i64 = &.{};
    try fs.int64SliceVarP(&i64s, "z_i64s", 0, &.{}, "");
    var f32s: []const f32 = &.{};
    try fs.float32SliceVarP(&f32s, "z_f32s", 0, &.{}, "");
    var f64s: []const f64 = &.{};
    try fs.float64SliceVarP(&f64s, "z_f64s", 0, &.{}, "");
    var bs: []const bool = &.{};
    try fs.boolSliceVarP(&bs, "z_bs", 0, &.{}, "");
    var ds: []const i64 = &.{};
    try fs.durationSliceVarP(&ds, "z_ds", 0, &.{}, "");

    var ip_v: []const u8 = "";
    try fs.ipVarP(&ip_v, "z_ip", 0, "", "");
    var ipm: []const u8 = "";
    try fs.ipMaskVarP(&ipm, "z_ipm", 0, "", "");
    var ipn: []const u8 = "";
    try fs.ipNetVarP(&ipn, "z_ipn", 0, "", "");

    var bh: []const u8 = "";
    try fs.bytesHexVarP(&bh, "z_bh", 0, "", "");
    var bb: []const u8 = "";
    try fs.bytesBase64VarP(&bb, "z_bb", 0, "", "");

    var sts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try fs.stringToStringVarP(&sts, "z_sts", 0, "");
    var sti: std.StringHashMapUnmanaged(i32) = .empty;
    try fs.stringToIntVarP(&sti, "z_sti", 0, "");
    var sti64: std.StringHashMapUnmanaged(i64) = .empty;
    try fs.stringToInt64VarP(&sti64, "z_sti64", 0, "");

    inline for (.{ "z_strs", "z_strarr", "z_ints", "z_i32s", "z_i64s", "z_f32s", "z_f64s", "z_bs", "z_ds", "z_bh", "z_bb", "z_sts", "z_sti", "z_sti64" }) |name| {
        try std.testing.expect(fs.lookup(name).?.isZeroDefault());
    }
    inline for (.{ "z_ip", "z_ipm", "z_ipn" }) |name| {
        try std.testing.expect(fs.lookup(name).?.isZeroDefault());
    }
}

test "Flag.typeName: exotic-type arms + int64/uint64 aliasing" {
    const gpa = std.testing.allocator;
    var fs = zobra.flag.FlagSet.init(gpa);
    defer fs.deinit();

    // int64/uint64 alias to "int"/"uint" — pflag's display convention.
    var i64v: i64 = 0;
    var u64v: u64 = 0;
    try fs.int64VarP(&i64v, "v_int64", 0, 0, "");
    try fs.uint64VarP(&u64v, "v_uint64", 0, 0, "");
    try std.testing.expectEqualStrings("int", fs.lookup("v_int64").?.typeName());
    try std.testing.expectEqualStrings("uint", fs.lookup("v_uint64").?.typeName());

    var ss: []const []const u8 = &.{};
    try fs.stringSliceVarP(&ss, "v_strs", 0, &.{}, "");
    var sa: []const []const u8 = &.{};
    try fs.stringArrayVarP(&sa, "v_strarr", 0, &.{}, "");
    var ints: []const i64 = &.{};
    try fs.intSliceVarP(&ints, "v_ints", 0, &.{}, "");
    var i32s: []const i32 = &.{};
    try fs.int32SliceVarP(&i32s, "v_i32s", 0, &.{}, "");
    var f32s: []const f32 = &.{};
    try fs.float32SliceVarP(&f32s, "v_f32s", 0, &.{}, "");
    var f64s: []const f64 = &.{};
    try fs.float64SliceVarP(&f64s, "v_f64s", 0, &.{}, "");
    var bs: []const bool = &.{};
    try fs.boolSliceVarP(&bs, "v_bs", 0, &.{}, "");
    var ds: []const i64 = &.{};
    try fs.durationSliceVarP(&ds, "v_ds", 0, &.{}, "");

    var ip_v: []const u8 = "";
    try fs.ipVarP(&ip_v, "v_ip", 0, "", "");
    var ipm: []const u8 = "";
    try fs.ipMaskVarP(&ipm, "v_ipm", 0, "", "");
    var ipn: []const u8 = "";
    try fs.ipNetVarP(&ipn, "v_ipn", 0, "", "");

    var bh: []const u8 = "";
    try fs.bytesHexVarP(&bh, "v_bh", 0, "", "");
    var bb: []const u8 = "";
    try fs.bytesBase64VarP(&bb, "v_bb", 0, "", "");

    var sts: std.StringHashMapUnmanaged([]const u8) = .empty;
    try fs.stringToStringVarP(&sts, "v_sts", 0, "");
    var sti: std.StringHashMapUnmanaged(i32) = .empty;
    try fs.stringToIntVarP(&sti, "v_sti", 0, "");
    var sti64: std.StringHashMapUnmanaged(i64) = .empty;
    try fs.stringToInt64VarP(&sti64, "v_sti64", 0, "");

    try std.testing.expectEqualStrings("strings", fs.lookup("v_strs").?.typeName());
    try std.testing.expectEqualStrings("stringArray", fs.lookup("v_strarr").?.typeName());
    try std.testing.expectEqualStrings("ints", fs.lookup("v_ints").?.typeName());
    try std.testing.expectEqualStrings("int32Slice", fs.lookup("v_i32s").?.typeName());
    try std.testing.expectEqualStrings("float32Slice", fs.lookup("v_f32s").?.typeName());
    try std.testing.expectEqualStrings("float64Slice", fs.lookup("v_f64s").?.typeName());
    try std.testing.expectEqualStrings("bools", fs.lookup("v_bs").?.typeName());
    try std.testing.expectEqualStrings("durationSlice", fs.lookup("v_ds").?.typeName());
    try std.testing.expectEqualStrings("ip", fs.lookup("v_ip").?.typeName());
    try std.testing.expectEqualStrings("ipMask", fs.lookup("v_ipm").?.typeName());
    try std.testing.expectEqualStrings("ipNet", fs.lookup("v_ipn").?.typeName());
    try std.testing.expectEqualStrings("bytesHex", fs.lookup("v_bh").?.typeName());
    try std.testing.expectEqualStrings("bytesBase64", fs.lookup("v_bb").?.typeName());
    try std.testing.expectEqualStrings("stringToString", fs.lookup("v_sts").?.typeName());
    try std.testing.expectEqualStrings("stringToInt", fs.lookup("v_sti").?.typeName());
    try std.testing.expectEqualStrings("stringToInt64", fs.lookup("v_sti64").?.typeName());
}

test "Flag.typeName: custom flag uses vtable type_name" {
    const gpa = std.testing.allocator;
    var fs = zobra.flag.FlagSet.init(gpa);
    defer fs.deinit();

    const CustomCtx = struct {
        value: []const u8 = "",
        fn set(ptr: *anyopaque, v: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.value = v;
        }
        fn str(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return alloc.dupe(u8, self.value);
        }
    };
    var ctx: CustomCtx = .{};
    const cf: zobra.flag.CustomFlag = .{
        .ptr = &ctx,
        .type_name = "json",
        .set_fn = CustomCtx.set,
        .string_fn = CustomCtx.str,
    };
    try fs.varP(cf, "config", 0, "JSON blob");

    try std.testing.expectEqualStrings("json", fs.lookup("config").?.typeName());
}

test "Flag.typeName: cobra-style display names" {
    const gpa = std.testing.allocator;
    var fs = zobra.flag.FlagSet.init(gpa);
    defer fs.deinit();
    var b: bool = false;
    var s: []const u8 = "";
    var i64v: i64 = 0;
    var i32v: i32 = 0;
    var f: f64 = 0;
    var c: i32 = 0;
    var d: i64 = 0;
    try fs.boolVarP(&b, "b", 0, false, "");
    try fs.stringVarP(&s, "s", 0, "", "");
    try fs.intVarP(&i64v, "int", 0, 0, "");
    try fs.int32VarP(&i32v, "i32", 0, 0, "");
    try fs.float64VarP(&f, "f", 0, 0, "");
    try fs.countVarP(&c, "cnt", 0, "");
    try fs.durationVarP(&d, "dur", 0, 0, "");

    try std.testing.expectEqualStrings("", fs.lookup("b").?.typeName());
    try std.testing.expectEqualStrings("string", fs.lookup("s").?.typeName());
    try std.testing.expectEqualStrings("int", fs.lookup("int").?.typeName());
    try std.testing.expectEqualStrings("int32", fs.lookup("i32").?.typeName());
    try std.testing.expectEqualStrings("float", fs.lookup("f").?.typeName());
    try std.testing.expectEqualStrings("count", fs.lookup("cnt").?.typeName());
    try std.testing.expectEqualStrings("duration", fs.lookup("dur").?.typeName());
}

test "FlagSet: missing value fills diagnostic" {
    const gpa = testing.allocator;
    var fs = FlagSet.init(gpa);
    defer fs.deinit();

    var n: i64 = 0;
    try fs.intVarP(&n, "retries", 0, 0, "");

    const tokens = try zobra.parser.parse(gpa, &.{"--retries"}, fs.flagSchema(), null);
    defer gpa.free(tokens);

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.MissingValue, fs.apply(tokens, &diag));
    try testing.expectEqualStrings("retries", diag.flag_name.?);
}
