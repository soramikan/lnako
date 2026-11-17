// `--compat-js` AOTの成果物分離を検査する。
//
// 通常AOT成果物にQuickJS/compat ABIが混入しないこと、compat AOT成果物には
// QuickJSとESM manifestが収録され、`JS実行` からESM moduleを呼べることを
// 実際の生成物（シンボルと実行結果）で確認する。Issue #55の最小スライス。
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = parseArguments(process.argv.slice(2));
const compiler = resolveCompiler(args.compiler ?? join(root, "zig-out", "bin", "lnako"));
const runtimeLib = resolveRuntimeLib(args["runtime-lib"], "lnako_runtime.lib", "liblnako_runtime.a", "通常AOT runtime library");
const runtimeCompatLib = resolveRuntimeLib(args["runtime-compat-lib"], "lnako_runtime_compat.lib", "liblnako_runtime_compat.a", "compat AOT runtime library");
const nm = resolveNm(args.nm);
const work = mkdtempSync(join(tmpdir(), "lnako-aot-quickjs-"));
let failed = false;

try {
  const modulePath = join(work, "mod.mjs");
  writeFileSync(modulePath, "export function add(a, b) { return a + b; }\n");
  const normalSource = join(work, "normal.nako3");
  writeFileSync(normalSource, "1+2を表示\n");
  const compatSource = join(work, "compat.nako3");
  writeFileSync(
    compatSource,
    `!「mod.mjs」を取り込む\nJS実行("import('${modulePath.replaceAll("\\", "/")}').then(m => m.add(2,3))")を表示\n`,
  );

  const normalBinary = join(work, "normal");
  const compatBinary = join(work, "compat");
  runCompiler(normalSource, normalBinary, []);
  runCompiler(compatSource, compatBinary, ["--compat-js", "--backend", "aot"]);

  const normalOutput = runBinary(normalBinary);
  expectEqual(normalOutput, "3", "通常AOTの実行結果");
  // 生成物の起動時ESM登録だけを検証するため、実行前にmoduleファイルを退避する。
  // QuickJSのmodule_loaderは未登録名をFSから読むfallbackを持つため、ファイルが
  // 残っているとmanifest登録が壊れていても通ってしまう。
  const parkedModule = `${modulePath}.parked`;
  renameSync(modulePath, parkedModule);
  try {
    const compatOutput = runBinary(compatBinary);
    expectEqual(compatOutput, "5", "compat AOTのESM呼出し結果（manifest登録経由）");
  } finally {
    renameSync(parkedModule, modulePath);
  }

  const normalSymbols = listSymbols(normalBinary);
  for (const forbidden of ["lnako_qjs_", "lnako_aot_compat_", "lnako.compat.esm.manifest"]) {
    if (normalSymbols.some((symbol) => symbol.includes(forbidden))) {
      fail(`通常AOT成果物に ${forbidden} が混入しています`);
    }
  }
  const compatSymbols = listSymbols(compatBinary);
  for (const required of ["lnako_qjs_", "lnako_aot_compat_js_eval", "lnako.compat.esm.manifest"]) {
    if (!compatSymbols.some((symbol) => symbol.includes(required))) {
      fail(`compat AOT成果物に ${required} がありません`);
    }
  }
  const compatBytes = readFileSync(compatBinary);
  if (!compatBytes.includes(Buffer.from("export function add"))) {
    fail("compat AOT成果物にESM sourceが収録されていません");
  }
  if (!compatBytes.includes(Buffer.from(modulePath))) {
    fail("compat AOT成果物にESM identity（path）が収録されていません");
  }

  // `JS関数実行`: AOTとインタプリタが同じfixtureで同じstdoutを返すこと。
  // 引数（プリミティブと浅い配列/辞書）と戻り値の最小変換を固定する。
  const functionCallFixture = join(root, "tests", "fixtures", "compat-js-function-call.nako3");
  const interpreterCall = spawnSync(compiler, ["run", functionCallFixture, "--compat-js"], { encoding: "utf8" });
  if (interpreterCall.status !== 0) {
    fail(`JS関数実行fixtureのインタプリタ実行が失敗しました: ${interpreterCall.stdout}${interpreterCall.stderr}`);
  }
  const functionCallBinary = join(work, "compat-js-function-call");
  runCompiler(functionCallFixture, functionCallBinary, ["--compat-js", "--backend", "aot"]);
  const functionCallSymbols = listSymbols(functionCallBinary);
  if (!functionCallSymbols.some((symbol) => symbol.includes("lnako_aot_compat_js_call"))) {
    fail("JS関数実行のcompat AOT成果物に lnako_aot_compat_js_call がありません");
  }
  const functionCallOutput = runBinary(functionCallBinary);
  expectEqual(functionCallOutput, interpreterCall.stdout.trim(), "JS関数実行のAOT/インタプリタ一致");
  expectEqual(
    functionCallOutput,
    "0\n3\n5\n3\nx!\n1\n0\n1\n1\n3\n0\n30\n0\n5\n1,2\n\n[object Object]\n[object Object]\na,true,\n3\n1,2\n{\"x\":10}\ns\ntrue\nnull\nundefined",
    "JS関数実行の最小変換結果（戻り値の配列・辞書・Promise解決値を含む）",
  );

  // compat AOT の dispatch trace: `JS関数実行` も AOT の dispatch 列に載ること
  // （#55 の残ゲート）。trace 無効時と同じ出力であることと、route 名・
  // opcode・success を固定する。
  const functionCallTrace = join(work, "compat-js-function-call-trace.jsonl");
  const tracedRun = spawnSync(functionCallBinary, [], {
    encoding: "utf8",
    env: { ...process.env, LNAKO_DISPATCH_TRACE: functionCallTrace },
  });
  if (tracedRun.status !== 0) {
    fail(`trace有効実行が異常終了しました: status=${tracedRun.status}\n${tracedRun.stdout ?? ""}${tracedRun.stderr ?? ""}`);
  }
  expectEqual((tracedRun.stdout ?? "").trim(), functionCallOutput, "trace有効時もJS関数実行の出力が一致");
  const traceEvents = readTraceLines(functionCallTrace);
  const jsResults = traceEvents.filter((event) => event.phase === "dispatch-result" && event.route === "JS関数実行");
  if (jsResults.length === 0) fail("compat AOTのdispatch traceにJS関数実行が記録されていません");
  if (!jsResults.every((event) => event.opcode === 65535)) fail(`compat AOTのJS関数実行 opcodeが65535以外です: ${JSON.stringify(jsResults[0])}`);
  if (!jsResults.every((event) => event.engine === "aot")) fail("compat AOTのtraceイベントのengineがaotではありません");
  if (!jsResults.some((event) => event.success === true)) fail("compat AOTのJS関数実行にsuccess=trueのresultがありません");
  // `JS実行` も trace に載る（fixture は JS実行 を含む）。
  const evalResults = traceEvents.filter((event) => event.phase === "dispatch-result" && event.route === "JS実行");
  if (evalResults.length === 0) fail("compat AOTのdispatch traceにJS実行が記録されていません");

  // Issue #55 Unit 2: Nako→JS callback（hostFunction / hostInvoke）のE2E。
  // NakoクロージャをJS関数値へ直接・`{cb: fn}`・`[fn]` で渡し、Promise.then と
  // GC誘発ループを挟んでもcaptureが更新されること、BigInt・循環オブジェクト・
  // 配列/辞書が往復することを、AOT/interpreterの完全一致で固定する。
  const nakoCallbackFixtures = [
    [
      "Nako callback（高階・Promise・GC）",
      "compat-js-nako-callback.nako3",
      "33\n2\n10\n4\n22\n6\n17\n7\n15\n8",
    ],
    [
      "Nako callback（BigInt・循環・配列/辞書）",
      "compat-js-nako-callback-values.nako3",
      "9007199254740994\n42\ntrue\n2,42\n1,99\n[object Object]\n1,42\n1,99\n[object Object]",
    ],
  ];
  for (const [index, [label, fixture, expected]] of nakoCallbackFixtures.entries()) {
    const fixturePath = join(root, "tests", "fixtures", fixture);
    const interpreterCallback = spawnSync(compiler, ["run", fixturePath, "--compat-js"], { encoding: "utf8" });
    if (interpreterCallback.status !== 0) {
      fail(`${label}fixtureのインタプリタ実行が失敗しました: ${interpreterCallback.stdout}${interpreterCallback.stderr}`);
    }
    const callbackBinary = join(work, `compat-js-nako-callback-${index}`);
    runCompiler(fixturePath, callbackBinary, ["--compat-js", "--backend", "aot"]);
    const callbackSymbols = listSymbols(callbackBinary);
    for (const required of ["lnako_qjs_host_function", "lnako_aot_compat_js_call"]) {
      if (!callbackSymbols.some((symbol) => symbol.includes(required))) {
        fail(`${label}のcompat AOT成果物に ${required} がありません`);
      }
    }
    const callbackOutput = runBinary(callbackBinary);
    expectEqual(callbackOutput, interpreterCallback.stdout.trim(), `${label}のAOT/インタプリタ一致`);
    expectEqual(callbackOutput, expected, `${label}の期待出力`);
  }

  // `JSオブジェクト取得` / `JSメソッド実行`: JS関数実行が返した配列/辞書を
  // external binding（JS参照）として保持し、AOTとインタプリタが同じ結果を返すこと。
  const objectFixture = join(root, "tests", "fixtures", "compat-js-object-binding.nako3");
  const interpreterObject = spawnSync(compiler, ["run", objectFixture, "--compat-js"], { encoding: "utf8" });
  if (interpreterObject.status !== 0) {
    fail(`JSオブジェクト取得/JSメソッド実行fixtureのインタプリタ実行が失敗しました: ${interpreterObject.stdout}${interpreterObject.stderr}`);
  }
  const objectBinary = join(work, "compat-js-object-binding");
  runCompiler(objectFixture, objectBinary, ["--compat-js", "--backend", "aot"]);
  const objectSymbols = listSymbols(objectBinary);
  for (const required of ["lnako_aot_compat_js_object_get", "lnako_aot_compat_js_method_call"]) {
    if (!objectSymbols.some((symbol) => symbol.includes(required))) {
      fail(`JSオブジェクト取得/JSメソッド実行のcompat AOT成果物に ${required} がありません`);
    }
  }
  const objectOutput = runBinary(objectBinary);
  expectEqual(objectOutput, interpreterObject.stdout.trim(), "JSオブジェクト取得/JSメソッド実行のAOT/インタプリタ一致");
  expectEqual(
    objectOutput,
    "10\n1\n1-2\n1-2-3\n7\n5\n1\n9\na\n8\n2\n1-3\ntrue\n5\n1,2,9\n2\n1\n20\ntrue\ntrue\n1,,3\ntrue\n1\nfalse\n7\n1\nundefined\ntrue",
    "JSオブジェクト取得/JSメソッド実行のexternal binding結果",
  );

  // external bindingを持たない値のうち、共有変換規則でJSへ渡せないものは
  // AOT/interpreterが同じ文言で明示エラーになること。
  const unsupportedObjectCases = [
    ["JSオブジェクト取得の関数レシーバ", "F=関数(A)それはA;ここまで\nJSオブジェクト取得(F,\"x\")を表示\n", "JSオブジェクト取得 does not support"],
    ["JSオブジェクト取得のBigIntレシーバ", 'JSオブジェクト取得(JS実行("1n"),"x")を表示\n', "JSオブジェクト取得 does not support"],
    ["JSオブジェクト取得のbytesレシーバ", 'B=3のランダム配列生成\nJSオブジェクト取得(B,"0")を表示\n', "JSオブジェクト取得 does not support"],
    ["JSオブジェクト取得のコンテナ内bytes", 'B=3のランダム配列生成\nJSオブジェクト取得([B],"0")を表示\n', "JSオブジェクト取得 does not support"],
    ["JSオブジェクト取得のコンテナ内BigInt", 'JSオブジェクト取得(JS実行("[1n]"),"0")を表示\n', "JSオブジェクト取得 does not support"],
    ["JSメソッド実行のBigIntレシーバ", 'JSメソッド実行(JS実行("1n"),"toString",[])を表示\n', "JSメソッド実行 does not support"],
    ["JSメソッド実行の関数レシーバ", "F=関数(A)それはA;ここまで\nJSメソッド実行(F,\"x\",[])を表示\n", "JSメソッド実行 does not support"],
    ["JSメソッド実行の関数実引数", 'JSメソッド実行("[1,2]","join",[関数(A)それはA;ここまで])を表示\n', "JSメソッド実行 does not support"],
    ["JSオブジェクト取得の3引数", 'JSオブジェクト取得("[1,2]","0","x")を表示\n', "JSオブジェクト取得 accepts a value and a property name only"],
    ["JSオブジェクト取得の0引数", 'JSオブジェクト取得()を表示\n', "JSオブジェクト取得 requires a value and a property name"],
    ["JSメソッド実行の関数戻り値", 'JSメソッド実行(『({f(){return ()=>{}}})』,"f",[])を表示\n', "JSメソッド実行 does not support"],
    ["JSメソッド実行のPromise戻り値", 'JSメソッド実行(『({f(){return Promise.resolve(1)}})』,"f",[])を表示\n', "JSメソッド実行 does not support"],
    ["JSメソッド実行の巨大length戻り値", 'JSメソッド実行(『({f(){const a=[];a.length=10000000;return a}})』,"f",[])を表示\n', "QuickJsCollectionTooLarge"],
    ["JSメソッド実行のbytesレシーバ", 'B=3のランダム配列生成\nA=JS関数実行("()=>[1]",[])\nA[0]=B\nJSメソッド実行(A,"join",["-"])を表示\n', "JSメソッド実行 does not support"],
    ["JSメソッド実行のコンテナ内bytes", 'B=3のランダム配列生成\nJSメソッド実行("[1,2]","join",[[B]])を表示\n', "JSメソッド実行 does not support"],
    ["JSメソッド実行の深い戻り値", 'JSメソッド実行(『({deep(){let o={};for(let i=0;i<70;i++)o={a:o};return o}})』,"deep",[])を表示\n', "QuickJsNestingTooDeep"],
  ];
  for (const [index, [label, source, expected]] of unsupportedObjectCases.entries()) {
    const unsupportedSource = join(work, `compat-js-unsupported-object-${index}.nako3`);
    writeFileSync(unsupportedSource, source);
    const unsupportedBinary = join(work, `compat-js-unsupported-object-${index}`);
    runCompiler(unsupportedSource, unsupportedBinary, ["--compat-js", "--backend", "aot"]);
    const aot = spawnSync(unsupportedBinary, [], { encoding: "utf8" });
    const interpreter = spawnSync(compiler, ["run", unsupportedSource, "--compat-js"], { encoding: "utf8" });
    for (const [kind, result] of [["AOT", aot], ["インタプリタ", interpreter]]) {
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      if (result.status === 0 || !output.includes(expected)) {
        fail(`${label}が${kind}で明示エラーになりません: status=${result.status}\n${output}`);
      }
    }
  }

  // Issue #55 Unit 2: `JSオブジェクト取得` の1引数形（公式のグローバル名解決）は
  // AOTでも変数フレーム・動的グローバル・名前付き関数・システム定数を解決し、
  // interpreterと完全一致する。QuickJSのglobalThisへはフォールバックしない
  // （`JSオブジェクト取得("Math")` はnull）。ローカル・クロージャ・
  // シャドーイング・未束縛ローカルのフォールバック・`それ`・例外巻戻し後の
  // 外側ローカル・名前付き関数＋`JS関数実行`・システム定数・falsyの規則を
  // 1つのfixtureで固定する。
  const objectGetNameFixtures = [
    [
      "JSオブジェクト取得の1引数形（公式quirks）",
      "compat-js-find-quirks.nako3",
      "null\nnull\nnull\nnull\nnull",
    ],
    [
      "JSオブジェクト取得の1引数形（basic fixture）",
      "compat-js-basic.nako3",
      "3\n[1,2,{\"x\":3}]\n5\n7\n5\n8\n123456789012345678901234567890",
    ],
    [
      "JSオブジェクト取得の1引数形（ローカル・クロージャ・それ・例外・定数）",
      "compat-js-object-get-name.nako3",
      "10\n20\n3\n3\n2\n5\n1\n6\ncaught\n6\n7\n15\n42\ntrue\n3.141592653589793\n3.7.24\ncnako3\nnull\nnull\nnull\nnull\nnull\nnull\nnull",
    ],
  ];
  for (const [index, [label, fixture, expected]] of objectGetNameFixtures.entries()) {
    const fixturePath = join(root, "tests", "fixtures", fixture);
    const interpreter = spawnSync(compiler, ["run", fixturePath, "--compat-js"], { encoding: "utf8" });
    if (interpreter.status !== 0) {
      fail(`${label}fixtureのインタプリタ実行が失敗しました: ${interpreter.stdout}${interpreter.stderr}`);
    }
    const binary = join(work, `compat-js-object-get-name-${index}`);
    runCompiler(fixturePath, binary, ["--compat-js", "--backend", "aot"]);
    const output = runBinary(binary);
    expectEqual(output, interpreter.stdout.trim(), `${label}のAOT/インタプリタ一致`);
    expectEqual(output, expected, `${label}の期待出力`);
  }
  // AOTの `●DefAdd`（def_function）は同一の登録済みClosureを返すため、`===` が真になる
  // （設計書 §5.1(2) / 公式cnako3準拠）。
  const defIdentitySource = join(work, "compat-js-def-identity.nako3");
  writeFileSync(
    defIdentitySource,
    '●DefAdd(AとBを)\n  それはA+B\nここまで\n(JSオブジェクト取得("DefAdd") === JSオブジェクト取得("DefAdd"))を表示\nJS関数実行(JSオブジェクト取得("DefAdd"),[4,9])を表示\n',
  );
  const defIdentityBinary = join(work, "compat-js-def-identity");
  runCompiler(defIdentitySource, defIdentityBinary, ["--compat-js", "--backend", "aot"]);
  expectEqual(runBinary(defIdentityBinary), "true\n13", "AOTの名前付き関数(def_function)同一性と呼出し");
  // 1引数形の解決対象が無い場合の0引数・3引数以上の引数エラーは、上の
  // `unsupportedObjectCases` でAOT/interpreter両方の明示エラーを固定済み。
  // このfixtureは cnako3 との3者比較には含めない: cnako3 3.7.24 の
  // `__findVar` は外側クロージャのローカルと `__v0` のシステム定数を探索せず、
  // 数値引数では例外になるため（3者比較は tools/compare_compat_js_oracle.mjs）。

  // Issue #55 Unit 3: QuickJS ホスト変数bridge（`sys.__getSysVar` /
  // `sys.__findVar` / `sys.__setSysVar` / `sys.__getSore` / `sys.__setSore`）。
  // `compat-js-var-bridge.nako3` は cnako3/interpreter/AOT の3者一致fixtureで、
  // ここでは interpreter と AOT の一致・期待出力を固定する（公式比較は
  // tools/compare_compat_js_oracle.mjs）。
  // `compat-js-var-bridge-lnako.nako3` は cnako3 3.7.24 が関数内ローカルを
  // `sys.__findVar` で解決せず、無修飾 `__setSysVar` の値を無修飾
  // `__findVar` で見ないため2者一致fixtureとして分離している。
  const variableBridgeFixtures = [
    [
      "ホスト変数bridge（3者一致）",
      "compat-js-var-bridge.nako3",
      "missing\n5\n99\ndefault\ndefault\nfallback\n9\n9\nok\nmiss\n123\n123\n123\n0\n3.7.24\ncnako3\n13\nfunction\n77\n77\nbigint",
    ],
    [
      "ホスト変数bridge（ローカル・無修飾setSysVarのlnako契約）",
      "compat-js-var-bridge-lnako.nako3",
      "1\n43\n1\nok\n123\n123\n123\n1",
    ],
  ];
  for (const [index, [label, fixture, expected]] of variableBridgeFixtures.entries()) {
    const fixturePath = join(root, "tests", "fixtures", fixture);
    const interpreter = spawnSync(compiler, ["run", fixturePath, "--compat-js"], { encoding: "utf8" });
    if (interpreter.status !== 0) {
      fail(`${label}fixtureのインタプリタ実行が失敗しました: ${interpreter.stdout}${interpreter.stderr}`);
    }
    const binary = join(work, `compat-js-var-bridge-${index}`);
    runCompiler(fixturePath, binary, ["--compat-js", "--backend", "aot"]);
    const output = runBinary(binary);
    expectEqual(output, interpreter.stdout.trim(), `${label}のAOT/インタプリタ一致`);
    expectEqual(output, expected, `${label}の期待出力`);
  }

  // Issue #55 レビュー回帰: `.binary`（減算）の ToPrimitive はオブジェクトの
  // JS `valueOf` を呼び得る。その中から `sys.__findVar` で関数ローカルを
  // 解決できるよう、AOT は `.binary` を含む関数でも `AotVarFrame` を省略
  // しない。フレーム省略時は fallback の -1 が使われ `-2` になる。
  const valueOfFixture = join(root, "tests", "fixtures", "compat-js-valueof-findvar.nako3");
  const valueOfInterpreter = spawnSync(compiler, ["run", valueOfFixture, "--compat-js"], { encoding: "utf8" });
  if (valueOfInterpreter.status !== 0) {
    fail(`valueOf変数解決fixtureのインタプリタ実行が失敗しました: ${valueOfInterpreter.stdout}${valueOfInterpreter.stderr}`);
  }
  const valueOfBinary = join(work, "compat-js-valueof-findvar");
  runCompiler(valueOfFixture, valueOfBinary, ["--compat-js", "--backend", "aot"]);
  const valueOfOutput = runBinary(valueOfBinary);
  expectEqual(valueOfOutput, valueOfInterpreter.stdout.trim(), "valueOfからのローカル解決のAOT/インタプリタ一致");
  expectEqual(valueOfOutput, "6", "valueOfからのローカル解決結果");

  // `sys.__exec`（組み込み命令の文字列dispatch）はAOTでもinterpreterと
  // 同じ結果になる。Unit 1 のコア命令ディスパッチを出力一致で固定する。
  const hostExecSource = join(work, "compat-js-host-exec.nako3");
  writeFileSync(hostExecSource, 'JS実行(『sys.__exec("整数変換",["12.9"])』)を表示\n');
  const hostExecInterpreter = spawnSync(compiler, ["run", hostExecSource, "--compat-js"], { encoding: "utf8" });
  expectEqual((hostExecInterpreter.stdout ?? "").trim(), "12", "sys.__execのinterpreter結果");
  const hostExecBinary = join(work, "compat-js-host-exec");
  runCompiler(hostExecSource, hostExecBinary, ["--compat-js", "--backend", "aot"]);
  const hostExecAot = spawnSync(hostExecBinary, [], { encoding: "utf8" });
  const hostExecOutput = `${hostExecAot.stdout ?? ""}${hostExecAot.stderr ?? ""}`;
  if (hostExecAot.status !== 0) {
    fail(`sys.__execのAOT実行が失敗しました: status=${hostExecAot.status}\n${hostExecOutput}`);
  }
  expectEqual((hostExecAot.stdout ?? "").trim(), "12", "sys.__execのAOT結果");

  // Issue #282 Unit 2: `sys.__exec` の Node / 非同期 / HTTP / プラグイン命令を
  // AOTとインタプリタの2者一致で固定する。`tests/fixtures/compat-js-host.nako3`
  // は evidence hash 保護のため変更せず、専用 fixture を新設している。
  // Promise 値そのものは QuickJS bridge を越えられないため、`動時` / `束` /
  // `成功時` の成功経路は compat_js_test.zig の単体テストが担当し、ここでは
  // 両経路が同じ InternalError になることを固定する。
  const hostExecParityFixtures = [
    [
      "sys.__execコア命令（ユーザ関数・ローカルシャドーイング・暗黙変数）",
      "compat-js-host-exec-core.nako3",
      "42\n12\n42\nhello\n42\n12\n42\nhello\n\nA\nB\n123\n123\n1\n3\n5\n9\n9",
    ],
    [
      "sys.__exec Node命令（ファイル・タイマー・Promise）",
      "compat-js-host-exec-node.nako3",
      "0\n0\ncopied.nako3\nInternalError\n上書き\ntrue\nstopped\nInternalError\nInternalError\nInternalError\ndeleted",
    ],
    [
      "sys.__exec再入（なでしこ関数→JS実行→sys.__exec・例外捕捉後の継続）",
      "compat-js-host-exec-reentrant.nako3",
      "7\n8\n11\ncaught:InternalError\nok",
    ],
    [
      "ESM plugin命令のsys.__exec（plugin内sys.__execからのビルトイン・別命令呼出し）",
      "compat-js-host-exec-plugin.nako3",
      "42\n42\nplugin\nplugin",
    ],
  ];
  for (const [index, [label, fixture, expected]] of hostExecParityFixtures.entries()) {
    const fixturePath = join(root, "tests", "fixtures", fixture);
    const interpreter = spawnSync(compiler, ["run", fixturePath, "--compat-js"], { encoding: "utf8" });
    if (interpreter.status !== 0) {
      fail(`${label}fixtureのインタプリタ実行が失敗しました: ${interpreter.stdout}${interpreter.stderr}`);
      continue;
    }
    const binary = join(work, `compat-js-host-exec-parity-${index}`);
    runCompiler(fixturePath, binary, ["--compat-js", "--backend", "aot"]);
    const output = runBinary(binary);
    expectEqual(output, interpreter.stdout.trim(), `${label}のAOT/インタプリタ一致`);
    expectEqual(output, expected, `${label}の期待出力`);
  }
  // plugin 命令は AOT codegen ではなく実行時 dispatch で解決されるため、
  // ESM plugin fixture の成果物にも compat ABI が含まれることを確認する。
  const pluginExecSymbols = listSymbols(join(work, "compat-js-host-exec-parity-3"));
  for (const required of ["lnako_qjs_", "lnako_aot_compat_js_eval"]) {
    if (!pluginExecSymbols.some((symbol) => symbol.includes(required))) {
      fail(`ESM pluginのsys.__exec成果物に ${required} がありません`);
    }
  }

  // `JS関数実行` の full 変換（ネスト配列・辞書、関数値、BigInt、bytes、循環、
  // 疎配列、Promise解決値）と、`JSオブジェクト取得` / `JSメソッド実行` の
  // 制限付き結果変換（ネスト配列・辞書、関数値、bytes、循環）を
  // AOT/interpreter の完全一致で固定する。
  const fullConversionFixtures = [
    [
      "JS関数実行のfull変換",
      "compat-js-full-conversion.nako3",
      "6\n42\nfunction\n2\n3\ntrue\n3:false\n1,2,[object Object]\n1\n42\n2\ntrue\n1,,3",
    ],
    [
      "JSオブジェクト取得/JSメソッド実行のfull変換",
      "compat-js-object-full.nako3",
      "1\n5\nfunction\n43\ntrue\n12",
    ],
  ];
  for (const [index, [label, fixture, expected]] of fullConversionFixtures.entries()) {
    const fixturePath = join(root, "tests", "fixtures", fixture);
    const interpreter = spawnSync(compiler, ["run", fixturePath, "--compat-js"], { encoding: "utf8" });
    if (interpreter.status !== 0) {
      fail(`${label}fixtureのインタプリタ実行が失敗しました: ${interpreter.stdout}${interpreter.stderr}`);
    }
    const binary = join(work, `compat-js-full-${index}`);
    runCompiler(fixturePath, binary, ["--compat-js", "--backend", "aot"]);
    const output = runBinary(binary);
    expectEqual(output, interpreter.stdout.trim(), `${label}のAOT/インタプリタ一致`);
    expectEqual(output, expected, `${label}の期待出力`);
  }

  // Promise戻り値は解決値をawaitする。rejectはreject理由、pendingはbridgeの
  // 文言で、AOT/interpreterが同じ明示エラーになること（無限待機しない）。
  // Nako Promiseを実引数に渡す経路はNakoスクリプトからPromise値を直接
  // 構築できないため、AOT/interpreter双方の単体テスト
  // （compat_js_test.zig / quickjs_test.zig）で固定する。
  const promiseFailureCases = [
    ["Promiseのreject", 'JS関数実行(『()=>Promise.reject(new Error("x"))』, [])を表示\n', "Error: x"],
    ["pendingのPromise", 'JS関数実行(『()=>new Promise(()=>{})』, [])を表示\n', "QuickJS promise is still pending"],
  ];
  for (const [index, [label, source, expected]] of promiseFailureCases.entries()) {
    const promiseFailureSource = join(work, `compat-js-promise-failure-${index}.nako3`);
    writeFileSync(promiseFailureSource, source);
    const promiseFailureBinary = join(work, `compat-js-promise-failure-${index}`);
    runCompiler(promiseFailureSource, promiseFailureBinary, ["--compat-js", "--backend", "aot"]);
    const aot = spawnSync(promiseFailureBinary, [], { encoding: "utf8" });
    const interpreter = spawnSync(compiler, ["run", promiseFailureSource, "--compat-js"], { encoding: "utf8" });
    for (const [kind, result] of [["AOT", aot], ["インタプリタ", interpreter]]) {
      const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
      if (result.status === 0 || !output.includes(expected)) {
        fail(`${label}が${kind}で明示エラーになりません: status=${result.status}\n${output}`);
      }
    }
  }

  // 既定の `--compat-js` は従来の同梱実行ファイル方式（embedded）へ戻っている。
  // AOT+QuickJSは `--backend aot` の明示opt-inであることを実行で固定する。
  const defaultCompatSource = join(work, "default-compat.nako3");
  writeFileSync(defaultCompatSource, 'JS実行("1+2")を表示\n');
  const defaultCompatBinary = join(work, "default-compat");
  runCompiler(defaultCompatSource, defaultCompatBinary, ["--compat-js"]);
  expectEqual(runBinary(defaultCompatBinary), "3", "既定compat-js（embedded）の実行結果");
  // 既定がAOTへ戻ると実行結果だけでは区別できないため、compat AOT専用ABIを
  // 持たないことも固定する。
  const defaultSymbols = listSymbols(defaultCompatBinary);
  for (const forbidden of ["lnako_aot_compat_js_eval", "lnako.compat.esm.manifest"]) {
    if (defaultSymbols.some((symbol) => symbol.includes(forbidden))) {
      fail(`既定compat-js（embedded）成果物に ${forbidden} が混入しています`);
    }
  }

  checkDistributionLayout(work);

  if (failed) process.exitCode = 1;
  else console.log("AOT QuickJS分離検査: 通常AOTはQuickJS非依存、compat AOTはQuickJS＋ESMを収録しESM呼出しに成功");
} finally {
  rmSync(work, { recursive: true, force: true });
}

function parseArguments(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--compiler" || argument === "--nm" || argument === "--runtime-lib" || argument === "--runtime-compat-lib") {
      index += 1;
      if (index >= argv.length) throw new Error(`${argument} の値がありません`);
      parsed[argument.slice(2)] = argv[index];
    } else {
      throw new Error(`不明な引数です: ${argument}`);
    }
  }
  return parsed;
}

function resolveCompiler(path) {
  const resolved = resolve(path);
  const candidates = process.platform === "win32" ? [resolved, `${resolved}.exe`] : [resolved];
  for (const candidate of candidates) {
    try {
      readFileSync(candidate);
      return candidate;
    } catch {}
  }
  throw new Error(`コンパイラが見つかりません: ${path}`);
}

function resolveRuntimeLib(explicit, windowsName, unixName, label) {
  const path = explicit ?? join(root, "zig-out", "lib", process.platform === "win32" ? windowsName : unixName);
  const resolved = resolve(path);
  try {
    readFileSync(resolved);
    return resolved;
  } catch {
    throw new Error(`${label}が見つかりません: ${path}`);
  }
}

/// 配布アーカイブを再現し、compat runtimeを同梱したレイアウトでは
/// `--compat-js --backend aot` が動き、同梱しないレイアウトでは明確なエラーに
/// なること、既定の `--compat-js`（embedded）がどちらでも動くことを固定する。
function checkDistributionLayout(work) {
  const compatSource = join(work, "distribution-compat.nako3");
  writeFileSync(compatSource, 'JS実行("1+2")を表示\n');
  const cleanEnv = { ...process.env };
  // 配布利用者と同じ探索（実行ファイル隣接の ../lib）を再現する。
  delete cleanEnv.LNAKO_AOT_RUNTIME_LIBRARY;
  delete cleanEnv.LNAKO_AOT_RUNTIME_LIBRARY_COMPAT;

  const withCompat = join(work, "distribution-with-compat");
  stageDistribution(withCompat, true);
  const compatOutput = join(work, "distribution-compat-aot");
  const aot = spawnSync(join(withCompat, "bin", compilerName()), ["build", compatSource, "-o", compatOutput, "--compat-js", "--backend", "aot"], { encoding: "utf8", env: cleanEnv });
  if (aot.status !== 0) fail(`compat runtime同梱レイアウトのAOTが失敗しました: ${aot.stdout}${aot.stderr}`);
  expectEqual(runBinary(compatOutput), "3", "配布レイアウト（compat runtime同梱）のAOT実行結果");

  const withoutCompat = join(work, "distribution-without-compat");
  stageDistribution(withoutCompat, false);
  const missingOutput = join(work, "distribution-compat-missing");
  const missing = spawnSync(join(withoutCompat, "bin", compilerName()), ["build", compatSource, "-o", missingOutput, "--compat-js", "--backend", "aot"], { encoding: "utf8", env: cleanEnv });
  if (missing.status === 0 || !missing.stderr.includes("AOTランタイム静的ライブラリを読み込めません")) {
    fail(`compat runtime非同梱レイアウトのAOTが明確なエラーになりません: ${missing.stdout}${missing.stderr}`);
  }

  for (const [label, staging] of [["同梱", withCompat], ["非同梱", withoutCompat]]) {
    const embeddedOutput = join(work, `distribution-embedded-${label}`);
    const embedded = spawnSync(join(staging, "bin", compilerName()), ["build", compatSource, "-o", embeddedOutput, "--compat-js"], { encoding: "utf8", env: cleanEnv });
    if (embedded.status !== 0) fail(`配布レイアウト（${label}）の既定compat-jsが失敗しました: ${embedded.stdout}${embedded.stderr}`);
    expectEqual(runBinary(embeddedOutput), "3", `配布レイアウト（${label}）の既定compat-js実行結果`);
  }
}

function compilerName() {
  return process.platform === "win32" ? "lnako.exe" : "lnako";
}

function stageDistribution(staging, includeCompat) {
  const binDir = join(staging, "bin");
  const libDir = join(staging, "lib");
  mkdirSync(binDir, { recursive: true });
  mkdirSync(libDir, { recursive: true });
  copyFileSync(compiler, join(binDir, compilerName()));
  copyFileSync(runtimeLib, join(libDir, process.platform === "win32" ? "lnako_runtime.lib" : "liblnako_runtime.a"));
  if (includeCompat) copyFileSync(runtimeCompatLib, join(libDir, process.platform === "win32" ? "lnako_runtime_compat.lib" : "liblnako_runtime_compat.a"));
}

function resolveNm(explicit) {
  if (explicit) return explicit;
  const candidates = [];
  if (process.env.LNAKO_LLVM_DIR) candidates.push(join(process.env.LNAKO_LLVM_DIR, "bin", "llvm-nm"));
  const toolchains = join(root, ".cache", "toolchains");
  try {
    for (const entry of readdirSync(toolchains)) {
      if (entry.startsWith("llvm-")) candidates.push(join(toolchains, entry, "bin", "llvm-nm"));
    }
  } catch {}
  candidates.push("llvm-nm", "nm");
  for (const candidate of candidates) {
    const probe = spawnSync(candidate, ["--version"], { encoding: "utf8" });
    if (probe.status === 0) return candidate;
  }
  throw new Error("nm/llvm-nmが見つかりません（--nmで指定してください）");
}

function runCompiler(source, output, extra) {
  const result = spawnSync(compiler, ["build", source, "-o", output, ...extra], { encoding: "utf8" });
  if (result.status !== 0) fail(`コンパイルに失敗しました: ${source}\n${result.stdout}${result.stderr}`);
}

/// dispatch trace（JSONL）を読む。trace が無い/壊れている場合は失敗させる。
function readTraceLines(path) {
  if (!existsSync(path)) fail(`dispatch traceが生成されませんでした: ${path}`);
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
}

function runBinary(path) {
  const result = spawnSync(path, [], { encoding: "utf8" });
  if (result.status !== 0 || typeof result.stdout !== "string") {
    fail(`実行に失敗しました: ${path}\n${result.stdout ?? ""}${result.stderr ?? ""}`);
    return "";
  }
  return result.stdout.trim();
}

function listSymbols(path) {
  const result = spawnSync(nm, ["-g", path], { encoding: "utf8" });
  if (result.status !== 0) fail(`シンボル一覧の取得に失敗しました: ${path}\n${result.stderr}`);
  return result.stdout.split("\n").map((line) => line.trim()).filter(Boolean);
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) fail(`${label}が一致しません: expected=${expected} actual=${actual}`);
}

function fail(message) {
  failed = true;
  console.error(`AOT QuickJS分離検査: ${message}`);
}
