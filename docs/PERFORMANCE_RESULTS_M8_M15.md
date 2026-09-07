# M8〜M15 性能改善の検証結果

3 OSのCIで測定した実行・コンパイル性能、CPU profile、runtime counterの記録。測定条件と達成・未達を分けて示す。

## 比較方法

- 正式比較はcnako3 / gonako / lnako Interpreter / lnako AOT。C / Rustは参考値として分離する。
- 同一CI内の同一ケース・入力・正解を比較する。wall timeにはprocess起動とsetupが含まれ、数値kernel単独の時間ではない。
- 別CI間はrunner負荷や比較処理系の時間も変動するため、中央値の差をすべてコード変更の効果に帰属させない。
- runtime counter有効時の測定はallocation・GC構造の診断に使い、通常の性能測定と混ぜない。immutable string-concatのコピー操作を維持し、in-place builderへ置換しない。
- 12診断ケースでは配列・辞書の構築を反復read/writeの外へ分けた。ただし計測器はprocess全体を測るため、固定setupや起動もwall timeに含む。純粋なread/write kernel時間とは扱わない。200 ms未満の測定には起動時間への感度が高い旨の警告を残す。

## 測定結果

測定対象は`02457acce036c239d12313da6bd528dd22e48f6b`。[比較CI 34093414459](https://github.com/soramikan/lnako/actions/runs/34093414459)は3 OSとも成功した。[通常CI 34093414457](https://github.com/soramikan/lnako/actions/runs/34093414457)も54/54ジョブ成功。各OSで正式20ケース / 108測定行（warmup 3・測定10回）、診断12ケース / 48測定行（warmup 1・測定3回）が正解照合と結果検査を通過した。開始版と正式suite・各ケースのsource hashが一致する。

CPU解析ツールと本書は、このランタイムの測定後に追加した。解析ツールのcommitと測定対象のruntime commitを同一とは扱わない。

| 目標の測定結果 | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| AOT < cnako（steady-state） | 17/17 | 17/17 | 17/17 |
| AOT < gonako（steady-state） | 16/17 | 16/17 | 16/17 |
| AOT < Interpreter（steady-state） | 17/17 | 16/17 | 16/17 |
| Interpreter < cnako（steady-state） | 6/17 | 6/17 | 6/17 |
| Interpreter ≤ gonakoの2倍 | 3/17 | 4/17 | 4/17 |
| compile-stressの開始版比 | -44.6% | -38.5% | -49.4% |
| AOT実行ファイル < 1 MiB | 14/19 | 0/19 | 14/19 |

AOT対cnakoの全ケース、compile-stress 30%以上短縮、Windows nbodyのgonako以下は達成した。AOT対gonakoは3 OSともstring-concatだけ未達。AOT対InterpreterもmacOS/Windowsのstring-concatで未達で、startupのノイズだけでは説明しない。Interpreter対cnakoの過半数、対gonakoの全ケース2倍以内は未達。

| 個別ケースの中央値 / AOTサイズ | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| nbody AOT / gonako (ms) | 15.004 / 47.524 | 33.508 / 72.175 | 7.530 / 28.769 |
| nbody AOT bytes | 698,312 | 8,947,200 | 554,656 |
| string-concat AOT / gonako (ms) | 28.802 / 22.417 | 85.213 / 52.660 | 60.088 / 21.662 |
| string-concat AOT bytes | 632,208 | 8,935,936 | 504,560 |
| compile-stress 開始版 → 最終 (ms) | 800.860 → 443.400 | 1013.563 → 623.207 | 764.978 → 387.218 |

Linux/macOSでもstring-builder、unicode-scan、word-count、json-transform、file-readの5ケースは1 MiB以上で、汎用runtime依存が残る。Windowsは全19実行ケースで未達。サイズ縮小を全機能へ一般化したとは記述しない。

C/Rustは正式比較とは別の参考値である。測定済みnumericケースはinteger-arithmeticだけで、nbody等のC/Rust比較は未測定。

| integer-arithmetic AOT / 参考処理系 | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| C | 28.24倍 | 3.45倍 | 16.82倍 |
| Rust | 25.84倍 | 3.26倍 | 14.27倍 |

5倍以内はWindowsのみ達成した。process起動を含む比較であり、他OSや純粋なnumeric kernelの達成を主張しない。

### 保存した証拠

[artifact indexとSHA-256](benchmarks/2026-09-07-m8-m15-artifacts.json)、[目標判定と開始版compile samples](benchmarks/2026-09-07-m8-m15-goals.json)、[3 OS数値profileとcounter](benchmarks/2026-09-07-m8-m15-numeric-profiles.json)、[Windows CPU解析](benchmarks/2026-09-07-m8-m15-windows-cpu.json)を保存した。以下のJSONはCIのraw samplesを変更せず複製したものである。

| 環境 | 正式20ケース | 診断12ケース |
| --- | --- | --- |
| linux | [JSON](benchmarks/2026-09-07-m8-m15-linux-x64-comparison.json) | [JSON](benchmarks/2026-09-07-m8-m15-linux-x64-diagnostics.json) |
| windows | [JSON](benchmarks/2026-09-07-m8-m15-windows-x64-comparison.json) | [JSON](benchmarks/2026-09-07-m8-m15-windows-x64-diagnostics.json) |
| macos | [JSON](benchmarks/2026-09-07-m8-m15-macos-arm64-comparison.json) | [JSON](benchmarks/2026-09-07-m8-m15-macos-arm64-diagnostics.json) |

## Windows CPU sampling

### 測定対象 `02457ac`

Windows traceは308,945 events、loss 0、SampledProfile 14,416 records。nbody processへ2,095、nbody.exeへ1,451 recordsが対応し、実mapの10,717 symbolsによるexe内sampleの未解決は0だった。target以外や不明intervalのsampleを推測でnbodyへ帰属させていない。

| 主なsampled symbol | records |
| --- | ---: |
| valueToPrimitive | 237 |
| arithmetic | 218 |
| lnako_aot_arithmetic | 126 |
| valueToNumberRuntime | 119 |
| recordPhase | 100 |
| aotCanonicalArrayIndex | 83 |
| valueToParseFloatRuntime | 78 |
| wmain | 78 |
| lnako_aot_index_get | 53 |

数値変換と汎用演算helperが上位に残り、typed internal ABIの定義はnbodyでは0、静的数学Value ABIは6箇所で、配列要素から得た値の型が証明されない演算はgenericを維持する。Windows専用ABI変更を追加する根拠にはしていない。

別実行のruntime counterでは、3 OSとも数学Value ABI 7,205 entry、index_get 52,803 entry、index_set 19,200 entry、汎用builtin 0 entryで、計測した各entryの失敗は0だった。ETWのsample record数と、このentry数を混同しない。

| nbody counter診断 | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| allocator alloc / resize / remap / free | 3629 / 0 / 5 / 3629 | 3627 / 0 / 3 / 3627 | 3629 / 0 / 5 / 3629 |
| 終了時live bytes | 0 | 0 | 0 |
| peak live bytes | 21,660 | 21,646 | 21,666 |
| GC collections | 66 | 66 | 66 |
| mark ns | 11,320 | 15,100 | 7,579 |
| sweep ns | 130,075 | 168,400 | 145,875 |
| root high-water | 26 | 26 | 26 |

各Runtimeで`allocator_telemetry_active=1`、初期化失敗0を確認した。mark/sweepはcounter有効の単発診断、live/peakは観測wrapper内に限る。全processのRSSや、通常benchmark実行時のGC時間としては扱わない。

## 追加計測の読み方

- `allocations`はmanaged objectの生成数、`allocated_bytes`はobject構造と計上対象のUTF-16 payloadの合計。配列・辞書等の可変bufferを含む全allocator確保量ではない。
- `allocator_*_calls`はwrapperが観測したallocator vtable操作数。`allocator_live_bytes` / `allocator_peak_live_bytes`もwrapperで観測した範囲で、process RSSやcompiler frontendの全メモリではない。
- `allocator_telemetry_active=0`は当該Runtimeで未計測、`allocator_telemetry_init_failures`は計測初期化失敗を表す。欠測時の0を実測0とは扱わない。計測管理用allocationの失敗はbase allocatorへfallbackする。
- AOT内の動的Interpreterは既存wrapperを再ラップせず使う。managed object/GCは別Runtimeのreportとなり得る。複数reportは個別contextで保持し、合計値や最終reportへの上書きで表現しない。
- AOT helperの`calls` / `successes` / `failures`は対象ABIへのentry数。wrapperとfallbackの双方が呼ばれる場合があるため、異なるentryの合計を言語の関数呼出し回数とは扱わない。

## 残る性能課題

- Interpreterは動的Value演算やbuiltin処理の固定費が残り、cnako/gonakoへの全般的な速度優位には達していない。
- string-concatはimmutable copyを維持するためコピー量が入力長に応じて増え、3 OSともgonakoより遅い。
- Windowsは不要runtimeを除去し切れず、全19実行ケースで1 MiB以上。Linux/macOSも汎用runtimeを使う5ケースで1 MiB以上となる。
