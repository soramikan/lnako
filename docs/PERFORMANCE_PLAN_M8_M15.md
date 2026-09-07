# M8〜M15 性能改善実施計画

[提供レビュー全文](PERFORMANCE_REVIEW_2026-09-07.md)を要求の基準とする。開始HEADは `3c417fab192bbb8648a33525d02fbf9944ae8380`、作業ツリーはクリーン。レビュー内の性能値は開始時点の参考値であり、下記変更の成果ではない。

## 実装と受け入れ条件

| 単位 | 実装内容 | 受け入れ条件 | 状態 |
| --- | --- | --- | --- |
| M8 | Prepared Interpreter、名前・演算子・callee・value countの事前解決、サイズクラスpool | 動的実行・capture・例外の互換性、診断benchmark比較 | 実装中 |
| M9 | 共通capture/escape解析、Interpreter/AOTの直接local Value | 非capture関数cellゼロ、capture共有維持 | AOT側検証済み、Interpreter側実装中 |
| M10 | AOT safepoint、参照liveness、root coloring | GC強制時の分岐・phi・loop・callback安全性、root数減少 | 未実装 |
| M11 | Number/Boolean typed internal ABIとgeneric wrapper | NaN/Infinity/-0維持、直接・動的呼出し同値 | 未実装 |
| M12 | exact-size文字列allocation、GC/concat統計 | immutable copy量維持、UTF-16境界・GC安全性、3 OS測定 | 実装中 |
| M13 | Windows nbody sampling・LLVM IR・assembly・imports診断 | Win64 ABI/stack/helperの実測比較と原因に基づく判断 | 未実装 |
| M14 | Interpreter interrupt safepoint/budget、dispatch軽量化 | 割り込み応答上限、timer/callback/dynamic/global観測維持 | 未実装 |
| M15 | compiler stage timing/index/worklist、hot builtin専用ABI/dead strip | コンパイル同値、時間・symbol/size比較 | 未実装 |
| 診断ケース | local/global/direct/captured/index/dict/string/GC/numeric 12ケース | 正解照合、build/read/write範囲を区別 | 未実装 |

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

- 予約globalの配列定数でも同分類問題があることをcoverageで検出したため、array/property代入をlocal新規定義から除外。予約globalを含む回帰テスト、単体911/911、公式差分10ケース、dispatch coverage 56 fixtures/1917 sitesが成功。
