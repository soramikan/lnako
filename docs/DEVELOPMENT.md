# 開発・検証手順

この文書は、lnakoを変更するときの固定条件と検証順序を定義します。実装状況の数値は [`compat/v3.7.24/summary.json`](../compat/v3.7.24/summary.json)、証拠の状態は [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md) を参照してください。

## 固定条件

| 対象 | 固定値 |
| --- | --- |
| Zig | 0.16.0 |
| LLVM / LLD | 22.1.8（ベースライン; 21.x–23.x 実行時対応） |
| なでしこ3 | v3.7.24 / `aa18c7e640523938c680958fe731418cc6f7a58f` |
| Node.js | 24.15.0（oracle専用） |
| QuickJS | 2026-06-04（`--compat-js`専用） |

公式TypeScriptはoracleにだけ使います。通常モードへJavaScript runtimeを混入させず、JS実行は明示的な `--compat-js` に限定します。

## セットアップ

```sh
node tools/setup_llvm.mjs
node tools/setup_quickjs.mjs
node tools/setup_oracle.mjs
```

toolchainは `toolchain.lock.json` のarchiveとSHA-256を検証します。手動配置したLLVMを使う場合は `LNAKO_LLVM_DIR` または `LNAKO_LLVM_LIBRARY` を指定します。

## 基本の検証順序

変更した機能に対応する差分テストを追加したうえで、次の順に実行します。

```sh
zig build fmt-check
zig build test --summary all
node tools/check_ci_workflow.mjs
node tools/check_docs_current.mjs
node tools/sync_compat.mjs --check
node tools/sync_compat_evidence.mjs --check
node tools/check_compat_report.mjs
```

互換台帳を変更した場合は、catalog ID、分類、fixture、evidenceの整合をすべて確認します。CIではこれに加えて3 OSのAOT、QuickJS、fuzz、artifact集約、attestationを実行します。CIのjob構成は [`CI.md`](CI.md) にあります。

## 差分fixture

fixtureは「どの経路を比較したか」と「どの証拠状態へ接続できるか」を分けて記録します。

| 経路 | 代表的な検証 |
| --- | --- |
| lexer / syntax / parser / semantic | 公式oracleとのtoken、AST、診断、意味結果比較 |
| Interpreter | Nako SSA IRの制御構文、値、plugin、Promise、timer |
| LLVM AOT | O0〜O3のcompile、実行結果、manifest、runtime trace |
| QuickJS | `--compat-js` の4命令と期待失敗 |
| host | filesystem、process、encoding、HTTP、crypto、ZIPのOS境界 |
| fuzz | 生成文法、タイムアウト、縮小case、回帰fixture |

fixtureの存在や実行成功だけで、catalog entryを `verified` にしません。成功経路から除外する終了・例外・外部hostは、除外理由と専用fixtureまたは別namespaceを記録します。同名命令は表示名ではなく `catalogIds` を明示します。

## AOT・QuickJSの確認

```sh
zig build run -- build tests/fixtures/run-control.nako3 -o /tmp/lnako-aot -O0
node tools/compare_native_oracle.mjs
node tools/check_dispatch_trace.mjs --no-build
node tools/check_dispatch_coverage.mjs --no-build
node tools/check_compat_js_evidence.mjs --no-build
```

OS依存値や外部通信を扱うfixtureは、固定入力、loopback、synthetic adapterなどの境界を明記します。任意の実OS状態や外部サービスへの接続を、決定的な互換証拠とみなしません。

## 文書化の規則

公式ドキュメントの説明不足、公式実装のバグ候補、lnakoの意図的制限、未実装境界は [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md) の領域別文書へ記録します。各項目には公式実測、lnakoの現在動作、意図的制限か未実装か、対象経路、差分テストID、TODO識別子を含めます。

文書には現行仕様・検証条件・残る制約を記載し、完了した実装日誌や一時的な計画は残しません。過去の経緯はGit履歴から参照します。性能結果はCIの測定commitと生データを明示します。日本語の「」や（）を含む文にはMarkdownの二重アスタリスクによる強調を使いません。

## コミットとpush

機能とテストが完結した単位で、日本語の署名付きコミットを作成します。force push、rebaseによる履歴改変、未検証状態のコミットは行いません。push前に直前のmain CI runを確認し、push後は次の作業区切りで新runの失敗jobを確認します。CI完了待ちが次の作業の前提でない場合、無期限に待機しません。

## 証拠更新とpush前検査

pre-pushフックは整形・単体テスト・ソース構造・互換性証拠・interpreter-only分類の検査を行い、ファイルやコミットを自動生成しません。製品変更で証拠の再生成が必要な場合は、実装を検証し、対象のコード変更をstageしてから `node tools/update_current_evidence.mjs` を実行します。manifest対象にunstaged/untrackedの変更を残さず、生成中はHEADと対象ソースを変更しません。通常経路と明示的なcompat-js経路をそれぞれビルドし、全証拠が揃うまで追跡済みファイルを保持します。生成後の差分を確認・検証し、コード変更と証拠更新を同じ日本語署名付きコミットにまとめてください。証拠のsource manifest SHA-256とbinary hashで検証対象を識別するため、生成前のコード専用コミットは不要です。

`tools/fast_forward_evidence.mjs`による、再実行を伴わないprovenanceの書き換えは廃止しました。既存の証拠は測定したcommitとbinary hashを保持し、検証ツール・文書だけの変更は明示的なfollow-up対象として扱います。

## ソース構造の保守

モジュールは行数ではなく、変更理由・状態所有権・依存方向・互換性保証の単位で分けます。公開import/C ABIの入口を薄いファサードとして保ち、状態定義から処理実装への逆向き依存を避けます。分割のためだけの動的dispatchやheap allocationは追加しません。

サイズ閾値・import層・例外台帳は`tools/source_structure.json`を正本とし、`node tools/check_source_structure.mjs`で検査します。frontend/semantic/IRからInterpreterやLLVM実装への依存、LLVM backendからInterpreterへの依存、AOT runtimeからCLIへの依存を追加しません。parserやruntimeの密結合部分は例外台帳の理由を確認し、公開ABI・GC root・非同期の所有権を維持して変更します。
