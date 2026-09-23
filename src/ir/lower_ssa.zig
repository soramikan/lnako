const std = @import("std");
const hir = @import("hir.zig");
const ir = @import("nako_ir.zig");
const system_constant = @import("../runtime/system_constant.zig");

pub fn lower(backing_allocator: std.mem.Allocator, hir_program: hir.Program) !ir.Program {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var functions: std.ArrayList(ir.Function) = .empty;
    for (hir_program.functions) |function| {
        var builder = FunctionBuilder{
            .allocator = allocator,
            .hir_program = hir_program,
            .function = function,
            .next_value = @intCast(function.parameters.len),
        };
        _ = try builder.createBlock("entry");
        for (function.parameters, 0..) |parameter, index| try builder.parameters.append(allocator, .{
            .name = try allocator.dupe(u8, parameter.name),
            .value = @intCast(index),
        });
        // 公式は関数内の`引数`を実引数の配列へ束縛する（nako_genのyCallFunc相当）。
        // 関数値呼び出しでは仮引数より多い実引数が届きうるため、配列は
        // 仮引数の並びではなく実行時の実引数列から作る専用命令をemitする。
        // InterpreterとAOTが同じIRを受け取るようここで作る。
        if (findArgumentsReference(hir_program, function.body)) |reference| try builder.lowerArgumentsBinding(reference);
        _ = try builder.lowerNode(function.body);
        if (!builder.isTerminated()) builder.terminate(.{ .return_value = builder.implicitResult() });
        var lowered = try builder.finish();
        try assignDispatchSiteIds(&lowered);
        try functions.append(allocator, lowered);
    }
    const module_entries = try allocator.alloc(ir.FunctionId, hir_program.modules.len);
    const variant_entries = try allocator.alloc([]ir.FunctionId, hir_program.modules.len);
    for (hir_program.modules, 0..) |module, index| {
        module_entries[index] = module.entry_function;
        variant_entries[index] = try allocator.dupe(ir.FunctionId, module.variant_entries);
    }
    const module_names = try allocator.alloc([]const u8, hir_program.modules.len);
    const module_paths = try allocator.alloc([]const u8, hir_program.modules.len);
    for (hir_program.modules, 0..) |module, index| {
        module_names[index] = try allocator.dupe(u8, module.name);
        module_paths[index] = try allocator.dupe(u8, module.path);
    }
    // arenaを返却値へコピーする前に確保を済ませる。リテラル内で呼ぶと
    // コピー後のarena状態へ確保が記録されずリークする。
    const lowered_functions = try functions.toOwnedSlice(allocator);
    return .{
        .arena = arena,
        .functions = lowered_functions,
        .module_entries = module_entries,
        .variant_entries = variant_entries,
        .module_names = module_names,
        .module_paths = module_paths,
    };
}

/// Assigns deterministic dispatch identities before any optimizer can clone,
/// fold, or remove instructions.  Function IDs are stable within a lowered
/// program and the low word is the source/CFG traversal ordinal, so IDs do not
/// depend on absolute paths or allocator addresses.
fn assignDispatchSiteIds(function: *ir.Function) !void {
    var ordinal: u64 = 0;
    var throw_ordinal: u64 = 0;
    var global_ordinal: u64 = 0;
    var literal_ordinal: u64 = 0;
    for (function.blocks) |*block| {
        for (block.instructions) |*instruction| {
            if (instruction.opcode == .call and instruction.direct_callee == null and instruction.is_builtin_call) {
                ordinal += 1;
                if (ordinal > std.math.maxInt(u32)) return error.DispatchSiteIdOverflow;
                instruction.site_id = (@as(u64, function.id) << 32) | ordinal;
            }
            // グローバル書き込みを行い得る名前付き命令もsite IDを付与する。
            // ensure_array_varはlocal_target=falseのとき変数スロットへ
            // 新規配列を書き戻すため、グローバル書き込みサイトとして記録する。
            // システム定数名は実行時・emitterとも初期化を省略するため記録しない。
            // lowering生成の内部命令（反復の退避・復元）は観測対象外とする。
            if (!instruction.synthetic and
                (instruction.opcode == .load_global or instruction.opcode == .store_global or
                    (instruction.opcode == .ensure_array_var and !instruction.local_target and
                        !system_constant.isConstant(instruction.name))))
            {
                global_ordinal += 1;
                if (global_ordinal > std.math.maxInt(u32)) return error.GlobalSiteIdOverflow;
                instruction.global_site_id = (@as(u64, function.id) << 32) | global_ordinal;
            }
            if (isStaticLiteralInstruction(instruction)) {
                literal_ordinal += 1;
                if (literal_ordinal > std.math.maxInt(u32)) return error.LiteralSiteIdOverflow;
                instruction.literal_site_id = (@as(u64, function.id) << 32) | literal_ordinal;
            }
        }
        switch (block.terminator) {
            .throw_value => |*throw_value| {
                throw_ordinal += 1;
                // The high bit of the low word separates throw sites from
                // builtin-call sites while preserving the function prefix.
                if (throw_ordinal > 0x7fff_ffff) return error.ThrowSiteIdOverflow;
                throw_value.site_id = (@as(u64, function.id) << 32) | 0x8000_0000 | throw_ordinal;
            },
            else => {},
        }
    }
}

fn isStaticLiteralInstruction(instruction: *const ir.Instruction) bool {
    if (instruction.opcode != .const_boolean and instruction.opcode != .const_null) return false;
    return std.mem.eql(u8, instruction.text, "はい") or
        std.mem.eql(u8, instruction.text, "いいえ") or
        std.mem.eql(u8, instruction.text, "真") or
        std.mem.eql(u8, instruction.text, "偽") or
        std.mem.eql(u8, instruction.text, "オン") or
        std.mem.eql(u8, instruction.text, "オフ") or
        std.mem.eql(u8, instruction.text, "NULL");
}

/// 関数本体が`引数`を参照しているかを調べ、最初の参照ノードを返す。
/// 解析器は`引数`を関数スコープのローカルとして宣言するため、参照は
/// `load_local`/`store_local`として現れる（トップレベルは対象外）。
/// ノード種別ではなく意味解析の束縛（`uses_implicit_arguments`）で判定する。
fn findArgumentsReference(program: hir.Program, node_id: hir.NodeId) ?hir.Node {
    const node = program.node(node_id);
    if (node.uses_implicit_arguments) return node;
    // `.nop`/`.closure`は入れ子の関数定義をloweringした痕跡で、子には本体が
    // 残る。入れ子関数はそれぞれ独自の`引数`束縛を持つため走査しない。
    if (node.kind == .nop or node.kind == .closure) return null;
    for (node.children) |child| if (findArgumentsReference(program, child)) |found| return found;
    return null;
}

const BlockBuilder = struct {
    id: ir.BlockId,
    name: []const u8,
    instructions: std.ArrayList(ir.Instruction) = .empty,
    terminator: ir.Terminator = .none,
};

/// ループ脱出先のブロックと、ループ突入時点の例外ハンドラ深さ。
/// handler_depthはループ本体の内側で開始した監視領域だけを脱出時に
/// 畳くための基準で、ループを外側から囲む監視領域は対象外とする。
const LoopTargets = struct { continue_block: ir.BlockId, break_block: ir.BlockId, handler_depth: usize };

const FunctionBuilder = struct {
    allocator: std.mem.Allocator,
    hir_program: hir.Program,
    function: hir.Function,
    blocks: std.ArrayList(*BlockBuilder) = .empty,
    parameters: std.ArrayList(ir.Parameter) = .empty,
    current: ir.BlockId = 0,
    next_value: ir.ValueId,
    loops: std.ArrayList(LoopTargets) = .empty,
    exception_handlers: std.ArrayList(ir.BlockId) = .empty,

    fn finish(self: *FunctionBuilder) !ir.Function {
        // 引数位置の『エラー発生』等で途中終端した経路では、生成済みだが
        // 未到達となったブロックが終端未設定のまま残りうる。実行されない
        // ブロックとして unreachable を補っておく。
        for (self.blocks.items) |block| if (block.terminator == .none) {
            block.terminator = .unreachable_terminator;
        };
        var blocks = try self.allocator.alloc(ir.BasicBlock, self.blocks.items.len);
        for (self.blocks.items, 0..) |block, index| blocks[index] = .{
            .id = block.id,
            .name = block.name,
            .instructions = try block.instructions.toOwnedSlice(self.allocator),
            .terminator = block.terminator,
        };
        return .{
            .id = self.function.id,
            .name = try self.allocator.dupe(u8, self.function.name),
            .parameters = try self.parameters.toOwnedSlice(self.allocator),
            .captures = try dupeStrings(self.allocator, self.function.captures),
            .blocks = blocks,
            .entry = 0,
            .return_type = toType(self.function.return_type),
            .is_async = self.function.is_async,
            .is_test = self.function.is_test,
            .sore_scope = !self.function.is_entry,
        };
    }

    fn lowerNode(self: *FunctionBuilder, node_id: hir.NodeId) anyerror!?ir.ValueId {
        const node = self.hir_program.node(node_id);
        return switch (node.kind) {
            .nop => null,
            .block => self.lowerBlock(node),
            .number => try self.emitValue(.const_number, .number, &.{}, node),
            .bigint => try self.emitValue(.const_bigint, .bigint, &.{}, node),
            .boolean => try self.emitValue(.const_boolean, .boolean, &.{}, node),
            .null_value => try self.emitValue(.const_null, .null_value, &.{}, node),
            .string, .string_template => try self.emitValue(.const_string, .string, &.{}, node),
            .load_global => try self.emitValue(.load_global, toType(node.type_hint), &.{}, node),
            .load_local => try self.emitValue(.load_local, toType(node.type_hint), &.{}, node),
            .store_global => try self.lowerStore(.store_global, node),
            .store_local => try self.lowerStore(.store_local, node),
            .destructure_store => try self.lowerVariadic(.destructure_store, .void, node),
            .binary => if (isLogicalOperator(node.operator)) try self.lowerLogical(node) else try self.lowerFallible(.binary, toType(node.type_hint), node),
            .unary => if (std.mem.eql(u8, node.operator, "+") or std.mem.eql(u8, node.operator, "-"))
                try self.lowerFallible(.unary, toType(node.type_hint), node)
            else
                try self.lowerVariadic(.unary, toType(node.type_hint), node),
            .call => try self.lowerCall(.call, node),
            .call_value => try self.lowerCall(.call_value, node),
            .make_array => try self.lowerVariadic(.make_array, .array, node),
            .make_object => try self.lowerVariadic(.make_object, .object, node),
            // 公式は undefined/null コンテナへの添字・プロパティ読み出しで
            // 実行時TypeErrorになるため、読み取り系も例外境界を付ける
            .array_get => try self.lowerFallible(.array_get, .dynamic, node),
            .property_get => try self.lowerFallible(.property_get, .dynamic, node),
            .array_set => try self.lowerIndexedSet(node),
            .property_set => try self.lowerIndexedSet(node),
            .increment => try self.lowerIncrement(node),
            // 添字増減はコンテナ未宣言・null等で実行時失敗し得るため例外境界を付ける
            .increment_indexed => try self.lowerIncrementIndexed(node),
            .if_statement => self.lowerIf(node),
            .while_statement => self.lowerWhile(node, false),
            .post_test_loop => self.lowerWhile(node, true),
            .repeat_times, .for_statement, .foreach_statement => self.lowerIteratorLoop(node),
            .return_statement => self.lowerReturn(node),
            .break_statement => self.lowerBreak(node),
            .continue_statement => self.lowerContinue(node),
            .closure => try self.emitValue(.make_closure, .function, &.{}, node),
            .try_except => self.lowerTry(node),
            .throw_statement => self.lowerThrow(node),
            .switch_statement => self.lowerSwitch(node),
            .speed_mode => self.lowerScopedMode(.speed_mode_begin, .speed_mode_end, node),
            .performance_monitor => self.lowerScopedMode(.performance_monitor_begin, .performance_monitor_end, node),
        };
    }

    fn lowerBlock(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        var last: ?ir.ValueId = null;
        for (node.children) |child| {
            if (self.isTerminated()) break;
            last = try self.lowerNode(child);
        }
        return last;
    }

    /// 関数先頭で`引数 = 実引数配列`を実行する。公式はJSの`arguments`を
    /// 束縛するため、関数値呼び出しで仮引数より多く渡された実引数も
    /// 要素に含まれる（末尾の`__self`相当だけはJS実装詳細のため含めない）。
    /// 参照ノードを渡すのは、生成する命令へ`引数`という名前とspanを
    /// 引き継ぐため。
    fn lowerArgumentsBinding(self: *FunctionBuilder, reference: hir.Node) !void {
        const array = try self.emitValue(.arguments_array, .array, &.{}, reference);
        try self.emitVoid(.store_local, &.{array}, reference);
    }

    fn lowerStore(self: *FunctionBuilder, opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        // 公式は初期値を省略した宣言（`変数 A`・`Aとは変数`）のnopブロックを
        // 0として保存する（nako_genのconvDefLocalVar相当）。保存先を持たない
        // 文はchildを持たないため、従来どおりundefinedを保存する。
        const value = if (node.children.len > 0)
            (try self.lowerNode(node.children[0])) orelse try self.emitConstNumber(0, node)
        else
            try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        try self.emitVoid(opcode, &.{value}, node);
        return value;
    }

    fn lowerVariadic(self: *FunctionBuilder, opcode: ir.Opcode, result_type: ir.Type, node: hir.Node) !?ir.ValueId {
        var operands: std.ArrayList(ir.ValueId) = .empty;
        for (node.children) |child| {
            if (self.isTerminated()) break;
            if (try self.lowerNode(child)) |value| try operands.append(self.allocator, value);
        }
        // 引数位置の『エラー発生』など、子の評価でブロックが終端した場合は
        // 後続の命令を発行しない（終端を上書きしてthrowを失わないため）。
        if (self.isTerminated()) return null;
        if (result_type == .void) {
            try self.emitVoid(opcode, operands.items, node);
            return null;
        }
        return try self.emitValue(opcode, result_type, operands.items, node);
    }

    fn lowerCall(self: *FunctionBuilder, opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        const result = (try self.lowerVariadic(opcode, toType(node.type_hint), node)) orelse return null;
        try self.lowerExceptionCheck(node);
        return result;
    }

    fn lowerFallible(self: *FunctionBuilder, opcode: ir.Opcode, result_type: ir.Type, node: hir.Node) !?ir.ValueId {
        const result = (try self.lowerVariadic(opcode, result_type, node)) orelse return null;
        try self.lowerExceptionCheck(node);
        return result;
    }

    fn lowerFallibleVoid(self: *FunctionBuilder, opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        _ = try self.lowerVariadic(opcode, .void, node);
        if (self.isTerminated()) return null;
        try self.lowerExceptionCheck(node);
        return null;
    }

    /// 添字・プロパティ代入（array_set/property_set相当）。公式convLet/
    /// convLetArrayは `get(name)[k0]..[kn-1] = value` の形を生成し、
    /// ルート変数参照を添字式の評価より先に束縛する。添字式がルート変数を
    /// 再束縛しても代入は束縛済みコンテナへ行われるため、ここでも先に
    /// loadして使い回す。中間レベルは公式の左辺走査と同じく、添字評価と
    /// array_getを交互にemitする（中間読出しの失敗は後続添字・値の評価
    /// より先に伝播する）。check_array_init付きはDNCLの自動初期化として
    /// 『ルート初期化 → 中間レベルの添字再評価つき初期化』を先に挿入する。
    fn lowerIndexedSet(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        // element_setはcontainer/key/valueの3operandを要求するため、
        // 値または添字を欠くHIRはそのまま命令へ落とさず失敗させる
        if (node.children.len < 2) return error.InvalidHir;
        const key_nodes = node.children[1..];
        if (node.check_array_init) {
            try self.emitVoid(.ensure_array_var, &.{}, node);
            try self.lowerExceptionCheck(node);
        }
        // 公式の `tmpVar = get(name)` 相当: ルート変数を1度だけ束縛する
        const tmp = try self.emitValue(if (node.local_target) .load_local else .load_global, .dynamic, &.{}, node);
        if (node.check_array_init) {
            // 公式convLetArrayのcheckInitは中間レベルで
            // `if (!(tmp[k0]..[ki] instanceof Array)) { tmp[k0]..[ki] = 新規配列 }`
            // を生成する。check式とwrite-back式で同一添字式を評価し直すため、
            // 副作用を持つ添字式は初期化が走るレベルで2回評価される。
            for (0..key_nodes.len - 1) |level| {
                // check式: tmp[k0]..[k_level] を添字評価つきで走査する
                var container = tmp;
                for (0..level + 1) |j| {
                    const key = (try self.lowerNode(key_nodes[j])) orelse try self.emitUndefined(node);
                    if (self.isTerminated()) return null;
                    container = try self.emitValue(.array_get, .dynamic, &.{ container, key }, node);
                    // チェーン途中のnullish読出し失敗を最初の文言で伝播させる
                    try self.lowerExceptionCheck(node);
                }
                const is_array = try self.emitValue(.is_array, .boolean, &.{container}, node);
                const init_block = try self.createBlock("dncl_init.writeback");
                const merge_block = try self.createBlock("dncl_init.merge");
                self.terminate(.{ .conditional_branch = .{ .condition = is_array, .then_block = merge_block, .else_block = init_block } });
                // write-back式: 添字を評価し直して tmp[k0']..[k_level'] = 新規配列
                self.current = init_block;
                var write_container = tmp;
                for (0..level) |j| {
                    const key = (try self.lowerNode(key_nodes[j])) orelse try self.emitUndefined(node);
                    if (self.isTerminated()) return null;
                    write_container = try self.emitValue(.array_get, .dynamic, &.{ write_container, key }, node);
                    try self.lowerExceptionCheck(node);
                }
                const write_key = (try self.lowerNode(key_nodes[level])) orelse try self.emitUndefined(node);
                if (self.isTerminated()) return null;
                try self.emitVoid(.init_array_index, &.{ write_container, write_key }, node);
                try self.lowerExceptionCheck(node);
                self.terminate(.{ .branch = merge_block });
                self.current = merge_block;
            }
        }
        // 最終代入（公式のcode部相当）は添字評価と中間走査を織り交ぜ、
        // 値は全添字の評価後に評価する。
        // checkInit付きでは公式が `code = name` から生成するため、
        // ルート変数を束縛し直してから走査する（初期化チェックの添字評価で
        // ルートが再束縛された場合、公式は新しい値へ書き込む）。
        var container = if (node.check_array_init)
            try self.emitValue(if (node.local_target) .load_local else .load_global, .dynamic, &.{}, node)
        else
            tmp;
        for (key_nodes[0 .. key_nodes.len - 1]) |key_node| {
            const key = (try self.lowerNode(key_node)) orelse try self.emitUndefined(node);
            if (self.isTerminated()) return null;
            container = try self.emitValue(.array_get, .dynamic, &.{ container, key }, node);
            try self.lowerExceptionCheck(node);
        }
        const last_key = (try self.lowerNode(key_nodes[key_nodes.len - 1])) orelse try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        const value = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        try self.emitVoid(.element_set, &.{ container, last_key, value }, node);
        try self.lowerExceptionCheck(node);
        return null;
    }

    /// 変数増減（XをN増やす）。公式convIncの変数経路:
    /// `v0 = varGetter` → `if (typeof v0 === 'undefined') { varInitter; v0 = 0 }`
    /// → `v0 = Number(v0) + Number(incValue)` → `varSetter`。
    /// 増減量式は加算行に埋め込まれるため、読み出し・初期化の後に評価する。
    fn lowerIncrement(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        const load_op: ir.Opcode = if (node.local_target) .load_local else .load_global;
        const store_op: ir.Opcode = if (node.local_target) .store_local else .store_global;
        const old = try self.emitValue(load_op, .dynamic, &.{}, node);
        const is_undefined = try self.emitValue(.is_undefined, .boolean, &.{old}, node);
        const init_block = try self.createBlock("increment.init");
        const merge_block = try self.createBlock("increment.merge");
        self.terminate(.{ .conditional_branch = .{ .condition = is_undefined, .then_block = init_block, .else_block = merge_block } });
        self.current = init_block;
        const init_zero = try self.emitConstNumber(0, node);
        try self.emitVoid(store_op, &.{init_zero}, node);
        try self.lowerExceptionCheck(node);
        self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        const base = try self.emitValue(.coalesce_or_zero, .dynamic, &.{old}, node);
        const amount = if (node.children.len > 0)
            (try self.lowerNode(node.children[0])) orelse try self.emitConstNumber(1, node)
        else
            try self.emitConstNumber(1, node);
        if (self.isTerminated()) return null;
        const updated = try self.emitValue(.increment_values, .dynamic, &.{ base, amount }, node);
        try self.lowerExceptionCheck(node);
        try self.emitVoid(store_op, &.{updated}, node);
        try self.lowerExceptionCheck(node);
        return null;
    }

    /// 添字増減（A[i]をN増やす）。公式convIncのref_array/ref_prop経路:
    /// `o1=get(name); i1=k; …` でコンテナと添字を一度だけ束縛し、
    /// `v0=o1[i1]…` → `if (typeof v0==='undefined') { o1[i1]…=0; v0=0 }`
    /// → `v0=Number(v0)+Number(incValue)` → `o1[i1]…=v0` の順で評価する。
    /// ルート変数や中間レベルの自動初期化は公式も行わない（TypeErrorになる）。
    fn lowerIncrementIndexed(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        const key_nodes = node.children[1..];
        // 公式のpreCode相当: コンテナ→添字の順に一度だけ束縛する
        const container = try self.emitValue(if (node.local_target) .load_local else .load_global, .dynamic, &.{}, node);
        var keys: std.ArrayList(ir.ValueId) = .empty;
        for (key_nodes) |key_node| {
            try keys.append(self.allocator, (try self.lowerNode(key_node)) orelse try self.emitUndefined(node));
            if (self.isTerminated()) return null;
        }
        // varGetter相当: 束縛したコンテナ・添字で要素を読み出す
        var deepest = container;
        for (keys.items[0 .. keys.items.len - 1]) |key| {
            deepest = try self.emitValue(.array_get, .dynamic, &.{ deepest, key }, node);
            try self.lowerExceptionCheck(node);
        }
        const last_key = keys.items[keys.items.len - 1];
        const old = try self.emitValue(.array_get, .dynamic, &.{ deepest, last_key }, node);
        try self.lowerExceptionCheck(node);
        // 公式の `if (typeof v0 === 'undefined') { varInitter; v0 = 0 }` 相当
        const is_undefined = try self.emitValue(.is_undefined, .boolean, &.{old}, node);
        const init_block = try self.createBlock("increment.init");
        const merge_block = try self.createBlock("increment.merge");
        self.terminate(.{ .conditional_branch = .{ .condition = is_undefined, .then_block = init_block, .else_block = merge_block } });
        self.current = init_block;
        const init_zero = try self.emitConstNumber(0, node);
        try self.emitVoid(.element_set, &.{ deepest, last_key, init_zero }, node);
        try self.lowerExceptionCheck(node);
        self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        const base = try self.emitValue(.coalesce_or_zero, .dynamic, &.{old}, node);
        // 公式は `Number(v0) + Number(incValue)` の行で増減量式を評価する
        const amount = if (node.children.len > 0)
            (try self.lowerNode(node.children[0])) orelse try self.emitConstNumber(1, node)
        else
            try self.emitConstNumber(1, node);
        if (self.isTerminated()) return null;
        const updated = try self.emitValue(.increment_values, .dynamic, &.{ base, amount }, node);
        try self.lowerExceptionCheck(node);
        // varSetter相当: 公式は `o1[i1]…` を再評価するため、量の評価で
        // 中間コンテナが変化した場合は新しい中間コンテナへ書き込む
        var write_container = container;
        for (keys.items[0 .. keys.items.len - 1]) |key| {
            write_container = try self.emitValue(.array_get, .dynamic, &.{ write_container, key }, node);
            try self.lowerExceptionCheck(node);
        }
        try self.emitVoid(.element_set, &.{ write_container, last_key, updated }, node);
        try self.lowerExceptionCheck(node);
        return null;
    }

    fn lowerExceptionCheck(self: *FunctionBuilder, node: hir.Node) !void {
        if (self.isTerminated()) return;
        const pending = try self.emitValue(.exception_pending, .boolean, &.{}, node);
        const exception_block = if (self.exception_handlers.items.len > 0)
            self.exception_handlers.items[self.exception_handlers.items.len - 1]
        else
            try self.createBlock("exception.propagate");
        const continue_block = try self.createBlock("exception.continue");
        self.terminate(.{ .conditional_branch = .{ .condition = pending, .then_block = exception_block, .else_block = continue_block } });
        if (self.exception_handlers.items.len == 0) {
            self.current = exception_block;
            self.terminate(.propagate_exception);
        }
        self.current = continue_block;
    }

    fn lowerLogical(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len != 2) return error.InvalidHir;
        const left = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        const left_predecessor = self.current;
        const right_block = try self.createBlock("logical.right");
        const merge_block = try self.createBlock("logical.end");
        const is_and = std.mem.eql(u8, node.operator, "&&") or std.mem.eql(u8, node.operator, "and");
        self.terminate(.{ .conditional_branch = .{
            .condition = left,
            .then_block = if (is_and) right_block else merge_block,
            .else_block = if (is_and) merge_block else right_block,
        } });

        self.current = right_block;
        const right = (try self.lowerNode(node.children[1])) orelse try self.emitUndefined(node);
        const right_predecessor = self.current;
        var incoming: std.ArrayList(ir.PhiIncoming) = .empty;
        try incoming.append(self.allocator, .{ .predecessor = left_predecessor, .value = left });
        if (!self.isTerminated()) {
            self.terminate(.{ .branch = merge_block });
            try incoming.append(self.allocator, .{ .predecessor = right_predecessor, .value = right });
        }

        self.current = merge_block;
        const result = self.next_value;
        self.next_value += 1;
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = result,
            .opcode = .phi,
            .type = toType(node.type_hint),
            .phi_incoming = try incoming.toOwnedSlice(self.allocator),
            .operator = try self.allocator.dupe(u8, node.operator),
            .span = node.span,
        });
        return result;
    }

    fn lowerIf(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 3) return error.InvalidHir;
        const condition = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        const then_block = try self.createBlock("if.then");
        const else_block = try self.createBlock("if.else");
        const merge_block = try self.createBlock("if.end");
        self.terminate(.{ .conditional_branch = .{ .condition = condition, .then_block = then_block, .else_block = else_block } });

        self.current = then_block;
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = else_block;
        _ = try self.lowerNode(node.children[2]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerWhile(self: *FunctionBuilder, node: hir.Node, post_test: bool) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        const condition_block = try self.createBlock("loop.cond");
        const body_block = try self.createBlock("loop.body");
        const exit_block = try self.createBlock("loop.end");
        self.terminate(.{ .branch = if (post_test) body_block else condition_block });
        try self.loops.append(self.allocator, .{ .continue_block = condition_block, .break_block = exit_block, .handler_depth = self.exception_handlers.items.len });

        self.current = body_block;
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = condition_block });
        self.current = condition_block;
        const condition = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        if (self.isTerminated()) {
            _ = self.loops.pop();
            self.current = exit_block;
            return null;
        }
        self.terminate(.{ .conditional_branch = .{ .condition = condition, .then_block = body_block, .else_block = exit_block } });
        _ = self.loops.pop();
        self.current = exit_block;
        return null;
    }

    /// 反復構文で退避するシステム変数名。公式convForeachは対象・対象キー・
    /// それの3つをループ前に退避し、出口で復元する。
    const foreach_saved_names = [_][]const u8{ "対象", "対象キー", "それ" };

    fn lowerIteratorLoop(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        const is_foreach = node.kind == .foreach_statement;
        const is_repeat_times = node.kind == .repeat_times;
        // 公式convForeachは反復データの評価より先に「対象」「対象キー」「それ」を
        // 退避し、ループ出口で復元する（#1735の入れ子ループ互換）。
        var saved: [foreach_saved_names.len]ir.ValueId = undefined;
        if (is_foreach) {
            for (foreach_saved_names, 0..) |name, index| saved[index] = try self.emitSyntheticGlobalAccess(.load_global, name, null, node);
        }
        // 公式convRepeatTimesは回数繰り返しの前に「回数」を退避し、
        // 出口で「回数」と「それ」の両方へその退避値を書き戻す。
        const saved_kaisu: ?ir.ValueId = if (is_repeat_times)
            try self.emitSyntheticGlobalAccess(.load_global, "回数", null, node)
        else
            null;
        var inputs: std.ArrayList(ir.ValueId) = .empty;
        for (node.children[0 .. node.children.len - 1]) |child| {
            const value = (try self.lowerNode(child)) orelse try self.emitUndefined(node);
            try inputs.append(self.allocator, value);
            if (self.isTerminated()) return null;
        }
        const iterator = try self.emitValue(.iterator_begin, .dynamic, inputs.items, node);
        // 範囲終端の変換はカスタムvalueOfを呼び得るため、失敗時は
        // 通常のループ入りではなく例外経路へ送る。
        try self.lowerExceptionCheck(node);
        const condition_block = try self.createBlock("iterator.cond");
        const body_block = try self.createBlock("iterator.body");
        const exit_block = try self.createBlock("iterator.end");
        self.terminate(.{ .branch = condition_block });
        try self.loops.append(self.allocator, .{ .continue_block = condition_block, .break_block = exit_block, .handler_depth = self.exception_handlers.items.len });
        self.current = condition_block;
        const has_next = try self.emitValue(.iterator_has_next, .boolean, &.{iterator}, node);
        // `N回`ガードの抽象関係比較は反復ごとにカスタムvalueOfを呼び得る
        // ため、失敗時は通常のループ脱出ではなく例外経路へ送る。
        try self.lowerExceptionCheck(node);
        self.terminate(.{ .conditional_branch = .{ .condition = has_next, .then_block = body_block, .else_block = exit_block } });
        self.current = body_block;
        _ = try self.emitValue(.iterator_next, .dynamic, &.{iterator}, node);
        // iterator_nextもpending例外を設定し得る（要素アクセスや将来の
        // 関係比較失敗）ため、本文実行前に例外経路へ送る。
        try self.lowerExceptionCheck(node);
        _ = try self.lowerNode(node.children[node.children.len - 1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = condition_block });
        _ = self.loops.pop();
        self.current = exit_block;
        if (is_foreach) {
            for (foreach_saved_names, 0..) |name, index| _ = try self.emitSyntheticGlobalAccess(.store_global, name, saved[index], node);
        }
        if (saved_kaisu) |value| {
            _ = try self.emitSyntheticGlobalAccess(.store_global, "それ", value, node);
            _ = try self.emitSyntheticGlobalAccess(.store_global, "回数", value, node);
        }
        return null;
    }

    /// 反復の退避・復元のように、ソースの式ではなくloweringが生成する
    /// グローバルアクセス。観測証跡（global site ID）を持たない内部命令とする。
    fn emitSyntheticGlobalAccess(self: *FunctionBuilder, opcode: ir.Opcode, name: []const u8, operand: ?ir.ValueId, node: hir.Node) !ir.ValueId {
        const value = self.next_value;
        self.next_value += 1;
        const operands: []const ir.ValueId = if (operand) |id| &.{id} else &.{};
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = if (opcode == .store_global) null else value,
            .opcode = opcode,
            .type = if (opcode == .store_global) .void else .dynamic,
            .operands = try self.allocator.dupe(ir.ValueId, operands),
            .name = try self.allocator.dupe(u8, name),
            .synthetic = true,
            .span = node.span,
        });
        return value;
    }

    fn lowerReturn(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        const value = if (node.children.len > 0) try self.lowerNode(node.children[0]) else null;
        if (self.isTerminated()) return null;
        // 関数を抜ける経路でも残りの監視ハンドラを畳く。フレーム解体で
        // スタック自体は消えるが、try_begin/try_endを全経路で対に保ち、
        // 「ブロックを抜けるとハンドラ深さが戻る」不変条件を維持する。
        try self.unwindExceptionHandlers(0, node);
        self.terminate(.{ .return_value = value });
        return value;
    }

    fn lowerBreak(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (self.loops.items.len == 0) {
            self.terminate(.unreachable_terminator);
        } else {
            const targets = self.loops.items[self.loops.items.len - 1];
            try self.unwindExceptionHandlers(targets.handler_depth, node);
            self.terminate(.{ .branch = targets.break_block });
        }
        return null;
    }

    fn lowerContinue(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (self.loops.items.len == 0) {
            self.terminate(.unreachable_terminator);
        } else {
            const targets = self.loops.items[self.loops.items.len - 1];
            try self.unwindExceptionHandlers(targets.handler_depth, node);
            self.terminate(.{ .branch = targets.continue_block });
        }
        return null;
    }

    /// ループ脱出・関数脱出で監視領域を横切る経路へ、抜ける側のtry_begin分の
    /// try_endをemitする。Interpreterはtry_beginでハンドラをフレームの
    /// スタックへ積みtry_endで降ろすため、try_endを欠く脱出経路は終了済みの
    /// ハンドラを残し、後続の例外を死んだ監視ブロックへ誤配送する（ループ内
    /// ハンドラなら本体のゾンビ再実行になる）。静的な深さの記録
    /// （exception_handlers）は構造上まだtry内のため、ここでは変更しない。
    fn unwindExceptionHandlers(self: *FunctionBuilder, target_depth: usize, node: hir.Node) !void {
        std.debug.assert(self.exception_handlers.items.len >= target_depth);
        for (0..self.exception_handlers.items.len -| target_depth) |_| {
            try self.emitVoid(.try_end, &.{}, node);
        }
    }

    fn lowerTry(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len < 2) return error.InvalidHir;
        const handler_block = try self.createBlock("try.handler");
        const merge_block = try self.createBlock("try.end");
        try self.emitVoid(.try_begin, &.{}, node);
        self.currentBlock().instructions.items[self.currentBlock().instructions.items.len - 1].exception_target = handler_block;
        try self.exception_handlers.append(self.allocator, handler_block);
        if (node.children.len > 0) _ = try self.lowerNode(node.children[0]);
        _ = self.exception_handlers.pop();
        if (!self.isTerminated()) {
            try self.emitVoid(.try_end, &.{}, node);
            self.terminate(.{ .branch = merge_block });
        }
        self.current = handler_block;
        try self.emitVoid(.exception_take, &.{}, node);
        _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerThrow(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        const value = if (node.children.len > 0)
            (try self.lowerNode(node.children[node.children.len - 1])) orelse try self.emitUndefined(node)
        else
            try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        self.terminate(.{ .throw_value = .{
            .value = value,
            .target = if (self.exception_handlers.items.len > 0) self.exception_handlers.items[self.exception_handlers.items.len - 1] else null,
            .span = node.span,
            .coerce_to_error_message = true,
        } });
        return value;
    }

    fn lowerSwitch(self: *FunctionBuilder, node: hir.Node) !?ir.ValueId {
        if (node.children.len == 0) return null;
        const discriminant = (try self.lowerNode(node.children[0])) orelse try self.emitUndefined(node);
        if (self.isTerminated()) return null;
        const merge_block = try self.createBlock("switch.end");
        var index: usize = 2;
        while (index + 1 < node.children.len) : (index += 2) {
            const case_value = (try self.lowerNode(node.children[index])) orelse try self.emitUndefined(node);
            if (self.isTerminated()) return null;
            const compare = try self.emitValue(.binary, .boolean, &.{ discriminant, case_value }, node);
            self.currentBlock().instructions.items[self.currentBlock().instructions.items.len - 1].operator = "==";
            const case_block = try self.createBlock("switch.case");
            const next_block = try self.createBlock("switch.next");
            self.terminate(.{ .conditional_branch = .{ .condition = compare, .then_block = case_block, .else_block = next_block } });
            self.current = case_block;
            _ = try self.lowerNode(node.children[index + 1]);
            if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
            self.current = next_block;
        }
        if (node.children.len > 1) _ = try self.lowerNode(node.children[1]);
        if (!self.isTerminated()) self.terminate(.{ .branch = merge_block });
        self.current = merge_block;
        return null;
    }

    fn lowerScopedMode(self: *FunctionBuilder, begin_opcode: ir.Opcode, end_opcode: ir.Opcode, node: hir.Node) !?ir.ValueId {
        try self.emitVoid(begin_opcode, &.{}, node);
        const result = if (node.children.len > 0) try self.lowerNode(node.children[node.children.len - 1]) else null;
        if (!self.isTerminated()) try self.emitVoid(end_opcode, &.{}, node);
        return result;
    }

    fn emitUndefined(self: *FunctionBuilder, node: hir.Node) !ir.ValueId {
        return self.emitValue(.const_undefined, .dynamic, &.{}, node);
    }

    /// loweringで生成する数値リテラル（増減文の初期化0・既定量1）。
    /// HIRノード由来でないためnumber_valueを明示的に設定する。
    fn emitConstNumber(self: *FunctionBuilder, number: f64, node: hir.Node) !ir.ValueId {
        const value = try self.emitValue(.const_number, .number, &.{}, node);
        self.currentBlock().instructions.items[self.currentBlock().instructions.items.len - 1].number_value = number;
        return value;
    }

    fn emitValue(self: *FunctionBuilder, opcode: ir.Opcode, result_type: ir.Type, operands: []const ir.ValueId, node: hir.Node) !ir.ValueId {
        const value = self.next_value;
        self.next_value += 1;
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = value,
            .opcode = opcode,
            .type = result_type,
            .operands = try self.allocator.dupe(ir.ValueId, operands),
            .name = try self.allocator.dupe(u8, node.name),
            .text = try self.allocator.dupe(u8, node.text),
            .operator = try self.allocator.dupe(u8, node.operator),
            .names = try dupeStrings(self.allocator, node.names),
            .names_local = try self.allocator.dupe(bool, node.names_local),
            .number_value = node.number_value,
            .boolean_value = node.boolean_value,
            .loop_direction = toLoopDirection(node.loop_direction),
            .is_builtin_call = node.is_builtin_call,
            .check_array_init = node.check_array_init,
            .local_target = node.local_target,
            .is_foreach = node.kind == .foreach_statement,
            .is_module_entry = node.is_module_entry,
            .site_module = node.site_module,
            .site_order = node.site_order,
            .callee_module = node.callee_module,
            .callee_order = node.callee_order,
            .site_toplevel = node.site_toplevel,
            .callee_variant = node.callee_variant,
            .span = node.span,
        });
        return value;
    }

    fn emitVoid(self: *FunctionBuilder, opcode: ir.Opcode, operands: []const ir.ValueId, node: hir.Node) !void {
        try self.currentBlock().instructions.append(self.allocator, .{
            .result = null,
            .opcode = opcode,
            .type = .void,
            .operands = try self.allocator.dupe(ir.ValueId, operands),
            .name = try self.allocator.dupe(u8, node.name),
            .text = try self.allocator.dupe(u8, node.text),
            .operator = try self.allocator.dupe(u8, node.operator),
            .names = try dupeStrings(self.allocator, node.names),
            .names_local = try self.allocator.dupe(bool, node.names_local),
            .loop_direction = toLoopDirection(node.loop_direction),
            .is_builtin_call = node.is_builtin_call,
            .check_array_init = node.check_array_init,
            .local_target = node.local_target,
            .is_foreach = node.kind == .foreach_statement,
            .is_module_entry = node.is_module_entry,
            .site_module = node.site_module,
            .site_order = node.site_order,
            .callee_module = node.callee_module,
            .callee_order = node.callee_order,
            .site_toplevel = node.site_toplevel,
            .callee_variant = node.callee_variant,
            .span = node.span,
        });
    }

    fn createBlock(self: *FunctionBuilder, base_name: []const u8) !ir.BlockId {
        const id: ir.BlockId = @intCast(self.blocks.items.len);
        const block = try self.allocator.create(BlockBuilder);
        block.* = .{ .id = id, .name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ base_name, id }) };
        try self.blocks.append(self.allocator, block);
        return id;
    }

    fn currentBlock(self: *FunctionBuilder) *BlockBuilder {
        return self.blocks.items[self.current];
    }

    fn isTerminated(self: *FunctionBuilder) bool {
        return self.currentBlock().terminator != .none;
    }

    /// 関数末尾の暗黙戻り値。末尾が『それ』への保存ならその値をそのまま
    /// 返す。それ以外は`null`を返し、sore_scope関数では実行側が現在の
    /// 『それ』を返す（公式は全ユーザー関数へ`return (それ)`を付与する
    /// nako_genのconvDefFuncCommon相当）。呼出し結果は実行時に『それ』へ
    /// 書き戻されるため、末尾の命令呼出しの結果も届く。
    /// モジュールエントリは呼び出し側と同じスコープで動くため従来どおり
    /// `null`（=undefined）のまま。
    fn implicitResult(self: *FunctionBuilder) ?ir.ValueId {
        const instructions = self.currentBlock().instructions.items;
        if (instructions.len == 0) return null;
        const last = instructions[instructions.len - 1];
        if (last.opcode != .store_global or !std.mem.eql(u8, last.name, "それ") or last.operands.len != 1) return null;
        return last.operands[0];
    }

    fn terminate(self: *FunctionBuilder, terminator: ir.Terminator) void {
        self.currentBlock().terminator = terminator;
    }
};

fn toType(value: hir.TypeHint) ir.Type {
    return switch (value) {
        .dynamic => .dynamic,
        .number => .number,
        .bigint => .bigint,
        .boolean => .boolean,
        .null_value => .null_value,
        .string => .string,
        .array => .array,
        .object => .object,
        .function => .function,
        .void => .void,
    };
}

fn toLoopDirection(value: @import("../frontend/ast.zig").LoopDirection) ir.LoopDirection {
    return switch (value) {
        .automatic => .automatic,
        .up => .up,
        .down => .down,
    };
}

fn isLogicalOperator(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and") or
        std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "or");
}

fn dupeStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, strings.len);
    for (strings, 0..) |value, index| result[index] = try allocator.dupe(u8, value);
    return result;
}

pub const tests = @import("lower_ssa_test.zig");
