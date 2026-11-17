const std = @import("std");
const js_scanner = @import("js_scanner.zig");

/// package経由plugin命令のソース上の修飾aliasと、runtime登録名への写像。
/// ソースは `<source_namespace>__<命令>` で束縛するが、実際のdispatch名は
/// `dispatch_namespace` 側を使う。root scope のimportでは両者が一致し、
/// package内scopeの推移importでは所有者keyを含む修飾名になる。
pub const DynamicCommandAlias = struct {
    /// Source-level alias the user writes (e.g. `util`).
    /// `unqualified=true` のときは空でもよく、ソース上の無修飾命令名を
    /// `{dispatch_namespace}__{命令}` へ写す catch-all として使う。
    source_namespace: []const u8,
    /// Runtime dispatch prefix the command was registered under
    /// (e.g. `pkg_a__util` for a transitive dependency of package A).
    dispatch_namespace: []const u8,
    /// このaliasを導入する取り込み文のソース位置。それより前に書かれた
    /// `alias__命令` は対応する `pkg:` import がまだ無いため束縛しない
    /// （source packageの `NamespaceAlias.import_position` と同じ規則）。
    import_position: usize = 0,
    /// true: package所有module内の相対native plugin取り込み。取り込み位置
    /// 以降の無修飾命令名を `{dispatch_namespace}__{命令}` へ写像する
    /// （runtime は owner 固有 namespace へ隔離登録済み）。修飾名
    /// `<source>__<命令>` の longest-prefix 規則とは別経路。
    unqualified: bool = false,
    /// true: `source_namespace` と完全一致する呼出しだけを受理する。
    /// `ナデシコ`/`ナデシコ続` の動的評価、および package 内 ESM plugin の
    /// 抽出済み無修飾命令名に使用し、`dispatch_namespace` へ直接写像する。
    /// prefix一致や無修飾catch-allへ流さず、未登録名は診断させる。
    exact: bool = false,
};

/// 動的builtinとして束縛する命令名か判定する。直接取り込んだnative plugin
/// （`allows_dynamic_commands`）は任意名を受理し、package経由のnative plugin
/// （`dynamic_command_aliases`）は `<alias>__<命令>` の修飾名のみ受理する。
/// 一致した package alias を返す（dispatch namespace への写像用）。
/// package alias 一致は直接plugin fallbackより先に評価する。両方を取り込んだ
/// moduleで `util__命令` が恒等写像へ先に流れると、依存pluginが登録した
/// `{owner}__util__命令` には届かず、直接pluginの同名raw命令へ誤配送される。
/// `use_position` は呼出し側のソース位置で、import 文より前の参照はaliasを
/// 持たない扱いにする（取り込み前の修飾名がpreinstalled pluginへ誤配送
/// されるのを防ぐ）。`allows_from` は直接plugin取り込みを有効にした最初の
/// import位置。
pub fn binds(allows_dynamic_commands: bool, allows_from: usize, aliases: []const DynamicCommandAlias, name: []const u8, use_position: usize) ?DynamicCommandAlias {
    // 実行時登録名およびESM plugin抽出命令名の完全一致はprefix規則より先に
    // 評価する（dispatch名そのもの、または取り込み位置以降の所有plugin解決）。
    // 同名命令を複数pluginが持つ場合は後勝ち（最大のimport_position）にする。
    var selected_exact: ?DynamicCommandAlias = null;
    for (aliases) |alias| {
        if (!alias.exact) continue;
        if (use_position < alias.import_position) continue;
        if (std.mem.eql(u8, alias.source_namespace, name)) {
            if (selected_exact == null or alias.import_position >= selected_exact.?.import_position)
                selected_exact = alias;
        }
    }
    if (selected_exact) |alias| return alias;
    // 最長 namespace を優先する（`foo` と `foo__bar` が併存するとき短い
    // 方が先に一致して誤配送しないよう、analyzer の namespace alias と同じ
    // longest-prefix 規則）。
    var selected: ?DynamicCommandAlias = null;
    for (aliases) |alias| {
        if (alias.unqualified or alias.exact) continue;
        if (use_position < alias.import_position) continue;
        if (std.mem.startsWith(u8, name, alias.source_namespace) and name.len > alias.source_namespace.len + 2 and
            name[alias.source_namespace.len] == '_' and name[alias.source_namespace.len + 1] == '_')
        {
            if (selected == null or alias.source_namespace.len > selected.?.source_namespace.len) selected = alias;
        }
    }
    if (selected) |alias| return alias;
    // package内相対native/非静的ESM: 取り込み位置以降の無修飾命令を owner 修飾
    // dispatch へ写す。複数ある場合はより後の取り込みを優先する（後勝ち）。
    var selected_unqualified: ?DynamicCommandAlias = null;
    for (aliases) |alias| {
        if (!alias.unqualified or alias.exact) continue;
        if (use_position < alias.import_position) continue;
        if (selected_unqualified == null or alias.import_position >= selected_unqualified.?.import_position)
            selected_unqualified = alias;
    }
    if (selected_unqualified) |alias| return alias;
    if (allows_dynamic_commands and use_position >= allows_from) return .{ .source_namespace = name, .dispatch_namespace = name };
    return null;
}

/// `binds` が受理したソース名を runtime 登録名へ変換する。
/// package内scopeの推移importでは `dispatch_namespace` が所有者修飾を含む
/// （例: `util__足す` → `pkg_a__util__足す`）。root scope は alias がそのまま
/// 登録名なので変換しない。`unqualified` は無修飾名を
/// `{dispatch_namespace}__{命令}` へ写す（相対nativeの owner 隔離登録と一致）。
/// `exact` は `dispatch_namespace` が既に完全な dispatch 名を持つためそのまま返す。
pub fn dispatchName(allocator: std.mem.Allocator, alias: DynamicCommandAlias, name: []const u8) ![]const u8 {
    if (alias.unqualified) {
        return std.fmt.allocPrint(allocator, "{s}__{s}", .{ alias.dispatch_namespace, name });
    }
    if (alias.exact) {
        if (std.mem.eql(u8, alias.dispatch_namespace, name)) return name;
        return allocator.dupe(u8, alias.dispatch_namespace);
    }
    if (std.mem.eql(u8, alias.dispatch_namespace, alias.source_namespace)) return name;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ alias.dispatch_namespace, name[alias.source_namespace.len..] });
}

/// package所有module内のESM plugin (`source`) から登録命令キーを静的抽出し、
/// `aliases` へ `exact` alias (`{dispatch_namespace}__{命令}`) として追加する。
/// `export default { ... }`・`const X = { ... }; export default X;`・
/// `addPluginObject(..., { ... })` を解析し、検出した全plugin定義が静的
/// オブジェクトリテラル（`...spread` や算出キー無し）で完結する場合は `true`
/// を返す。解析不能な動的構成がある場合は `false` を返し、呼出し側が
/// unqualified catch-all fallback を置けるようにする。
pub fn appendJavaScriptPluginAliases(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList(DynamicCommandAlias),
    source: []const u8,
    dispatch_namespace: []const u8,
    import_position: usize,
) !bool {
    var scanner = js_scanner.JavaScriptScanner{ .source = source };
    var tokens: std.ArrayList(js_scanner.JavaScriptToken) = .empty;
    defer tokens.deinit(allocator);
    while (scanner.next()) |token| try tokens.append(allocator, token);
    if (scanner.truncated) return false;

    const items = tokens.items;
    var found_plugin_site = false;
    var all_static_complete = true;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < items.len) : (index += 1) {
        const token = items[index];
        const prev_is_dot = index > 0 and isPunct(items[index - 1], ".");
        if (depth == 0 and !prev_is_dot and isIdent(token, "export") and index + 1 < items.len and isIdent(items[index + 1], "default")) {
            found_plugin_site = true;
            const expr_start = unwrapParens(items, index + 2, items.len);
            if (expr_start >= items.len) {
                all_static_complete = false;
            } else if (isPunct(items[expr_start], "{")) {
                const ok = try extractObjectLiteralKeys(allocator, aliases, items, expr_start, dispatch_namespace, import_position);
                if (!ok) all_static_complete = false;
            } else if (items[expr_start].kind == .identifier and !isExpressionKeyword(items[expr_start].text) and isSimpleIdentEnd(items, expr_start)) {
                if (findVariableObjectInitializer(items, index, items[expr_start].text)) |obj_brace| {
                    const ok = try extractObjectLiteralKeys(allocator, aliases, items, obj_brace, dispatch_namespace, import_position);
                    if (!ok) all_static_complete = false;
                } else {
                    all_static_complete = false;
                }
            } else {
                all_static_complete = false;
            }
        } else if (isIdent(token, "addPluginObject") and !(index > 0 and isIdent(items[index - 1], "function")) and index + 1 < items.len and isPunct(items[index + 1], "(")) {
            found_plugin_site = true;
            const ok = try extractAddPluginObjectSecondArg(allocator, aliases, items, index + 1, dispatch_namespace, import_position);
            if (!ok) all_static_complete = false;
        }
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token) and depth > 0) {
            depth -= 1;
        }
    }
    return found_plugin_site and all_static_complete;
}

fn isPunct(token: js_scanner.JavaScriptToken, expected: []const u8) bool {
    return token.kind == .punctuation and std.mem.eql(u8, token.text, expected);
}

fn isIdent(token: js_scanner.JavaScriptToken, expected: []const u8) bool {
    return token.kind == .identifier and std.mem.eql(u8, token.text, expected);
}

fn isOpenDelim(token: js_scanner.JavaScriptToken) bool {
    return token.kind == .punctuation and (std.mem.eql(u8, token.text, "{") or std.mem.eql(u8, token.text, "(") or std.mem.eql(u8, token.text, "["));
}

fn isCloseDelim(token: js_scanner.JavaScriptToken) bool {
    return token.kind == .punctuation and (std.mem.eql(u8, token.text, "}") or std.mem.eql(u8, token.text, ")") or std.mem.eql(u8, token.text, "]"));
}

fn isExpressionKeyword(text: []const u8) bool {
    return std.mem.eql(u8, text, "function") or
        std.mem.eql(u8, text, "async") or
        std.mem.eql(u8, text, "class") or
        std.mem.eql(u8, text, "await") or
        std.mem.eql(u8, text, "new");
}

fn isSimpleIdentEnd(items: []const js_scanner.JavaScriptToken, ident_index: usize) bool {
    if (ident_index + 1 >= items.len) return true;
    const next_token = items[ident_index + 1];
    return !(isPunct(next_token, ".") or
        isPunct(next_token, "(") or
        isPunct(next_token, "[") or
        isPunct(next_token, "+") or
        isPunct(next_token, "?"));
}

fn unwrapParens(items: []const js_scanner.JavaScriptToken, start: usize, limit: usize) usize {
    var pos = start;
    while (pos < limit and isPunct(items[pos], "(")) pos += 1;
    return pos;
}

fn findVariableObjectInitializer(items: []const js_scanner.JavaScriptToken, limit: usize, name: []const u8) ?usize {
    var depth: usize = 0;
    var found: ?usize = null;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const token = items[index];
        if (depth == 0 and token.kind == .identifier and
            (std.mem.eql(u8, token.text, "const") or std.mem.eql(u8, token.text, "let") or std.mem.eql(u8, token.text, "var")) and
            index + 2 < limit and isIdent(items[index + 1], name) and isPunct(items[index + 2], "="))
        {
            const rhs = unwrapParens(items, index + 3, limit);
            found = if (rhs < limit and isPunct(items[rhs], "{")) rhs else null;
        }
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token) and depth > 0) {
            depth -= 1;
        }
    }
    return found;
}

fn extractAddPluginObjectSecondArg(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList(DynamicCommandAlias),
    items: []const js_scanner.JavaScriptToken,
    open_paren_index: usize,
    dispatch_namespace: []const u8,
    import_position: usize,
) !bool {
    var pos = open_paren_index + 1;
    var nested: usize = 0;
    var arg2_start: ?usize = null;
    while (pos < items.len) : (pos += 1) {
        const token = items[pos];
        if (nested == 0 and isPunct(token, ",")) {
            arg2_start = pos + 1;
            break;
        }
        if (nested == 0 and isPunct(token, ")")) return false;
        if (isOpenDelim(token)) {
            nested += 1;
        } else if (isCloseDelim(token) and nested > 0) {
            nested -= 1;
        }
    }
    const raw_start = arg2_start orelse return false;
    const expr_start = unwrapParens(items, raw_start, items.len);
    if (expr_start >= items.len) return false;
    if (isPunct(items[expr_start], "{")) {
        return extractObjectLiteralKeys(allocator, aliases, items, expr_start, dispatch_namespace, import_position);
    }
    if (items[expr_start].kind == .identifier and !isExpressionKeyword(items[expr_start].text) and
        (expr_start + 1 >= items.len or isPunct(items[expr_start + 1], ",") or isPunct(items[expr_start + 1], ")")))
    {
        const obj_brace = findVariableObjectInitializer(items, open_paren_index, items[expr_start].text) orelse return false;
        return extractObjectLiteralKeys(allocator, aliases, items, obj_brace, dispatch_namespace, import_position);
    }
    return false;
}

fn extractObjectLiteralKeys(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList(DynamicCommandAlias),
    items: []const js_scanner.JavaScriptToken,
    open_brace_index: usize,
    dispatch_namespace: []const u8,
    import_position: usize,
) !bool {
    var complete = true;
    var pos = open_brace_index + 1;
    while (pos < items.len) {
        if (isPunct(items[pos], "}")) return complete;
        // Skip empty comma if present
        if (isPunct(items[pos], ",")) {
            pos += 1;
            continue;
        }
        // Check spread `...expr` or computed property `[expr]: ...`
        if ((pos + 2 < items.len and isPunct(items[pos], ".") and isPunct(items[pos + 1], ".") and isPunct(items[pos + 2], ".")) or
            isPunct(items[pos], "["))
        {
            complete = false;
            pos = skipPropertyRemainder(items, pos);
            continue;
        }
        // Skip optional generator star `*`
        if (isPunct(items[pos], "*")) pos += 1;
        if (pos >= items.len) return false;
        // Skip `get`/`set`/`async` method modifier when followed by a property name (not `:`, `(`, `,`, `}`)
        if (items[pos].kind == .identifier and
            (std.mem.eql(u8, items[pos].text, "get") or std.mem.eql(u8, items[pos].text, "set") or std.mem.eql(u8, items[pos].text, "async")) and
            pos + 1 < items.len and
            (items[pos + 1].kind == .identifier or items[pos + 1].kind == .string or isPunct(items[pos + 1], "*")))
        {
            pos += 1;
            if (isPunct(items[pos], "*")) pos += 1;
            if (pos >= items.len) return false;
        }
        var raw_key: ?[]const u8 = null;
        if (items[pos].kind == .identifier) {
            raw_key = items[pos].text;
            pos += 1;
        } else if (items[pos].kind == .string) {
            if (try unescapeSimpleString(allocator, items[pos].text)) |decoded| {
                raw_key = decoded;
            } else {
                complete = false;
            }
            pos += 1;
        } else {
            complete = false;
        }
        if (raw_key) |key| {
            // `quickjs.zig` の `__lnako_registerPlugin` と同じ除外規則:
            // `meta` / `初期化` / `__` 含有名は package 修飾コマンドとして登録されない。
            if (!std.mem.eql(u8, key, "meta") and
                !std.mem.eql(u8, key, "初期化") and
                std.mem.indexOf(u8, key, "__") == null)
            {
                const dispatch = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ dispatch_namespace, key });
                var duplicate = false;
                for (aliases.items) |existing| {
                    if (existing.exact and
                        existing.import_position == import_position and
                        std.mem.eql(u8, existing.source_namespace, key) and
                        std.mem.eql(u8, existing.dispatch_namespace, dispatch))
                    {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) {
                    try aliases.append(allocator, .{
                        .source_namespace = try allocator.dupe(u8, key),
                        .dispatch_namespace = dispatch,
                        .import_position = import_position,
                        .exact = true,
                    });
                }
            }
        }
        pos = skipPropertyRemainder(items, pos);
    }
    return false;
}

fn unescapeSimpleString(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\\') {
            if (i + 1 >= raw.len) return null;
            i += 1;
            switch (raw[i]) {
                '\\', '\'', '"' => try out.append(allocator, raw[i]),
                else => {
                    out.deinit(allocator);
                    return null;
                },
            }
        } else {
            try out.append(allocator, raw[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn skipPropertyRemainder(items: []const js_scanner.JavaScriptToken, start: usize) usize {
    var pos = start;
    var depth: usize = 0;
    while (pos < items.len) : (pos += 1) {
        const token = items[pos];
        if (depth == 0 and isPunct(token, ",")) return pos + 1;
        if (depth == 0 and isPunct(token, "}")) return pos;
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token) and depth > 0) {
            depth -= 1;
        }
    }
    return pos;
}

test "appendJavaScriptPluginAliases は export default と addPluginObject から命令名を抽出し meta・初期化・__ 含有名を除外する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const ok = try appendJavaScriptPluginAliases(allocator, &aliases,
        \\import { x } from "./helper.mjs";
        \\// export default { ダミー: {} }
        \\const re = /}/g;
        \\export default {
        \\  meta: { type: "const", value: {} },
        \\  初期化: { type: "func", fn: () => {} },
        \\  '内部__隠し': { type: "func", fn: () => {} },
        \\  外部甲: { type: "func", josi: [], fn: () => 1 },
        \\  "外部乙": { type: "func", josi: [], fn: () => `${re}` },
        \\};
        \\navigator.nako3.addPluginObject("extra", {
        \\  外部丙: { type: "func", fn: () => 3 },
        \\});
    , "pkg:test:a.mjs", 42);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 3), aliases.items.len);
    try std.testing.expectEqualStrings("外部甲", aliases.items[0].source_namespace);
    try std.testing.expectEqualStrings("pkg:test:a.mjs__外部甲", aliases.items[0].dispatch_namespace);
    try std.testing.expectEqual(@as(usize, 42), aliases.items[0].import_position);
    try std.testing.expect(aliases.items[0].exact);
    try std.testing.expectEqualStrings("外部乙", aliases.items[1].source_namespace);
    try std.testing.expectEqualStrings("外部丙", aliases.items[2].source_namespace);
}

test "appendJavaScriptPluginAliases は spread や動的生成式で false を返し fallback を許容する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const spread_ok = try appendJavaScriptPluginAliases(allocator, &aliases, "export default { ...base, 外部甲: { type: 'func', fn: () => 1 } };", "pkg:test:a.mjs", 10);
    try std.testing.expect(!spread_ok);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("外部甲", aliases.items[0].source_namespace);

    var dynamic_aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const dynamic_ok = try appendJavaScriptPluginAliases(allocator, &dynamic_aliases, "export default buildPlugin();", "pkg:test:b.mjs", 20);
    try std.testing.expect(!dynamic_ok);
    try std.testing.expectEqual(@as(usize, 0), dynamic_aliases.items.len);
}

test "binds の exact alias は import_position 以降のみ許可し後勝ちで選ぶ" {
    const aliases = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:one.mjs__外部甲", .import_position = 10, .exact = true },
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:two.mjs__外部甲", .import_position = 30, .exact = true },
        .{ .source_namespace = "外部乙", .dispatch_namespace = "pkg:a:two.mjs__外部乙", .import_position = 30, .exact = true },
    };
    try std.testing.expect(binds(false, 0, &aliases, "外部甲", 5) == null);
    const first = binds(false, 0, &aliases, "外部甲", 20) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pkg:a:one.mjs__外部甲", first.dispatch_namespace);
    const second = binds(false, 0, &aliases, "外部甲", 40) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pkg:a:two.mjs__外部甲", second.dispatch_namespace);
}
