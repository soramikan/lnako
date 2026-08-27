# 開発手順

GitHub Actionsのスイート分割、同一refの旧run取消、変更前後の所要時間は[`CI.md`](CI.md)に記録します。
CI定義を変更した場合は `node tools/check_ci_workflow.mjs` で3環境×5スイートの15テストジョブ、attestation job、全検証ステップの所属も確認します。

## 検証順序

1. `zig build fmt-check`
2. `zig build test --summary all`
3. 変更した機能の差分互換テスト
4. マイルストーンでは全互換テストとベンチマーク

公式なでしこ3 v3.7.24との字句解析差分テストは次で実行します。初回だけ固定アーカイブを
SHA-256検証して `.cache/oracle/` に展開し、公式TypeScriptをNode 24でビルドします。
`compat/upstream.lock.json`にはoracle build 4のCLI／marker SHA-256と、markerを除く実行ツリー全体の
決定的tree hashも固定され、cache hitと各差分テストで実体を照合します。tree対象はproduction prune後の
`node_modules`を含み、production prune後にnpmが生成する全階層の`.bin`と`.package-lock.json`を明示削除します。残存metadataは
tree hash側で拒否します。tscの改行をLFへ固定し、
package-lockからproduction optional dependencyがないことを構築時に確認することで、正式3環境へ同一値を登録しています。
各OSでの初回再計算一致が必要で、未登録環境を推測で通しません。tree hashのmacOS実測は現行cacheで約0.6秒
（13 MiBのproduction tree）でした。markerだけを差し替えた改変CLIや、他ファイルを改変した公式oracleは受理しません。

```sh
node tools/setup_oracle.mjs
node tools/setup_llvm.mjs
node tools/setup_quickjs.mjs
node tools/compare_lexer_oracle.mjs
node tools/compare_syntax_oracle.mjs
node tools/compare_parser_oracle.mjs
node tools/compare_parser_diagnostics_oracle.mjs
node tools/compare_semantic_oracle.mjs
node tools/compare_value_oracle.mjs
node tools/compare_interpreter_oracle.mjs
node tools/generate_unicode_case.mjs --check
node tools/update_plugin_system_implemented.mjs --check
node tools/check_plugin_system_coverage.mjs
node tools/check_system_runtime_coverage.mjs
node tools/compare_plugin_system_oracle.mjs
node tools/check_standard_plugin_coverage.mjs
node tools/compare_standard_plugin_oracle.mjs
node tools/compare_supplemental_plugin_oracle.mjs
node tools/check_compat_js_coverage.mjs
node tools/compare_compat_js_oracle.mjs
node tools/check_native_plugin_abi.mjs
node tools/generate_legacy_encoding.mjs --check
node tools/update_node_implemented.mjs --check
node tools/check_node_plugin_coverage.mjs
node tools/compare_node_file_oracle.mjs
node tools/check_encoding_compat.mjs
node tools/compare_node_exit_oracle.mjs
node tools/compare_node_interrupt_oracle.mjs
node tools/check_node_archive_smoke.mjs
node tools/compare_native_oracle.mjs
node tools/check_dispatch_trace.mjs
node tools/check_builtin_catalog.mjs
node tools/sync_compat.mjs --check
node tools/sync_compat_evidence.mjs --check
node tools/check_compat_report.mjs
```

CIのmain実行で生成したdispatch evidenceを昇格する場合は、GitHub CLIの署名検証を省略せず、3正式OS artifactをまとめて次で検証します。
`--catalog-evidence`の出力はCI一時artifactであり、追跡中の`compat/v3.7.24/evidence.json`は変更しません。fork PRやattest権限のない実行は昇格対象外です。

```sh
node tools/verify_dispatch_attestation.mjs --directory /absolute/path/dispatch-evidence --bundle /absolute/path/attestation-bundle.json --output /absolute/path/dispatch-attestation.json --catalog-evidence /absolute/path/evidence-verified.json --repository soramikan/lnako --commit <40-hex-commit> --source-ref refs/heads/main --workflow soramikan/lnako/.github/workflows/ci.yml
```

Actions artifactの期限に依存しない履歴成果物は`compat/v3.7.24/attestations/32983175945/`に置く。対象commit、3 OS、digest、bundleのSLSA identity、
禁止field、historical catalogと現在台帳の分離を確認するには次を実行する。署名の再検証は保存bundleを公式`gh attestation verify`へ渡す。
通常syncで過去証拠を明示検査する場合だけ`--historical-commit`と非canonical outputを使い、現行HEAD一致やcanonical output上書きを許可することはない。

```sh
node tools/check_tracked_dispatch_attestation.mjs
node tools/check_tracked_dispatch_attestation_security.mjs
```

AST差分テストは公式の `core/test/fixtures/parser_corpus.mjs` を直接読み、コメント・空行の保持方式に
左右されない構文フィンガープリントを比較します。ローカル追加ケースは
`tests/oracle/parser-cases.json`、拒否ケースは `tests/oracle/parser-diagnostic-cases.json` に置きます。
実行差分ケースは `tests/oracle/interpreter-cases.json` に置き、公式CLIと `lnako run` の双方で成功することを
必須にします。

AOT差分ケースは `tests/oracle/native-cases.json` に置きます。公式CLIの直接実行と `--compile` 生成物、
`lnako run`、LLVM AOT `-O0` / `-O1` / `-O2` / `-O3`生成物の7経路を比較します。固定LLVM配布物は `tools/setup_llvm.mjs` が
`toolchain.lock.json` のURLとSHA-256から構築し、CIでは `LNAKO_LLVM_DIR` とアーカイブ内で検出した
`LNAKO_LLVM_LIBRARY` を自動設定します。

原則は公式CLI直接実行と公式生成JavaScriptの両方が一致することを必須にします。公式2経路の挙動が既知の理由で
異なるケースだけ、採用する側を `"oracle": "official-source"` または `"oracle": "official-generated"` で指定します。
この指定を使った差異は `docs/COMPATIBILITY_QUIRKS.md` に両経路の実測結果と採用理由を記録し、ハーネスの
成功表示にも基準別の件数を出します。

全115件の実行結果を保存する必要がある検証では、任意の絶対パスを明示してJSON artifactを生成できます。
通常実行のstdout、所要時間、比較処理は変わりません。

```sh
node tools/compare_native_oracle.mjs --artifact /absolute/path/native-oracle.json
# または
LNAKO_NATIVE_ORACLE_ARTIFACT=/absolute/path/native-oracle.json node tools/compare_native_oracle.mjs
```

artifactは公式baselineのタグ・commit、lnakoのcommit、OS/CPUアーキテクチャ、7経路名、fixture ID、
採用した既知oracle、各経路の終了状態、fixture単位の等価性判定を含みます。各fixtureのソース、生成JS、
各経路の正規化stdout/stderr、比較スクリプト、lnako本体はSHA-256だけを記録します。プログラムの
stdout/stderr、引数、ソース本文は保存しません。出力先は絶対パスの新規ファイルに限り、同一ディレクトリ内の一時ファイルから
原子的に作成します。AOT `-O0`生成時に得たcompile manifestは完了レコードを検証した上で、命令名・numeric opcode・
canonical opcode・route・固定site IDをfixtureの`compileManifest`へ要約します。manifestのsourcePath、関数名、
位置情報はartifactへ持ち込みません。artifactの`comparisonSucceeded`と各fixtureの`equivalent`は、全経路の終了コードが0という意味ではなく、
採用した公式経路と終了状態を含む結果が等価だったことを表します。両方がtrueであることを確認してから比較証拠として扱ってください。
トップレベルの`status`は比較失敗とインフラ失敗を区別し、インフラ失敗ではfixture結果を空にして成功扱いにしません。
実際に実行した公式CLIと固定情報markerのSHA-256も保存し、markerがbaselineのタグ・commit・archive hashと一致しない場合や、
CLI／markerの実体hashが`upstream.lock.json`のoracle identityと一致しない場合は実行前に拒否します。

標準命令を実装して個別の公式差分テストを追加したら `compat/v3.7.24/implemented.json` にテストIDと理由を記録し、
`node tools/sync_compat.mjs --generate` で分類表と集計を再生成します。固定した公式スナップショット自体を再取得する
`--refresh` とは分離されているため、通常の進捗更新ではネットワークを使用しません。

`src/root.zig` のテストルートは各サブモジュールを明示的に参照します。Zigの遅延解析によりテストが未収集に
ならないよう、`zig build test --summary all` の実行件数も確認してください。

HIRから生成したNako SSA IRは、次の開発用プローブで確認できます。出力前にIR検証も実行されます。

```sh
zig build ir-probe -- $'A=1\nAを表示\n'
```

## ベンチマーク

`benchmarks/suite.json`を正本とし、各fixtureの`expected_stdout`を全sampleで照合します。
`lnako benchmark`は同じsuiteを`interpreter`、`aot_compile`（LLVM O2での生成）、`aot_run`（生成実行ファイル）で計測し、
`benchmarks/results/latest.json`と`benchmarks/results/latest.md`へ保存します。JSONにはsuite、対象OS/CPU、固定toolchain、
commit（`LNAKO_BENCHMARK_COMMIT`指定時）、iteration/warmup、個別sampleとmin/median/maxを含めます。
値は子プロセス完了までのwall-clock値であり、CIの壁時計やrunner合計時間とは別の指標です。

```sh
LNAKO_BENCHMARK_COMMIT="$(git rev-parse HEAD)" zig build run -- benchmark
zig build run -- benchmark --iterations 10 --warmup 2 \
  --output /tmp/lnako-benchmark.json --markdown /tmp/lnako-benchmark.md
```

ベンチマーク結果は対象OS・CPUごとに分けて比較し、異なるOSの値を単純に横並びで性能回帰と解釈しません。

## コミット

- 機能と対応テストを同じコミットに含める。
- テスト成功後に日本語の署名付きコミットを作る。
- 壊れた中間状態はコミットしない。
- force pushや履歴改変を行わない。

## LLVM探索

ローカルでは `LNAKO_LLVM_LIBRARY`、`LNAKO_LLVM_DIR` を優先し、未指定時はPATH、Homebrew、一般的なLinuxパスの順でLLVM 22.1.8を
探します。見つかった共有ライブラリは `LLVMGetVersion`、Clang/LLDは `--version` で完全な版を検証します。
SDK配布物は対応するLLVM/LLDを同梱し、生成プログラム自体はLLVMやZigに依存しません。

## QuickJS互換モード

`zig build -Dcompat-js=true`だけがQuickJSを静的リンクします。通常の`zig build`は同じZig APIをC stubへ
接続するため、JSエンジンを含みません。固定ソースは`tools/setup_quickjs.mjs`がURL、SHA-256、`VERSION`、
必須ソース一式を検証します。

QuickJSは`js_realloc_rt(JSRuntime *, ...)`を汎用`DynBuf` callbackへ意図的に型変換します。Zigの
ReleaseSafeが有効にするC関数型sanitizerは、このABI互換呼び出しをmacOS arm64で`SIGTRAP`にします。
また、tagged pointer、flexible array上の`container_of`、符号付きshift等もWindows ReleaseSafeのUBSanに
捕捉されます。このため固定・ハッシュ検証済みのQuickJS本体Cソースに限り`undefined`群と`function`検査を
無効化します。ローカルbridgeを含む他のZig/Cコードの安全検査は維持し、CIでDebugとReleaseSafeの両方を
実行します。

```sh
node tools/setup_quickjs.mjs
zig build -Dcompat-js=true test
node tools/check_compat_js_coverage.mjs
node tools/compare_compat_js_oracle.mjs
```

差分テストは4命令、なでしこ変数・関数との双方向呼び出し、配列・辞書の変更同期、ES moduleの相対依存、
Promise、失敗境界、`build --compat-js`生成物を検証します。通常ビルドと互換ビルドを別々にテストし、
リンク境界の混入も検出します。

## ネイティブプラグインABI

公開Cヘッダとfixtureを使う実ロードテストを、macOS・Linux・Windowsの各CIランナーで実行します。

```sh
zig build native-plugin-fixture
node tools/check_native_plugin_abi.mjs
node tools/check_native_plugin_abi.mjs --release-safe
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe native-plugin-fixture
```

非WindowsホストのZig 0.16.0はMSVC libcを提供しないため、ローカルのWindowsクロス検査にはGNU ABIを
使います。正式対象のMSVC ABIはWindows CIランナー上でビルドと実ロードの両方を検証します。

所有権、スレッド制約、非同期完了、セキュリティ境界は
[`docs/NATIVE_PLUGIN_ABI.md`](NATIVE_PLUGIN_ABI.md)を参照してください。
