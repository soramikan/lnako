const std = @import("std");
const ast = @import("../frontend/ast.zig");

pub const ValueId = u32;
pub const BlockId = u32;
pub const FunctionId = u32;

pub const Type = enum { dynamic, number, bigint, boolean, null_value, string, array, object, function, void };

pub const Opcode = enum {
    const_number,
    const_bigint,
    const_boolean,
    const_null,
    const_string,
    const_undefined,
    load_global,
    load_local,
    store_global,
    store_local,
    destructure_store,
    binary,
    unary,
    call,
    call_value,
    make_array,
    make_object,
    array_get,
    property_get,
    /// 解決済みコンテナへの要素代入。operands=[container, key, value]。
    /// 公式convLet/convLetArrayはルート変数を添字・値の評価より先に束縛し、
    /// 中間レベルはarray_getで走査するため、lowering側で添字評価と走査を
    /// 織り交ぜてからこの命令をemitする。nameは参照しない。
    element_set,
    /// 増減文の分解命令（公式convInc相当）。lowering側で
    /// 読み出し→undefined初期化→量の評価→加算→書き戻しの順にemitする。
    /// is_undefined: operands=[value]。公式の `typeof v === 'undefined'`
    /// 相当で、値が未定義なら真を返す。
    is_undefined,
    /// coalesce_or_zero: operands=[value]。undefinedなら0、それ以外は
    /// そのまま返す（公式convIncの初期化分岐後の `v = 0` 相当）。
    coalesce_or_zero,
    /// increment_values: operands=[old, amount]。公式の
    /// `Number(v0) + Number(incValue)` 相当の数値強制つき加算を返す。
    increment_values,
    /// DNCL互換の配列自動初期化（公式convLetArrayのcheckInit相当）。
    /// 値・添字の評価より先に実行されるようloweringで分解してemitされる。
    /// ensure_array_var: name=対象変数。変数が配列でなければ30要素の0配列で初期化する。
    ensure_array_var,
    /// is_array: operands=[value]。公式convLetArrayのcheck式
    /// `tmp[..] instanceof Array` 相当で、値が配列なら真を返す。
    is_array,
    /// init_array_index: operands=[container, key]。公式convLetArrayの
    /// write-back式 `tmp[..] = arrayDefCode` 相当で、container[key]へ
    /// 無条件に30要素の0配列を書き込む。nullishなコンテナへの書き込みは
    /// 公式同様『Cannot set properties of …』で失敗する。
    init_array_index,
    make_closure,
    iterator_begin,
    iterator_next,
    iterator_has_next,
    try_begin,
    try_end,
    exception_pending,
    exception_take,
    dynamic_execute,
    speed_mode_begin,
    speed_mode_end,
    performance_monitor_begin,
    performance_monitor_end,
    phi,
};

pub const PhiIncoming = struct { predecessor: BlockId, value: ValueId };
pub const LoopDirection = enum { automatic, up, down };

pub const Instruction = struct {
    result: ?ValueId,
    opcode: Opcode,
    type: Type,
    /// Stable identity for a statically named dispatch site.  This is assigned
    /// while lowering, before optimization, and is intentionally independent
    /// of source paths so it can join compile and runtime traces.
    site_id: ?u64 = null,
    /// Stable identity for a statically named global access. Global accesses
    /// use a separate namespace from builtin dispatch sites so adding read or
    /// write evidence never changes existing dispatch trace identities.
    global_site_id: ?u64 = null,
    /// Stable identity for a catalog constant that the parser lowers directly
    /// to a typed literal. Literal constants use a third namespace so their
    /// execution evidence cannot be mistaken for a global read or builtin
    /// dispatch.
    literal_site_id: ?u64 = null,
    is_builtin_call: bool = false,
    /// DNCL互換の配列要素代入で、未初期化変数へ30要素の0配列を自動初期化する。
    check_array_init: bool = false,
    /// 対象名がローカルシンボルへ解決された代入系命令で真。
    /// local slotの登録対象判定に使う。
    local_target: bool = false,
    /// 実効取り込み文からのモジュールエントリ呼び出しで真。
    /// モジュール直下の取り込み文（site_toplevel）は、その辺が存在する
    /// ストリームでのみ実行される: ベース側の辺（callee_order <=
    /// site_order）はコピー実行中に抑止され、コピー側のみの辺
    /// （callee_order > site_order）はベース実行中に抑止される。
    /// 関数本体内の取り込み文は公式同様に到達するたび常に実行される。
    is_module_entry: bool = false,
    site_module: u32 = 0,
    site_order: u32 = 0,
    callee_module: u32 = 0,
    callee_order: u32 = 0,
    site_toplevel: bool = false,
    operands: []ValueId = &.{},
    phi_incoming: []PhiIncoming = &.{},
    name: []const u8 = "",
    text: []const u8 = "",
    operator: []const u8 = "",
    names: []const []const u8 = &.{},
    /// destructure_storeの各namesがローカルシンボルへ束縛されたか。
    /// loweringが意味解析の束縛結果から設定し、namesと同じ長さになる。
    /// local_targetと同じく、修飾名の有無ではなく束縛結果を権威にする。
    names_local: []const bool = &.{},
    number_value: ?f64 = null,
    boolean_value: bool = false,
    direct_callee: ?FunctionId = null,
    loop_direction: LoopDirection = .automatic,
    exception_target: ?BlockId = null,
    span: ast.Span,
};

/// destructure_storeのターゲット名がローカル束縛かを返す。
/// names_localは意味解析の束縛結果を写したもの。手組みIR等で
/// 未設定の場合は修飾名ヒューリスティックへフォールバックする。
pub fn destructureTargetIsLocal(instruction: Instruction, index: usize) bool {
    if (index < instruction.names_local.len) return instruction.names_local[index];
    return index < instruction.names.len and std.mem.indexOf(u8, instruction.names[index], "__") == null;
}

pub const ConditionalBranch = struct { condition: ValueId, then_block: BlockId, else_block: BlockId };
pub const Throw = struct {
    value: ValueId,
    target: ?BlockId = null,
    /// Stable identity for the source-level `エラー発生` throw site. Throws
    /// use a separate namespace from builtin calls because they do not enter
    /// the generic dispatch ABI.
    site_id: ?u64 = null,
    span: ast.Span,
    /// `エラー発生` uses JavaScript Error(message) semantics rather than
    /// preserving an arbitrary thrown value in `エラーメッセージ`.
    coerce_to_error_message: bool = false,
};

pub const Terminator = union(enum) {
    none,
    branch: BlockId,
    conditional_branch: ConditionalBranch,
    return_value: ?ValueId,
    throw_value: Throw,
    propagate_exception,
    unreachable_terminator,
};

pub const BasicBlock = struct {
    id: BlockId,
    name: []const u8,
    instructions: []Instruction,
    terminator: Terminator,
};

pub const Parameter = struct { name: []const u8, value: ValueId, type: Type = .dynamic };

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    parameters: []Parameter,
    captures: []const []const u8 = &.{},
    blocks: []BasicBlock,
    entry: BlockId,
    return_type: Type,
    is_async: bool,
    is_test: bool,
};

pub const JavaScriptModule = struct {
    path: []const u8,
    source: []const u8,
    is_plugin: bool = false,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    functions: []Function,
    module_entries: []FunctionId,
    module_names: []const []const u8 = &.{},
    module_paths: []const []const u8 = &.{},
    compat_js: bool = false,
    javascript_modules: []JavaScriptModule = &.{},
    native_plugin_paths: []const []const u8 = &.{},
    http_server_plugin_imported: bool = false,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn clone(self: Program, backing_allocator: std.mem.Allocator) !Program {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const functions = try allocator.alloc(Function, self.functions.len);
        for (self.functions, functions) |source_function, *target_function| {
            const blocks = try allocator.alloc(BasicBlock, source_function.blocks.len);
            for (source_function.blocks, blocks) |source_block, *target_block| {
                const instructions = try allocator.dupe(Instruction, source_block.instructions);
                for (instructions) |*instruction| {
                    instruction.operands = try allocator.dupe(ValueId, instruction.operands);
                    instruction.phi_incoming = try allocator.dupe(PhiIncoming, instruction.phi_incoming);
                    instruction.name = try allocator.dupe(u8, instruction.name);
                    instruction.text = try allocator.dupe(u8, instruction.text);
                    instruction.operator = try allocator.dupe(u8, instruction.operator);
                    const names = try allocator.alloc([]const u8, instruction.names.len);
                    for (instruction.names, names) |source_name, *target_name| target_name.* = try allocator.dupe(u8, source_name);
                    instruction.names = names;
                    instruction.names_local = try allocator.dupe(bool, instruction.names_local);
                }
                target_block.* = source_block;
                target_block.name = try allocator.dupe(u8, source_block.name);
                target_block.instructions = instructions;
            }
            target_function.* = source_function;
            target_function.parameters = try allocator.dupe(Parameter, source_function.parameters);
            for (target_function.parameters) |*parameter| parameter.name = try allocator.dupe(u8, parameter.name);
            target_function.captures = try cloneStrings(allocator, source_function.captures);
            target_function.name = try allocator.dupe(u8, source_function.name);
            target_function.blocks = blocks;
        }
        const javascript_modules = try allocator.dupe(JavaScriptModule, self.javascript_modules);
        for (javascript_modules) |*module| {
            module.path = try allocator.dupe(u8, module.path);
            module.source = try allocator.dupe(u8, module.source);
        }
        const native_plugin_paths = try allocator.alloc([]const u8, self.native_plugin_paths.len);
        for (self.native_plugin_paths, native_plugin_paths) |source_path, *target_path| target_path.* = try allocator.dupe(u8, source_path);
        // arenaを返却値へコピーする前に確保を済ませる。リテラル内で呼ぶと
        // コピー後のarena状態へ確保が記録されずリークする。
        const module_entries = try allocator.dupe(FunctionId, self.module_entries);
        const module_names = try cloneStrings(allocator, self.module_names);
        const module_paths = try cloneStrings(allocator, self.module_paths);
        return .{
            .arena = arena,
            .functions = functions,
            .module_entries = module_entries,
            .module_names = module_names,
            .module_paths = module_paths,
            .compat_js = self.compat_js,
            .javascript_modules = javascript_modules,
            .native_plugin_paths = native_plugin_paths,
            .http_server_plugin_imported = self.http_server_plugin_imported,
        };
    }

    pub fn findFunction(self: Program, name: []const u8) ?Function {
        for (self.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
        return null;
    }
};

fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    for (source, result) |value, *target| target.* = try allocator.dupe(u8, value);
    return result;
}
