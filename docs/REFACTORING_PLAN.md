# 巨大ファイル分割 実装指針

この文書は、大規模ソースファイルを機能単位へ分割するための実装指針を記録したものです。
レビュー開始時にコード構造を固定したSHAは `7ce7acf5`、指針作成時の `main` はその直後の `b5e4c4ac` です。

> **現状**: この計画の大部分は既に実施済みです。`main.zig` → `src/cli/`・`src/compiler_pipeline/`・`src/benchmark/`・`src/host/`、正規表現 → `src/regexp/`、`node.zig` → `src/plugins/node/`、`arrays.zig` → `src/plugins/system/arrays/`、`interpreter.zig` → `src/runtime/interpreter/`、`aot` → `src/runtime/aot/` への分割が完了しています。残タスクは末尾の「進捗状況」を参照してください。

## 結論

巨大ファイルは、**行数やバイト数を均等に割るのではなく、変更理由・状態所有権・依存方向・互換性保証の単位で分割**するべきです。

推奨順序は次です。

1. 分割前の同値性検査と依存ルールを追加
2. `main.zig` とCLIホストを分割
3. `regexp.zig` を共有エンジン化
4. `arrays.zig` と `node.zig` を機能群ごとに分割
5. `backend/llvm/module.zig` をEmitter中心に分割
6. `interpreter.zig` を状態・実行・イベント・プラグイン境界へ分割
7. 最後に `runtime/aot` を段階的に分割
8. 二次対象と検証ツールを整理

**最初から `runtime/aot` に着手するべきではありません。** 最大サイズですが、公開C ABI、GC、非同期処理、OS依存処理、トレース、動的実行が密結合しており、分割事故の影響範囲が最も大きいためです。

## 1. 分割の基本原則

### 元のパスを薄いファサードとして残す

外部から見えるimportパスは原則として変えません。元ファイルは次の役割だけを残します。

- 公開型・公開関数の再公開
- 公開ディスパッチ
- ライフサイクルの入口
- ABIの入口
- 内部モジュールへの委譲

### 分割PRでは挙動を変更しない

分割と次の変更を同じPRに混ぜてはいけません: バグ修正、エラー文言変更、新機能、命令の再分類、event loop順序変更、allocator変更、キャッシュ追加、アルゴリズム最適化、重複実装の統合。

### 1命令1ファイルにはしない

適切な粒度は、同じデータ構造を操作する・同じ例外規則を使う・同じ状態を所有する・同じhost APIを使う・一緒に変更される・一緒にテストすべき不変条件を持つまとまりです。

### 状態と処理を分離する

```text
types / state / contracts
          ↓
      implementations
          ↓
   public façade / router
```

`state.zig` や `types.zig` は処理モジュールをimportしません。処理側がstateをimportし、`*State` や限定されたContextを受け取ります。

### 分割のために動的ディスパッチを増やさない

ファイルを分けるためだけに、function pointer table、runtime hash lookup、interface object、heap allocation、virtual dispatch を導入してはいけません。既存の静的な `switch` や直接関数呼び出しを維持します。

## 2. 目標となる依存方向

```text
main
  └─ cli
      ├─ compiler_pipeline
      ├─ benchmark
      └─ cli_host

interpreter
  ├─ SSA IR
  ├─ runtime values
  ├─ plugins
  ├─ host contracts
  └─ shared algorithms

plugins
  ├─ runtime values
  ├─ host contracts
  └─ shared algorithms

LLVM backend
  ├─ SSA IR
  ├─ AOT ABI definitions
  └─ shared algorithms

AOT runtime
  ├─ AOT ABI definitions
  ├─ shared algorithms
  └─ AOT専用host実装
```

禁止する依存:

- frontend → interpreter / LLVM / host
- semantic → interpreter / LLVM / host
- IR → interpreter / LLVM実装
- LLVM backend → interpreter
- shared engine → plugin adapter
- host leaf → なでしこ命令名やRuntime.Value
- AOT runtime → CLI main

## 3. ガードレール

### ファイルサイズ検査

| 種別 | 目安 | CI警告 | 原則上限 |
|---|---:|---:|---:|
| ファサード | 5～20 KB | 30 KB | 50 KB |
| 通常モジュール | 10～45 KB | 60 KB | 80 KB |
| 独立アルゴリズム | 20～60 KB | 80 KB | 要理由 |
| ABI wrapper一覧 | 20～80 KB | 100 KB | 要理由 |
| 生成物・生成表 | 対象外 | — | — |

上限超過を機械的に禁止するだけでなく、例外ファイルには理由を記録します。

### import層検査

`tools/check_source_structure.mjs` が相対 `@import` を解析し、禁止依存が増えた場合はCIを失敗させます。

### 公開API一覧・ABI symbol inventory

分割前後で `src/root.zig` の公開宣言、plugin公開型、Interpreter公開メソッド、LLVM module公開関数、native plugin C header、AOT C ABI symbol を比較します。

### テストimport漏れ検査

`src/all_tests.zig` で新規ファイルを明示的にimportします。

## 4. 各対象の目標構成

### `main.zig` / CLI / host（完了）

```text
src/
├─ main.zig            # プロセスbootstrapのみ
├─ cli/app.zig, arguments.zig, commands/*
├─ compiler_pipeline/compile.zig, diagnostics.zig, embedded.zig
├─ benchmark/model.zig, runner.zig, statistics.zig, report.zig
└─ host/state.zig, adapters.zig, lifecycle.zig, environment.zig, tracing.zig,
   random.zig, filesystem.zig, process.zig, async_operations.zig,
   http_client.zig, http_server.zig, archive.zig, network.zig, open_external.zig
```

### `regexp`（完了）

```text
src/regexp/   # runtime Value を知らない中立エンジン
  api.zig, types.zig, syntax.zig, parser.zig, character_class.zig,
  unicode.zig, matcher.zig, captures.zig, replacement.zig, error_message.zig
src/plugins/system/regexp.zig  # なでしこ命令adapterのみ
```

### `arrays`（基本分割完了・表/sort細分化は残課題）

```text
src/plugins/system/arrays/
  context.zig, common.zig, sparse.zig, properties.zig, mutation.zig,
  slicing.zig, search.zig, higher_order.zig, set_operations.zig,
  sort_adapter.zig, sort_v8.zig,
  table_common.zig, table_projection.zig, table_filtering.zig,
  table_structure.zig, table_sort.zig
```

中核ルール:

- `sparse.zig` がholeの扱いを一元化（`isPresent`/`copySlot`/`appendHole`/`materializeUndefined`）
- `sort_v8.zig` はTimSort純粋アルゴリズムのみ。なでしこcallback・runtime errorは `sort_adapter.zig`
- 表命令は `table_projection`（列取得/挿入/削除/合計）・`table_filtering`（検索/ピックアップ/曖昧/正規表現/重複削除）・`table_structure`（行数/列数/転置/回転）に分類
- `arrays.zig` は命令ディスパッチのみ。命令所有権検査（全登録命令→所有モジュール必ず1つ）を追加

### `node`（基本分割完了）

```text
src/plugins/node/
  types.zig, context.zig, state.zig, dispatch.zig,
  path_commands.zig, file_commands.zig, process_commands.zig,
  archive_commands.zig, http_commands.zig, os_environment.zig,
  stdin_console.zig, crypto_commands.zig, pending_operations.zig,
  error_message.zig
```

`pending_operations` にoperation token・callback・Promise・completion mode・完了順を集約し、非同期完了順を複数ファイルへ分散させません。

### `backend/llvm`（残課題）

```text
src/backend/llvm/
├─ module.zig      # 公開生成・manifest APIのみ
├─ manifest.zig
├─ sites.zig
├─ unsupported.zig
├─ routes.zig
└─ emitter/
   ├─ context.zig
   ├─ preamble.zig
   ├─ declarations.zig
   ├─ functions.zig
   ├─ blocks.zig
   ├─ terminators.zig
   ├─ instruction_router.zig
   └─ operations/
      constants.zig, values.zig, variables.zig, arithmetic.zig,
      control.zig, calls.zig, collections.zig, properties.zig,
      exceptions.zig, promises.zig, plugins.zig
```

Zigの循環importを避けるため `Emitter` は `emitter/context.zig` に置き、各operation moduleは `pub fn emit(emitter: *context.Emitter, instruction) !void` というfree functionにします。依存方向は `context ← operations/* ← instruction_router ← module.zig` で、`context.zig` がoperation moduleをimportすることは禁止です。

### `interpreter`（基本分割完了・operations整理は残課題）

```text
src/runtime/interpreter/
  state.zig, host.zig, lifecycle.zig, trace.zig, engine.zig,
  instruction_router.zig, frames.zig, calls.zig, variables.zig,
  properties.zig, exceptions.zig, plugins.zig, event_loop.zig,
  promises.zig, timers.zig, dynamic_execution.zig,
  operations/{constants,arithmetic,control,functions,collections,plugin_calls}.zig
```

event loop順序は `drain` 一か所に固定し、専用テストで守ります。opcode switchを先に細分化せず、Stateとevent/plugin境界を先に整えます。

### `runtime/aot`（完了）

```text
src/runtime/aot/
  state.zig  # 互換ファサード（再エクスポート＋pub var＋最小helperのみ）
  runtime_core.zig, host.zig, tests.zig, json.zig, datetime.zig, text.zig,
  node_file.zig, math.zig, node_path.zig, http_server.zig, async.zig,
  caniuse.zig, node_http.zig, string.zig, node.zig, kansuji.zig,
  url_path.zig, regexp.zig, table.zig, sort.zig, collection.zig,
  search.zig, primitive.zig, dynamic.zig, conversion.zig, display.zig,
  trace.zig, builtins.zig, instructions.zig, functions.zig, values.zig,
  shared.zig
```

### 二次対象

- `strings.zig` → `strings/{search,slicing,normalization,comparison,formatting,conversion}.zig`
- `text_convert` → `{kana,width,numeral,escape,classification}.zig`
- `parser.zig` は相互依存が強いため早期分割しない（分割する場合も演算子優先順位とtoken cursorは中央に残す）
- `value.zig` はGC tracingが型を直接知る現状では分割しない。`traceChildren` 契約が整ってから実施

### 検証ツール

```text
tools/lib/
  process.mjs, filesystem.mjs, json.mjs, git.mjs, hashing.mjs, schema.mjs,
  evidence/{identity,provenance,dispatch,globals,literals,attestation,comparison}.mjs
```

CLIファイルは引数解析と終了コードだけにし、検証関数を純粋関数化してfixtureで自己テストできるようにします。

## 5. 実行規則

### コミット順序

1. コード移動（新ファイル作成・関数本体無変更・名前変更なし）
2. importと委譲（元ファイルから接続・公開API維持・未使用削除）
3. テスト・文書（test aggregation・dependency map・証拠更新）

互換性証拠がsource SHAへ結び付くため、製品コード変更を完了した後、最終コミットを証拠更新専用にします。

### 同じPRで行わない組み合わせ

- LLVM emitter分割とAOT runtime分割
- GC分割と値レイアウト変更
- ABI wrapper移動とABI署名変更
- Promise分割とevent ordering変更
- host分割とOS固有バグ修正
- trace分割とschema変更

### 失敗しやすい点

| リスク | 対策 |
|---|---|
| Zigの循環import | `state/types → implementation → façade` を固定 |
| testのimport漏れ | `all_tests.zig` で明示import |
| GC root順序変更 | 文の順序を変えず、GC stressを実行 |
| event順変更 | event loopを一か所に置き、同時完了fixture |
| ABI symbol脱落 | 3 OS symbol inventory |
| manifest順変更 | byte-level manifest比較 |
| site ID変更 | site生成を別モジュールへ集約しgolden化 |
| OS分岐の未解析 | Linux/macOS/Windows実ジョブ |
| helperの過剰共通化 | 機械的移動後の別PRでのみ共通化 |
| 巨大Stateの横移動 | subsystemごとにStateを分ける |
| 抽象化による性能低下 | free functionと静的callを維持 |
| 大規模rename | 元名称とファサードを維持 |

## 6. 完了条件

### 構造

- `main.zig` はプロセスbootstrapとCLI入口だけ
- `arrays.zig`、`regexp.zig`、`node.zig` は公開ファサードだけ
- `backend/llvm/module.zig` は公開生成・manifest APIだけ
- `interpreter.zig` は公開Interpreter APIだけ
- `aot` の `state.zig` はABI wrapperと最小限の初期化だけ
- 通常モジュールは原則80 KB以下
- 新規の逆方向依存がない、循環importがない

### 互換性

- 標準命令差分テスト成功、parser fuzz成功、Interpreter差分成功
- AOT O0～O3成功、Linux/macOS/Windows成功
- QuickJS互換経路成功、native plugin ABI成功
- manifest・trace・site IDが意図せず変わっていない、公開ABI symbolが維持されている

### メモリ・非同期

- GC stress成功、allocator失敗注入成功
- Promise/timer/process/HTTP完了順が不変
- deinit後にworkerやsocketが残らない、callback中のGC allocationが安全

### 性能

- startup、Interpreter、AOT compile、AOT runを分割前と比較
- 安定したケースで中央値5%以上の悪化は要調査
- 実行ファイル・runtime libraryサイズの増加を確認
- 分割のためだけのheap allocationやruntime lookupがない

## 進捗状況

| 領域 | 状態 |
|---|---|
| Wave 0 ガードレール | 完了（`src/all_tests.zig` ＋ `tools/check_source_structure.mjs`／`tools/source_structure.json`：サイズ閾値・import層許可リスト・例外台帳をCI検査） |
| `main.zig` / CLI / host / benchmark / compile pipeline | 完了（`main.zig` 20行、`src/cli/`・`src/compiler_pipeline/`・`src/benchmark/`・`src/host/` 稼働中） |
| `regexp` 中立エンジン化 | 完了（`src/regexp/` + `plugins/system/regexp.zig` adapter） |
| `arrays` | 完了（`arrays/` core/map/prototype/shared ＋ `sort.zig`→`sort_adapter`/`sort_v8`、`table.zig`→`table_projection`/`table_filtering`/`table_sort`/`table_structure`） |
| `node` 分割 | 完了（`plugins/node/` call/filesystem/http/network/platform/process/shared） |
| `backend/llvm` | 完了（`module.zig`→`module/manifest.zig`＋`module/unsupported.zig`、`emitter.zig`→`emitter/{context,preamble,declarations,functions,terminators,instruction_router}.zig`＋`emitter/operations/*`。`Emitter`公開API維持） |
| `interpreter` | 完了相当（`interpreter/` events/execute/plugins/shared/state/tests に責務分離済み。`execute.zig` 45KBで閾値内のため追加分割は保留） |
| `runtime/aot` | 完了（`state.zig` は互換ファサード。`collection`/`runtime_core`/`table`/`aot_builtin`/`value` は例外台帳で監視中） |
| `strings.zig` | 完了（`strings/{cutting,core,search_replace,trim_case,kana,format,units}.zig`へ分離。ファサード34.5KB） |
| `parser.zig`（82KB） | 保留（指針上は早期分割しない・例外台帳登録済み） |
| `value.zig`（75KB） | 保留（`traceChildren` 契約整備後・例外台帳登録済み） |
| 検証ツール分割 | 完了（`check_dispatch_coverage.mjs`→`tools/lib/coverage_{process,http,fixtures,sites}.mjs`＋`evidence_common.mjs`、`sync_compat_evidence.mjs`→`tools/lib/evidence/{constants,records,validators,env}.mjs`。証拠フォーマット不変） |
