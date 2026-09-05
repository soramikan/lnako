# ベンチマーク結果

正式比較は **cnako・gonako・lnako**、別言語の参考値は **C・Rust** です。実行対象19ケースとコンパイル専用1ケースを測定し、正式比較と参考値を別表にしています。

## gonako・C・Rustを含む結果

新しい記録の日付は2026年9月6日（JST）です。個別文書にはUTCの測定日時も記載しています。測定コミットは `d072a540a26765bd16b5b61d767c5728eef7c3dd`。各環境20ケース・108測定行で、ウォームアップ3回後に各10回測定しています。JSONは実測結果を変更せずに保存しています。[比較CI #33998967402](https://github.com/soramikan/lnako/actions/runs/33998967402)は正式3環境すべて成功しました。

| 環境 | 全結果（Markdown） | 生サンプル（JSON） |
| --- | --- | --- |
| Linux x86_64（CI） | [詳細](2026-09-06-linux-x64.md) | [JSON](2026-09-06-linux-x64.json) |
| macOS arm64（CI） | [詳細](2026-09-06-macos-arm64.md) | [JSON](2026-09-06-macos-arm64.json) |
| Windows x86_64（CI） | [詳細](2026-09-06-windows-x64.md) | [JSON](2026-09-06-windows-x64.json) |
| macOS arm64（開発機Apple M1） | [詳細](2026-09-06-macos-local.md) | [JSON](2026-09-06-macos-local.json) |

ローカル測定のlnakoはReleaseSafe、LLVM/LLD 22.1.8、Node.js 24.15.0を使用しています。CはClang 22.1.8、Rustは1.95.0です。CIではRustを1.98.0へ固定しています。ローカルとCIの数値を直接順位付けしないでください。

## 正式比較の条件

- cnakoは互換基準の3.7.24です。lnakoはinterpreterとAOT O2の実行時間を分けています。
- gonakoは[公式配布3.8.1](https://github.com/kujirahand/nadesiko3go/releases/tag/3.8.1)をSHA-256で固定しています。自己表示が `gonako v3.6.0` であるため、配布版・自己表示・バイナリハッシュを別々に記録しています。「正式比較」は比較対象の区分であり、lnakoのcnako 3.7.24互換基準を変更するものではありません。
- gonakoの19実行ケースすべてで期待出力が一致しました。6ケースはcnako・lnakoと共通ソースです。13ケースは引数の取り出しだけを調整した専用ソースを使い、専用ソースもcnako・lnako interpreterで出力を照合しています。反復数・入力・計算内容・期待値は同じです。個別文書から両ソースと調整内容を参照できます。
- gonakoは `run <source> [args...]` を測定します。gonakoの `build` は実行ファイルへの梱包、`gengo` はGoソース生成であり、今回のlnakoネイティブコンパイルと同一工程ではありません。コンパイル専用ケースのgonakoは未比較と明記し、0msとして扱いません。

## C・Rustの参考値

整数演算、文字列の反復コピー、文字列構築の3ケースに限定しています。いずれも同じ入力・反復数・期待出力で検証し、最適化O2の生成物の実行時間とコンパイル時間を分離しています。別言語の自然な実装を使うため、なでしこ処理系の正式比較とは別表です。

| ケース | 比較する処理 |
| --- | --- |
| `integer-arithmetic` | seed/countに依存する同一LCGとchecksum |
| `string-concat` | 毎回新しい領域を確保し、旧文字列をコピーして連結 |
| `string-builder` | なでしこは配列追加と一括結合、Cは容量を確保したバッファ、Rustは可変Stringへの追加 |

C・Rustの他のケースは未測定です。Pythonはランナーで任意選択できますが、今回の正式比較・参考値の記録には含めていません。

## 読み方

- 実行時間はプロセス起動から終了までです。cnako・gonako・lnako interpreterは解析・実行を含み、AOT・C・Rustは事前コンパイル済みの実行ファイルを起動します。コンパイル費用は別表です。
- `steady_state` も起動を含む反復処理全体の時間です。中央値200ms未満には†を付けています。純粋なカーネル速度や、長時間常駐時の性能とは区別してください。
- 共有CIランナーのCPU、OS、プロセス生成方式やファイルキャッシュの影響があります。OS間の数値を直接順位付けせず、同じ環境・同じケースで比較してください。
- 辞書検索など、lnako AOTが他の経路より遅いケースもあります。得意なケースだけから全体性能を判断せず、用途ごとの結果を確認してください。異なるスイート・環境の過去記録との差を、性能回帰とは断定しません。
- 表示はms単位で小数2桁に丸めています。総合スコアは作らず、四分位範囲・MAD・CVなどのばらつきとともに読んでください。測定順の生サンプルはJSONに残しています。

## 過去の2処理系比較

2026年9月5日の[比較CI](https://github.com/soramikan/lnako/actions/runs/33976608090)、コミット `9fdd244` の記録です。各環境20ケース・77測定行です。この記録にはgonako・C・Rustの測定値はありません。

| 環境 | 全結果 | 生データ |
| --- | --- | --- |
| Linux x86_64 | [Markdown](2026-09-05-linux-x64.md) | [JSON](2026-09-05-linux-x64.json) |
| macOS arm64 | [Markdown](2026-09-05-macos-arm64.md) | [JSON](2026-09-05-macos-arm64.json) |
| Windows x86_64 | [Markdown](2026-09-05-windows-x64.md) | [JSON](2026-09-05-windows-x64.json) |

## 実行方法と改善記録

[入力一覧と実行・Markdown生成手順](../../benchmarks/README.md)を参照してください。[比較ワークフロー](../../.github/workflows/comparison-benchmark.yml)はPRでsmoke、main更新・夜間にnormal、手動でfullを選択できます。CI artifactは90日保持し、ここに保存したJSONは保持期限後も参照できます。

別のローカル実験で測定した[SSA検証のコンパイル時間改善](../BENCHMARK_IMPROVEMENTS.md)は、このCIの中規模コンパイルケースとは入力・環境が異なります。[旧v1の記録](../../benchmarks/comparison/README-v1.md)も測定上の制約とともに保存しています。
