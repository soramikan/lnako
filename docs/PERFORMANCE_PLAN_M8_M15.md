# M8〜M15 性能改善実施計画

[提供レビュー全文](PERFORMANCE_REVIEW_2026-09-07.md)を要求の基準とする。開始HEADは `3c417fab192bbb8648a33525d02fbf9944ae8380`、作業ツリーはクリーン。レビュー内の性能値は開始時点の参考値であり、下記変更の成果ではない。

## 実装と受け入れ条件

| 単位 | 実装内容 | 受け入れ条件 | 状態 |
| --- | --- | --- | --- |
| M8 | Prepared Interpreter、名前・演算子・callee・value countの事前解決、サイズクラスpool | 動的実行・capture・例外の互換性、診断benchmark比較 | b394fa9 isolated snapshotで実装・検証済み。main統合待ち |
| M9 | 共通capture/escape解析、Interpreter/AOTの直接local Value | 非capture関数cellゼロ、capture共有維持 | AOT側検証済み、Interpreter側実装中 |
| M10 | AOT safepoint、参照liveness、root coloring | GC強制時の分岐・phi・loop・callback安全性、root数減少 | 実装・検証中 |
| M11 | Number/Boolean typed internal ABIとgeneric wrapper | NaN/Infinity/-0維持、直接・動的呼出し同値 | 実装中 |
| M12 | exact-size文字列allocation、GC/concat統計 | immutable copy量維持、UTF-16境界・GC安全性、3 OS測定 | 実装中 |
| M13 | Windows nbody sampling・LLVM IR・assembly・imports診断 | Win64 ABI/stack/helperの実測比較と原因に基づく判断 | 取得tool/CI実装、Windows測定未完了 |
| M14 | Interpreter interrupt safepoint/budget、dispatch軽量化 | 割り込み応答上限、timer/callback/dynamic/global観測維持 | isolated snapshotで実装・境界検証済み。wall-clock上限の実測は未完了 |
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

### M12 telemetry隔離検証（2026-09-07）

- `b394fa9`から作成した`/private/tmp/lnako-performance-telemetry`で、Zig 0.16.0、固定LLVM/LLD 22.1.8、Node.js 24.15.0を使用した。`zig test`のtelemetry filterは8/8（AOT Runtime移動、Interpreter Runtime移動・同一base allocator共有、allocatorのoperation/live bytes、GC mark/sweep時間、遅いtelemetry activation後のunknown free）に成功し、AOT concatの一体copy・GC境界テストは7/7に成功した。
- 固定Node `/Users/sora/Repositories/soramikan/lnako/.cache/toolchains/node-24.15.0/bin/node`、`LNAKO_LLVM_DIR=/Users/sora/Repositories/soramikan/lnako/.cache/toolchains/llvm-22.1.8-macos-aarch64`で、公式source・公式生成JavaScript・`lnako run`・LLVM AOT O0/O1/O2/O3の公式11境界をtelemetry無効・有効の両条件で比較した。各条件とも11/11成功した。一時的に11 fixtureへ絞った`tests/oracle/native-cases.json`は実行後に295 fixtureへ復元し、fixtureのgit diffが空であることを確認した。
- `LNAKO_ALLOCATOR_TELEMETRY=0`（`LNAKO_PERF_COUNTERS`未設定）ではcounter行を出さず、`LNAKO_PERF_COUNTERS=1`ではallocator telemetryを有効にしてcounter行を出すことをAOT実行で確認した。下表はtelemetry有効、AOTは-O2、各Nを1回実行した値で、`allocator_*`はwrapper activation後のallocator operation、`allocations`/`allocated_bytes`はmanaged Object単位、`concat_output_bytes`/`string_payload_bytes`はUTF-16 byte数である。`allocator_live_bytes`は全ケース終了時0だった。

| AOT case (N) | stdout | alloc/resize/remap/free | peak live | Object allocations/bytes | concat calls/output | payload allocations/bytes | GC collections/scanned/reclaimed | mark/sweep ns |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| string-copy-fixed (2000) | 20000 | 4024/0/5/4024 | 21746 | 2009/666840 | 2000/40000 | 2006/40154 | 36/324/1980 | 6543/536623 |
| string-concat (500) | 1000 | 521/0/5/521 | 119508 | 508/659510 | 500/501000 | 506/501126 | 8/64/448 | 3293/422126 |
| gc-short-lived (1000) | 501500 | 3018/0/5/3018 | 38341 | 1007/314198 | 0/0 | 5/130 | 17/102/986 | 3500/300293 |
| gc-long-lived (1000) | 500500 | 3022/0/17/3022 | 605864 | 1009/314822 | 0/0 | 5/128 | 4/945/1 | 7834/4917 |

- Interpreterの診断3ケースでもstdoutはAOTと一致し、allocator operation/peak/mark・sweepとmanaged counterを観測できる。Interpreterの`allocations`/`allocated_bytes`は各GC対象の実体構造体サイズと論理UTF-16 payload、`concat_*`は新しいUTF-16出力、`gc_*`は実体構造体単位のmark/reclaimを数える。StringのunitsやArrayのitemsなど別に確保するpayloadはmanaged bytesへ重ねて数えず、UTF-16 string payloadだけを`string_payload_*`として別計上する。これらは総allocator bytesではなく、AOTの一体allocation値とも分けて読む。allocator vtable操作数と観測済みlive/peak bytesはwrapperの`allocator_*`で示すが、process全体の総確保量ではない。固定Node/LLVMでN=2000/1000を実行したmanaged counterは、`string-copy-fixed`: allocations/bytes 6189/364650、concat/output 2000/40000、payload 6162/114450、GC collections/scanned/reclaimed 35/6227/5925、`gc-short-lived`: 2187/198542、0/0、1160/4422、13/2169/1873、`gc-long-lived`: 3188/244462、0/0、2160/10198、7/4278/1982だった。各ケースのgc scanned/reclaimed bytesは順に338616/237000、119360/171952、518912/79280。`value_counters_test.zig`で3文字列のobject/payload/concat/scan/reclaimの期待値を固定した。
- CLIのCompiler frontendとRuntime activation前の確保はtelemetry範囲外である。Runtimeと同じbase allocatorを`Interpreter.init`へ渡した場合は`allocatorForInterpreter`がwrapperを共有するため、activation後のInterpreter-owned frame buffer、prepared/local/function-index等の確保と解放はallocator operation/live bytesへ含まれる。別allocatorを明示した場合は共有せず、host側の別allocatorも含めない。M8 frame poolの`frame_pools_hits/misses`はRuntime counterへ接続済みであり、pool利用回数はallocator operationと分けて読む。
- AOTの任意entry telemetryは`LNAKO_PERF_COUNTERS=1`または`LNAKO_ALLOCATOR_TELEMETRY=1`時に有効で、`aot_index_get`/`aot_index_set`、`aot_math_f64`/`aot_math_value`、`aot_unicode_length`、`aot_generic_builtin`を各`calls`/`successes`/`failures`で分離する。これらはABI entryごとの計測であり、専用ABIからgeneric fallbackへ移行した場合には専用側とgeneric側の両entryが記録され得る。したがってこれらを合算して言語のunique呼出し数とは解釈しない。`profile_aot_numeric.mjs`の`static_call_sites`はLLVM IRの静的site数であり、これらの動的entry回数とは別の値である。専用ABIの結果値、例外境界、成功/失敗分類はAOT math/Unicode/indexのunit testで固定する。
- AOTからdynamic Value Runtimeを起動する場合は、既存のtelemetry wrapper allocatorを借用して再wrapしない。counter行はmanaged objectをdynamic contextとして分離して出力し、借用側の`allocator_telemetry_active=0`、`allocator_*`とGC時間は0になる。これはdynamic context自身のallocator snapshotが未計測で外側wrapperに含まれることを示し、初期化失敗は`allocator_telemetry_init_failures`へ記録する。外側AOT contextだけがwrapperのallocator operation/live/peakとGC時間を持つ。`/private/tmp/lnako-telemetry-dynamic-aot-active.log`でstdout `3`とこの二重観測防止を確認した。
- `allocator_peak_live_bytes`は単一Runtimeのwrapper内でのpeakである。`Counters.add`で複数Runtimeを集計する場合はcontextごとのpeakの加算になるため、同時全体peakとは表示しない。3 OSの時間・peak比較は未実施であり、上記mark/sweep nsはこのmacOS単発実行の診断値である。

### 診断toolと追加benchmark

- 既存v2の20ケースを保持し、`benchmarks/suites/diagnostics.json` に12ケースを追加。setupを含むprocess全体計測であることをREADMEへ明記。実装時の公式/Interpreter正解照合12件、比較結果48 rowsを確認。
- numeric profileはsource/compiler/binary hash、取得元repository revision、IR、再生成assemblyと実際のlinked disassembly、imports、runtime countersを保存する。baseline macOSでnbody出力と取得を確認。
- Nodeの診断suite/profile検査、LLVM prune self-test、CI構成検査と現行文書検査を実施。比較CIに3 OS診断実行とartifact保存を追加。Windows ETLは取得後の解析が必要。

### M15a: compiler計測・索引化と数値builtin ABI

- module-load/parse、semantic、AST lowering、SSA construction/verificationとLLVM各段階を分けて計測。ValueId def-use worklist、callsite evidence集約、関数名索引を追加。
- 純粋単項builtinは数値literalを固定double ABIへ、他の入力をtag確認付き単一Value ABIへ接続。数値以外は既存coercion、O0は従来generic経路を維持。dispatch trace/site/例外の境界を保持。
- INTの科学表記・subnormal、TOFLOATの負のゼロを公式処理系に合わせて検証。generic Interpreter/AOTのTOFLOATもnumber -0を+0へ正規化し、文字列"-0"は負のゼロを保持。
- fmt-check、単体922/922、公式差分11ケースInterpreter/AOT O0/O2成功。追加境界fixtureのIRで固定ABI call 7箇所、nbodyの段階別計測を確認。
- 初期版ではnbodyのdynamic配列要素を対象外にしていたが、追加回帰対応でtag確認付き単一Value ABIを適用した。3 OS実行時間、compile-stress 30%、binary size目標の最終評価は未完了。

### M15aの追加回帰とCI修正

- 直接callの推論型だけでは、文字列名からの動的entryの引数型を保証できない。`調整(9)`と`AWAIT実行("調整",["16"])`のSQRT結果が3/4になるようruntime tag確認を追加。単体923/923、公式差分11ケース成功。
- 拡張dispatch auditは228 fixtures/4510 sites、native entry 426/unique name 424。新規fixtureを含め、検査の固定件数と現行文書を更新。
- macOS nbodyで正解を保ち、実験snapshotのbinaryは7,526,464→553,904 bytes、IRの汎用builtin静的call 6→0。runtime call回数や3 OS性能達成とは区別する。
- 比較CI run 34079518569のmacOS profile stepがBash 3の空配列+nounsetで失敗。常に非空の引数配列へ変更し、実際のworkflow shellをmacOS Bashでテスト。Linux/Windowsの同run比較・診断jobは成功。
- Windows ETL取得を確認。次回からtracerpt XML/summaryも保存し、別hostでの解析を可能にする。ETL取得だけではCPUの原因分析完了とは扱わない。

### 次回push前のCI調査

- 通常CI run 34079518578は3 OS共通で`runtime_core.zig`の85.5 KiBが80 KiB上限を超えたため失敗。型・処理の分割で対応中。
- Windows dispatch coverage shard 2/3は初回に詳細出力なしで終了したが、同一commitの再実行（attempt 2）は成功。原因未特定・再現なし。以後はfixture開始とcleanup前の例外をログへ記録する。3 OS coreの構造検査失敗は再現しており、別途修正する。

### M13 中間観測（e6f3887、M15適用前）

- Windows/Linuxのnbody IRはいずれも汎用builtin静的callが6箇所、runtime counterのroot pushは122,421回、root high-waterは201。静的call箇所数と動的root push回数を混同しない。
- Windows再生成assemblyのmainは3,432 byteのstack frameを持ち、配列要素のtag/payloadを引数用stack領域へコピーして汎用builtinを呼ぶ。これだけではWindows固有の実行時間差の原因とは断定できない。
- 同CIのnbody AOT中央値はWindows 57.02 ms / gonako 62.34 ms、Linux 16.25 / 52.19 ms、macOS 11.43 / 36.12 ms。開始CIとhost負荷・処理系の時間も変動しているため、差分すべてを変更効果に帰属させない。
- string-concat AOT / gonako中央値はWindows 71.17 / 41.43 ms、Linux 31.89 / 23.13 ms、macOS 55.93 / 28.44 ms。一体割当だけでは3 OS目標は未達。
- 出典: 比較CI run 34079518569のcomparison-benchmark各OS artifact、numeric-profile-windows-x64/linux-x64 artifact。M15・M10・M11後の計測とsampling解析は継続中。

### CI構造検査の修正検証

- dictionary / byte storage / CSV state / async task typesを専用moduleへ分割。M15版runtime_coreは77,538 bytes（75.7 KiB）。上限設定は変更しない。
- fmt-check、全単体テスト（HTTP bind許可）、ReleaseSafe build、公式/Interpreter/AOT O0/O2の11 fixture差分、source structure、diff checkが成功。
- pre-pushにもsource structure検査を追加。違反で後続検査前に停止する回帰を含むhook 5テスト、numeric profile tool検査が成功。
- M15証拠更新は43b32a1へ保存。CI修正に伴うsource manifestは改めて更新する。

### M10: AOT root liveness / coloring

- CFGの逆向きlivenessでphi edge・例外targetを含めて生存参照を求め、干渉しないValueのroot slotを共有。確実なprimitive opcodeのみrootから除外し、呼出しからの推論型だけでは除外しない。
- 512 Valueまたは262,144 instruction×Value cellsを超える関数は専用slotへfallbackし、解析の二次メモリ増大を抑える。境界値・fallbackの非aliasテストを追加。
- M12基準の隔離単位で919単体と公式差分10ケース成功。M15との統合でもfmt-check、全単体、ReleaseSafe build、公式/Interpreter/O0/O2差分11ケース成功。
- M12基準のroot slot合計/runtime high-water: nbody 197→22 / 201→26、string-concat 29→9 / 33→13、binary-trees 100→26 / 459→117。各正解を照合済み。
- M10+M15のmacOS診断snapshotでもnbody正解93200371、runtime root high-water 26、553,904 bytes、汎用builtin静的callゼロを確認。root push回数122,422は削減されておらず、root保持数と呼出し回数を区別する。計測toolはcompiler/binary hashを記録しているが、3 OS性能達成の証拠ではない。
- 統合後のdiagnostics 12ケース/36測定も正解・JSON/Markdown検査成功。単発測定なので速度比較には使用しない。

### native AOT検査のfixture件数同期

- 03b2c41の通常CI coreで、native fixture 295件に対して成果物検査の固定値294が残っていることを検出。成果物検査とattestation検査を295件へ同期。
- native AOTのshard partition/schema/tamper拒否self-test成功。CI互換基準確認の全コマンドを実行し、未更新source manifestに依存する2検査以外は成功。証拠更新後に同じ全ステップを再実行する。

### コードと証拠の同一コミット / M13 link map

- ユーザー指示に従い、以降は検証済みコードをstageし、source manifestに基づく証拠生成後にコード・証拠を同じ署名付きコミットにする。既存履歴は改変しない。DEVELOPMENTと生成toolの説明を同期。
- Windows PEのsymbol tableが空だったため、trace有効時に実リンクのmapを保存する。Linux `-Map`、macOS `-map`、Windows LLD `/lldmap`を`-Xlinker`経由で渡し、空白・カンマを含むpathを保持。通常buildはmapを作らない。
- profileにはmap SHA-256と各child PIDを保存。fmt-check/全単体/ReleaseSafe build成功。macOSで空白・カンマ付きpathのnbody正解、map内の数学専用ABI symbol、PID記録を確認。Windows samplingへの対応付けは新CI artifactで検証する。

### M15: ELF / COFF runtime section分割

- 03b2c41の比較CIは3 OS成功。nbodyはmacOS 554,624 bytesに縮小したが、Linux 8,834,648 / Windows 9,043,456 bytesが残った。
- Zigのstatic runtime libraryにLinux/Windowsのみfunction/data sectionsを有効化。既存のELF `--gc-sections` / COFF `/OPT:REF`が不要なruntime関数・データを除去できる粒度にする。Mach-Oは既存symbol-level dead stripを保持。
- Linux x86_64 GNUクロスビルド成功。Runtime初期化・終了だけを参照するCのリンク検証では、同一archiveのno-gc / gcが8,849,008 / 322,920 bytes。これはリンク構造の検証であり、正式ななでしこbenchmarkやLinux実行検証ではない。
- Windows MSVC向けruntime libraryのクロスビルドは成功。CLIのリンクはmacOS側にWindows SDKのshell32がないため未完了。Windowsでのリンク・実行はCIで検証する。
- コードをstageした状態で17証拠ファイルを再生成し、CIの互換基準チェック13項目がすべて成功。コードと同じコミットに保存する。

### M8/M14 isolated snapshot 検証（b394fa9）

- `/private/tmp/lnako-performance-m8` のsnapshotへM8 Prepared Interpreter、M14 interrupt budget/safepoint、timer・test callbackのexception boundary修正を統合した。`root_liveness` と `result_effect` は同じ `ir` namespaceへ公開し、M8側のpool counter版 `state.zig`/`tests.zig` はRuntime telemetry共有を持たない。
- `zig build fmt-check` は成功し、権限付き `zig build test --summary all` は **955/955** 成功した。これはtelemetry専用テストと親側M11追加分を含めない隔離snapshotの件数である。
- Node `v24.15.0` 固定の `tools/compare_native_oracle.mjs --no-build` は、公式CLI・公式生成JavaScript・`lnako run`・LLVM AOT O0/O1/O2/O3の7経路 **295/295** 成功。既知の公式経路差はCLI基準24件、公式生成JavaScript基準44件で、比較器が許容する既知差として記録された。
- diagnostics suiteはNodeテスト **2/2** 成功、公式cnakoとInterpreter/AOT O2の実測は **12 cases / 48 measurements、failures 0**。smoke測定ではprocess-batched wallの200ms未満警告が27件あり、正解不一致ではない。
- `git diff --check` は成功。Windows callback fixtureの50ms raceを0.01秒間隔・最大100回のbounded pollへ置換した修正を受領し、Node 24.15.0でdispatch coverageを再測定した。結果は228 fixtures/4510 sites、native entry 426/unique name 424で、17証拠の再生成へ進める状態である。

### M11: Number / Boolean internal ABI

- 非破壊の型解析でNumber / Booleanの内部関数を生成し、型が確定した直接呼出しをdouble / i1引数・戻り値へ接続する。再帰・相互再帰は固定点で解析する。
- 名前による動的呼出しに備え、公開関数のgeneric Value経路を保持。直接呼出しの観測だけで公開引数型を狭めず、不明な型・capture・非対応命令はgeneric経路に戻す。
- 独立レビューで数値・真偽値・再帰・callback・NaN/Infinity/-0・それのInterpreter/AOT O2同値を確認し、現時点でP1/P2なし。隔離環境のfmt-checkと全単体テスト成功。公式/Interpreter/O0/O1/O2/O3差分11ケースも成功。拡張fixtureを含むdispatch auditは228 fixtures / 4,515 sites / native entry 426で成功。性能の最終評価は継続中。
- 2,000回の数値更新を並べた追加stressでは、b394fa9とM11の生成LLVM IRが5,220,471 bytes、SHA-256 `164f9337086018e296f4c84f6c329a043b98c7b9d379306e6afb1374eda2e50e`で完全一致。IR生成は42 / 15 msに対しLLVM最適化・object出力が約14 / 19秒を占めた。同時負荷下の単発測定なので速度差を変更効果とは扱わない。typed解析の回帰は検出されず、巨大IRのLLVM処理負荷は残る。
- M8/M14とWindows callback fixture修正を統合した状態でもfmt-check・全単体・公式11ケース（InterpreterとAOT O0〜O3）が成功。最終dispatchは228 fixtures / 4,516 sites、17証拠再生成後のCI互換baseline 13項目すべて成功。

### Unicode `文字数` Value ABI（6b6899b isolated）

- `/private/tmp/lnako-unicode-length-abi.patch` の6ファイルだけを6b6899bへ適用し、公開AOT ABIを `ptr, ptr, i16, i64` へ追加した。`文字数` の入力はValueのまま保持し、`valueUtf16Alloc`・ToPrimitive・pending exception・dispatch trace・root frameをgeneric経路と揃えた。
- `out` と `input` が同一slotになる公開ABI境界をレビューで検出し、入力を出力clear前にコピーする修正と回帰テストを追加した。fmt-check成功、全単体 **965/965** 成功。
- Node 24.15.0固定のReleaseSafe compilerで公式CLI・公式生成JavaScript・Interpreter・AOT O0/O1/O2/O3を **295/295** 比較し、Unicode・数値ABI境界を含め全件一致した（既知の公式経路差はCLI基準24件、生成JavaScript基準44件）。
- `文字数("A😀B")` のReleaseSafe O3実行は `3`。生成LLVM IRは専用 `lnako_aot_unicode_length_call_site` を1箇所呼び、generic `lnako_aot_builtin_call_site` を呼ばない。`llvm-nm`で専用symbolを確認し、fixture実行ファイルは338,096 bytesだった。runtime countersはconcat 0、object allocation 3、string payload 3件/12 bytes、root high-water 6を記録した。UTF-16 scratchはgenericと同じ `valueUtf16Alloc` 1回のimmutable copy経路で、専用ABIによる追加concat/object copyはない。
