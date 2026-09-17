# 開発・検証手順

この文書は、`lnako` の開発・検証における固定条件、推奨セットアップ手順、および品質検証フローを定義する開発ガイドです。
実装状況の数値は [`compat/v3.7.24/summary.json`](../compat/v3.7.24/summary.json)、互換証拠の状態は [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md) を参照してください。

## 固定条件（環境基準）

| 対象 | 固定値 | 備考 |
| --- | --- | --- |
| Zig | 0.16.0 | 言語およびビルドシステム |
| LLVM / LLD | 22.1.8 | ベースライン（21.x–23.x 実行時対応） |
| なでしこ3 | v3.7.24 | commit `aa18c7e640523938c680958fe731418cc6f7a58f` |
| Node.js | 24.15.0 | 公式oracle差分テスト専用 |
| QuickJS | 2026-06-04 | `--compat-js` モード専用 |

公式TypeScriptコードはoracle差分比較にのみ使用します。製品ランタイムへは含めず、JS実行は明示的な `--compat-js` に限定します。

## 開発環境のセットアップ

リポジトリをクローンした後、必要なツールチェーンとテスト資産をセットアップします。

```sh
node tools/setup_llvm.mjs      # LLVM/LLDツールチェーンの配置
node tools/setup_quickjs.mjs   # QuickJSの配置
node tools/setup_oracle.mjs    # 公式なでしこ3 oracleの準備
```

toolchainは `toolchain.lock.json` に記載されたアーカイブURLとSHA-256で検証されます。
ローカルに既存のLLVMがある場合は `lnako build --llvm-dir <path>` または環境変数 `LNAKO_LLVM_DIR`、`LNAKO_LLVM_LIBRARY` で指定可能です。

## コンパイラのビルドと実行

### 通常ビルド（開発用）

```sh
zig build
zig build run -- --help
zig build run -- run program.nako3
zig build run -- build program.nako3 -o program -O2
```

### QuickJS互換モードを有効にした配布相当ビルド

```sh
zig build -Doptimize=ReleaseSafe -Dcompat-js=true
zig build -Dcompat-js=true test
zig build -Dcompat-js=true run -- run program.nako3 --compat-js
```

利用者のインストール手順は[使い始める](GETTING_STARTED.md)、配布アーカイブの生成仕様は[リリース手順](RELEASE.md)を参照してください。

## 基本の検証順序

機能を変更した際は、対応する単体テストや差分テストを追加したうえで、以下の順序でローカル検証を実行します。

```sh
zig build fmt-check                      # コードフォーマット検証
zig build test --summary all             # 単体テスト全実行
zig build package-schema-check           # パッケージスキーマ検証
node tools/check_ci_workflow.mjs         # CIワークフロー検証
node tools/check_docs_current.mjs        # ドキュメント整合性検査
node tools/sync_compat.mjs --check       # 互換カタログ整合性検査
node tools/sync_compat_evidence.mjs --check # 互換証拠整合性検査
node tools/check_compat_report.mjs       # レポート検査
```

互換台帳を変更した場合は、catalog ID、分類、fixture、evidenceの整合をすべて確認します。CIではこれらに加え、3 OSでのAOT実行、QuickJSテスト、fuzzテスト、attestation署名検証が自動実行されます（詳細は [`CI.md`](CI.md)）。

## 差分fixtureによる互換性検証

fixtureは「どの実行経路を比較したか」と「どの証拠状態へ接続できるか」を厳格に分けて記録します。

| 経路 | 検証内容 |
| --- | --- |
| lexer / syntax / parser / semantic | 公式oracleとのトークン、AST、診断メッセージ、意味解析の比較 |
| Interpreter | Nako SSA IRの制御構文、値、プラグイン、Promise、タイマー |
| LLVM AOT | 最適化レベル（O0〜O3）のコンパイル、実行結果、manifest、runtime trace |
| QuickJS | `--compat-js` の4命令と期待失敗挙動 |
| host | ファイルシステム、プロセス、文字コード、HTTP、暗号、ZIPのOS境界 |
| fuzz | 文法自動生成、タイムアウト検査、縮小ケース、回帰テスト |

fixtureの存在や実行成功だけで安易に `verified` とせず、成功経路から除外する終了・例外・外部ホストは理由と専用fixtureを明記します。

## AOTおよびQuickJSの個別検証

```sh
# AOTコンパイルの動作確認
zig build run -- build tests/fixtures/run-control.nako3 -o /tmp/lnako-aot -O0

# 公式oracleとの比較およびdispatchトレースの検証
node tools/compare_native_oracle.mjs
node tools/check_dispatch_trace.mjs --no-build
node tools/check_dispatch_coverage.mjs --no-build
node tools/check_compat_js_evidence.mjs --no-build
```

OS依存値や外部通信を扱うfixtureは、固定入力、loopback、synthetic adapterなどの境界を明記します。

## ドキュメント化の規則

- 公式ドキュメントの説明不足、公式実装のバグ候補、lnakoの意図的制限、未実装境界は [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md) の領域別文書へ記録します。
- 各項目には公式実測値、lnakoの現在動作、制限の理由、対象経路、差分テストID、TODO識別子を含めます。
- ドキュメントには現行仕様・検証条件・残る制約を記載し、完了した過去の実装日誌や一時的な計画は残しません。
- 日本語の「」や（）を含む文にはMarkdownの二重アスタリスクによる強調を使いません。

## コミットとプッシュの規律

- 機能とテストが完結した単位で、日本語の署名付きコミットを作成します。
- force push、rebaseによる履歴改変、未検証状態でのコミットは行いません。
- push前に直前のmainブランチのCI状況を確認し、push後は新runの状況を適宜確認します。

## 証拠更新とpush前検査

pre-pushフックは整形・単体テスト・ソース構造・互換性証拠・interpreter-only分類の検査を行い、ファイルやコミットを自動生成しません。
製品変更に伴い証拠の再生成が必要な場合の手順は以下のとおりです。

1. 実装の動作を十分に検証します。
2. 対象のコード変更をgit stageに追加します（unstagedやuntrackedの変更を残さない）。
3. `node tools/update_current_evidence.mjs` を実行します（生成中はHEADや対象ソースを変更しない）。
4. 通常経路と明示的なcompat-js経路をビルドし、証拠ファイルを生成・確認します。
5. 生成後の差分を確認し、コード変更と証拠更新を同一の日本語署名付きコミットにまとめます。

## ソースコード構造の保守

モジュールは行数の多寡ではなく、変更理由・状態の所有権・依存方向・互換性保証の単位で適切に分離します。

- 公開importやC ABIのエントリポイントは薄いファサードとして保ちます。
- 状態定義から処理実装への逆向き依存を避けます。
- サイズ閾値、import階層、例外台帳は `tools/source_structure.json` を正本とし、`node tools/check_source_structure.mjs` で検査します。
- `frontend`/`semantic`/`IR` から InterpreterやLLVM実装への依存、LLVMバックエンドから Interpreterへの依存、AOTランタイムからCLIへの依存は追加しません。
