const std = @import("std");
const ir = @import("../../../ir/nako_ir.zig");
const aot_builtin = @import("../../../runtime/aot_builtin.zig");
const builtin_catalog = @import("../../../semantic/builtin_catalog.zig");

pub const manifest_schema = "lnako.aot.builtin-manifest.v1";
pub const global_manifest_schema = "lnako.aot.global-manifest.v1";
pub const literal_manifest_schema = "lnako.aot.literal-manifest.v1";
pub const StringConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, units: []u16, index: usize };
pub const DebugPathConstant = struct { path: []const u8 };
pub const SystemStringConstant = struct { global_index: usize, units: []u16 };
pub const BigIntConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, text: []const u8, index: usize };
pub const DebugLocation = struct { id: usize, line: usize, column: usize, scope: usize };

pub fn lookupFunction(program: ir.Program, name: []const u8) ?ir.Function {
    // 同名関数は生成順の後勝ち（循環再展開変体の定義が本体を置き換える
    // 公式挙動、Issue #73）。
    var found: ?ir.Function = null;
    for (program.functions) |function| if (std.mem.eql(u8, function.name, name)) {
        found = function;
    };
    return found;
}

pub const BuiltinClosure = struct {
    command: aot_builtin.Command,
    arity: usize,
    /// 可変長命令は実引数列をそのままcallbackへ渡すgenerated ABIを使う。
    variable: bool,
};

/// `{関数}名`で関数値化する組み込み命令。汎用call siteが処理できない専用ABI
/// 命令は関数値呼出しでUnknownCommandになるためnullを返し、make_closureを
/// 未対応扱いにする。可変長命令はgenerated wrapper経由で実引数列を渡す。
pub fn builtinClosureCommand(name: []const u8) ?BuiltinClosure {
    const command = aot_builtin.lookup(name) orelse return null;
    if (!aot_builtin.hasGenericCallSiteDispatch(command)) return null;
    const arity = builtin_catalog.findArity(name) orelse return null;
    return .{ .command = command, .arity = arity.count, .variable = arity.is_variable };
}

/// `{関数}名`で関数値化されたネイティブプラグイン命令。意味解析の動的命令
/// 束縛（`dynamic_call`印）はプラグイン取り込みモジュールでのみ付くため、
/// 未束縛の同名参照はplugin命令へ流さない。専用ABI命令をここへ流すと
/// 実行時plugin dispatchで失敗するため、カタログ名も除外する。
pub fn nativePluginClosure(program: ir.Program, instruction: ir.Instruction) bool {
    if (!instruction.dynamic_call) return false;
    const name = instruction.name;
    if (program.native_plugin_paths.len == 0 or lookupFunction(program, name) != null) return false;
    for (builtin_catalog.assign_to_function_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return false;
    }
    return true;
}

pub fn isDynamicNamedCall(function: ir.Function, name: []const u8) bool {
    return isQualifiedGlobal(name) or hasLocalName(function, name);
}

/// plugin（native/ESM）命令の本体内dispatchか。
///
/// ESM plugin（`--compat-js`）だけを import した program は
/// `native_plugin_paths` が空になるため、native の有無だけで判定すると
/// `{namespace}__{命令}` が「変数に入った関数の呼出し」と誤分類され、
/// codegen が代入先（存在しない変数）を探して失敗する（Issue #55）。
/// ESM plugin の namespace も同じ dispatch 対象として扱う。
pub fn isNativePluginCall(program: ir.Program, function: ir.Function, instruction: ir.Instruction) bool {
    const has_native_plugins = program.native_plugin_paths.len > 0;
    const has_esm_plugins = hasEsmPluginNamespace(program);
    if (!has_native_plugins and !has_esm_plugins) return false;
    return instruction.opcode == .call and
        instruction.direct_callee == null and
        !instruction.is_builtin_call and
        // 動的builtin束縛の印が無い呼出しはplugin dispatchへ流さない。
        // 取り込み辺を持たないモジュールが `{namespace}__{命令}` を書いても
        // package plugin の命令へ届かないようにする。
        instruction.dynamic_call and
        instruction.name.len > 0 and
        lookupFunction(program, instruction.name) == null and
        (!isDynamicNamedCall(function, instruction.name) or
            isPackagePluginCommandName(program, instruction.name) or
            isEsmPluginCommandName(program, instruction.name));
}

/// `--compat-js` の ESM plugin が公開 namespace を持つか。
pub fn hasEsmPluginNamespace(program: ir.Program) bool {
    for (program.javascript_modules) |module| {
        if (!module.is_plugin) continue;
        for (module.namespaces) |namespace| {
            // 空 namespace は直接 path import の無修飾公開 sentinel。
            if (namespace.len > 0) return true;
        }
    }
    return false;
}

/// ESM plugin の公開命令名 `{namespace}__{命令}` か。
pub fn isEsmPluginCommandName(program: ir.Program, name: []const u8) bool {
    for (program.javascript_modules) |module| {
        if (!module.is_plugin) continue;
        for (module.namespaces) |namespace| {
            if (namespace.len == 0) continue;
            if (name.len > namespace.len + 2 and
                std.mem.startsWith(u8, name, namespace) and
                name[namespace.len] == '_' and name[namespace.len + 1] == '_') return true;
        }
    }
    return false;
}

/// `pkg:` import経由native pluginの公開命令名 `{namespace}__{命令}` か。
/// 修飾名は`isQualifiedGlobal`として動的グローバル参照へ分類されてしまう
/// ため、plugin dispatchへ流すかどうかをnamespace対応表で判定する。
pub fn isPackagePluginCommandName(program: ir.Program, name: []const u8) bool {
    for (program.native_plugin_packages) |package| {
        const namespace = package.namespace;
        // 空namespaceは直接path importの無修飾公開 sentinel であり
        // `{ns}__{名}` の照合には使えない。
        if (namespace.len == 0) continue;
        if (name.len > namespace.len + 2 and
            std.mem.startsWith(u8, name, namespace) and
            name[namespace.len] == '_' and name[namespace.len + 1] == '_') return true;
    }
    return false;
}

pub fn hasLocalName(function: ir.Function, name: []const u8) bool {
    for (function.captures) |capture| if (std.mem.eql(u8, capture, name)) return true;
    for (function.parameters) |parameter| if (std.mem.eql(u8, parameter.name, name)) return true;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if ((instruction.opcode == .load_local or instruction.opcode == .store_local) and
            std.mem.eql(u8, instruction.name, name)) return true;
        // DNCL自動初期化のローカル束縛も同名ローカルの痕跡として扱う
        if (instruction.opcode == .ensure_array_var and instruction.local_target and
            std.mem.eql(u8, instruction.name, name)) return true;
        // 範囲繰り返し変数のローカル束縛も同様（iterator_nextが書き戻す）
        if (instruction.opcode == .iterator_begin and instruction.local_target and
            std.mem.eql(u8, instruction.name, name)) return true;
        if (instruction.opcode == .destructure_store) for (instruction.names, 0..) |local_name, index| {
            if (ir.destructureTargetIsLocal(instruction, index) and std.mem.eql(u8, local_name, name)) return true;
        };
    };
    return false;
}

pub fn isDisplayCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する") or std.mem.eql(u8, name, "連続表示");
}

pub fn valueType(function: ir.Function, value: ir.ValueId) ir.Type {
    for (function.parameters) |parameter| if (parameter.value == value) return parameter.type;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| if (result == value) return instruction.type;
    };
    return .dynamic;
}

pub fn isQualifiedGlobal(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "__") != null;
}

pub fn arithmeticOpcode(operator: []const u8) ?[]const u8 {
    const entries = [_]struct { operator: []const u8, opcode: []const u8 }{
        .{ .operator = "+", .opcode = "fadd" },
        .{ .operator = "-", .opcode = "fsub" },
        .{ .operator = "*", .opcode = "fmul" },
        .{ .operator = "/", .opcode = "fdiv" },
        .{ .operator = "÷", .opcode = "fdiv" },
        .{ .operator = "÷÷", .opcode = "divfloor" },
        .{ .operator = "%", .opcode = "frem" },
        .{ .operator = "**", .opcode = "pow" },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

pub fn shiftOpcode(operator: []const u8) ?u8 {
    const entries = [_]struct { operator: []const u8, opcode: u8 }{
        .{ .operator = "shift_l", .opcode = 0 },
        .{ .operator = "shift_r", .opcode = 1 },
        .{ .operator = "shift_r0", .opcode = 2 },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

const testing = std.testing;

/// ESM plugin の namespace だけを持つ最小の program を作る。
fn testEsmPluginProgram(javascript_modules: []const ir.JavaScriptModule) ir.Program {
    return .{
        .arena = std.heap.ArenaAllocator.init(testing.allocator),
        .functions = &.{},
        .module_entries = &.{},
        .javascript_modules = @constCast(javascript_modules),
    };
}

fn testInstruction(name: []const u8) ir.Instruction {
    return .{
        .result = null,
        .span = .{ .start = 0, .end = 0, .source_start = 0, .source_end = 0, .line = 0, .column = 0 },
        .opcode = .call,
        .type = .dynamic,
        .name = name,
        .dynamic_call = true,
        .direct_callee = null,
        .is_builtin_call = false,
    };
}

test "isNativePluginCallはESM pluginの公開namespaceをdispatch対象にする" {
    const modules = [_]ir.JavaScriptModule{
        .{ .path = "plugin.mjs", .source = "", .is_plugin = true, .namespaces = &.{"greet"} },
    };
    var program = testEsmPluginProgram(&modules);
    defer program.arena.deinit();
    const function = ir.Function{
        .id = 0,
        .name = "main",
        .parameters = &.{},
        .blocks = &.{},
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    };
    // native plugin が無くても ESM plugin の `{ns}__{命令}` を拾う。
    try testing.expect(isNativePluginCall(program, function, testInstruction("greet__挨拶")));
    // namespace 不一致は拾わない。
    try testing.expect(!isNativePluginCall(program, function, testInstruction("other__挨拶")));
    // `dynamic_call` の印が無い呼出しは対象外。
    var not_dynamic = testInstruction("greet__挨拶");
    not_dynamic.dynamic_call = false;
    try testing.expect(!isNativePluginCall(program, function, not_dynamic));
}

test "isNativePluginCallは空namespaceと非plugin moduleを無視する" {
    // 空 namespace は直接 path import の無修飾公開 sentinel。
    const empty_ns = [_]ir.JavaScriptModule{
        .{ .path = "direct.mjs", .source = "", .is_plugin = true, .namespaces = &.{""} },
    };
    var program_empty = testEsmPluginProgram(&empty_ns);
    defer program_empty.arena.deinit();
    try testing.expect(!hasEsmPluginNamespace(program_empty));
    const empty_function = ir.Function{
        .id = 0,
        .name = "main",
        .parameters = &.{},
        .blocks = &.{},
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    };
    try testing.expect(!isNativePluginCall(program_empty, empty_function, testInstruction("__挨拶")));

    // `is_plugin` でない module は plugin ではない（通常の ESM library）。
    const library = [_]ir.JavaScriptModule{
        .{ .path = "lib.mjs", .source = "", .is_plugin = false, .namespaces = &.{"lib"} },
    };
    var program_library = testEsmPluginProgram(&library);
    defer program_library.arena.deinit();
    try testing.expect(!hasEsmPluginNamespace(program_library));
    try testing.expect(!isEsmPluginCommandName(program_library, "lib__関数"));
}

test "isEsmPluginCommandNameは境界を跨ぐprefixを拒否する" {
    const modules = [_]ir.JavaScriptModule{
        .{ .path = "plugin.mjs", .source = "", .is_plugin = true, .namespaces = &.{"greet"} },
    };
    var program = testEsmPluginProgram(&modules);
    defer program.arena.deinit();
    try testing.expect(isEsmPluginCommandName(program, "greet__挨拶"));
    // `__` が無い・namespace が部分一致するだけの名前は対象外。
    try testing.expect(!isEsmPluginCommandName(program, "greet_挨拶"));
    try testing.expect(!isEsmPluginCommandName(program, "greet"));
    try testing.expect(!isEsmPluginCommandName(program, "greetx__挨拶"));
}
