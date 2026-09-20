import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(await readFile(resolve(root, "compat/v3.7.24/standard-cnako.json"), "utf8"));
const defaultPlugins = [
  "plugin_system",
  "plugin_math",
  "plugin_promise",
  "plugin_test",
  "plugin_csv",
  "plugin_toml",
  "plugin_node",
];
const defaultNames = [];
const seenDefaultNames = new Set();
for (const plugin of defaultPlugins) {
  const pluginNames = catalog.commands.filter((command) => command.plugin === plugin).map((command) => command.name);
  if (plugin === "plugin_test") pluginNames.push("ASSERT等", "テスト実行", "テスト等");
  if (plugin === "plugin_node") pluginNames.push("AJAX:ONERROR");
  for (const name of pluginNames) {
    if (name.startsWith("__") || name.startsWith("!") || name === "meta" || seenDefaultNames.has(name)) continue;
    seenDefaultNames.add(name);
    defaultNames.push({ name });
  }
}

// `args`は助詞の異表記を`/`で連結したカタログ表記である。
// 通常は大文字の仮引数名の重複を除けば引数スロット数になるが、
// `OBJ{ [KEY}`のようなオブジェクト引数内のKEYは外側の1スロットに含め、
// コールバック仮引数の`CALLBACK(F`表記（`標準入力取得時`）も外側の1スロットに含める。
function normalizedArgumentNotation(args) {
  return args.replace(/[A-Z][A-Z0-9_]*\s*\{[^}]*\}/g, "").replace(/\([A-Z][A-Z0-9_]*\)?/g, "");
}

function argumentNames(args) {
  const objectArguments = args.match(/[A-Z][A-Z0-9_]*\s*\{[^}]*\}/g) ?? [];
  const normalized = normalizedArgumentNotation(args);
  const names = [...new Set(normalized.match(/[A-Z][A-Z0-9_]*/g) ?? [])];
  const objectNames = [...new Set(objectArguments.map((argument) => argument.match(/^[A-Z][A-Z0-9_]*/)?.[0]))].filter(Boolean);
  return names.concat(objectNames.map((name) => `__object_argument_${name}`));
}

// 助詞スロット表では、オブジェクト引数は波括弧の中だけを取り除いて外側の引数名と
// 助詞を1スロットとして残す（`OBJ{ [KEY}を` → `OBJを`。`CSVオプション設定`）。
function normalizedJosiNotation(args) {
  return args.replace(/\{[^}]*\}/g, "").replace(/\([A-Z][A-Z0-9_]*\)?/g, "");
}

// `args`から助詞スロット表を作る。異表記は`/`区切りで、名前の並びは最長variantの
// 部分列になっている（例: `置換`の`SでAからBへ`は`SのAをBに`と同スロット数の異表記、
// `文字抜出`の`SのCNT`は`SでAからCNTを`の部分列）。整列できない定義は補完対象外にする。
function josiSlots(args) {
  const variants = args.split("/").map((variant) => {
    const entries = [];
    // 仮引数名は`_TOKEN`のようにアンダースコアで始まることがあるため名前側で受理し、
    // 助詞側ではアンダースコアを受理しない（`_TOKENへ`が`TOKEN`＋`へ_`にならないようにする）。
    for (const match of normalizedJosiNotation(variant).matchAll(/(_?[A-Z][A-Z0-9_]*)([^A-Z_]*)/g)) {
      // `...A`は可変長引数の印で、直前の助詞へ混ざるため助詞から取り除く。
      entries.push({ name: match[1], josi: match[2].replace(/\.\.\./g, "") });
    }
    return entries;
  });
  if (variants.length === 0) return null;
  const canonical = variants.reduce((a, b) => (b.length > a.length ? b : a));
  const names = canonical.map((entry) => entry.name);
  if (names.length === 0) return null;
  const slots = names.map(() => []);
  for (const variant of variants) {
    let cursor = -1;
    const mapping = [];
    for (const entry of variant) {
      const index = names.indexOf(entry.name, cursor + 1);
      if (index < 0) return null; // 部分列として整列できない定義は補完しない
      mapping.push(index);
      cursor = index;
    }
    for (const [offset, entry] of variant.entries()) {
      const slot = slots[mapping[offset]];
      if (!slot.includes(entry.josi)) slot.push(entry.josi);
    }
  }
  // 助詞を1つも持たないスロットは助詞なしの末尾値を受理する。
  for (const slot of slots) if (slot.length === 0) slot.push("");
  return { slots, variable: args.includes("...") };
}

const arityEntries = [];
const arityByName = new Map();
for (const command of catalog.commands) {
  if (command.type !== "関数") continue;
  const entry = {
    name: command.name,
    count: argumentNames(command.args).length,
    isVariable: command.args.includes("..."),
  };
  const existing = arityByName.get(entry.name);
  if (existing) {
    if (existing.count !== entry.count || existing.isVariable !== entry.isVariable) {
      throw new Error(`同名関数の引数定義が一致しません: ${entry.name}`);
    }
  } else {
    arityByName.set(entry.name, entry);
    arityEntries.push(entry);
  }
}

// `zig fmt`は要素が1つの配列リテラルの内側空白を削るため、生成時から合わせる。
function zigArray(values) {
  return values.length === 1 ? `&.{${values[0]}}` : `&.{ ${values.join(", ")} }`;
}

const josiEntries = [];
const josiByName = new Map();
for (const command of catalog.commands) {
  if (command.type !== "関数") continue;
  const parsed = josiSlots(command.args);
  if (!parsed) continue;
  const starts = [];
  const josi = [];
  for (const slot of parsed.slots) {
    starts.push(josi.length);
    josi.push(...slot);
  }
  const entry = { name: command.name, starts, josi, isVariable: parsed.variable };
  const existing = josiByName.get(entry.name);
  if (existing) {
    // 同名で別プラグインに定義がある命令は、助詞の異表記をスロット単位で統合する
    // （`ファイル名抽出`は`DIRの`と`Sから`の2定義がある）。
    if (existing.starts.length !== entry.starts.length) {
      throw new Error(`同名関数の助詞スロット数が一致しません: ${entry.name}`);
    }
    const ranges = (starts, josi) =>
      starts.map((start, index) => [start, index + 1 < starts.length ? starts[index + 1] : josi.length]);
    const current = ranges(existing.starts, existing.josi);
    const other = ranges(entry.starts, entry.josi);
    const mergedStarts = [];
    const mergedJosi = [];
    for (const index of current.keys()) {
      mergedStarts.push(mergedJosi.length);
      for (const [start, end] of [current[index], other[index]]) {
        for (const value of existing.josi.slice(start, end).concat(entry.josi.slice(start, end))) {
          if (!mergedJosi.includes(value)) mergedJosi.push(value);
        }
      }
    }
    existing.starts = mergedStarts;
    existing.josi = mergedJosi;
    existing.isVariable = existing.isVariable || entry.isVariable;
  } else {
    josiByName.set(entry.name, entry);
    josiEntries.push(entry);
  }
}
const functionNames = [];
const seenFunctionNames = new Set();
for (const command of catalog.commands) {
  if (command.type !== "関数" || seenFunctionNames.has(command.name)) continue;
  seenFunctionNames.add(command.name);
  functionNames.push(command.name);
}

const lines = [
  "const std = @import(\"std\");",
  "",
  "/// なでしこ3 v3.7.24の標準cnako命令名。tools/sync_compat.mjsの固定データから生成。",
  "pub const names = [_][]const u8{",
  ...catalog.commands.map((command) => `    ${JSON.stringify(command.name)},`),
  "};",
  "",
  "/// C風呼び出しの引数個数。standard-cnako.jsonの関数定義から生成。",
  "pub const BuiltinArity = struct {",
  "    name: []const u8,",
  "    count: usize,",
  "    is_variable: bool,",
  "};",
  "",
  "pub const arities = [_]BuiltinArity{",
  ...arityEntries.map((entry) => `    .{ .name = ${JSON.stringify(entry.name)}, .count = ${entry.count}, .is_variable = ${entry.isVariable} },`),
  "};",
  "",
  "/// 公式の`func token`に相当する命令名（カタログ種別が「関数」のもの）。",
  "/// パーサは助詞付きのこの名前を、公式`yCallFunc`と同じく連鎖呼出しとして解決する。",
  "/// `定数`（`回数`など）は変数として使われるため含めない。",
  "pub const function_names = [_][]const u8{",
  ...functionNames.map((name) => `    ${JSON.stringify(name)},`),
  "};",
  "",
  "pub fn findArity(name: []const u8) ?BuiltinArity {",
  "    for (arities) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;",
  "    return null;",
  "}",
  "",
  "/// 公式cnako3が既定で読み込む7プラグインの公開システム変数名。",
  "pub const default_names = [_][]const u8{",
  ...defaultNames.map((command) => `    ${JSON.stringify(command.name)},`),
  "};",
  "",
];
// 助詞スロット表は組み込み命令索引より大きいため、別の生成ファイルへ分ける
// （`tools/source_structure.json`の1ファイル上限を守る）。
const josiLines = [
  "const std = @import(\"std\");",
  "",
  "/// 助詞呼出しの引数スロット定義。standard-cnako.jsonの`args`表記から生成する。",
  "/// スロット`i`の助詞異表記は`josi[slot_starts[i]..next]`（末尾は`josi.len`）で、",
  "/// 空文字列の異表記は助詞なしの末尾値を表す。`is_variable`の最終スロットは",
  "/// 可変長引数で、値が無くても「それ」補完しない。",
  "pub const BuiltinJosi = struct {",
  "    name: []const u8,",
  "    slot_starts: []const usize,",
  "    josi: []const []const u8,",
  "    is_variable: bool,",
  "};",
  "",
  "pub const josi_table = [_]BuiltinJosi{",
  ...josiEntries.map((entry) =>
    `    .{ .name = ${JSON.stringify(entry.name)}, .slot_starts = ${zigArray(entry.starts.map(String))}, ` +
    `.josi = ${zigArray(entry.josi.map((josi) => JSON.stringify(josi)))}, ` +
    `.is_variable = ${entry.isVariable} },`),
  "};",
  "",
  "pub fn findJosi(name: []const u8) ?BuiltinJosi {",
  "    for (josi_table) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;",
  "    return null;",
  "}",
  "",
];
const outputs = [
  { path: resolve(root, "src/semantic/builtin_catalog.zig"), expected: lines.join("\n"), label: "組み込み命令索引" },
  { path: resolve(root, "src/semantic/builtin_josi.zig"), expected: josiLines.join("\n"), label: "助詞スロット表" },
];
const generate = process.argv.includes("--generate");
for (const output of outputs) {
  if (generate) {
    await writeFile(output.path, output.expected);
    continue;
  }
  const actual = await readFile(output.path, "utf8");
  if (actual !== output.expected) throw new Error(`${output.label}がstandard-cnako.jsonと一致しません`);
}
if (catalog.commands.length !== 527) throw new Error(`組み込み命令数が527件ではありません: ${catalog.commands.length}`);
if (defaultNames.length !== 478) throw new Error(`既定システム変数名が478件ではありません: ${defaultNames.length}`);
console.log(`${generate ? "生成" : "検証"}しました: 組み込み命令索引527件（既定478件）・助詞スロット${josiEntries.length}件`);
