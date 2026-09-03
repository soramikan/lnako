# LLVM AOTのquirks

この文書は、InterpreterとLLVM AOTの結果を比較するときに、compile、runtime、OS、attestationを混同しないための注意事項です。

## 最適化レベル

- 公式実測・source根拠: なでしこ公式はJavaScript実行をoracleとして提供します。LLVMのO0〜O3自体はlnakoの生成経路であり、公式の最適化結果と同一であることを前提にしません。
- lnakoの現在動作: O0はNako SSA IRの動的変換を保ち、O1以上は独立複製IRに安全な型推論・定数伝播・直接呼出し・dead code eliminationを適用します。全レベルで結果と未対応IRの診断を検査します。
- 判定: lnakoの実装契約
- 対象経路: AOT
- 差分テストID: `native-arithmetic`、`native-dynamic-arithmetic`（全AOT fixtureはCIのnative AOT matrixでO0〜O3を検証）、検査器: `check_native_aot_artifacts`
- TODO識別子: なし

## compile manifestとruntime trace

- 公式実測・source根拠: 公式source／generated JavaScriptの結果は、lnakoのAOT dispatchを証明するためのoracleです。fixture参照だけではcompile siteとruntime siteの一致は分かりません。
- lnakoの現在動作: catalog ID、source site、compile manifest、Interpreter/AOT traceを同じ証拠recordへ結び付けます。manifest欠落、重複、traceのみのsiteは成功と数えません。
- 判定: 証拠運用上の意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `check_dispatch_trace`、`check_dispatch_coverage`、`check_dispatch_trace_security`
- TODO識別子: なし

## 終了・例外・外部host

- 公式実測・source根拠: 未捕捉例外、意図的終了、外部process、launcher、外部7zは、通常の成功traceを途中で終端させます。終了コード・signal・stderrをstdout一致だけで判定できません。
- lnakoの現在動作: expected-exit、expected-failure、external-hostを別policy・fixtureへ分離し、終了結果・stderr・trace終端を記録します。
- 判定: 証拠運用上の意図的制限
- 対象経路: Interpreter / AOT
- 差分テストID: `native-node-exit-code`、`native-uncaught-exception`、`native-node-host-open-external`
- TODO識別子: `TODO: node-exit-cross-os-attestation`

## Windowsのentry pointとUTF-16 argv

- 公式実測・source根拠: WindowsのNode相当経路はwide argv、drive letter、CRLF、unpaired surrogateを扱います。POSIXのbyte argvへ単純変換すると値が変わります。
- lnakoの現在動作: generated `wmain`からUTF-16 code unitのままNode定数へ渡し、AOT runtime内で保持します。path root scanもvolume rootで停止します。
- 判定: 仕様／意図的制限（無限走査防止）
- 対象経路: AOT
- 差分テストID: `native-node-command-line-constants`、`native-node-path-type-errors`、`native-node-path-mixed-separators`
- TODO識別子: `TODO: aot-node-windows-wtf8-argv`

## Buffer・TypedArray・ArrayBuffer

- 公式実測・source根拠: Bufferはviewとして `parent`・`offset`・numeric index・prototype methodを持ち、`slice`はstorageを共有します。Uint8ArrayとArrayBufferはslice、length、prototype、own propertyが異なります。custom `__proto__` は標準propertyの可視性を変えます。
- lnakoの現在動作: 3種のbyte buffer family、numeric index、view共有、prototype代表値、null prototype境界をAOTへ接続します。receiver未束縛のmethod call、descriptor、全view identityは未検証境界として残します。
- 判定: 仕様／未実装境界
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-byte-buffer-direct-properties`、`native-system-byte-buffer-null-prototype`、`native-system-byte-buffer-backing`、`native-system-byte-buffer-method-calls`
- TODO識別子: `TODO: aot-byte-buffer-value`

## AOTのToPrimitive

- 公式実測・source根拠: object・array・Buffer・functionのcustom `toString` / `valueOf` はhint順序とreceiverを持ち、methodがobjectを返すと次の候補へ進みます。
- lnakoの現在動作: own/prototype propertyを参照し、primitiveを得るまでhint順に呼び出します。通常モードはJS runtimeをfallbackに使いません。
- 判定: 仕様／未実装境界
- 対象経路: Interpreter / AOT
- 差分テストID: `native-system-object-to-primitive-host-properties`、`native-system-array-to-primitive`
- TODO識別子: `TODO: aot-object-to-primitive`、`TODO: aot-function-string-name`

## AOTへのネイティブplugin

- 公式実測・source根拠: 公式TypeScript pluginはoracle側の命令登録です。外部native pluginをAOT配布物へ静的に組み込むことは、公式互換証拠とは別の製品機能です。
- lnakoの現在動作: `lnako_plugin_v1` のdynamic loader、`run`、`test` ABIを実装・検証しています。AOTではJavaScriptを使わず、既存のZig runtimeとhost callbackを利用します。
- 判定: 未実装（AOT静的組み込み）
- 対象経路: Interpreter / AOT
- 差分テストID: `check_native_plugin_abi`
- TODO識別子: `TODO: aot-native-plugin-static-bundle`

## 3 OS attestation

- 公式実測・source根拠: macOS arm64、Linux x86_64 GNU、Windows x86_64 MSVCは別toolchain・別OS状態を持つため、1環境のtraceから他OSの実行を推定できません。
- lnakoの現在動作: CIで3 OSのAOT artifact、partition、provenanceを別々に検証し、後段でattestationします。canonical `evidence.json`へCI実行の署名を自動転記しません。
- 判定: 証拠運用上の意図的制限
- 対象経路: AOT
- 差分テストID: `check_dispatch_attestation_security`、`check_tracked_dispatch_attestation`
- TODO識別子: なし

「AOT fixtureあり」「artifactあり」「native分類」は、3 OS attestation済みや全527 entryの純LLVM AOT証明を意味しません。証拠の読み方は [`../COMPATIBILITY_EVIDENCE.md`](../COMPATIBILITY_EVIDENCE.md) を参照してください。
