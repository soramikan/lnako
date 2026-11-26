const std = @import("std");
const js_scanner = @import("js_scanner.zig");
const argument_completion = @import("argument_completion.zig");

/// ESM plugin entry の `josi` 配列を、公式`yCallFunc`のスロット表として
/// 保持する。`slots[slot][alternative]` の文字列で、空文字列は助詞なしを表す。
pub const JosiSignature = struct {
    slots: []const []const []const u8,
    variable_final: bool = false,
    /// `isVariableJosi` をリテラル真偽値として確定できたか。省略時はJSの
    /// false と同じだが、式で書かれた場合は実登録メタデータでのみ決まる。
    variable_known: bool = true,
};

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
    /// 静的に「関数」と確認できた命令か。ESM plugin の `type: "const"` の
    /// ような非関数entryを、実引数付きの戻り値候補として呼出しに消費しない
    /// ために使う。native pluginの実行時登録名など、呼出し可能と分かって
    /// いるaliasは既定値trueのままにする。
    callable: bool = true,
    /// 静的に「値」と確認できた命令か。ESM plugin の `type: "const"` だけを
    /// 値参照として許可し、型やシグネチャが判定不能なentryはどちらにも
    /// 確定しない。
    value: bool = false,
    /// 呼出しに必要な助詞スロット。nullはシグネチャ判定不能を表す。
    signature: ?JosiSignature = null,
    /// ESM plugin の静的抽出由来か。trueなら `signature` が無い関数entryを
    /// 呼出し可能と推測せず、未解決引数として診断させる。native pluginの
    /// 実行時登録名など、registryで関数と確認できるaliasはfalseのまま。
    signature_required: bool = false,
    /// 抽出元の登録が取り込み時の評価で必ず実行されるか。トップレベルの
    /// `export default`・`addPluginObject` は真、関数内など未実行になり得る
    /// 登録は偽。偽の候補の助詞定義を主候補の呼出し計画へ流用しない。
    registration_certain: bool = true,
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
    // package内相対native/非静的ESM: 取り込み位置以降の無修飾命令を owner 修飾
    // dispatch へ写す。複数ある場合はより後の取り込みを優先する（後勝ち）。
    var selected_unqualified: ?DynamicCommandAlias = null;
    for (aliases) |alias| {
        if (!alias.unqualified or alias.exact) continue;
        if (use_position < alias.import_position) continue;
        if (selected_unqualified == null or alias.import_position >= selected_unqualified.?.import_position)
            selected_unqualified = alias;
    }
    // 後発の動的ESM/native pluginやprefix aliasが後から取り込まれている場合は、
    // 先発ESM pluginの完全一致aliasより後勝ち規則を優先する。
    if (selected_exact) |exact_alias| {
        if (selected) |prefix_alias| {
            if (prefix_alias.import_position > exact_alias.import_position) return prefix_alias;
        }
        if (selected_unqualified) |unqualified_alias| {
            if (unqualified_alias.import_position > exact_alias.import_position) return unqualified_alias;
        }
        return exact_alias;
    }
    if (selected) |alias| return alias;
    if (selected_unqualified) |alias| return alias;
    if (allows_dynamic_commands and use_position >= allows_from) return .{ .source_namespace = name, .dispatch_namespace = name };
    return null;
}

/// 実引数付きの戻り値候補を、静的に呼出し可能と確認できる完全一致aliasへ
/// だけ解決する。catch-all（`unqualified`）や、ESMの `type: "const"` の
/// ような非関数entryは返さない。呼出し側は解決できなかった候補を値として
/// 消費せず、未解決引数の診断へ戻す。
pub fn bindsCallableExact(
    allocator: std.mem.Allocator,
    allows_dynamic_commands: bool,
    allows_from: usize,
    aliases: []const DynamicCommandAlias,
    name: []const u8,
    use_position: usize,
) !?CandidateResolution {
    const alias = binds(allows_dynamic_commands, allows_from, aliases, name, use_position) orelse return null;
    if (!alias.exact or !alias.callable) return null;
    if (alias.signature_required and alias.signature == null) return null;
    return bindsWithFallbacks(allocator, allows_dynamic_commands, allows_from, aliases, name, use_position);
}

/// 実引数を持たない値参照を、静的に非関数と確認できる完全一致aliasへ解決
/// する。ESM pluginの `type: "const"` を通常の値として読む経路に使い、
/// 呼出し可能な関数entryやcatch-allは返さない。
pub fn bindsValueExact(
    allocator: std.mem.Allocator,
    allows_dynamic_commands: bool,
    allows_from: usize,
    aliases: []const DynamicCommandAlias,
    name: []const u8,
    use_position: usize,
) !?CandidateResolution {
    const alias = binds(allows_dynamic_commands, allows_from, aliases, name, use_position) orelse return null;
    if (!alias.exact or alias.callable or !alias.value) return null;
    return bindsWithFallbacks(allocator, allows_dynamic_commands, allows_from, aliases, name, use_position);
}

pub const CandidateResolution = struct {
    resolved_name: []const u8,
    fallback_names: []const []const u8 = &.{},
    signature: ?JosiSignature = null,
    /// 実登録される候補が静的には確定できず、候補ごとの助詞定義も一致
    /// しない場合に真。呼出し側は実引数を未整列のまま実行時へ渡し、
    /// 選択された登録のメタデータで割り当てる。
    runtime_alignment: bool = false,
};

/// `binds` と同じ優先規則で主配送先 `resolved_name` を決めつつ、主配送先が
/// `unqualified` catch-all または静的抽出由来の `exact` のとき、先発の
/// `exact` / `unqualified` を実行時フォールバック候補 `fallback_names` として
/// 後勝ち順（降順）で収集する。
/// 動的 ESM / native plugin に同名命令が無い非競合ケースでも先発 plugin の
/// 命令へ到達できるようにするために使う。返却スライスと各文字列は
/// `allocator` 所有。
pub fn bindsWithFallbacks(
    allocator: std.mem.Allocator,
    allows_dynamic_commands: bool,
    allows_from: usize,
    aliases: []const DynamicCommandAlias,
    name: []const u8,
    use_position: usize,
) !?CandidateResolution {
    const primary = binds(allows_dynamic_commands, allows_from, aliases, name, use_position) orelse return null;
    const resolved_name = try allocDispatchName(allocator, primary, name);
    errdefer allocator.free(resolved_name);
    // 明示 prefix 呼出し・直接 plugin の恒等写像は登録名を確定できるため候補を持たない。
    // exact 主候補は静的抽出由来で実登録の保証ではない（呼ばれない関数内の
    // `addPluginObject` 等からも抽出される）ため、unqualified と同じく先発候補を
    // 実行時の登録照合へ渡す。
    if (!primary.unqualified and !primary.exact) return .{ .resolved_name = resolved_name, .signature = primary.signature };

    const CandidateEntry = struct {
        alias: DynamicCommandAlias,
        index: usize,
    };
    var candidates: std.ArrayList(CandidateEntry) = .empty;
    defer candidates.deinit(allocator);
    for (aliases, 0..) |alias, index| {
        if (alias.import_position > use_position or alias.import_position > primary.import_position) continue;
        if ((alias.exact and std.mem.eql(u8, alias.source_namespace, name)) or
            (alias.unqualified and !alias.exact))
        {
            try candidates.append(allocator, .{ .alias = alias, .index = index });
        }
    }
    std.mem.sort(CandidateEntry, candidates.items, {}, struct {
        fn lessThan(_: void, a: CandidateEntry, b: CandidateEntry) bool {
            if (a.alias.import_position != b.alias.import_position)
                return a.alias.import_position > b.alias.import_position;
            if (a.alias.exact != b.alias.exact) return a.alias.exact;
            return a.index > b.index;
        }
    }.lessThan);

    // 候補ごとの助詞定義が一致しない、または可変長助詞をリテラルで確定
    // できない場合は、主候補の呼出し計画を先発候補へ流用できない。実引数を
    // 未整列のまま実行時へ渡し、実際に登録された候補のメタデータで割り当てる。
    var runtime_alignment = primary.exact and !primary.registration_certain;
    if (primary.exact and primary.signature != null) {
        if (!primary.signature.?.variable_known) runtime_alignment = true;
    }
    var all_esm_signatures = primary.exact and primary.signature != null;
    for (candidates.items) |entry| {
        if (!entry.alias.exact or !entry.alias.signature_required or entry.alias.signature == null) {
            all_esm_signatures = false;
            continue;
        }
        if (primary.signature) |primary_signature| {
            if (!signatureEql(entry.alias.signature.?, primary_signature)) runtime_alignment = true;
        }
        if (!entry.alias.signature.?.variable_known) runtime_alignment = true;
    }
    if (!all_esm_signatures) runtime_alignment = false;

    var fallbacks: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fallbacks.items) |item| allocator.free(item);
        fallbacks.deinit(allocator);
    }
    for (candidates.items) |entry| {
        const candidate_name = try allocDispatchName(allocator, entry.alias, name);
        if (std.mem.eql(u8, candidate_name, resolved_name)) {
            allocator.free(candidate_name);
            continue;
        }
        var duplicate = false;
        for (fallbacks.items) |existing| {
            if (std.mem.eql(u8, existing, candidate_name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            allocator.free(candidate_name);
            continue;
        }
        fallbacks.append(allocator, candidate_name) catch |failure| {
            // 配列へ所有権を移せなかった候補名は errdefer の対象外なのでここで解放する。
            allocator.free(candidate_name);
            return failure;
        };
    }
    return .{
        .resolved_name = resolved_name,
        .fallback_names = try fallbacks.toOwnedSlice(allocator),
        .signature = primary.signature,
        .runtime_alignment = runtime_alignment,
    };
}

/// 2つの助詞シグネチャが同じスロット表・可変長指定か。文字列は内容で比較する。
fn signatureEql(a: JosiSignature, b: JosiSignature) bool {
    if (a.variable_final != b.variable_final or a.variable_known != b.variable_known) return false;
    if (a.slots.len != b.slots.len) return false;
    for (a.slots, b.slots) |a_slot, b_slot| {
        if (a_slot.len != b_slot.len) return false;
        for (a_slot, b_slot) |a_item, b_item| {
            if (!std.mem.eql(u8, a_item, b_item)) return false;
        }
    }
    return true;
}

/// 解析中の一時arenaに由来する`JosiSignature`を、Programの生存期間を持つ
/// allocatorへ深く複製する。BindingはHIR loweringまで保持されるため、
/// module graphの一時arenaを参照してはならない。
pub fn cloneSignature(allocator: std.mem.Allocator, signature: JosiSignature) !JosiSignature {
    const slots = try allocator.alloc([]const []const u8, signature.slots.len);
    for (signature.slots, 0..) |alternatives, index| {
        const copied = try allocator.alloc([]const u8, alternatives.len);
        for (alternatives, 0..) |alternative, alternative_index| copied[alternative_index] = try allocator.dupe(u8, alternative);
        slots[index] = copied;
    }
    return .{ .slots = slots, .variable_final = signature.variable_final, .variable_known = signature.variable_known };
}

/// `JosiSignature`を`argument_completion.plan`のスロット表へ変換する。
/// 返却スライスは`allocator`所有で、各要素はsignatureの文字列を参照する。
pub fn signatureSlots(allocator: std.mem.Allocator, signature: JosiSignature) ![]argument_completion.Slot {
    const slots = try allocator.alloc(argument_completion.Slot, signature.slots.len);
    for (signature.slots, 0..) |alternatives, index| slots[index] = .{ .josi = alternatives };
    return slots;
}

fn allocDispatchName(allocator: std.mem.Allocator, alias: DynamicCommandAlias, name: []const u8) ![]const u8 {
    const raw = try dispatchName(allocator, alias, name);
    if (raw.ptr == name.ptr and raw.len == name.len) return allocator.dupe(u8, raw);
    return raw;
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
    // 依存 ESM（static/dynamic import・再export・require）は評価時に同じ active
    // namespace へ `addPluginObject` で自己登録し得る。依存先の登録集合までは
    // 抽出しないため、依存辺があれば完全抽出とは判定しない。
    var has_dependency_edge = false;
    var depth: usize = 0;
    var index: usize = 0;
    while (index < items.len) : (index += 1) {
        const token = items[index];
        const prev_is_dot = index > 0 and isPunct(items[index - 1], ".");
        if (depth == 0 and !prev_is_dot and isIdent(token, "export") and index + 1 < items.len and isIdent(items[index + 1], "default")) {
            found_plugin_site = true;
            const raw_start = index + 2;
            const expr_start = unwrapParens(items, raw_start, items.len);
            const open_parens = expr_start - raw_start;
            if (expr_start >= items.len) {
                all_static_complete = false;
            } else if (isPunct(items[expr_start], "{")) {
                const result = try extractObjectLiteralKeys(allocator, aliases, items, expr_start, dispatch_namespace, import_position, true);
                if (!result.complete or result.close_brace_index == null or
                    !isExportDefaultExpressionEnd(source, items, result.close_brace_index.?, open_parens))
                    all_static_complete = false;
            } else if (items[expr_start].kind == .identifier and !isExpressionKeyword(items[expr_start].text) and
                isExportDefaultExpressionEnd(source, items, expr_start, open_parens))
            {
                if (findVariableObjectInitializer(source, items, index, items[expr_start].text)) |obj_brace| {
                    const result = try extractObjectLiteralKeys(allocator, aliases, items, obj_brace, dispatch_namespace, import_position, true);
                    if (!result.complete or result.close_brace_index == null) all_static_complete = false;
                } else {
                    all_static_complete = false;
                }
            } else {
                all_static_complete = false;
            }
        } else if (isIdent(token, "addPluginObject") and !(index > 0 and isIdent(items[index - 1], "function"))) {
            if (index + 1 < items.len and isPunct(items[index + 1], "(")) {
                found_plugin_site = true;
                const ok = try extractAddPluginObjectSecondArg(allocator, aliases, source, items, index + 1, dispatch_namespace, import_position, depth == 0);
                if (!ok) all_static_complete = false;
            } else {
                // `const reg = navigator.nako3.addPluginObject`・分割代入・`?.()`・`.call()` などの
                // 間接参照経由の自己登録は静的抽出できないため catch-all を残す。
                all_static_complete = false;
            }
        } else if ((token.kind == .string and std.mem.eql(u8, token.text, "addPluginObject")) or
            (isIdent(token, "nako3") and ((index + 1 < items.len and isPunct(items[index + 1], "[")) or
                (index + 3 < items.len and isPunct(items[index + 1], "?") and isPunct(items[index + 2], ".") and isPunct(items[index + 3], "[")))))
        {
            // `navigator.nako3['addPluginObject'](...)` や `navigator.nako3[key](...)` の
            // ブラケット経由アクセスも間接登録の可能性があるため catch-all を残す。
            all_static_complete = false;
        }
        if (!prev_is_dot and isModuleDependencyToken(items, index)) has_dependency_edge = true;
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token) and depth > 0) {
            depth -= 1;
        }
    }
    return found_plugin_site and all_static_complete and !has_dependency_edge;
}

/// 他モジュールの評価を引き起こす記述か。`import x from '..'` / `import '..'` /
/// `import(..)`（`import.meta` は除く）、`export .. from '..'`、`require(..)`。
fn isModuleDependencyToken(items: []const js_scanner.JavaScriptToken, index: usize) bool {
    const token = items[index];
    if (isIdent(token, "import")) {
        return !(index + 1 < items.len and isPunct(items[index + 1], "."));
    }
    if (isIdent(token, "require")) {
        return index + 1 < items.len and isPunct(items[index + 1], "(");
    }
    if (isIdent(token, "from")) {
        return index + 1 < items.len and items[index + 1].kind == .string;
    }
    return false;
}

const ObjectExtractResult = struct {
    complete: bool,
    close_brace_index: ?usize,
};

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

fn unwrapParens(items: []const js_scanner.JavaScriptToken, start: usize, limit: usize) usize {
    var pos = start;
    while (pos < limit and isPunct(items[pos], "(")) pos += 1;
    return pos;
}

fn consumeClosingParens(items: []const js_scanner.JavaScriptToken, after_expr: usize, open_parens: usize) ?usize {
    var pos = after_expr;
    var remaining = open_parens;
    while (remaining > 0) : (remaining -= 1) {
        if (pos >= items.len or !isPunct(items[pos], ")")) return null;
        pos += 1;
    }
    return pos;
}

fn hasNewlineBetween(source: []const u8, prev: js_scanner.JavaScriptToken, next: js_scanner.JavaScriptToken) bool {
    const source_start = @intFromPtr(source.ptr);
    const source_end = source_start + source.len;
    const prev_ptr = @intFromPtr(prev.text.ptr);
    const next_ptr = @intFromPtr(next.text.ptr);
    if (prev_ptr < source_start or next_ptr < source_start) return false;
    const prev_end = (prev_ptr - source_start) + prev.text.len + @intFromBool(prev.kind == .string);
    const next_start = (next_ptr - source_start) -| @intFromBool(next.kind == .string);
    if (prev_end > next_start or prev_ptr + prev.text.len > source_end or next_start > source.len) return false;
    return std.mem.indexOfAny(u8, source[prev_end..next_start], "\n\r") != null;
}

fn isContinuationToken(items: []const js_scanner.JavaScriptToken, pos: usize) bool {
    const token = items[pos];
    if (token.kind == .identifier) {
        return std.mem.eql(u8, token.text, "in") or std.mem.eql(u8, token.text, "instanceof");
    }
    if (token.kind != .punctuation or token.text.len != 1) return false;
    return switch (token.text[0]) {
        '.', '(', '[', ',', '?', ':', '+', '-', '*', '/', '%', '=', '&', '|', '^', '<', '>' => true,
        '!' => pos + 1 < items.len and isPunct(items[pos + 1], "="),
        else => false,
    };
}

fn isExportDefaultExpressionEnd(
    source: []const u8,
    items: []const js_scanner.JavaScriptToken,
    expr_end_index: usize,
    open_parens: usize,
) bool {
    const end_pos = consumeClosingParens(items, expr_end_index + 1, open_parens) orelse return false;
    if (end_pos >= items.len) return true;
    if (isPunct(items[end_pos], ";")) return true;
    if (!hasNewlineBetween(source, items[end_pos - 1], items[end_pos])) return false;
    return !isContinuationToken(items, end_pos);
}

fn isCallArgEnd(items: []const js_scanner.JavaScriptToken, after_expr: usize, open_parens: usize) bool {
    const end_pos = consumeClosingParens(items, after_expr, open_parens) orelse return false;
    return end_pos < items.len and (isPunct(items[end_pos], ")") or isPunct(items[end_pos], ","));
}

fn isVarInitEnd(
    source: []const u8,
    items: []const js_scanner.JavaScriptToken,
    close_brace_index: usize,
    open_parens: usize,
) bool {
    const end_pos = consumeClosingParens(items, close_brace_index + 1, open_parens) orelse return false;
    if (end_pos >= items.len) return true;
    if (isPunct(items[end_pos], ";") or isPunct(items[end_pos], ",")) return true;
    if (!hasNewlineBetween(source, items[end_pos - 1], items[end_pos])) return false;
    return !isContinuationToken(items, end_pos);
}

fn matchingCloseBrace(items: []const js_scanner.JavaScriptToken, open_brace_index: usize) ?usize {
    var depth: usize = 0;
    var pos = open_brace_index;
    while (pos < items.len) : (pos += 1) {
        const token = items[pos];
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token)) {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return if (isPunct(token, "}")) pos else null;
        }
    }
    return null;
}

fn isObjectPropertyKey(items: []const js_scanner.JavaScriptToken, index: usize) bool {
    if (index == 0 or index + 1 >= items.len) return false;
    return (isPunct(items[index - 1], "{") or isPunct(items[index - 1], ",")) and isPunct(items[index + 1], ":");
}

fn isAddPluginObjectSecondArgRef(items: []const js_scanner.JavaScriptToken, comma_index: usize) bool {
    var nested: usize = 0;
    var pos = comma_index;
    while (pos > 0) {
        pos -= 1;
        const token = items[pos];
        if (isCloseDelim(token)) {
            nested += 1;
        } else if (isOpenDelim(token)) {
            if (nested == 0) {
                return isPunct(token, "(") and pos >= 1 and isIdent(items[pos - 1], "addPluginObject") and
                    !(pos >= 2 and isIdent(items[pos - 2], "function"));
            }
            nested -= 1;
        } else if (nested == 0 and (isPunct(token, ",") or
            (pos >= 2 and isPunct(token, ".") and isPunct(items[pos - 1], ".") and isPunct(items[pos - 2], "."))))
        {
            return false;
        }
    }
    return false;
}

fn isAllowedPluginReference(source: []const u8, items: []const js_scanner.JavaScriptToken, ref_index: usize) bool {
    var start = ref_index;
    while (start > 0 and isPunct(items[start - 1], "(")) start -= 1;
    const open_parens = ref_index - start;
    if (start >= 2 and isIdent(items[start - 2], "export") and isIdent(items[start - 1], "default") and
        !(start >= 3 and isPunct(items[start - 3], ".")))
    {
        return isExportDefaultExpressionEnd(source, items, ref_index, open_parens);
    }
    if (start >= 1 and isPunct(items[start - 1], ",") and isCallArgEnd(items, ref_index + 1, open_parens)) {
        return isAddPluginObjectSecondArgRef(items, start - 1);
    }
    return false;
}

fn hasVariableMutationOrEscape(
    source: []const u8,
    items: []const js_scanner.JavaScriptToken,
    name: []const u8,
    decl_name_index: usize,
) bool {
    for (items, 0..) |token, index| {
        if (index == decl_name_index) continue;
        if (!isIdent(token, name)) continue;
        if (index > 0 and isPunct(items[index - 1], ".")) continue;
        if (isObjectPropertyKey(items, index)) continue;
        if (!isAllowedPluginReference(source, items, index)) return true;
    }
    return false;
}

fn findVariableObjectInitializer(
    source: []const u8,
    items: []const js_scanner.JavaScriptToken,
    limit: usize,
    name: []const u8,
) ?usize {
    var depth: usize = 0;
    var found_brace: ?usize = null;
    var decl_name_index: ?usize = null;
    var index: usize = 0;
    while (index < limit) : (index += 1) {
        const token = items[index];
        if (depth == 0 and token.kind == .identifier and
            (std.mem.eql(u8, token.text, "const") or std.mem.eql(u8, token.text, "let") or std.mem.eql(u8, token.text, "var")) and
            index + 2 < limit and isIdent(items[index + 1], name) and isPunct(items[index + 2], "="))
        {
            if (found_brace != null) return null;
            const raw_rhs = index + 3;
            const rhs = unwrapParens(items, raw_rhs, limit);
            const open_parens = rhs - raw_rhs;
            if (rhs >= limit or !isPunct(items[rhs], "{")) return null;
            const close_brace = matchingCloseBrace(items, rhs) orelse return null;
            if (!isVarInitEnd(source, items, close_brace, open_parens)) return null;
            found_brace = rhs;
            decl_name_index = index + 1;
        }
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token) and depth > 0) {
            depth -= 1;
        }
    }
    const obj_brace = found_brace orelse return null;
    const decl_index = decl_name_index orelse return null;
    if (hasVariableMutationOrEscape(source, items, name, decl_index)) return null;
    return obj_brace;
}

fn extractAddPluginObjectSecondArg(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList(DynamicCommandAlias),
    source: []const u8,
    items: []const js_scanner.JavaScriptToken,
    open_paren_index: usize,
    dispatch_namespace: []const u8,
    import_position: usize,
    registration_certain: bool,
) !bool {
    var pos = open_paren_index + 1;
    var nested: usize = 0;
    var arg2_start: ?usize = null;
    while (pos < items.len) : (pos += 1) {
        const token = items[pos];
        if (nested == 0 and pos + 2 < items.len and isPunct(token, ".") and isPunct(items[pos + 1], ".") and isPunct(items[pos + 2], ".")) {
            return false;
        }
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
    const open_parens = expr_start - raw_start;
    if (expr_start >= items.len) return false;
    if (isPunct(items[expr_start], "{")) {
        const result = try extractObjectLiteralKeys(allocator, aliases, items, expr_start, dispatch_namespace, import_position, registration_certain);
        return result.complete and
            result.close_brace_index != null and
            isCallArgEnd(items, result.close_brace_index.? + 1, open_parens);
    }
    if (items[expr_start].kind == .identifier and !isExpressionKeyword(items[expr_start].text) and
        isCallArgEnd(items, expr_start + 1, open_parens))
    {
        const obj_brace = findVariableObjectInitializer(source, items, open_paren_index, items[expr_start].text) orelse return false;
        const result = try extractObjectLiteralKeys(allocator, aliases, items, obj_brace, dispatch_namespace, import_position, registration_certain);
        return result.complete and result.close_brace_index != null;
    }
    return false;
}

fn isPropertyNameTerminator(token: js_scanner.JavaScriptToken) bool {
    return isPunct(token, ":") or isPunct(token, "(") or isPunct(token, ",") or isPunct(token, "}");
}

/// plugin entryの静的な分類。関数・値・判定不能を混同しない。
const EntryClass = enum { function, constant, unknown };
const EntryInfo = struct {
    class: EntryClass = .unknown,
    signature: ?JosiSignature = null,
    /// オブジェクト値の直後の位置（閉じ`}`の次）。プロパティ値として
    /// 単独で完結しているかの境界確認に使う。
    end: usize = 0,
};

/// `key: value` の値が、なでしこ plugin の entry として静的に何に確定するか。
/// 明示 `type` は entry 全体の最後の値を優先し、メソッド宣言や `fn` 関数式で
/// 覆さない。関数は呼出し計画に必要な `josi` signature まで確定できた場合だけ
/// `.function` とし、型やシグネチャが動的な形は `.unknown` にする。
fn propertyEntryInfo(allocator: std.mem.Allocator, items: []const js_scanner.JavaScriptToken, header_index: usize) !EntryInfo {
    if (header_index >= items.len) return .{};
    // メソッド宣言 `key() { ... }`。plugin entryのjosiは宣言できないため
    // 呼出し計画を確定できず、関数としても値としても扱わない。
    if (isPunct(items[header_index], "(")) return .{};
    if (!isPunct(items[header_index], ":")) return .{};
    const value_start = header_index + 1;
    if (value_start >= items.len) return .{};
    const value = items[value_start];
    if (value.kind == .identifier) {
        if (std.mem.eql(u8, value.text, "function") or std.mem.eql(u8, value.text, "class")) {
            return if (std.mem.eql(u8, value.text, "function")) .{ .class = .function } else .{};
        }
        if (std.mem.eql(u8, value.text, "async")) {
            const next = value_start + 1;
            if (next >= items.len) return .{};
            if (isIdent(items[next], "function")) return .{ .class = .function };
            return if (isArrowFunctionAt(items, next)) .{ .class = .function } else .{};
        }
        return if (isArrowFunctionAt(items, value_start)) .{ .class = .function } else .{};
    }
    if (isPunct(value, "{")) {
        const info = try objectEntryInfo(allocator, items, value_start);
        // `{...} && {...}` のようにオブジェクト式がさらに式の一部になる場合、
        // 先頭のオブジェクトだけを entry 全体と確定しない。
        if (info.end >= items.len or !(isPunct(items[info.end], ",") or isPunct(items[info.end], "}"))) return .{};
        return info;
    }
    if (isPunct(value, "(")) return if (isArrowFunctionAt(items, value_start)) .{ .class = .function } else .{};
    return .{};
}

/// プロパティ値が`"..."`の1個だけで、直後がプロパティ境界になっているか。
/// `type: "func" && "const"`のように式が続く場合は判定不能としてnullを返す。
fn exactStringValue(items: []const js_scanner.JavaScriptToken, start: usize) ?[]const u8 {
    if (start >= items.len or items[start].kind != .string) return null;
    if (start + 1 >= items.len) return items[start].text;
    if (isPunct(items[start + 1], ",") or isPunct(items[start + 1], "}")) return items[start].text;
    return null;
}

/// 真偽値リテラル1個だけで、直後がプロパティ境界になっているか。
fn exactBooleanValue(items: []const js_scanner.JavaScriptToken, start: usize) ?bool {
    if (start >= items.len or items[start].kind != .identifier) return null;
    const value = if (std.mem.eql(u8, items[start].text, "true"))
        true
    else if (std.mem.eql(u8, items[start].text, "false"))
        false
    else
        return null;
    if (start + 1 < items.len and !isPunct(items[start + 1], ",") and !isPunct(items[start + 1], "}")) return null;
    return value;
}

const JosiParse = struct {
    signature: JosiSignature,
    end: usize,
};

/// `[["を"], ["から", "を"]]`形式の`josi`値を読み、外側`]`直後の位置を返す。
/// 文字列以外・入れ子の式・閉じない配列は判定不能としてnullにする。
fn parseJosiValue(allocator: std.mem.Allocator, items: []const js_scanner.JavaScriptToken, start: usize) !?JosiParse {
    if (start >= items.len or !isPunct(items[start], "[")) return null;
    var slots: std.ArrayList([]const []const u8) = .empty;
    errdefer {
        for (slots.items) |slot| allocator.free(slot);
        slots.deinit(allocator);
    }
    var pos = start + 1;
    if (pos < items.len and isPunct(items[pos], "]")) {
        return .{ .signature = .{ .slots = try slots.toOwnedSlice(allocator) }, .end = pos + 1 };
    }
    while (pos < items.len) {
        if (!isPunct(items[pos], "[")) return null;
        pos += 1;
        var alternatives: std.ArrayList([]const u8) = .empty;
        errdefer alternatives.deinit(allocator);
        if (pos < items.len and isPunct(items[pos], "]")) {
            pos += 1;
        } else {
            while (pos < items.len) {
                if (items[pos].kind != .string) return null;
                const decoded = (try unescapeSimpleString(allocator, items[pos].text)) orelse return null;
                try alternatives.append(allocator, decoded);
                pos += 1;
                if (pos < items.len and isPunct(items[pos], ",")) {
                    pos += 1;
                    continue;
                }
                if (pos < items.len and isPunct(items[pos], "]")) {
                    pos += 1;
                    break;
                }
                return null;
            }
        }
        try slots.append(allocator, try alternatives.toOwnedSlice(allocator));
        if (pos < items.len and isPunct(items[pos], ",")) {
            pos += 1;
            continue;
        }
        if (pos < items.len and isPunct(items[pos], "]")) {
            return .{ .signature = .{ .slots = try slots.toOwnedSlice(allocator) }, .end = pos + 1 };
        }
        return null;
    }
    return null;
}

/// plugin entry object `{ type: "func", josi: ..., fn: ... }` の最上位
/// プロパティだけを走査し、最後に有効な`type`・`josi`・`fn`で分類する。
/// 入れ子object内の`type`、computed key、spread、式が続く`type`、未知の
/// `josi`は判定不能として扱う。同名プロパティはJSと同じく後勝ち。
fn objectEntryInfo(allocator: std.mem.Allocator, items: []const js_scanner.JavaScriptToken, open_brace_index: usize) !EntryInfo {
    var saw_type = false;
    var type_class: EntryClass = .unknown;
    var fn_function = false;
    var signature: ?JosiSignature = null;
    var variable_final = false;
    var variable_known = true;
    var opaque_entry = false;
    var close_index: ?usize = null;
    var pos = open_brace_index + 1;
    while (pos < items.len) {
        if (isPunct(items[pos], "}")) {
            close_index = pos;
            break;
        }
        if (isPunct(items[pos], ",")) {
            pos += 1;
            continue;
        }
        // spread・算出キーは最終的なプロパティ集合を確定できない。
        if ((pos + 2 < items.len and isPunct(items[pos], ".") and isPunct(items[pos + 1], ".") and isPunct(items[pos + 2], ".")) or
            isPunct(items[pos], "["))
        {
            opaque_entry = true;
            pos = skipPropertyRemainder(items, pos);
            continue;
        }
        // `*` または `get`/`set`/`async` 修飾子付きのメソッド。
        var accessor = false;
        if (isPunct(items[pos], "*")) {
            pos += 1;
            if (pos >= items.len) return .{};
        } else if (items[pos].kind == .identifier and
            (std.mem.eql(u8, items[pos].text, "get") or std.mem.eql(u8, items[pos].text, "set") or std.mem.eql(u8, items[pos].text, "async")) and
            pos + 1 < items.len and !isPropertyNameTerminator(items[pos + 1]))
        {
            accessor = std.mem.eql(u8, items[pos].text, "get") or std.mem.eql(u8, items[pos].text, "set");
            pos += 1;
            if (pos < items.len and isPunct(items[pos], "*")) pos += 1;
            if (pos >= items.len) return .{};
        }
        if (pos >= items.len or (items[pos].kind != .identifier and items[pos].kind != .string)) return .{};
        const key = items[pos].text;
        pos += 1;
        if (pos >= items.len) return .{};
        // アクセサで `type`・`josi`・`fn` 等を再定義すると、後続の値から
        // 最終的なメタデータを確定できない。先に見た値だけを確定扱いしない。
        if (accessor and (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "josi") or
            std.mem.eql(u8, key, "fn") or std.mem.eql(u8, key, "isVariableJosi")))
        {
            opaque_entry = true;
            pos = skipPropertyRemainder(items, pos);
            continue;
        }
        if (isPunct(items[pos], "(")) {
            if (std.mem.eql(u8, key, "fn")) fn_function = true;
            pos = skipPropertyRemainder(items, pos);
            continue;
        }
        if (!isPunct(items[pos], ":")) return .{};
        const value_start = pos + 1;
        if (value_start >= items.len) return .{};
        if (items[pos - 1].kind == .string) {
            // エスケープ表記のキーは単純比較では同一プロパティと判定できない。
            // 後続の同名キーで分類が変わり得るため entry 全体を確定しない。
            if (try unescapeSimpleString(allocator, items[pos - 1].text) == null) opaque_entry = true;
        }
        if (std.mem.eql(u8, key, "type")) {
            saw_type = true;
            if (exactStringValue(items, value_start)) |type_text| {
                type_class = if (std.mem.eql(u8, type_text, "func"))
                    .function
                else if (std.mem.eql(u8, type_text, "const"))
                    .constant
                else
                    .unknown;
            } else {
                type_class = .unknown;
            }
        } else if (std.mem.eql(u8, key, "fn")) {
            fn_function = isDirectFunctionValue(items, value_start);
        } else if (std.mem.eql(u8, key, "josi")) {
            const parsed = try parseJosiValue(allocator, items, value_start);
            if (parsed) |josi| {
                if (josi.end < items.len and (isPunct(items[josi.end], ",") or isPunct(items[josi.end], "}"))) {
                    signature = josi.signature;
                } else {
                    signature = null;
                }
            } else {
                signature = null;
            }
        } else if (std.mem.eql(u8, key, "isVariableJosi")) {
            if (exactBooleanValue(items, value_start)) |value| {
                variable_final = value;
            } else {
                // 式の値は plugin 評価時にしか決まらない。false とみなして
                // 固定長シグネチャを確定しない。
                variable_known = false;
            }
        }
        pos = skipPropertyRemainder(items, value_start);
    }
    if (opaque_entry or close_index == null) return .{};
    if (saw_type) {
        return switch (type_class) {
            .function => .{ .class = .function, .signature = if (signature) |sig| .{ .slots = sig.slots, .variable_final = variable_final, .variable_known = variable_known } else null, .end = close_index.? + 1 },
            .constant => .{ .class = .constant, .end = close_index.? + 1 },
            .unknown => .{},
        };
    }
    if (fn_function) {
        return .{ .class = .function, .signature = if (signature) |sig| .{ .slots = sig.slots, .variable_final = variable_final, .variable_known = variable_known } else null, .end = close_index.? + 1 };
    }
    return .{};
}

/// scannerは`=>`を`=`と`>`の2 tokenへ分けるため、その並びを確認する。
fn isArrowPunctuation(items: []const js_scanner.JavaScriptToken, start: usize) bool {
    return start + 1 < items.len and isPunct(items[start], "=") and isPunct(items[start + 1], ">");
}

/// `(` ... `)` `=>` または `識別子 =>` のarrow関数か。
fn isArrowFunctionAt(items: []const js_scanner.JavaScriptToken, start: usize) bool {
    if (start >= items.len) return false;
    if (items[start].kind == .identifier) {
        return isArrowPunctuation(items, start + 1);
    }
    if (!isPunct(items[start], "(")) return false;
    var depth: usize = 0;
    var pos = start;
    while (pos < items.len) : (pos += 1) {
        const token = items[pos];
        if (isOpenDelim(token)) {
            depth += 1;
        } else if (isCloseDelim(token)) {
            if (depth == 0) return false;
            depth -= 1;
            if (depth == 0) return isArrowPunctuation(items, pos + 1);
        }
    }
    return false;
}

/// 値の先頭が直接の関数式（`function` / arrow / async）か。
fn isDirectFunctionValue(items: []const js_scanner.JavaScriptToken, start: usize) bool {
    if (start >= items.len) return false;
    const value = items[start];
    if (value.kind == .identifier) {
        if (std.mem.eql(u8, value.text, "function")) return true;
        if (std.mem.eql(u8, value.text, "async")) {
            const next = start + 1;
            if (next >= items.len) return false;
            if (isIdent(items[next], "function")) return true;
            return isArrowFunctionAt(items, next);
        }
        return isArrowFunctionAt(items, start);
    }
    return isPunct(value, "(") and isArrowFunctionAt(items, start);
}

/// トップレベルに spread または computed key があれば、後続・先行する
/// 明示キーの最終値もJSの評価順では確定できない。抽出は続けつつ、全entryを
/// 判定不能として既知扱いしない。
fn objectHasOpaqueTopLevelKey(items: []const js_scanner.JavaScriptToken, open_brace_index: usize) bool {
    var pos = open_brace_index + 1;
    while (pos < items.len) {
        if (isPunct(items[pos], "}")) return false;
        if (isPunct(items[pos], ",")) {
            pos += 1;
            continue;
        }
        // プロパティ開始位置の spread / computed key だけを見る。値としての
        // 配列リテラル `key: [1, 2]` は不透明ではない。
        if ((pos + 2 < items.len and isPunct(items[pos], ".") and isPunct(items[pos + 1], ".") and isPunct(items[pos + 2], ".")) or
            isPunct(items[pos], "["))
            return true;
        var probe = pos;
        if (isPunct(items[probe], "*")) {
            probe += 1;
        } else if (items[probe].kind == .identifier and
            (std.mem.eql(u8, items[probe].text, "get") or std.mem.eql(u8, items[probe].text, "set") or std.mem.eql(u8, items[probe].text, "async")) and
            probe + 1 < items.len and !isPropertyNameTerminator(items[probe + 1]))
        {
            probe += 1;
            if (probe < items.len and isPunct(items[probe], "*")) probe += 1;
        }
        if (probe < items.len and isPunct(items[probe], "[")) return true;
        pos = skipPropertyRemainder(items, pos);
    }
    return true;
}

fn extractObjectLiteralKeys(
    allocator: std.mem.Allocator,
    aliases: *std.ArrayList(DynamicCommandAlias),
    items: []const js_scanner.JavaScriptToken,
    open_brace_index: usize,
    dispatch_namespace: []const u8,
    import_position: usize,
    registration_certain: bool,
) !ObjectExtractResult {
    var complete = true;
    const force_unknown = objectHasOpaqueTopLevelKey(items, open_brace_index);
    var pos = open_brace_index + 1;
    while (pos < items.len) {
        if (isPunct(items[pos], "}")) return .{ .complete = complete, .close_brace_index = pos };
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
        // `*` または `get`/`set`/`async` 修飾子をスキップする。
        // これらが修飾子ではなく自身のプロパティ名になるのは直後が `:`/`(`/`,`/`}` のときのみ。
        // そのため `get [key]() {}` や `get 0() {}` でも `get` をコマンド名として誤抽出しない。
        var has_modifier = false;
        if (isPunct(items[pos], "*")) {
            has_modifier = true;
            pos += 1;
            if (pos >= items.len) return .{ .complete = false, .close_brace_index = null };
        } else if (items[pos].kind == .identifier and
            (std.mem.eql(u8, items[pos].text, "get") or std.mem.eql(u8, items[pos].text, "set") or std.mem.eql(u8, items[pos].text, "async")) and
            pos + 1 < items.len and
            !isPropertyNameTerminator(items[pos + 1]))
        {
            has_modifier = true;
            const is_async = std.mem.eql(u8, items[pos].text, "async");
            pos += 1;
            if (is_async and pos < items.len and isPunct(items[pos], "*")) pos += 1;
            if (pos >= items.len) return .{ .complete = false, .close_brace_index = null };
        }
        if (isPunct(items[pos], "[")) {
            complete = false;
            pos = skipPropertyRemainder(items, pos);
            continue;
        }
        var raw_key: ?[]const u8 = null;
        var header_index: usize = pos;
        if (items[pos].kind == .identifier or items[pos].kind == .string) {
            const key_token = items[pos];
            pos += 1;
            header_index = pos;
            const valid_header = if (pos >= items.len)
                false
            else if (has_modifier)
                isPunct(items[pos], "(")
            else if (key_token.kind == .string)
                isPunct(items[pos], ":") or isPunct(items[pos], "(")
            else
                isPropertyNameTerminator(items[pos]);
            if (!valid_header) {
                complete = false;
            } else if (key_token.kind == .identifier) {
                raw_key = key_token.text;
            } else if (try unescapeSimpleString(allocator, key_token.text)) |decoded| {
                raw_key = decoded;
            } else {
                complete = false;
            }
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
                const info = if (force_unknown) EntryInfo{} else try propertyEntryInfo(allocator, items, header_index);
                const dispatch = try std.fmt.allocPrint(allocator, "{s}__{s}", .{ dispatch_namespace, key });
                const alias = DynamicCommandAlias{
                    .source_namespace = try allocator.dupe(u8, key),
                    .dispatch_namespace = dispatch,
                    .import_position = import_position,
                    .exact = true,
                    .callable = info.class == .function and info.signature != null,
                    .value = info.class == .constant,
                    .signature = info.signature,
                    .signature_required = true,
                    .registration_certain = registration_certain,
                };
                // 同じオブジェクト内の同名キーはJSの後勝ち。最後の値だけで
                // 分類し、先の関数entryを残さない。
                var replaced = false;
                for (aliases.items) |*existing| {
                    if (existing.exact and
                        existing.import_position == import_position and
                        std.mem.eql(u8, existing.source_namespace, key) and
                        std.mem.eql(u8, existing.dispatch_namespace, dispatch))
                    {
                        // 同時点で必ず実行される登録を、未実行になり得る登録で
                        // 上書きしない（助詞シグネチャの選択元を失わない）。
                        if (existing.registration_certain and !alias.registration_certain) {
                            replaced = true;
                            break;
                        }
                        existing.* = alias;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) try aliases.append(allocator, alias);
            }
        }
        pos = skipPropertyRemainder(items, pos);
    }
    return .{ .complete = false, .close_brace_index = null };
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

test "appendJavaScriptPluginAliases は type func だけを呼出し可能とし const と型不明は拒否する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const ok = try appendJavaScriptPluginAliases(allocator, &aliases,
        \\export default {
        \\  外部倍算: { type: "func", josi: [["を"]], fn: (x) => Number(x) * 2 },
        \\  外部定数: { type: "const", value: 8 },
        \\  関数式: { type: "func", josi: [["を"]], fn: function (x) { return x; } },
        \\  矢印: { type: "func", josi: [["を", "から"]], fn: (x) => x },
        \\  型不明: buildEntry(),
        \\  助詞なし関数: { type: "func", fn: (x) => x },
        \\};
    , "pkg:test:calls.mjs", 7);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 6), aliases.items.len);
    const expected = [_]struct { name: []const u8, callable: bool }{
        .{ .name = "外部倍算", .callable = true },
        .{ .name = "外部定数", .callable = false },
        .{ .name = "関数式", .callable = true },
        .{ .name = "矢印", .callable = true },
        .{ .name = "型不明", .callable = false },
        .{ .name = "助詞なし関数", .callable = false },
    };
    for (expected) |item| {
        var found = false;
        for (aliases.items) |alias| {
            if (!std.mem.eql(u8, alias.source_namespace, item.name)) continue;
            try std.testing.expectEqual(item.callable, alias.callable);
            found = true;
        }
        try std.testing.expect(found);
    }

    const callable = (try bindsCallableExact(allocator, false, 0, aliases.items, "外部倍算", 10)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pkg:test:calls.mjs__外部倍算", callable.resolved_name);
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, aliases.items, "外部定数", 10)) == null);
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, aliases.items, "型不明", 10)) == null);
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, aliases.items, "catch-allのみ", 10)) == null);

    const value = (try bindsValueExact(allocator, false, 0, aliases.items, "外部定数", 10)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pkg:test:calls.mjs__外部定数", value.resolved_name);
    try std.testing.expect((try bindsValueExact(allocator, false, 0, aliases.items, "外部倍算", 10)) == null);
    try std.testing.expect((try bindsValueExact(allocator, false, 0, aliases.items, "catch-allのみ", 10)) == null);
}

test "appendJavaScriptPluginAliases はtype全体・重複キー・不明josiを保守的に分類する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const ok = try appendJavaScriptPluginAliases(allocator, &aliases,
        \\export default {
        \\  定数とメソッド: { type: "const", value: 8, fn(x) { return x; } },
        \\  式が型: { type: "func" && "const", value: 8 },
        \\  上書き: { type: "func", josi: [["を"]], fn: (x) => x },
        \\  上書き: { type: "const", value: 8 },
        \\  逆上書き: { type: "const", value: 8 },
        \\  逆上書き: { type: "func", josi: [["を", "から"]], fn: (x) => x },
        \\  展開: { ...base, type: "func", josi: [["を"]], fn: (x) => x },
        \\  算出: { [key]: 1, type: "func", josi: [["を"]], fn: (x) => x },
        \\  助詞不明: { type: "func", josi: buildJosi(), fn: (x) => x },
        \\  メソッド: { fn(x) { return x; } },
        \\  配列値: { type: "const", value: [1, 2] },
        \\};
    , "pkg:test:classify.mjs", 9);
    try std.testing.expect(ok);

    const Expected = struct { name: []const u8, callable: bool, value: bool };
    const expected = [_]Expected{
        .{ .name = "定数とメソッド", .callable = false, .value = true },
        .{ .name = "式が型", .callable = false, .value = false },
        .{ .name = "上書き", .callable = false, .value = true },
        .{ .name = "逆上書き", .callable = true, .value = false },
        .{ .name = "展開", .callable = false, .value = false },
        .{ .name = "算出", .callable = false, .value = false },
        .{ .name = "助詞不明", .callable = false, .value = false },
        .{ .name = "メソッド", .callable = false, .value = false },
        .{ .name = "配列値", .callable = false, .value = true },
    };
    for (expected) |item| {
        var found = false;
        for (aliases.items) |alias| {
            if (!std.mem.eql(u8, alias.source_namespace, item.name)) continue;
            try std.testing.expectEqual(item.callable, alias.callable);
            try std.testing.expectEqual(item.value, alias.value);
            if (item.callable) try std.testing.expect(alias.signature != null) else try std.testing.expect(alias.signature == null);
            found = true;
        }
        try std.testing.expect(found);
    }
    // 重複キーはJSの最終有効値だけを残す。
    var overwrite_count: usize = 0;
    for (aliases.items) |alias| {
        if (std.mem.eql(u8, alias.source_namespace, "上書き")) overwrite_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), overwrite_count);

    const resolved = (try bindsCallableExact(allocator, false, 0, aliases.items, "逆上書き", 10)) orelse return error.TestUnexpectedResult;
    defer {
        for (resolved.fallback_names) |name| allocator.free(name);
        allocator.free(resolved.fallback_names);
        allocator.free(resolved.resolved_name);
    }
    try std.testing.expect(resolved.signature != null);
    try std.testing.expectEqual(@as(usize, 2), resolved.signature.?.slots[0].len);
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, aliases.items, "定数とメソッド", 10)) == null);
    try std.testing.expect((try bindsValueExact(allocator, false, 0, aliases.items, "定数とメソッド", 10)) != null);
    try std.testing.expect((try bindsValueExact(allocator, false, 0, aliases.items, "式が型", 10)) == null);
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, aliases.items, "助詞不明", 10)) == null);
    try std.testing.expect((try bindsValueExact(allocator, false, 0, aliases.items, "助詞不明", 10)) == null);
}

test "appendJavaScriptPluginAliases はトップレベルの算出アクセサがあると既知キーを確定しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const ok = try appendJavaScriptPluginAliases(allocator, &aliases,
        \\export default {
        \\  既知: { type: "const", value: 8 },
        \\  get [key]() { return 1; },
        \\};
    , "pkg:test:opaque.mjs", 3);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
    try std.testing.expectEqualStrings("既知", aliases.items[0].source_namespace);
    try std.testing.expect(!aliases.items[0].callable);
    try std.testing.expect(!aliases.items[0].value);
}

test "appendJavaScriptPluginAliases はアクセサ・エスケープキー・複合式のentryを確定しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const ok = try appendJavaScriptPluginAliases(allocator, &aliases,
        \\export default {
        \\  アクセサ上書き: { type: "func", josi: [["を"]], fn: (a) => a * 2, get type() { return "const" }, value: 8 },
        \\  エスケープキー: { type: "func", josi: [["を"]], fn: (a) => a * 2, "ty\u0070e": "const", value: 8 },
        \\  複合式: { type: "func", josi: [["を"]], fn: (a) => Number(a) * 2 } && { type: "const", value: 8 },
        \\  可変長式: { type: "func", josi: [["と", "を"]], fn: (...args) => args.length, isVariableJosi: Boolean(1) },
        \\  可変長真: { type: "func", josi: [["を"], ["に"]], fn: (a, b) => [a, b], isVariableJosi: true },
        \\};
    , "pkg:test:boundary.mjs", 5);
    try std.testing.expect(ok);

    for (aliases.items) |alias| {
        if (std.mem.eql(u8, alias.source_namespace, "アクセサ上書き") or
            std.mem.eql(u8, alias.source_namespace, "エスケープキー") or
            std.mem.eql(u8, alias.source_namespace, "複合式"))
        {
            try std.testing.expect(!alias.callable);
            try std.testing.expect(!alias.value);
            try std.testing.expect(alias.signature == null);
        }
        if (std.mem.eql(u8, alias.source_namespace, "可変長式")) {
            try std.testing.expect(alias.callable);
            try std.testing.expect(alias.signature != null);
            try std.testing.expect(!alias.signature.?.variable_known);
        }
        if (std.mem.eql(u8, alias.source_namespace, "可変長真")) {
            try std.testing.expect(alias.callable);
            try std.testing.expect(alias.signature.?.variable_known);
            try std.testing.expect(alias.signature.?.variable_final);
        }
    }

    const variable = (try bindsCallableExact(allocator, false, 0, aliases.items, "可変長式", 10)) orelse return error.TestUnexpectedResult;
    defer {
        for (variable.fallback_names) |name| allocator.free(name);
        allocator.free(variable.fallback_names);
        allocator.free(variable.resolved_name);
    }
    try std.testing.expect(variable.runtime_alignment);
}

test "appendJavaScriptPluginAliases は関数内addPluginObjectの登録を確定扱いしない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const ok = try appendJavaScriptPluginAliases(allocator, &aliases,
        \\export default {};
        \\function 未使用() { navigator.nako3.addPluginObject("b", { 外部命令: { type: "func", josi: [["に"]], fn: (a) => a * 3 } }); }
    , "pkg:test:ghost.mjs", 7);
    try std.testing.expect(ok);

    var uncertain_count: usize = 0;
    for (aliases.items) |alias| {
        if (!std.mem.eql(u8, alias.source_namespace, "外部命令")) continue;
        try std.testing.expect(!alias.registration_certain);
        try std.testing.expectEqualStrings("に", alias.signature.?.slots[0][0]);
        uncertain_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), uncertain_count);

    // 別moduleの先発候補（確実）と後発の未実行候補（不確実）で助詞が異なる。
    const mixed = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部命令", .dispatch_namespace = "pkg:a.mjs__外部命令", .import_position = 3, .exact = true, .signature = .{ .slots = &.{&.{"を"}} }, .signature_required = true },
        .{ .source_namespace = "外部命令", .dispatch_namespace = "pkg:b.mjs__外部命令", .import_position = 7, .exact = true, .signature = .{ .slots = &.{&.{"に"}} }, .signature_required = true, .registration_certain = false },
    };
    const resolved = (try bindsCallableExact(allocator, false, 0, &mixed, "外部命令", 10)) orelse return error.TestUnexpectedResult;
    defer {
        for (resolved.fallback_names) |name| allocator.free(name);
        allocator.free(resolved.fallback_names);
        allocator.free(resolved.resolved_name);
    }
    try std.testing.expect(resolved.runtime_alignment);
    try std.testing.expectEqualStrings("pkg:b.mjs__外部命令", resolved.resolved_name);
    try std.testing.expectEqual(@as(usize, 1), resolved.fallback_names.len);
    try std.testing.expectEqualStrings("pkg:a.mjs__外部命令", resolved.fallback_names[0]);
}

test "bindsCallableExact はcatch-allや非関数exactを呼出し候補にしない" {
    const allocator = std.testing.allocator;
    const aliases = [_]DynamicCommandAlias{
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dyn.mjs", .import_position = 5, .unqualified = true },
        .{ .source_namespace = "外部定数", .dispatch_namespace = "pkg:a:static.mjs__外部定数", .import_position = 5, .exact = true, .callable = false },
    };
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, &aliases, "外部定数", 10)) == null);
    try std.testing.expect((try bindsCallableExact(allocator, false, 0, &aliases, "外部関数", 10)) == null);
    const only_exact = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部関数", .dispatch_namespace = "pkg:a:static.mjs__外部関数", .import_position = 5, .exact = true },
    };
    const resolved = (try bindsCallableExact(allocator, false, 0, &only_exact, "外部関数", 10)) orelse return error.TestUnexpectedResult;
    defer {
        for (resolved.fallback_names) |name| allocator.free(name);
        allocator.free(resolved.fallback_names);
        allocator.free(resolved.resolved_name);
    }
    try std.testing.expectEqualStrings("pkg:a:static.mjs__外部関数", resolved.resolved_name);
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

test "appendJavaScriptPluginAliases は式終端が単一オブジェクトでない場合や宣言後に変更される変数を不完全と判定する" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // カンマ演算子・後続プロパティアクセス・改行越しチェーンは false にして fallback を残す。
    const incomplete_cases = [_][]const u8{
        "export default ({ 外部甲: { type: 'func', fn: () => 1 } }, { 外部乙: { type: 'func', fn: () => 2 } });",
        "export default { 外部甲: { type: 'func', fn: () => 1 } }.extra;",
        "export default { 外部甲: { type: 'func', fn: () => 1 } }\n  .extra;",
        "navigator.nako3.addPluginObject('extra', { 外部甲: { type: 'func', fn: () => 1 } }.extra);",
        "navigator.nako3.addPluginObject('extra', ({ 外部甲: { type: 'func', fn: () => 1 } }, { 外部乙: { type: 'func', fn: () => 2 } }));",
        "const plugin = {}; plugin.外部乙 = { type: 'func', fn: () => 2 }; export default plugin;",
        "const plugin = { 外部甲: { type: 'func', fn: () => 1 } }; Object.assign(plugin, extra); export default plugin;",
        "let plugin = { 外部甲: { type: 'func', fn: () => 1 } }; plugin = other; export default plugin;",
    };
    for (incomplete_cases) |source| {
        var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
        const ok = try appendJavaScriptPluginAliases(allocator, &aliases, source, "pkg:test:dyn.mjs", 10);
        try std.testing.expect(!ok);
    }

    // 改行 ASI で後続文が続くケースと、無変更変数の export default は true を維持する。
    const complete_cases = [_][]const u8{
        "export default ({ 外部甲: { type: 'func', fn: () => 1 } })\nconst helper = 1;\n",
        "const plugin = ({ 外部甲: { type: 'func', fn: () => 1 } }); export default (plugin);",
        "const plugin = { 外部甲: { type: 'func', fn: () => 1 } }; navigator.nako3.addPluginObject('p', (plugin));",
    };
    for (complete_cases) |source| {
        var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
        const ok = try appendJavaScriptPluginAliases(allocator, &aliases, source, "pkg:test:ok.mjs", 10);
        try std.testing.expect(ok);
        try std.testing.expectEqual(@as(usize, 1), aliases.items.len);
        try std.testing.expectEqualStrings("外部甲", aliases.items[0].source_namespace);
    }
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

test "binds は先発 exact alias より後の動的 catch-all を後勝ちで優先する" {
    const aliases = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:static.mjs__外部甲", .import_position = 10, .exact = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dynamic.mjs", .import_position = 30, .unqualified = true },
        .{ .source_namespace = "外部乙", .dispatch_namespace = "pkg:a:later.mjs__外部乙", .import_position = 50, .exact = true },
    };
    // 位置 20: exact(10) のみ有効
    const before_dynamic = binds(false, 0, &aliases, "外部甲", 20) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("pkg:a:static.mjs__外部甲", before_dynamic.dispatch_namespace);
    // 位置 40: 後発の dynamic catch-all(30) が先発 exact(10) より優先
    const after_dynamic = binds(false, 0, &aliases, "外部甲", 40) orelse return error.TestUnexpectedResult;
    try std.testing.expect(after_dynamic.unqualified);
    try std.testing.expectEqualStrings("pkg:a:dynamic.mjs", after_dynamic.dispatch_namespace);
    // 位置 60: さらに後の exact(50) は dynamic catch-all(30) より優先
    const after_later_static = binds(false, 0, &aliases, "外部乙", 60) orelse return error.TestUnexpectedResult;
    try std.testing.expect(after_later_static.exact);
    try std.testing.expectEqualStrings("pkg:a:later.mjs__外部乙", after_later_static.dispatch_namespace);
}

test "bindsWithFallbacks は後発 catch-all の背後に先発 exact/unqualified を降順で保持する" {
    const allocator = std.testing.allocator;
    const aliases = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:static.mjs__外部甲", .import_position = 10, .exact = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dyn1.mjs", .import_position = 20, .unqualified = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dyn2.mjs", .import_position = 30, .unqualified = true },
        .{ .source_namespace = "dyn2.mjs", .dispatch_namespace = "pkg:a:dyn2.mjs", .import_position = 30 },
    };

    const resolved = (try bindsWithFallbacks(allocator, false, 0, &aliases, "外部甲", 40)) orelse return error.TestUnexpectedResult;
    defer {
        allocator.free(resolved.resolved_name);
        for (resolved.fallback_names) |item| allocator.free(item);
        allocator.free(resolved.fallback_names);
    }
    try std.testing.expectEqualStrings("pkg:a:dyn2.mjs__外部甲", resolved.resolved_name);
    try std.testing.expectEqual(@as(usize, 2), resolved.fallback_names.len);
    try std.testing.expectEqualStrings("pkg:a:dyn1.mjs__外部甲", resolved.fallback_names[0]);
    try std.testing.expectEqualStrings("pkg:a:static.mjs__外部甲", resolved.fallback_names[1]);

    // 他の命令名では static.mjs(外部甲) は候補に入らない。
    const other = (try bindsWithFallbacks(allocator, false, 0, &aliases, "外部乙", 40)) orelse return error.TestUnexpectedResult;
    defer {
        allocator.free(other.resolved_name);
        for (other.fallback_names) |item| allocator.free(item);
        allocator.free(other.fallback_names);
    }
    try std.testing.expectEqualStrings("pkg:a:dyn2.mjs__外部乙", other.resolved_name);
    try std.testing.expectEqual(@as(usize, 1), other.fallback_names.len);
    try std.testing.expectEqualStrings("pkg:a:dyn1.mjs__外部乙", other.fallback_names[0]);

    // 明示prefix呼出し (`dyn2.mjs__外部甲`) は catch-all へフォールバックしない。
    const prefixed = (try bindsWithFallbacks(allocator, false, 0, &aliases, "dyn2.mjs__外部甲", 40)) orelse return error.TestUnexpectedResult;
    defer {
        allocator.free(prefixed.resolved_name);
        for (prefixed.fallback_names) |item| allocator.free(item);
        allocator.free(prefixed.fallback_names);
    }
    try std.testing.expectEqualStrings("pkg:a:dyn2.mjs__外部甲", prefixed.resolved_name);
    try std.testing.expectEqual(@as(usize, 0), prefixed.fallback_names.len);
}

test "bindsWithFallbacks は全ての割当て失敗位置でリーク・二重解放しない" {
    const aliases = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:static.mjs__外部甲", .import_position = 10, .exact = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dyn1.mjs", .import_position = 20, .unqualified = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dyn2.mjs", .import_position = 30, .unqualified = true },
    };
    const Check = struct {
        fn run(allocator: std.mem.Allocator, candidates: []const DynamicCommandAlias) !void {
            const resolved = (try bindsWithFallbacks(allocator, false, 0, candidates, "外部甲", 40)) orelse return error.TestUnexpectedResult;
            defer {
                allocator.free(resolved.resolved_name);
                for (resolved.fallback_names) |item| allocator.free(item);
                allocator.free(resolved.fallback_names);
            }
            try std.testing.expectEqual(@as(usize, 2), resolved.fallback_names.len);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{@as([]const DynamicCommandAlias, &aliases)});
}

test "bindsWithFallbacks は exact 主候補でも先発の exact/unqualified を実行時照合用に保持する" {
    const allocator = std.testing.allocator;
    const aliases = [_]DynamicCommandAlias{
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:a.mjs__外部甲", .import_position = 10, .exact = true },
        .{ .source_namespace = "", .dispatch_namespace = "pkg:a:dyn.mjs", .import_position = 20, .unqualified = true },
        .{ .source_namespace = "外部甲", .dispatch_namespace = "pkg:a:b.mjs__外部甲", .import_position = 30, .exact = true },
        .{ .source_namespace = "b.mjs", .dispatch_namespace = "pkg:a:b.mjs", .import_position = 30 },
    };

    const resolved = (try bindsWithFallbacks(allocator, false, 0, &aliases, "外部甲", 40)) orelse return error.TestUnexpectedResult;
    defer {
        allocator.free(resolved.resolved_name);
        for (resolved.fallback_names) |item| allocator.free(item);
        allocator.free(resolved.fallback_names);
    }
    try std.testing.expectEqualStrings("pkg:a:b.mjs__外部甲", resolved.resolved_name);
    try std.testing.expectEqual(@as(usize, 2), resolved.fallback_names.len);
    try std.testing.expectEqualStrings("pkg:a:dyn.mjs__外部甲", resolved.fallback_names[0]);
    try std.testing.expectEqualStrings("pkg:a:a.mjs__外部甲", resolved.fallback_names[1]);

    // 先発しか持たない命令は先発 exact が主候補になり、他 plugin の候補は付かない。
    const only_first = (try bindsWithFallbacks(allocator, false, 0, aliases[0..1], "外部甲", 40)) orelse return error.TestUnexpectedResult;
    defer {
        allocator.free(only_first.resolved_name);
        for (only_first.fallback_names) |item| allocator.free(item);
        allocator.free(only_first.fallback_names);
    }
    try std.testing.expectEqualStrings("pkg:a:a.mjs__外部甲", only_first.resolved_name);
    try std.testing.expectEqual(@as(usize, 0), only_first.fallback_names.len);

    // 明示 prefix 呼出しは exact 候補を持たず、先発へフォールバックしない（隔離の維持）。
    const prefixed = (try bindsWithFallbacks(allocator, false, 0, &aliases, "b.mjs__外部甲", 40)) orelse return error.TestUnexpectedResult;
    defer {
        allocator.free(prefixed.resolved_name);
        for (prefixed.fallback_names) |item| allocator.free(item);
        allocator.free(prefixed.fallback_names);
    }
    try std.testing.expectEqualStrings("pkg:a:b.mjs__外部甲", prefixed.resolved_name);
    try std.testing.expectEqual(@as(usize, 0), prefixed.fallback_names.len);
}

test "appendJavaScriptPluginAliases は依存ESMの評価を引き起こす記述があれば完全抽出と判定しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const dependent_sources = [_][]const u8{
        "import './commands.mjs';\nexport default {};",
        "import helper from './helper.mjs';\nexport default { 外部甲: { type: 'func', fn: () => helper } };",
        "export * from './commands.mjs';\nexport default { 外部甲: { type: 'func', fn: () => 1 } };",
        "export { x } from './commands.mjs';\nexport default {};",
        "export default {};\nimport('./commands.mjs');",
        "const m = require('./commands.mjs');\nexport default {};",
    };
    for (dependent_sources) |source| {
        var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
        try std.testing.expect(!try appendJavaScriptPluginAliases(allocator, &aliases, source, "pkg:test:dep.mjs", 10));
    }

    // 依存辺が無ければ従来どおり完全抽出できる。`import.meta` や `.import` メンバは依存ではない。
    const independent_sources = [_][]const u8{
        "export default {};",
        "const here = import.meta.url;\nexport default { 外部甲: { type: 'func', fn: () => here } };",
    };
    for (independent_sources) |source| {
        var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
        try std.testing.expect(try appendJavaScriptPluginAliases(allocator, &aliases, source, "pkg:test:ok.mjs", 10));
    }
}

test "appendJavaScriptPluginAliases は addPluginObject の間接参照・ブラケットアクセス・可変長先頭引数を完全抽出にしない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const indirect_sources = [_][]const u8{
        "const register = navigator.nako3.addPluginObject; register('p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "const { addPluginObject } = navigator.nako3; addPluginObject('p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "const { addPluginObject: register } = navigator.nako3; register('p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "navigator.nako3.addPluginObject?.('p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "navigator.nako3.addPluginObject.call(navigator.nako3, 'p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "navigator.nako3['addPluginObject']('p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "const key = 'add' + 'PluginObject'; navigator.nako3[key]('p', { 外部甲: { type: 'func', fn: () => 1 } }); export default {};",
        "const args = ['p', { 外部甲: { type: 'func', fn: () => 1 } }]; navigator.nako3.addPluginObject(...args, {}); export default {};",
        "const plugin = { 外部甲: { type: 'func', fn: () => 1 } }; const args = ['p', plugin]; navigator.nako3.addPluginObject(...args, plugin);",
    };
    for (indirect_sources) |source| {
        var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
        try std.testing.expect(!try appendJavaScriptPluginAliases(allocator, &aliases, source, "pkg:test:indirect.mjs", 10));
    }

    // `if (navigator.nako3)` のような存在確認 + 直接呼出しは引き続き完全抽出できる。
    var direct_aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const direct_ok = try appendJavaScriptPluginAliases(
        allocator,
        &direct_aliases,
        "if (typeof navigator === 'object' && navigator.nako3) { navigator.nako3.addPluginObject('p', { 外部甲: { type: 'func', fn: () => 1 } }); }",
        "pkg:test:direct.mjs",
        10,
    );
    try std.testing.expect(direct_ok);
    try std.testing.expectEqual(@as(usize, 1), direct_aliases.items.len);
    try std.testing.expectEqualStrings("外部甲", direct_aliases.items[0].source_namespace);
}

test "appendJavaScriptPluginAliases は算出プロパティ名付き修飾子や不正ヘッダから誤った exact alias を生成しない" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_or_computed = [_][]const u8{
        "const key = '外部甲'; export default { get [key]() { return { type: 'func', fn: () => 1 }; } };",
        "const key = '外部甲'; export default { set [key](v) {} };",
        "const key = '外部甲'; export default { async [key]() { return 1; } };",
        "const key = '外部甲'; export default { async *[key]() { yield 1; } };",
        "const key = '外部甲'; export default { *[key]() { yield 1; } };",
        "export default { get 0() { return { type: 'func', fn: () => 1 }; } };",
        "export default { get foo: 1 };",
        "export default { foo\\u0041: 1 };",
        "export default { 'foo' };",
    };
    for (invalid_or_computed) |source| {
        var aliases: std.ArrayList(DynamicCommandAlias) = .empty;
        const ok = try appendJavaScriptPluginAliases(allocator, &aliases, source, "pkg:test:hdr.mjs", 10);
        try std.testing.expect(!ok);
        try std.testing.expectEqual(@as(usize, 0), aliases.items.len);
    }

    // 修飾子名が自身のプロパティ名である場合と正当な修飾子付きメソッドは完全抽出できる。
    var valid_aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const valid_ok = try appendJavaScriptPluginAliases(allocator, &valid_aliases,
        \\export default {
        \\  get: { type: 'func', fn: () => 1 },
        \\  set() { return 2; },
        \\  async,
        \\  get 外部甲() { return { type: 'func', fn: () => 3 }; },
        \\  async *外部乙() { yield 4; },
        \\};
    , "pkg:test:valid_hdr.mjs", 10);
    try std.testing.expect(valid_ok);
    try std.testing.expectEqual(@as(usize, 5), valid_aliases.items.len);
    try std.testing.expectEqualStrings("get", valid_aliases.items[0].source_namespace);
    try std.testing.expectEqualStrings("set", valid_aliases.items[1].source_namespace);
    try std.testing.expectEqualStrings("async", valid_aliases.items[2].source_namespace);
    try std.testing.expectEqualStrings("外部甲", valid_aliases.items[3].source_namespace);
    try std.testing.expectEqualStrings("外部乙", valid_aliases.items[4].source_namespace);

    // `get async()` や `async get()` の組合せも正しく key 側を抽出する。
    var combo_aliases: std.ArrayList(DynamicCommandAlias) = .empty;
    const combo_ok = try appendJavaScriptPluginAliases(allocator, &combo_aliases,
        \\export default {
        \\  get async() { return { type: 'func', fn: () => 1 }; },
        \\  async get() { return { type: 'func', fn: () => 2 }; },
        \\};
    , "pkg:test:combo_hdr.mjs", 10);
    try std.testing.expect(combo_ok);
    try std.testing.expectEqual(@as(usize, 2), combo_aliases.items.len);
    try std.testing.expectEqualStrings("async", combo_aliases.items[0].source_namespace);
    try std.testing.expectEqualStrings("get", combo_aliases.items[1].source_namespace);
}
