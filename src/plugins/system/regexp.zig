const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");
const regexp_engine = @import("regexp");

const Value = value_mod.Value;
const Runtime = value_mod.Runtime;

pub const CallResult = struct { value: Value, captures: ?Value = null };

pub const Flags = regexp_engine.Flags;
pub const Span = regexp_engine.Span;
pub const Match = regexp_engine.Match;
pub const Compiled = regexp_engine.Compiled;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const result = (try callWithEffects(runtime, name, arguments)) orelse return null;
    return result.value;
}

pub fn callWithEffects(runtime: *Runtime, name: []const u8, arguments: []const Value) !?CallResult {
    if (!isRegexpCommand(name)) return null;
    var source_string = try ownedText(runtime, common.argument(arguments, 0));
    defer source_string.deinit();
    var pattern_string = try ownedText(runtime, common.argument(arguments, 1));
    defer pattern_string.deinit();
    var compiled = regexp_engine.compilePattern(runtime.allocator(), pattern_string.units, defaultGlobal(name)) catch |failure| {
        try setCompileFailureMessage(runtime, pattern_string.units, defaultGlobal(name), failure);
        return failure;
    };
    defer compiled.deinit();
    if (eql(name, "正規表現マッチ")) return try matchCommand(runtime, source_string.units, &compiled);
    if (eql(name, "正規表現抽出")) return try extractCommand(runtime, source_string.units, &compiled);
    if (eql(name, "正規表現置換")) {
        var replacement = try ownedText(runtime, common.argument(arguments, 2));
        defer replacement.deinit();
        return .{ .value = try replaceCommand(runtime, source_string.units, replacement.units, &compiled) };
    }
    return .{ .value = try splitCommand(runtime, source_string.units, &compiled) };
}

pub const RawPattern = regexp_engine.RawPattern;

pub fn testRaw(allocator: std.mem.Allocator, pattern: []const u16, source: []const u16, ignore_case: bool) !bool {
    return regexp_engine.testRaw(allocator, pattern, source, ignore_case);
}

pub fn compileFailureMessageAlloc(allocator: std.mem.Allocator, specification: []const u16, default_global: bool, failure: anyerror) !?[]u8 {
    return regexp_engine.compileFailureMessageAlloc(allocator, specification, default_global, failure);
}

pub fn setCompileFailureMessage(runtime: *Runtime, specification: []const u16, default_global: bool, failure: anyerror) !void {
    const message = try regexp_engine.compileFailureMessageAlloc(runtime.allocator(), specification, default_global, failure) orelse return;
    defer runtime.allocator().free(message);
    try runtime.setFailureMessage(message);
}

pub fn compilePattern(allocator: std.mem.Allocator, specification: []const u16, default_global: bool) !regexp_engine.Compiled {
    return regexp_engine.compilePattern(allocator, specification, default_global);
}

pub fn findMatches(allocator: std.mem.Allocator, source: []const u16, compiled: *const regexp_engine.Compiled) ![]regexp_engine.Match {
    return regexp_engine.findMatches(allocator, source, compiled);
}

pub fn replaceUnits(allocator: std.mem.Allocator, source: []const u16, replacement: []const u16, compiled: *const regexp_engine.Compiled) ![]u16 {
    return regexp_engine.replaceUnits(allocator, source, replacement, compiled);
}

fn matchCommand(runtime: *Runtime, source: []const u16, compiled: *const regexp_engine.Compiled) !CallResult {
    const matches = try regexp_engine.findMatches(runtime.allocator(), source, compiled);
    defer runtime.allocator().free(matches);
    var captures = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&captures);
    if (matches.len == 0) return .{ .value = .null_value, .captures = captures };
    if (!compiled.flags.global) {
        for (matches[0].captures[0..compiled.capture_count]) |span| {
            _ = try captures.array.push(if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined);
        }
        return .{ .value = try runtime.stringCodeUnits(source[matches[0].span.start..matches[0].span.end]), .captures = captures };
    }
    var result = try runtime.createArray();
    try roots.protect(&result);
    for (matches) |match| _ = try result.array.push(try runtime.stringCodeUnits(source[match.span.start..match.span.end]));
    return .{ .value = result, .captures = captures };
}

fn extractCommand(runtime: *Runtime, source: []const u16, compiled: *regexp_engine.Compiled) !CallResult {
    compiled.flags.global = true;
    const matches = try regexp_engine.findMatches(runtime.allocator(), source, compiled);
    defer runtime.allocator().free(matches);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var result = try runtime.createArray();
    try roots.protect(&result);
    var rows = try runtime.createArray();
    try roots.protect(&rows);
    for (matches) |match| {
        var has_named = false;
        for (compiled.capture_names[0..compiled.capture_count]) |name| if (name != null) {
            has_named = true;
            break;
        };
        if (has_named) {
            var row = try runtime.createDictionary();
            var row_roots = runtime.rootFrame();
            defer row_roots.deinit();
            try row_roots.protect(&row);
            for (compiled.capture_names[0..compiled.capture_count], 0..) |name, index| if (name) |key_units| {
                const span = match.captures[index];
                var item = if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined;
                var item_roots = runtime.rootFrame();
                defer item_roots.deinit();
                try item_roots.protect(&item);
                var key = try runtime.stringCodeUnits(key_units);
                try item_roots.protect(&key);
                try row.dictionary.set(key.string, item);
                _ = try result.array.push(item);
            };
            _ = try rows.array.push(row);
        } else {
            var row = try runtime.createArray();
            var row_roots = runtime.rootFrame();
            defer row_roots.deinit();
            try row_roots.protect(&row);
            if (compiled.capture_count == 0) {
                const item = try runtime.stringCodeUnits(source[match.span.start..match.span.end]);
                _ = try row.array.push(item);
                _ = try result.array.push(item);
            } else for (match.captures[0..compiled.capture_count]) |span| {
                const item = if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined;
                _ = try row.array.push(item);
                _ = try result.array.push(item);
            }
            _ = try rows.array.push(row);
        }
    }
    return .{ .value = result, .captures = rows };
}

fn replaceCommand(runtime: *Runtime, source: []const u16, replacement_text: []const u16, compiled: *const regexp_engine.Compiled) !Value {
    const output = try regexp_engine.replaceUnits(runtime.allocator(), source, replacement_text, compiled);
    defer runtime.allocator().free(output);
    return runtime.stringCodeUnits(output);
}

fn splitCommand(runtime: *Runtime, source: []const u16, compiled: *const regexp_engine.Compiled) !Value {
    var split_compiled = compiled.*;
    split_compiled.flags.global = true;
    const matches = try regexp_engine.findMatches(runtime.allocator(), source, &split_compiled);
    defer runtime.allocator().free(matches);
    var result = try runtime.createArray();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    var cursor: usize = 0;
    for (matches) |match| {
        if (match.span.start == match.span.end and (match.span.start == 0 or match.span.start == source.len or match.span.start == cursor)) continue;
        _ = try result.array.push(try runtime.stringCodeUnits(source[cursor..match.span.start]));
        for (match.captures[0..compiled.capture_count]) |span| {
            _ = try result.array.push(if (span.matched) try runtime.stringCodeUnits(source[span.start..span.end]) else .undefined);
        }
        cursor = match.span.end;
    }
    _ = try result.array.push(try runtime.stringCodeUnits(source[cursor..]));
    if (source.len == 0 and matches.len > 0) result.array.items.clearRetainingCapacity();
    return result;
}

fn ownedText(runtime: *Runtime, value: Value) !value_mod.String {
    const converted = try runtime.valueToString(value);
    return value_mod.String.fromCodeUnits(runtime.allocator(), converted.string.units);
}

fn defaultGlobal(name: []const u8) bool {
    return eql(name, "正規表現マッチ") or eql(name, "正規表現抽出") or eql(name, "正規表現置換") or eql(name, "正規表現区切");
}

fn isRegexpCommand(name: []const u8) bool {
    return eql(name, "正規表現マッチ") or eql(name, "正規表現抽出") or eql(name, "正規表現置換") or eql(name, "正規表現区切");
}

fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

test "正規表現の量指定・キャプチャ・置換・区切を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var source = try runtime.stringUtf8("AA,bb,CCC");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/([a-z]+),?/gi");
    try roots.protect(&pattern);
    const extracted = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), extracted.value.array.len());
    var replacement_pattern = try runtime.stringUtf8("/([a-z]+)/gi");
    try roots.protect(&replacement_pattern);
    var replacement_text = try runtime.stringUtf8("<$1>");
    try roots.protect(&replacement_text);
    const replacement = (try call(&runtime, "正規表現置換", &.{ source, replacement_pattern, replacement_text })).?;
    const utf8 = try replacement.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("<AA>,<bb>,<CCC>", utf8);
    var split_pattern = try runtime.stringUtf8("/,/");
    try roots.protect(&split_pattern);
    const split = (try call(&runtime, "正規表現区切", &.{ source, split_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), split.array.len());
}

test "正規表現のlegacy octal escapeは非Unicode classのcode unitになる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var unit_one = try runtime.stringUtf8("[\\1]");
    try roots.protect(&unit_one);
    var line_feed = try runtime.stringUtf8("[\\12]");
    try roots.protect(&line_feed);
    var letter_s = try runtime.stringUtf8("[\\123]");
    try roots.protect(&letter_s);
    var bell = try runtime.stringUtf8("\\07");
    try roots.protect(&bell);

    try std.testing.expect(try testRaw(std.testing.allocator, unit_one.string.units, &.{1}, false));
    try std.testing.expect(!try testRaw(std.testing.allocator, unit_one.string.units, &.{'1'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, line_feed.string.units, &.{10}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, letter_s.string.units, &.{'S'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, bell.string.units, &.{7}, false));

    var no_capture_one = try runtime.stringUtf8("\\1");
    try roots.protect(&no_capture_one);
    var no_capture_eight = try runtime.stringUtf8("\\8");
    try roots.protect(&no_capture_eight);
    var two_digit_octal = try runtime.stringUtf8("\\64");
    try roots.protect(&two_digit_octal);
    var three_digit_octal = try runtime.stringUtf8("\\400");
    try roots.protect(&three_digit_octal);
    var high_two_digit_octal = try runtime.stringUtf8("\\777");
    try roots.protect(&high_two_digit_octal);
    var mixed_octal = try runtime.stringUtf8("\\378");
    try roots.protect(&mixed_octal);
    try std.testing.expect(try testRaw(std.testing.allocator, no_capture_one.string.units, &.{1}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, no_capture_eight.string.units, &.{'8'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, two_digit_octal.string.units, &.{'4'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, three_digit_octal.string.units, &.{ 32, '0' }, false));
    try std.testing.expect(try testRaw(std.testing.allocator, high_two_digit_octal.string.units, &.{ 63, '7' }, false));
    try std.testing.expect(try testRaw(std.testing.allocator, mixed_octal.string.units, &.{ 31, '8' }, false));

    var captured = try runtime.stringUtf8("(a)\\1");
    try roots.protect(&captured);
    var forward_capture = try runtime.stringUtf8("\\1(a)");
    try roots.protect(&forward_capture);
    var missing_capture = try runtime.stringUtf8("(a)\\2");
    try roots.protect(&missing_capture);
    var second_capture = try runtime.stringUtf8("(a)(b)\\2");
    try roots.protect(&second_capture);
    var capture_then_octal = try runtime.stringUtf8("(a)\\12");
    try roots.protect(&capture_then_octal);
    try std.testing.expect(try testRaw(std.testing.allocator, captured.string.units, &.{ 'a', 'a' }, false));
    try std.testing.expect(try testRaw(std.testing.allocator, forward_capture.string.units, &.{'a'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, missing_capture.string.units, &.{ 'a', 2 }, false));
    try std.testing.expect(try testRaw(std.testing.allocator, second_capture.string.units, &.{ 'a', 'b', 'b' }, false));
    try std.testing.expect(try testRaw(std.testing.allocator, capture_then_octal.string.units, &.{ 'a', 10 }, false));

    var class_high_octal = try runtime.stringUtf8("[\\777]");
    try roots.protect(&class_high_octal);
    try std.testing.expect(try testRaw(std.testing.allocator, class_high_octal.string.units, &.{'?'}, false));
    try std.testing.expect(try testRaw(std.testing.allocator, class_high_octal.string.units, &.{'7'}, false));
}

test "正規表現構文エラーはV8互換の文言を設定する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("x");

    const raw_invalid = try runtime.stringUtf8("[");
    try std.testing.expectError(error.UnclosedCharacterClass, call(&runtime, "正規表現マッチ", &.{ source, raw_invalid }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[/g: Unterminated character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const delimited_invalid = try runtime.stringUtf8("/[/u");
    try std.testing.expectError(error.UnclosedCharacterClass, call(&runtime, "正規表現マッチ", &.{ source, delimited_invalid }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[/u: Unterminated character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_flags = try runtime.stringUtf8("/a/gg");
    try std.testing.expectError(error.DuplicateRegularExpressionFlag, call(&runtime, "正規表現マッチ", &.{ source, invalid_flags }));
    try std.testing.expectEqualStrings("Invalid flags supplied to RegExp constructor 'gg'", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const trailing_escape = try runtime.stringUtf8("\\");
    try std.testing.expectError(error.InvalidEscape, call(&runtime, "正規表現マッチ", &.{ source, trailing_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\/g: \\ at end of pattern", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const unmatched_close = try runtime.stringUtf8(")");
    try std.testing.expectError(error.UnexpectedPatternToken, call(&runtime, "正規表現マッチ", &.{ source, unmatched_close }));
    try std.testing.expectEqualStrings("Invalid regular expression: /)/g: Unmatched ')'", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_unicode = try runtime.stringUtf8("/\\u{/u");
    try std.testing.expectError(error.InvalidUnicodeEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_unicode }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\u{/u: Invalid Unicode escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_control = try runtime.stringUtf8("/\\c1/u");
    try std.testing.expectError(error.InvalidUnicodeEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_control }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\c1/u: Invalid Unicode escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_backreference = try runtime.stringUtf8("/\\1/u");
    try std.testing.expectError(error.InvalidBackreference, call(&runtime, "正規表現マッチ", &.{ source, invalid_backreference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\1/u: Invalid escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_multi_digit_backreference = try runtime.stringUtf8("/(a)\\12/u");
    try std.testing.expectError(error.InvalidBackreference, call(&runtime, "正規表現マッチ", &.{ source, invalid_multi_digit_backreference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(a)\\12/u: Invalid escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_named_reference = try runtime.stringUtf8("/(?<a>a)\\k<b>/u");
    try std.testing.expectError(error.InvalidNamedBackreference, call(&runtime, "正規表現マッチ", &.{ source, invalid_named_reference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<a>a)\\k<b>/u: Invalid named capture referenced", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const malformed_named_reference = try runtime.stringUtf8("/\\k/u");
    try std.testing.expectError(error.InvalidNamedReference, call(&runtime, "正規表現マッチ", &.{ source, malformed_named_reference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\k/u: Invalid named reference", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_decimal_escape = try runtime.stringUtf8("/[\\1]/u");
    try std.testing.expectError(error.InvalidDecimalEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_decimal_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\1]/u: Invalid decimal escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_zero_escape = try runtime.stringUtf8("/\\00/u");
    try std.testing.expectError(error.InvalidDecimalEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_zero_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\00/u: Invalid decimal escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_class = try runtime.stringUtf8("/[\\d-a]/u");
    try std.testing.expectError(error.InvalidCharacterClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_class }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\d-a]/u: Invalid character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_identity_escape = try runtime.stringUtf8("/\\q/u");
    try std.testing.expectError(error.InvalidIdentityEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_identity_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\q/u: Invalid escape", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const invalid_capture_name = try runtime.stringUtf8("/(?<1>a)/");
    try std.testing.expectError(error.InvalidNamedCapture, call(&runtime, "正規表現マッチ", &.{ source, invalid_capture_name }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<1>a)/: Invalid capture group name", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    const duplicate_capture_name = try runtime.stringUtf8("/(?<a>a)(?<a>b)/");
    try std.testing.expectError(error.DuplicateNamedCapture, call(&runtime, "正規表現マッチ", &.{ source, duplicate_capture_name }));
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<a>a)(?<a>b)/: Duplicate capture group name", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_hex_escape = try runtime.stringUtf8("/\\xZZ/u");
    try std.testing.expectError(error.InvalidHexEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_hex_escape }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\xZZ/u: Invalid escape", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const incomplete_quantifier = try runtime.stringUtf8("/a{,/u");
    try std.testing.expectError(error.IncompleteQuantifier, call(&runtime, "正規表現マッチ", &.{ source, incomplete_quantifier }));
    try std.testing.expectEqualStrings("Invalid regular expression: /a{,/u: Incomplete quantifier", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const lone_quantifier_brackets = try runtime.stringUtf8("/{/u");
    try std.testing.expectError(error.LoneQuantifierBrackets, call(&runtime, "正規表現マッチ", &.{ source, lone_quantifier_brackets }));
    try std.testing.expectEqualStrings("Invalid regular expression: /{/u: Lone quantifier brackets", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_set_character = try runtime.stringUtf8("/[a&&]/v");
    try std.testing.expectError(error.InvalidCharacterInClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_set_character }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[a&&]/v: Invalid character in character class", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_set_operator = try runtime.stringUtf8("/[a&&&&b]/v");
    try std.testing.expectError(error.InvalidCharacterInClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_set_operator }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[a&&&&b]/v: Invalid character in character class", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_class_property = try runtime.stringUtf8("/[\\p{Nope}]/u");
    try std.testing.expectError(error.InvalidUnicodePropertyInClass, call(&runtime, "正規表現マッチ", &.{ source, invalid_class_property }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\p{Nope}]/u: Invalid property name in character class", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_class_named_reference = try runtime.stringUtf8("/[\\k]/u");
    try std.testing.expectError(error.InvalidClassEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_class_named_reference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\k]/u: Invalid escape", runtime.failureMessage().?);

    runtime.clearFailureMessage();
    const invalid_class_named_backreference = try runtime.stringUtf8("/[\\k<a>]/u");
    try std.testing.expectError(error.InvalidClassEscape, call(&runtime, "正規表現マッチ", &.{ source, invalid_class_named_backreference }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\k<a>]/u: Invalid escape", runtime.failureMessage().?);
}

test "Unicode正規表現の10進後方参照は全桁で解決する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("abcdefghijkll");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)\\12/u");
    try roots.protect(&pattern);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqualSlices(u16, source.string.units, matched.string.units);

    var forward_source = try runtime.stringUtf8("abcdefghijkl");
    try roots.protect(&forward_source);
    var forward_pattern = try runtime.stringUtf8("/\\12(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)/u");
    try roots.protect(&forward_pattern);
    const forward_matched = (try call(&runtime, "正規表現マッチ", &.{ forward_source, forward_pattern })).?;
    try std.testing.expectEqualSlices(u16, forward_source.string.units, forward_matched.string.units);
}

test "名前付きキャプチャと非貪欲量指定を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("<a>1</a><a>2</a>");
    const result = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, try runtime.stringUtf8("/<a>(?<body>.+?)<\\/a>/g") })).?;
    try std.testing.expectEqual(@as(usize, 2), result.value.array.len());
    try std.testing.expect(result.captures.? == .array);
    try std.testing.expectEqual(@as(usize, 2), result.captures.?.array.len());
}

test "Unicode名前付き後方参照と未マッチ群の空一致を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("foo-foo");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/(?<word>[a-z]+)-\\k<word>/u");
    try roots.protect(&pattern);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqualSlices(u16, source.string.units, matched.string.units);

    var optional_source = try runtime.stringUtf8("y");
    try roots.protect(&optional_source);
    var optional_pattern = try runtime.stringUtf8("/(?<optional>x)?\\k<optional>/u");
    try roots.protect(&optional_pattern);
    const empty = (try call(&runtime, "正規表現マッチ", &.{ optional_source, optional_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{}, empty.string.units);
}

test "Unicode文字クラスの補助平面コードポイント範囲を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("😀A");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/[\\u{1F600}-\\u{1F64F}]/gu");
    try roots.protect(&pattern);
    const result = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqual(@as(usize, 1), result.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, result.array.items.items[0].string.units);

    var raw_pattern = try runtime.stringUtf8("/[😀]/u");
    try roots.protect(&raw_pattern);
    const raw_result = (try call(&runtime, "正規表現マッチ", &.{ source, raw_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, raw_result.string.units);

    var escaped_pair_pattern = try runtime.stringUtf8("/[\\uD83D\\uDE00]/u");
    try roots.protect(&escaped_pair_pattern);
    const escaped_pair_result = (try call(&runtime, "正規表現マッチ", &.{ source, escaped_pair_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, escaped_pair_result.string.units);
}

test "正規表現の空幅量指定は下限と上限内の反復を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("xa");

    const bounded = try runtime.stringUtf8("/(?:){2}a/");
    const bounded_result = (try call(&runtime, "正規表現マッチ", &.{ source, bounded })).?;
    try std.testing.expectEqualSlices(u16, &.{'a'}, bounded_result.string.units);

    const unbounded = try runtime.stringUtf8("/(){100,}/");
    const unbounded_result = (try callWithEffects(&runtime, "正規表現マッチ", &.{ source, unbounded })).?;
    try std.testing.expectEqualSlices(u16, &.{}, unbounded_result.value.string.units);
    const captures = unbounded_result.captures.?;
    try std.testing.expect(captures == .array);
    try std.testing.expectEqualSlices(u16, &.{}, captures.array.items.items[0].string.units);
}

test "正規表現の入れ子貪欲量指定は内側の選択を先に試す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const source = try runtime.stringUtf8("aaab");
    const pattern = try runtime.stringUtf8("/(a+)+b/");
    const result = (try callWithEffects(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expectEqualSlices(u16, source.string.units, result.value.string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'a', 'a' }, result.captures.?.array.items.items[0].string.units);
}

test "正規表現の反復captureは不参加branchを未定義へ戻す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("aba");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/(a(b)?)+/");
    try roots.protect(&pattern);
    const result = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, pattern })).?;
    const rows = result.captures.?;
    try std.testing.expect(rows == .array);
    try std.testing.expectEqual(@as(usize, 1), rows.array.len());
    const captures = rows.array.items.items[0];
    try std.testing.expect(captures == .array);
    try std.testing.expectEqualSlices(u16, &.{'a'}, captures.array.items.items[0].string.units);
    try std.testing.expect(captures.array.items.items[1] == .undefined);

    var second_source = try runtime.stringUtf8("abac");
    try roots.protect(&second_source);
    var second_pattern = try runtime.stringUtf8("/(a(b)?)+c/");
    try roots.protect(&second_pattern);
    const second_result = (try callWithEffects(&runtime, "正規表現抽出", &.{ second_source, second_pattern })).?;
    const second_captures = second_result.captures.?.array.items.items[0].array;
    try std.testing.expectEqualSlices(u16, &.{'a'}, second_captures.items.items[0].string.units);
    try std.testing.expect(second_captures.items.items[1] == .undefined);
}

test "後読みの量指定は右から捕捉する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    const cases = [_]struct {
        source: []const u8,
        pattern: []const u8,
        first: []const u8,
        second: []const u8,
    }{
        .{ .source = "abbbc", .pattern = "/(?<=([ab]+)([bc]+))c/", .first = "a", .second = "bbb" },
        .{ .source = "abbbc", .pattern = "/(?<=([ab]+)([bc]+?))c/", .first = "abb", .second = "b" },
        .{ .source = "abbbc", .pattern = "/(?<=([ab]+?)([bc]+?))c/", .first = "b", .second = "b" },
        .{ .source = "aab", .pattern = "/(?<=((a)\\2)\\1)b/", .first = "a", .second = "a" },
        .{ .source = "aaab", .pattern = "/(?<=((a+)\\2)\\1)b/", .first = "aaa", .second = "aaa" },
    };
    for (cases) |case| {
        var source = try runtime.stringUtf8(case.source);
        try roots.protect(&source);
        var pattern = try runtime.stringUtf8(case.pattern);
        try roots.protect(&pattern);
        const result = (try callWithEffects(&runtime, "正規表現抽出", &.{ source, pattern })).?;
        const rows = result.captures.?;
        try std.testing.expectEqual(@as(usize, 1), rows.array.len());
        const captures = rows.array.items.items[0].array;
        const first = try captures.items.items[0].string.toUtf8Lossy(std.testing.allocator);
        defer std.testing.allocator.free(first);
        const second = try captures.items.items[1].string.toUtf8Lossy(std.testing.allocator);
        defer std.testing.allocator.free(second);
        try std.testing.expectEqualStrings(case.first, first);
        try std.testing.expectEqualStrings(case.second, second);
    }
}

test "Unicode正規表現の探索はサロゲート対内部へ進まない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringCodeUnits(&.{ 0xd83d, 0xde00 });
    try roots.protect(&source);
    var low_unicode_pattern = try runtime.stringUtf8("/\\uDE00/u");
    try roots.protect(&low_unicode_pattern);
    const low_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, low_unicode_pattern })).?;
    try std.testing.expect(low_unicode == .null_value);

    var high_unicode_pattern = try runtime.stringUtf8("/\\uD83D/u");
    try roots.protect(&high_unicode_pattern);
    const high_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, high_unicode_pattern })).?;
    try std.testing.expect(high_unicode == .null_value);

    var class_pattern = try runtime.stringUtf8("/[\\uDE00]/u");
    try roots.protect(&class_pattern);
    const class_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, class_pattern })).?;
    try std.testing.expect(class_unicode == .null_value);

    var non_unicode_pattern = try runtime.stringUtf8("/\\uDE00/");
    try roots.protect(&non_unicode_pattern);
    const non_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, non_unicode_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{0xde00}, non_unicode.string.units);
}

test "Unicode lookbehindはサロゲート対内部を開始位置にしない" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("😀x");
    try roots.protect(&source);
    var low_unicode_pattern = try runtime.stringUtf8("/(?<=\\uDE00)x/u");
    try roots.protect(&low_unicode_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ source, low_unicode_pattern })).? == .null_value);

    var high_unicode_pattern = try runtime.stringUtf8("/(?<=\\uD83D)x/u");
    try roots.protect(&high_unicode_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ source, high_unicode_pattern })).? == .null_value);

    var pair_pattern = try runtime.stringUtf8("/(?<=😀)x/u");
    try roots.protect(&pair_pattern);
    const pair = (try call(&runtime, "正規表現マッチ", &.{ source, pair_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, pair.string.units);

    var non_unicode_pattern = try runtime.stringUtf8("/(?<=\\uDE00)x/");
    try roots.protect(&non_unicode_pattern);
    const non_unicode = (try call(&runtime, "正規表現マッチ", &.{ source, non_unicode_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, non_unicode.string.units);
}

test "Unicode大小文字無視のword判定を拡張する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var kelvin = try runtime.stringUtf8("K");
    try roots.protect(&kelvin);
    var word_pattern = try runtime.stringUtf8("/^\\w$/iu");
    try roots.protect(&word_pattern);
    const word = (try call(&runtime, "正規表現マッチ", &.{ kelvin, word_pattern })).?;
    try std.testing.expectEqualSlices(u16, kelvin.string.units, word.string.units);

    var boundary_pattern = try runtime.stringUtf8("/^\\b.\\b$/iu");
    try roots.protect(&boundary_pattern);
    const boundary = (try call(&runtime, "正規表現マッチ", &.{ kelvin, boundary_pattern })).?;
    try std.testing.expectEqualSlices(u16, kelvin.string.units, boundary.string.units);

    var ascii_only_pattern = try runtime.stringUtf8("/^\\w$/u");
    try roots.protect(&ascii_only_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ kelvin, ascii_only_pattern })).? == .null_value);

    var mixed = try runtime.stringUtf8("xKx");
    try roots.protect(&mixed);
    var non_boundary_pattern = try runtime.stringUtf8("/^x\\BK\\Bx$/iu");
    try roots.protect(&non_boundary_pattern);
    const non_boundary = (try call(&runtime, "正規表現マッチ", &.{ mixed, non_boundary_pattern })).?;
    try std.testing.expectEqualSlices(u16, mixed.string.units, non_boundary.string.units);

    var long_s = try runtime.stringUtf8("ſ");
    try roots.protect(&long_s);
    var unicode_sets_pattern = try runtime.stringUtf8("/^\\w$/iv");
    try roots.protect(&unicode_sets_pattern);
    const unicode_sets = (try call(&runtime, "正規表現マッチ", &.{ long_s, unicode_sets_pattern })).?;
    try std.testing.expectEqualSlices(u16, long_s.string.units, unicode_sets.string.units);
}

test "Unicode propertyの負集合はuとvのcase fold順序を分ける" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("aAkKKſS1éÉ");
    try roots.protect(&source);

    var unicode_pattern = try runtime.stringUtf8("/\\P{Lowercase_Letter}/giu");
    try roots.protect(&unicode_pattern);
    const unicode_match = (try call(&runtime, "正規表現マッチ", &.{ source, unicode_pattern })).?;
    try std.testing.expect(unicode_match == .array);
    try std.testing.expectEqual(@as(usize, 10), unicode_match.array.len());
    for (source.string.units, 0..) |unit, index| {
        try std.testing.expectEqualSlices(u16, &.{unit}, unicode_match.array.items.items[index].string.units);
    }

    var unicode_sets_pattern = try runtime.stringUtf8("/\\P{Lowercase_Letter}/giv");
    try roots.protect(&unicode_sets_pattern);
    const unicode_sets_match = (try call(&runtime, "正規表現マッチ", &.{ source, unicode_sets_pattern })).?;
    try std.testing.expect(unicode_sets_match == .array);
    try std.testing.expectEqual(@as(usize, 1), unicode_sets_match.array.len());
    try std.testing.expectEqualSlices(u16, &.{'1'}, unicode_sets_match.array.items.items[0].string.units);

    var ascii_source = try runtime.stringUtf8("kKK");
    try roots.protect(&ascii_source);
    var ascii_positive_pattern = try runtime.stringUtf8("/\\p{ASCII}/giv");
    try roots.protect(&ascii_positive_pattern);
    const ascii_positive = (try call(&runtime, "正規表現マッチ", &.{ ascii_source, ascii_positive_pattern })).?;
    try std.testing.expect(ascii_positive == .array);
    try std.testing.expectEqual(@as(usize, 2), ascii_positive.array.len());
    try std.testing.expectEqualSlices(u16, &.{'k'}, ascii_positive.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'K'}, ascii_positive.array.items.items[1].string.units);

    var ascii_negative_pattern = try runtime.stringUtf8("/\\P{ASCII}/giv");
    try roots.protect(&ascii_negative_pattern);
    const ascii_negative = (try call(&runtime, "正規表現マッチ", &.{ ascii_source, ascii_negative_pattern })).?;
    try std.testing.expect(ascii_negative == .array);
    try std.testing.expectEqual(@as(usize, 1), ascii_negative.array.len());
    try std.testing.expectEqualSlices(u16, &.{0x212a}, ascii_negative.array.items.items[0].string.units);
}

test "vフラグの文字集合intersectionとsubtractionを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var ascii_word_source = try runtime.stringUtf8("aé1_");
    try roots.protect(&ascii_word_source);
    var ascii_word_pattern = try runtime.stringUtf8("/[\\w&&\\p{ASCII}]/gv");
    try roots.protect(&ascii_word_pattern);
    const ascii_word = (try call(&runtime, "正規表現マッチ", &.{ ascii_word_source, ascii_word_pattern })).?;
    try std.testing.expect(ascii_word == .array);
    try std.testing.expectEqual(@as(usize, 3), ascii_word.array.len());
    try std.testing.expectEqualSlices(u16, &.{'a'}, ascii_word.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'1'}, ascii_word.array.items.items[1].string.units);
    try std.testing.expectEqualSlices(u16, &.{'_'}, ascii_word.array.items.items[2].string.units);

    var consonant_source = try runtime.stringUtf8("AbEc");
    try roots.protect(&consonant_source);
    var consonant_pattern = try runtime.stringUtf8("/[[a-z]--[aeiou]]/giv");
    try roots.protect(&consonant_pattern);
    const consonants = (try call(&runtime, "正規表現マッチ", &.{ consonant_source, consonant_pattern })).?;
    try std.testing.expect(consonants == .array);
    try std.testing.expectEqual(@as(usize, 2), consonants.array.len());
    try std.testing.expectEqualSlices(u16, &.{'b'}, consonants.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'c'}, consonants.array.items.items[1].string.units);

    var non_ascii_source = try runtime.stringUtf8("Aé😀");
    try roots.protect(&non_ascii_source);
    var non_ascii_pattern = try runtime.stringUtf8("/[\\p{Any}--\\p{ASCII}]/gv");
    try roots.protect(&non_ascii_pattern);
    const non_ascii = (try call(&runtime, "正規表現マッチ", &.{ non_ascii_source, non_ascii_pattern })).?;
    try std.testing.expect(non_ascii == .array);
    try std.testing.expectEqual(@as(usize, 2), non_ascii.array.len());
    try std.testing.expectEqualSlices(u16, &.{0x00e9}, non_ascii.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, non_ascii.array.items.items[1].string.units);

    var letter_source = try runtime.stringUtf8("A1é");
    try roots.protect(&letter_source);
    var letter_pattern = try runtime.stringUtf8("/[\\p{ASCII}&&\\p{Letter}]/gv");
    try roots.protect(&letter_pattern);
    const letter = (try call(&runtime, "正規表現マッチ", &.{ letter_source, letter_pattern })).?;
    try std.testing.expect(letter == .array);
    try std.testing.expectEqual(@as(usize, 1), letter.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, letter.array.items.items[0].string.units);
}

test "アンカー・空クラス・先読み・後読みを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var lines = try runtime.stringUtf8("x\ny");
    try roots.protect(&lines);
    var multiline = try runtime.stringUtf8("/^y/m");
    try roots.protect(&multiline);
    const anchored = (try call(&runtime, "正規表現マッチ", &.{ lines, multiline })).?;
    try std.testing.expect(anchored == .string);
    try std.testing.expectEqualSlices(u16, &.{'y'}, anchored.string.units);

    var all_units = try runtime.stringUtf8("/[^]/g");
    try roots.protect(&all_units);
    const any = (try call(&runtime, "正規表現マッチ", &.{ lines, all_units })).?;
    try std.testing.expectEqual(@as(usize, 3), any.array.len());
    var empty_class = try runtime.stringUtf8("/[]/");
    try roots.protect(&empty_class);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ lines, empty_class })).? == .null_value);

    var source = try runtime.stringUtf8("abac abcb");
    try roots.protect(&source);
    const patterns = [_][]const u8{ "/a(?=b)/g", "/a(?!b)/g", "/(?<=a)b/g", "/(?<!a)b/g" };
    const expected_counts = [_]usize{ 2, 1, 2, 1 };
    for (patterns, expected_counts) |text, expected_count| {
        var pattern = try runtime.stringUtf8(text);
        try roots.protect(&pattern);
        const result = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
        try std.testing.expectEqual(expected_count, result.array.len());
    }
}

test "二桁の量指定とゼロ幅区切をJavaScript互換で処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("aaaaaaaaaa");
    try roots.protect(&source);
    var quantified = try runtime.stringUtf8("/a{10}/");
    try roots.protect(&quantified);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, quantified })).?;
    try std.testing.expectEqual(@as(usize, 10), matched.string.units.len);

    var split_source = try runtime.stringUtf8("ab");
    try roots.protect(&split_source);
    var empty_pattern = try runtime.stringUtf8("(?:)");
    try roots.protect(&empty_pattern);
    const split = (try call(&runtime, "正規表現区切", &.{ split_source, empty_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), split.array.len());
    try std.testing.expectEqualSlices(u16, &.{'a'}, split.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'b'}, split.array.items.items[1].string.units);

    var consuming_pattern = try runtime.stringUtf8("/a*/");
    try roots.protect(&consuming_pattern);
    const consuming_split = (try call(&runtime, "正規表現区切", &.{ split_source, consuming_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), consuming_split.array.len());
    try std.testing.expectEqual(@as(usize, 0), consuming_split.array.items.items[0].string.units.len);
    try std.testing.expectEqualSlices(u16, &.{'b'}, consuming_split.array.items.items[1].string.units);
}

test "大文字小文字を区別しない照合は非ASCII文字にも適用する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var source = try runtime.stringUtf8("ÉCOLE");
    try roots.protect(&source);
    var pattern = try runtime.stringUtf8("/école/i");
    try roots.protect(&pattern);
    const matched = (try call(&runtime, "正規表現マッチ", &.{ source, pattern })).?;
    try std.testing.expect(matched == .string);
}

test "Unicode・sticky・indicesフラグはUTF-16共有エンジンで処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringCodeUnits(&.{ 0xd83d, 0xde00, 'x' });
    try roots.protect(&source);
    var unicode_pattern = try runtime.stringUtf8("/./gu");
    try roots.protect(&unicode_pattern);
    const unicode_matches = (try call(&runtime, "正規表現マッチ", &.{ source, unicode_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), unicode_matches.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, unicode_matches.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'x'}, unicode_matches.array.items.items[1].string.units);

    var split_pattern = try runtime.stringUtf8("/./u");
    try roots.protect(&split_pattern);
    const split = (try call(&runtime, "正規表現区切", &.{ source, split_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), split.array.len());
    for (split.array.items.items) |item| try std.testing.expectEqual(@as(usize, 0), item.string.units.len);

    var sticky_source = try runtime.stringUtf8("ba");
    try roots.protect(&sticky_source);
    var sticky_pattern = try runtime.stringUtf8("/a/y");
    try roots.protect(&sticky_pattern);
    try std.testing.expect((try call(&runtime, "正規表現マッチ", &.{ sticky_source, sticky_pattern })).? == .null_value);

    var sticky_global_source = try runtime.stringUtf8("aaab");
    try roots.protect(&sticky_global_source);
    var sticky_global_pattern = try runtime.stringUtf8("/a/gy");
    try roots.protect(&sticky_global_pattern);
    const sticky_global = (try call(&runtime, "正規表現マッチ", &.{ sticky_global_source, sticky_global_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), sticky_global.array.len());

    var escaped_pattern = try runtime.stringUtf8("/\\u{1F600}/u");
    try roots.protect(&escaped_pattern);
    const escaped = (try call(&runtime, "正規表現マッチ", &.{ source, escaped_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, escaped.string.units);

    var fold_source = try runtime.stringUtf8("𐐨ſK");
    try roots.protect(&fold_source);
    var fold_pattern = try runtime.stringUtf8("/\\u{10400}sk/iu");
    try roots.protect(&fold_pattern);
    const folded = (try call(&runtime, "正規表現マッチ", &.{ fold_source, fold_pattern })).?;
    try std.testing.expectEqualSlices(u16, fold_source.string.units, folded.string.units);

    var fold_property_source = try runtime.stringUtf8("AK");
    try roots.protect(&fold_property_source);
    var fold_property_pattern = try runtime.stringUtf8("/\\p{Lowercase_Letter}/giu");
    try roots.protect(&fold_property_pattern);
    const folded_properties = (try call(&runtime, "正規表現マッチ", &.{ fold_property_source, fold_property_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), folded_properties.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, folded_properties.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{0x212a}, folded_properties.array.items.items[1].string.units);

    var indices_pattern = try runtime.stringUtf8("/(x)/d");
    try roots.protect(&indices_pattern);
    const indices = (try call(&runtime, "正規表現マッチ", &.{ source, indices_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'x'}, indices.string.units);

    var control_source = try runtime.stringCodeUnits(&.{1});
    try roots.protect(&control_source);
    var control_pattern = try runtime.stringUtf8("/\\cA/u");
    try roots.protect(&control_pattern);
    const control = (try call(&runtime, "正規表現マッチ", &.{ control_source, control_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{1}, control.string.units);

    var lone_surrogate_source = try runtime.stringCodeUnits(&.{0xd800});
    try roots.protect(&lone_surrogate_source);
    var lone_surrogate_pattern = try runtime.stringUtf8("/\\u{D800}/u");
    try roots.protect(&lone_surrogate_pattern);
    const lone_surrogate = (try call(&runtime, "正規表現マッチ", &.{ lone_surrogate_source, lone_surrogate_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{0xd800}, lone_surrogate.string.units);
}

test "Unicode setsのvフラグは基本照合と未対応構文を扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("😀A1あ");
    try roots.protect(&source);
    var any_pattern = try runtime.stringUtf8("/./vg");
    try roots.protect(&any_pattern);
    const any = (try call(&runtime, "正規表現マッチ", &.{ source, any_pattern })).?;
    try std.testing.expectEqual(@as(usize, 4), any.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, any.array.items.items[0].string.units);

    var property_pattern = try runtime.stringUtf8("/\\p{Letter}/vg");
    try roots.protect(&property_pattern);
    const letters = (try call(&runtime, "正規表現マッチ", &.{ source, property_pattern })).?;
    try std.testing.expect(letters == .array);
    try std.testing.expectEqual(@as(usize, 2), letters.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, letters.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'あ'}, letters.array.items.items[1].string.units);

    var invalid_flags = try runtime.stringUtf8("/a/uv");
    try roots.protect(&invalid_flags);
    try std.testing.expectError(error.UnsupportedRegularExpressionFlag, call(&runtime, "正規表現マッチ", &.{ source, invalid_flags }));
    try std.testing.expectEqualStrings("Invalid flags supplied to RegExp constructor 'uv'", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    var unsupported_set = try runtime.stringUtf8("/[a-z--[aeiou]]/v");
    try roots.protect(&unsupported_set);
    try std.testing.expectError(error.UnsupportedUnicodeSetOperation, call(&runtime, "正規表現マッチ", &.{ source, unsupported_set }));
    try std.testing.expectEqualStrings("Invalid regular expression: /[a-z--[aeiou]]/v: Invalid set operation in character class", runtime.failureMessage().?);
}

test "Unicode property escapeは生成済み静的範囲を使う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var source = try runtime.stringUtf8("A1あ😀 ");
    try roots.protect(&source);
    var letter_pattern = try runtime.stringUtf8("/\\p{Letter}/gu");
    try roots.protect(&letter_pattern);
    const letters = (try call(&runtime, "正規表現マッチ", &.{ source, letter_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), letters.array.len());
    try std.testing.expectEqualSlices(u16, &.{'A'}, letters.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'あ'}, letters.array.items.items[1].string.units);

    var non_ascii_pattern = try runtime.stringUtf8("/\\P{ASCII}/gu");
    try roots.protect(&non_ascii_pattern);
    const non_ascii = (try call(&runtime, "正規表現マッチ", &.{ source, non_ascii_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), non_ascii.array.len());
    try std.testing.expectEqualSlices(u16, &.{'あ'}, non_ascii.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, non_ascii.array.items.items[1].string.units);

    var number_source = try runtime.stringUtf8("1");
    try roots.protect(&number_source);
    var number_pattern = try runtime.stringUtf8("/\\p{Decimal_Number}/u");
    try roots.protect(&number_pattern);
    const number = (try call(&runtime, "正規表現マッチ", &.{ number_source, number_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'1'}, number.string.units);

    var hiragana_source = try runtime.stringUtf8("あ");
    try roots.protect(&hiragana_source);
    var hiragana_pattern = try runtime.stringUtf8("/\\p{Script=Hiragana}/u");
    try roots.protect(&hiragana_pattern);
    const hiragana = (try call(&runtime, "正規表現マッチ", &.{ hiragana_source, hiragana_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'あ'}, hiragana.string.units);

    var class_source = try runtime.stringUtf8("A1");
    try roots.protect(&class_source);
    var class_pattern = try runtime.stringUtf8("/[\\p{Letter}\\p{Decimal_Number}]/gu");
    try roots.protect(&class_pattern);
    const class_matches = (try call(&runtime, "正規表現マッチ", &.{ class_source, class_pattern })).?;
    try std.testing.expectEqual(@as(usize, 2), class_matches.array.len());

    var alias_source = try runtime.stringUtf8("F🏻$");
    try roots.protect(&alias_source);
    var alias_pattern = try runtime.stringUtf8("/[\\p{AHex}\\p{Emoji_Modifier}\\p{gc=Sc}]/gu");
    try roots.protect(&alias_pattern);
    const aliases = (try call(&runtime, "正規表現マッチ", &.{ alias_source, alias_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), aliases.array.len());

    var xid_pattern = try runtime.stringUtf8("/\\p{XID_Start}/u");
    try roots.protect(&xid_pattern);
    const xid = (try call(&runtime, "正規表現マッチ", &.{ hiragana_source, xid_pattern })).?;
    try std.testing.expectEqualSlices(u16, &.{'あ'}, xid.string.units);

    var script_extensions_source = try runtime.stringUtf8("ー゠・々あア漢");
    try roots.protect(&script_extensions_source);
    var script_extensions_pattern = try runtime.stringUtf8("/\\p{scx=Hira}/gu");
    try roots.protect(&script_extensions_pattern);
    const hiragana_extensions = (try call(&runtime, "正規表現マッチ", &.{ script_extensions_source, script_extensions_pattern })).?;
    try std.testing.expectEqual(@as(usize, 4), hiragana_extensions.array.len());
    try std.testing.expectEqualSlices(u16, &.{'ー'}, hiragana_extensions.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'゠'}, hiragana_extensions.array.items.items[1].string.units);
    try std.testing.expectEqualSlices(u16, &.{'・'}, hiragana_extensions.array.items.items[2].string.units);
    try std.testing.expectEqualSlices(u16, &.{'あ'}, hiragana_extensions.array.items.items[3].string.units);

    var han_extensions_pattern = try runtime.stringUtf8("/\\p{Script_Extensions=Han}/gu");
    try roots.protect(&han_extensions_pattern);
    const han_extensions = (try call(&runtime, "正規表現マッチ", &.{ script_extensions_source, han_extensions_pattern })).?;
    try std.testing.expectEqual(@as(usize, 3), han_extensions.array.len());
    try std.testing.expectEqualSlices(u16, &.{'・'}, han_extensions.array.items.items[0].string.units);
    try std.testing.expectEqualSlices(u16, &.{'々'}, han_extensions.array.items.items[1].string.units);
    try std.testing.expectEqualSlices(u16, &.{'漢'}, han_extensions.array.items.items[2].string.units);

    var adlam_source = try runtime.stringUtf8("𞤀A");
    try roots.protect(&adlam_source);
    var adlam_pattern = try runtime.stringUtf8("/\\p{sc=Adlm}/gu");
    try roots.protect(&adlam_pattern);
    const adlam = (try call(&runtime, "正規表現マッチ", &.{ adlam_source, adlam_pattern })).?;
    try std.testing.expectEqual(@as(usize, 1), adlam.array.len());
    try std.testing.expectEqualSlices(u16, &.{ 0xd83a, 0xdd00 }, adlam.array.items.items[0].string.units);

    var invalid_pattern = try runtime.stringUtf8("/\\p{Nope}/u");
    try roots.protect(&invalid_pattern);
    try std.testing.expectError(error.InvalidUnicodeProperty, call(&runtime, "正規表現マッチ", &.{ source, invalid_pattern }));
    try std.testing.expectEqualStrings("Invalid regular expression: /\\p{Nope}/u: Invalid property name", runtime.failureMessage().?);
}
