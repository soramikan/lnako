# M8〜M15 性能改善の検証結果

[提供レビュー](PERFORMANCE_REVIEW_2026-09-07.md)と[実装・検証記録](PERFORMANCE_PLAN_M8_M15.md)に対応する測定記録。M8〜M15の実装と検証を終え、最終統合ランタイムの3 OS測定で達成・未達を判定した。

## 比較方法

- 正式比較はcnako3 / gonako / lnako Interpreter / lnako AOT。C / Rustは参考値として分離する。
- 同一CI内の同一ケース・入力・正解を比較する。wall timeにはprocess起動とsetupが含まれ、数値kernel単独の時間ではない。
- 別CI間はrunner負荷や比較処理系の時間も変動するため、中央値の差をすべてコード変更の効果に帰属させない。
- runtime counter有効時の測定はallocation・GC構造の診断に使い、通常の性能測定と混ぜない。immutable string-concatのコピー操作を維持し、in-place builderへ置換しない。
- 12診断ケースでは配列・辞書の構築を反復read/writeの外へ分けた。ただし計測器はprocess全体を測るため、固定setupや起動もwall timeに含む。純粋なread/write kernel時間とは扱わない。200 ms未満の測定には起動時間への感度が高い旨の警告を残す。

## 最終統合ランタイムの判定

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

## 中間CI

開始時点は`3c417fab192bbb8648a33525d02fbf9944ae8380`、[比較CI 34058162808](https://github.com/soramikan/lnako/actions/runs/34058162808)。M9・M12の一体文字列割当・M15の数学ABI等を含む中間版は`03b2c41470e167a5b6a272f3ce74eaef6db11233`、[比較CI 34082348062](https://github.com/soramikan/lnako/actions/runs/34082348062)。後者の比較jobは3 OSとも成功した。

| 中間版のsteady-state比較 | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| AOTがcnakoより速いケース | 17/17 | 17/17 | 17/17 |
| AOTがgonakoより速いケース | 16/17 | 16/17 | 16/17 |
| Interpreterがcnakoより速いケース | 6/17 | 6/17 | 6/17 |
| compile-stressの開始CI比 | +3.1% | -4.9% | -19.5% |

この中間版ではstring-concatのgonako超え、Interpreterの多数ケースでのcnako超え、compile-stress 30%短縮は未達。M8・M10・M11・ELF/COFF section分割を含む最終版を別途測定する。

## M8・M11統合版の3 OS確認

`6b6899b4c9f15a4d69a6e22d19a1de4c521a0d16`の[比較CI 34087590815](https://github.com/soramikan/lnako/actions/runs/34087590815)は3 OSとも成功。M8〜M11とELF/COFF section分割を含み、Unicode専用ABIと追加allocator telemetryはまだ含まない。正式suiteはwarmup 3・測定10回、診断suiteはwarmup 1・測定3回で、正解不一致はなかった。

| 統合版の比較 | Linux x86_64 | Windows x86_64 | macOS arm64 |
| --- | ---: | ---: | ---: |
| AOTがcnakoより速いsteady-state | 17/17 | 17/17 | 17/17 |
| AOTがgonakoより速いsteady-state | 16/17 | 16/17 | 16/17 |
| AOTがInterpreterより速いsteady-state | 17/17 | 16/17 | 16/17 |
| Interpreterがcnakoより速いsteady-state | 6/17 | 5/17 | 6/17 |
| compile-stressの開始CI比 | -45.4% | -40.0% | -54.9% |

compile-stress 30%短縮はこの測定で3 OS達成した。string-concatとInterpreter全般の目標は未達。AOT integer-arithmeticのC/Rust参考比はLinux 27.45 / 25.13倍、Windows 3.83 / 4.15倍、macOS 11.53 / 11.95倍で、5倍以内はWindowsのみ。これはprocess全体の中央値比であり、数値kernel単独の比ではない。

## Windows CPU sampling

### 最終計測版 `02457ac`

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

数値変換と汎用演算helperが上位に残り、中間版の観測と整合する。typed internal ABIの定義はnbodyでは0、静的数学Value ABIは6箇所で、配列要素から得た値の型が証明されない演算はgenericを維持する。Windows専用ABI変更を追加する根拠にはしていない。

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

### 中間版の記録

中間CIのETLをtracerpt XMLへ変換し、`tools/analyze_numeric_trace.py`でProcess / Thread / Image intervalとSampledProfileを時刻で対応付けた。全276,512 events、loss 0、SampledProfile 12,302 recordsのうちnbody processに1,969 recordsを対応付け、1,392 recordsがnbody.exe、361がkernel address、216がその他のuser imageまたは未解決だった。これらはsample record数であり、命令実行回数ではない。

当該PEのsymbol tableは空で、関数名の断定はできない。新しいtrace buildは実リンカのmapとchild PIDを保存する。LLVM 22.1.8の実`/lldmap`出力をCOFF probeで検証し、RVA形式・size 0 symbol・section終端を扱う回帰を追加した。

### map付きM8・M11統合版

`6b6899b`のWindows traceはSampledProfile 11,800 records中、nbody process 1,922、nbody.exe 1,396 recordsだった。実`/lldmap`の10,683 symbolへRVAを照合し、exe内サンプルのsymbol未解決は0。PID/TID再利用時は時刻とprocess imageの一致を必要とし、process interval不明275 recordsとthread不明1,436 recordsをtargetへ推測帰属しない。

| sampled symbol | records |
| --- | ---: |
| valueToPrimitive | 257 |
| arithmetic | 217 |
| lnako_aot_arithmetic | 161 |
| valueToNumberRuntime | 121 |
| valueToParseFloatRuntime | 98 |
| aotCanonicalArrayIndex | 89 |
| GlobalTrace.recordPhase | 80 |
| wmain | 57 |
| index_get | 54 |

サンプルでは数値変換と汎用演算helperが多い。IRには数学Value ABIが6、arithmeticが22、index_getが13、global read/writeが44/16静的call sitesあり、当該nbodyにtyped internal関数定義は0。配列から取り出した値の型は証明されていないためgenericな演算が残る。再生成assemblyとlinked disassemblyのsample対応を照合し、`__chkstk`を主要因とする証拠は得られなかった。sqrt命令近傍は1 recordで、呼出し回数の測定ではない。

この版のWindows nbodyはAOT 39.43 ms / gonako 76.97 ms。開始CIより改善し、今回の「gonako以下」は達成した。Win64 aggregate ABIだけが原因だったと断定できる対照実験ではないため、Windows専用の演算変更は追加しない。allocator操作数とmark/sweep時間はこのartifactにまだなく、後続telemetry版で測る。

## Windows実行ファイルサイズの参照調査

`6b6899b`ではLinux/macOSの13/19実行ケースが1 MiB未満だった一方、Windowsは0/19でnbodyが8,929,280 bytesだった。`394ca49`の文字数ABI追加後もWindowsの0/19は変わらなかった。

cross runtime archiveのCOFF調査では、非COMDAT `.rdata` section 21（46,452 bytes）が11,613本のREL32参照を持ち、293個のtext sectionへつながっていた。うちgeneric dispatcher sectionへの参照は996本。関数名への通常の参照だけを調べると見落とす、section symbol経由の共有コードアドレス表だった。

`wmain → lnako_aot_runtime_init`のみの最小linkでもdispatcherが残った。一時コピー内の該当参照を除く因果実験ではdispatcherがdiscardされ、8,658,944→8,372,224 bytesとなった。このCOFF書換えは診断専用で製品には採用しない。`.drectve`、export alias名、`.pdata`/`.xdata`単独root、`/OPT:REF`の無効化を原因とする根拠はなかった。

cross archiveとCIのobjectはbyte identityを確認していないため、同じ構造の観測として区別する。CI mapにも大きなruntime `.rdata`とgeneric dispatcherが残る。

Zig 0.16のZig-source compileと標準Build APIにはjump tableを抑制する入口を確認できず、実際に`-mllvm`と`-fno-jump-tables`は拒否された。LLVM 22.1.8のllcには対応候補のoptionがあるが、zig cc用のflagをZig runtimeへ適用することはできない。独自COFF書換えやruntime全体の二段ビルドへの変更は採用せず、Zig/LLVM側で関数単位のtable sectionを生成する対応を今後の候補として残す。Windows 1 MiB目標は未達である。

LLVM単体の因果probeでは、同一のruntime IR（SHA-256 `b3254af18d641027ad90b792e255763f3137ae227f231b87927f0a8ab7815025`）に`--function-sections --data-sections`を指定し、jump-table optionだけを変えた。defaultの`.rdata`参照17,233本に対し、`--jumptable-in-function-section`と`--min-jump-table-entries=1000000`はいずれも4,936本だった。standalone objectは25,226,707→25,073,185 / 24,744,392 bytes。共有table参照を減らす因果効果は確認したが、外部llcのobjectは現在のZig AOT archive生成経路と同一ではなく、製品実行ファイルの改善値や互換性証拠には使わない。

## Interpreter割り込み応答の観測

`6b6899b`のReleaseSafe compilerで、割り込みcallbackを登録してREADYを出力した後に数値loopを実行し、親processからSIGINTを送信した。macOSローカル10回はすべてcallbackによるexit code 0で終了し、loop後の出力には到達しなかった。signal送信からprocess終了までは中央値0.463 ms、最大2.418 msだった。compiler SHA-256は`a94ec0221d5bce3fcd04f7978eb7559a38224313be718ac59bc5be4279a6ac8e`。

これはscheduler・終了処理を含む観測値であり、他hostやblocking builtinを含む処理のwall-clock上限ではない。実装上はblock/call/allocationのsafepointに加え、通常命令を最大1,024命令ごとにpollする。timer・callback・動的実行・global traceの互換性は別の回帰・公式差分で検証した。

## 追加計測の読み方

- `allocations`はmanaged objectの生成数、`allocated_bytes`はobject構造と計上対象のUTF-16 payloadの合計。配列・辞書等の可変bufferを含む全allocator確保量ではない。
- `allocator_*_calls`はwrapperが観測したallocator vtable操作数。`allocator_live_bytes` / `allocator_peak_live_bytes`もwrapperで観測した範囲で、process RSSやcompiler frontendの全メモリではない。
- `allocator_telemetry_active=0`は当該Runtimeで未計測、`allocator_telemetry_init_failures`は計測初期化失敗を表す。欠測時の0を実測0とは扱わない。計測管理用allocationの失敗はbase allocatorへfallbackする。
- AOT内の動的Interpreterは既存wrapperを再ラップせず使う。managed object/GCは別Runtimeのreportとなり得る。複数reportは個別contextで保持し、合計値や最終reportへの上書きで表現しない。
- AOT helperの`calls` / `successes` / `failures`は対象ABIへのentry数。wrapperとfallbackの双方が呼ばれる場合があるため、異なるentryの合計を言語の関数呼出し回数とは扱わない。

ローカルの割り込み測定とallocator実験のraw samples・source/binary hashは[保存JSON](benchmarks/2026-09-07-m8-m15-local-probes.json)に収録した。

計測版`02457ac`相当のmacOSローカルInterpreterでは、string-concat（N=6,000）が出力12,000、concat 6,000回 / 72,012,000 bytes、allocator alloc/free各24,543回、終了時live 0 / peak 2,222,921 bytesだった。recursion（N=24）は正解46,368、frame pool hit 150,025 / miss 25。どちらも通常benchmarkとは別のcounter有効実行であり、最終統合Runtimeの構造確認に使う。

## allocator変更の限定実験（不採用）

`394ca49`を基準にAOT RuntimeとIoのbase allocatorだけを`c_allocator`から`std.heap.smp_allocator`へ変更して比較した。所有権・thread safetyを確認し、fmt-check・全単体・native plugin ABI（同期/Promise/失敗境界、AOT O0〜O3）が成功した。macOSローカルで各variantをwarmup 3回、交互10回実行した中央値は以下のとおり。

| ケース | c_allocator | smp_allocator |
| --- | ---: | ---: |
| string-concat | 53.119 ms | 52.699 ms |
| startup-empty | 3.773 ms | 3.823 ms |
| startup-hello | 3.496 ms | 3.965 ms |
| binary-trees | 14.668 ms | 16.560 ms |
| nbody | 9.868 ms | 10.127 ms |

string-concatは双方で出力12000、concat出力72,012,000 bytes、managed allocation 6,008が一致した。string-concatの差は約0.8%で、他ケースの改善も得られなかったため、このallocator置換は採用しない。通常実行の時間と別実行のcounterを区別し、他OSへの性能効果も主張しない。

## 残る性能課題

- Interpreterの名前解決・frame準備は削減したが、動的Value演算やbuiltin処理の固定費は残る。全ケースでのcnako/gonako超えは実装完了条件と混同しない。
- string-concatはimmutable copy量を維持して一体allocationを導入したが、gonako以下には届かなかった。追加allocator置換も一貫した改善がなく不採用とした。
- Windowsでは共有tableが不要関数の除去を妨げる。Zig 0.16のサポートされた設定で解消できず、toolchain側の改善候補として残す。
- packed NumberArray、世代別GC、in-place builderは提供レビューが本フェーズの先行実装から外した項目であり、今回実装したとは扱わない。
