# M8〜M15 性能改善実施計画

[提供レビュー全文](PERFORMANCE_REVIEW_2026-09-07.md)を要求の基準とする。開始HEADは `3c417fab192bbb8648a33525d02fbf9944ae8380`、作業ツリーはクリーン。レビュー内の性能値は開始時点の参考値であり、下記変更の成果ではない。

## 実装と受け入れ条件

| 単位 | 実装内容 | 受け入れ条件 | 状態 |
| --- | --- | --- | --- |
| M8 | Prepared Interpreter、名前・演算子・callee・value countの事前解決、サイズクラスpool | 動的実行・capture・例外の互換性、診断benchmark比較 | 実装中 |
| M9 | 共通capture/escape解析、Interpreter/AOTの直接local Value | 非capture関数cellゼロ、capture共有維持 | AOT側検証済み、Interpreter側実装中 |
| M10 | AOT safepoint、参照liveness、root coloring | GC強制時の分岐・phi・loop・callback安全性、root数減少 | 実装・検証中 |
| M11 | Number/Boolean typed internal ABIとgeneric wrapper | NaN/Infinity/-0維持、直接・動的呼出し同値 | 実装中 |
| M12 | exact-size文字列allocation、GC/concat統計 | immutable copy量維持、UTF-16境界・GC安全性、3 OS測定 | 実装中 |
| M13 | Windows nbody sampling・LLVM IR・assembly・imports診断 | Win64 ABI/stack/helperの実測比較と原因に基づく判断 | 取得tool/CI実装、Windows測定未完了 |
| M14 | Interpreter interrupt safepoint/budget、dispatch軽量化 | 割り込み応答上限、timer/callback/dynamic/global観測維持 | 未実装 |
| M15 | compiler stage timing/index/worklist、hot builtin専用ABI/dead strip | コンパイル同値、時間・symbol/size比較 | 実装・検証中 |
| 診断ケース | local/global/direct/captured/index/dict/string/GC/numeric 12ケース | 正解照合、build/read/write範囲を区別 | 12件追加、ローカル正解照合成功、3 OS CI追加 |

packed NumberArray、世代別GC、in-place文字列builderはレビューに従い先行解析・測定後に可否を判断する。安全性や測定で採用できない項目は理由と未達事項を明記し、実装済みとは扱わない。

## 検証と公開

実装単位ごとに `zig build fmt-check` → `zig build test` → 関連oracle/AOTテストを実施し、日本語署名付きコミットを作成してpushする。次回push前に前回CIを確認し、失敗を調査・修正する。未完了CIを成功とは記録しない。製品変更に必要な互換性証拠は開発手順に従い再測定する。

3 OS性能目標、compile-stress 30%短縮、小規模AOT 1 MiB未満は実測で判定する。ローカルmacOSの結果をLinux/Windowsの達成証拠にしない。

## 検証記録

- 開始時: Zig 0.16.0を確認。CI `34047279623`、比較benchmark `34058162808` は開始HEADで成功。
- 文書保存単位: fmt-check成功、単体906/906成功（loopback待受を許可して実行）、現行ドキュメント検査成功。

### M9a: 共通解析とAOT local Value（隔離検証）

- 通常localはroot登録済みValue slotを直接参照し、capture/dynamic/不明なclosureはBindingCellを維持する。
- 単体910/910成功。通常関数のcell生成ゼロとcapture維持の生成IRテストを追加。
- 既存公式差分9ケース（関数、戻り値、それ、引数不足、共有可変capture、捕捉引数型、推移的capture、引数なし呼出し、関数をまたぐ例外）で公式/Interpreter/AOT O0/O2一致。
- 性能評価とInterpreterの非capture cell除去は未完了。

- 総合dispatch再検証でglobal添字代入をlocalへ誤登録する回帰を検出。qualified名を除外し回帰テスト追加。修正後は単体911/911、上記9公式差分、dispatch総合（Interpreter 944/Node 42/AOT manifest 946/runtime 1888イベント）成功。

### M13: 数値コード診断の取得手順（実装中）

`tools/profile_aot_numeric.mjs --output <新規ディレクトリ>` はnbodyをO3でビルドし、正解、compiler/binary hash、LLVM IR、再生成assembly、linked disassembly、imports/symbols、runtime counters、compile traceを保存する。`static_call_sites` はIR内の静的call site数であり実行回数ではない。再生成assemblyと実際のlinked disassemblyを区別する。

Windowsでは `--windows-sampling` を指定し、独立したWPR instanceでCPU traceを取得する。コマンドは[Microsoft WPR仕様](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options)に基づく。ETL取得後も解析が必要であり、原因特定済みとは扱わない。比較CIは3 OSのnumeric-profile artifactを保存する設定を追加中。Windowsの実行・分析は未完了。

- macOSで開始commitのReleaseSafe compilerを使い、nbody正解照合・IR/assembly・linked disassembly・imports/symbols取得を確認した。`/private/tmp/lnako-numeric-profile-baseline/profile.json` は作業中の診断用で、3 OS性能目標の達成証拠ではない。

- 予約globalの配列定数でも同分類問題があることをcoverageで検出したため、array/property代入をlocal新規定義から除外。予約globalを含む回帰テスト、単体911/911、公式差分10ケース、dispatch coverage 56 fixtures/1917 sitesが成功。

### M9a 証拠更新完了

- oracle指定Node 24.15.0で17証拠を再生成。227 fixtures/4489 sites、expected-exit 4ケース、global binding・静的定数・compat-js 9ケースが成功。527 entryの既存分類を維持。

### M12a: 一体文字列割当

- ObjectとUTF-16 payloadを1 allocationで確保。連結・幅変換・paddingが出力を直接埋め、immutable copy量を維持する。
- borrowed unitsはGC前にコピーし、新しい文字列をroot保持してから回収する。concat入力もGC境界でroot保持する。
- fmt-check、単体915/915、公式差分9ケースInterpreter/AOT O0/O2成功。counting allocatorでconcat出力1 allocationを確認。
- concat/payload/GC scan countersを追加。全allocator malloc/realloc、mark/sweep時間、peak live bytes、3 OS性能目標の検証は未完了。

### 診断toolと追加benchmark

- 既存v2の20ケースを保持し、`benchmarks/suites/diagnostics.json` に12ケースを追加。setupを含むprocess全体計測であることをREADMEへ明記。実装時の公式/Interpreter正解照合12件、比較結果48 rowsを確認。
- numeric profileはsource/compiler/binary hash、取得元repository revision、IR、再生成assemblyと実際のlinked disassembly、imports、runtime countersを保存する。baseline macOSでnbody出力と取得を確認。
- Nodeの診断suite/profile検査、LLVM prune self-test、CI構成検査と現行文書検査を実施。比較CIに3 OS診断実行とartifact保存を追加。Windows ETLは取得後の解析が必要。

### M15a: compiler計測・索引化と数値builtin ABI

- module-load/parse、semantic、AST lowering、SSA construction/verificationとLLVM各段階を分けて計測。ValueId def-use worklist、callsite evidence集約、関数名索引を追加。
- 純粋単項builtinは数値literalを固定double ABIへ、他の入力をtag確認付き単一Value ABIへ接続。数値以外は既存coercion、O0は従来generic経路を維持。dispatch trace/site/例外の境界を保持。
- INTの科学表記・subnormal、TOFLOATの負のゼロを公式処理系に合わせて検証。generic Interpreter/AOTのTOFLOATもnumber -0を+0へ正規化し、文字列"-0"は負のゼロを保持。
- fmt-check、単体922/922、公式差分11ケースInterpreter/AOT O0/O2成功。追加境界fixtureのIRで固定ABI call 7箇所、nbodyの段階別計測を確認。
- nbodyのdynamic配列要素は専用ABI対象外。3 OS実行時間、compile-stress 30%、binary size目標は未測定であり達成とは扱わない。

### M15aの追加回帰とCI修正

- 直接callの推論型だけでは、文字列名からの動的entryの引数型を保証できない。`調整(9)`と`AWAIT実行("調整",["16"])`のSQRT結果が3/4になるようruntime tag確認を追加。単体923/923、公式差分11ケース成功。
- 拡張dispatch auditは228 fixtures/4509 sites、native entry 426/unique name 424。新規fixtureを含め、検査の固定件数と現行文書を更新。
- macOS nbodyで正解を保ち、実験snapshotのbinaryは7,526,464→553,904 bytes、IRの汎用builtin静的call 6→0。runtime call回数や3 OS性能達成とは区別する。
- 比較CI run 34079518569のmacOS profile stepがBash 3の空配列+nounsetで失敗。常に非空の引数配列へ変更し、実際のworkflow shellをmacOS Bashでテスト。Linux/Windowsの同run比較・診断jobは成功。
- Windows ETL取得を確認。次回からtracerpt XML/summaryも保存し、別hostでの解析を可能にする。ETL取得だけではCPUの原因分析完了とは扱わない。
