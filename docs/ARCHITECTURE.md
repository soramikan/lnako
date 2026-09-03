# アーキテクチャ

## 全体の流れ

```text
なでしこソース
  -> 正規化・字句解析・助詞／インデント処理
  -> AST・構文／意味解析
  -> HIR
  -> Nako SSA IR・検証
  -> Interpreter または LLVM IR
  -> Zigランタイム／LLDで実行ファイル
```

通常モードの実行経路にJavaScript runtimeはありません。JavaScript固有の命令は、明示的な `--compat-js` を付けたQuickJS経路に限定します。

## コンポーネント

| 層 | 主な責務 |
| --- | --- |
| frontend | UTF-8入力の正規化、lexer、助詞、インデント、DNCL/DNCL2、位置付き診断 |
| AST/parser | 式・文・関数・例外・モジュールの構文木と構文エラー |
| semantic | 名前解決、型・scope、module取り込み、未対応機能の拒否 |
| HIR / Nako SSA IR | 制御フロー、値、関数、closure、例外、property、plugin呼出しの中間表現 |
| Interpreter | SSAを決定的に実行。公式差分テストの通常モード基準経路 |
| runtime values | binary64、UTF-16、BigInt、配列、挿入順辞書、Promise、timer、正確なGC |
| LLVM backend | IR検証、debug metadata、PassBuilder O0〜O3、TargetMachine、LLD |
| host/plugin | filesystem、process、encoding、HTTP、crypto、ZIPなどの純Zig adapter |
| QuickJS adapter | `--compat-js` の4命令とJS値変換。通常モードから分離 |

## 値とメモリ

ランタイムの文字列はUTF-16 code unitを保持し、Windowsのwide argvやunpaired surrogateも同じ表現で扱います。数値はbinary64、整数範囲を超える値はBigIntとして区別します。配列はholeとown propertyを区別し、辞書は挿入順を保持します。

ヒープ値は型付きrootを使うmark-and-sweep GCで管理します。Interpreterの一時値、AOTの生成値、Promiseやtimerの保留callbackがrootから外れるタイミングを追跡し、workerからGC値を直接参照しない設計にします。

## 実行経路

### Interpreter

Nako SSA IRを直接実行し、条件・反復・関数・closure・例外・動的実行・Promise・timerを処理します。公式sourceまたは公式生成JavaScriptと比較するfixtureは、実行結果だけでなく終了状態、stderr、必要なtraceを記録します。

### LLVM AOT

LLVM/LLD 22.1.8を使い、Nako SSA IRを検証してLLVM IRへ変換します。O0は元IRの動的変換を維持し、O1以上では独立複製したSSA IRへ安全な型推論・定数伝播・直接呼出し・dead code eliminationを適用します。生成実行ファイルはZig製のJS非依存ランタイムを静的リンクし、実行先にZig、LLVM、Node.jsを要求しません。

未対応IRは誤変換せず、命令名と元ソース位置を伴って拒否します。AOTの実行証拠とattestationの状態は [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md) の規則に従います。

### QuickJS

QuickJSは互換性境界を明示するための別経路です。4命令、9 case（成功6、期待失敗3）を `compat-js-evidence.json` で管理し、native dispatch evidenceへ合算しません。

## plugin

標準pluginは、命令登録・global binding・runtime route・AOT ABIを同じcatalog IDへ接続します。外部ネイティブ拡張向けの `lnako_plugin_v1` は、sync／async／pure属性、opaque値、Promise、host callbackを定義し、`run` / `test` 経路で検証します。

AOTへネイティブプラグインを静的に組み込んだ配布bundleは今後のTODOです。現在のdynamic loaderやAOT証拠を、その未実装範囲の代替として扱いません。

## 設計上の境界

- 公式TypeScriptはoracleと差分テスト生成にだけ使用し、製品ランタイムへ組み込みません。
- 通常モードからJavaScriptへfallbackしません。
- OS依存値、外部プロセス、ネットワーク、意図的終了・例外は、純粋な成功経路の証拠と分離します。
- 同名命令は表示名で推定せず、catalog ID、plugin、source siteを一組として扱います。
- 公式処理系の説明不足、バグ候補、意図的制限は [`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md) に記録します。
