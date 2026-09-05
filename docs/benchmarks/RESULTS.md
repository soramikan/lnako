# ベンチマーク結果

2026年9月5日の[成功した比較CI](https://github.com/soramikan/lnako/actions/runs/33976608090)を保存したスナップショットです。測定コミットは `9fdd2445fe1d4352f12bd2e41560e38aa22bcd5b` であり、常に最新コミットの性能を表すものではありません。

## 環境別の全結果

各環境で20ケース・77測定行を実行しました。各行はウォームアップ3回後の10回測定です。

| 環境 | 全ケースの中央値・コンパイル時間・ばらつき | 生サンプル・環境・入力ハッシュ |
| --- | --- | --- |
| Linux x86_64 | [Markdown](2026-09-05-linux-x64.md) | [JSON](2026-09-05-linux-x64.json) |
| macOS arm64 | [Markdown](2026-09-05-macos-arm64.md) | [JSON](2026-09-05-macos-arm64.json) |
| Windows x86_64 | [Markdown](2026-09-05-windows-x64.md) | [JSON](2026-09-05-windows-x64.json) |

## 読み方

- 同じなでしこソースを使うcnako 3.7.24、lnako interpreter、lnako AOT O2を比較しています。C・Rust・Python・gonakoの測定値は今回のCIにはありません。
- 実行時間はプロセス起動から終了までです。cnakoとinterpreterは解析・実行を含み、AOTは事前コンパイル済み実行ファイルを起動します。AOTのコンパイル費用は別表に掲載しています。
- `steady_state` も起動を含む反復処理全体の時間です。中央値200ms未満には†を付けています。純粋なカーネル速度や、長時間常駐時の性能とは区別してください。
- 共有CIランナーのCPU、OS、ファイルキャッシュ、プロセス生成方式が異なります。OS間の数値を直接順位付けせず、同じ環境・同じケースで比較してください。特にファイル読み取りはキャッシュの影響を受けます。
- 辞書検索など、AOTがcnakoやinterpreterより遅いケースもあります。得意なケースだけから全体の速度を判断せず、用途ごとの結果を確認してください。
- 表示はms単位で小数2桁に丸めています。総合スコアは作らず、測定条件・ばらつきとともに読んでください。

## 実行方法と改善記録

[ベンチマークの実行方法・入力一覧](../../benchmarks/README.md)に再実行手順があります。JSONはCI artifactから変更せずに保存し、Markdownはその値を換算・整形したものです。artifactの保持期限後も、このスナップショットの生データを参照できます。

別のローカル実験で測定した[SSA検証のコンパイル時間改善](../BENCHMARK_IMPROVEMENTS.md)は、上記CIの中規模コンパイルケースとは入力・環境が異なるため、別記録として扱います。

[比較ワークフロー](../../.github/workflows/comparison-benchmark.yml)はPRでsmoke、main更新・夜間にnormal、手動でfullを選択できます。CI artifactは90日保持します。リリースでは正式3 OSの詳細測定を配布物に含める構成です。[旧v1の記録](../../benchmarks/comparison/README-v1.md)も測定上の制約とともに保存しています。
