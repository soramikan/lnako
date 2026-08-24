# アーキテクチャ

## コンパイルパイプライン

```text
source
  -> prepare / lexer / indentation / DNCL
  -> AST
  -> semantic HIR
  -> Nako SSA IR
  -> LLVM IR
  -> object
  -> LLD
  -> native executable
```

フロントエンド、言語非依存に近いNako IR、LLVMバックエンド、ランタイムを分離します。公式なでしこ3のTypeScript実装を実行時依存にせず、固定バージョンの公式処理系を差分テストのオラクルとして使用します。

## モジュール境界

- `frontend`: 正規化、字句解析、構文変換、AST、診断
- `semantic`: スコープ、命令解決、モジュール、HIR
- `ir`: SSA値、基本ブロック、型情報、検証
- `backend/llvm`: LLVM C API、最適化、TargetMachine
- `runtime`: Value、UTF-16文字列、GC、コレクション、例外、非同期
- `plugins`: 標準命令と `lnako_plugin_v1`
- `cli`: build/run/check/test/compat/benchmark

## フロントエンドの入力規約

- `frontend/source.zig` は改行、全角ASCII、句読点、演算記号を正規化し、文字列とコメントの内容を保持する。
- 正規化後の各UTF-8バイト位置から元入力のバイト位置へ戻せるソースマップを保持する。
- `frontend/lexer.zig` は数値・BigInt・文字列・演算子・予約語と助詞を位置情報付きトークンへ変換する。
- 助詞は最長一致で読み、`raw_josi` と意味上の `josi` を分離する。公式処理系との差分テストは
  `tools/compare_lexer_oracle.mjs` で固定バージョンのTypeScript実装へ直接照合する。
- `frontend/syntax_transform.zig` は明示インデント構文と行末コロンへ `ここまで` を補い、DNCL/DNCL2の
  代入、整数除算、制御構文、配列初期化、表示命令を標準トークンへ変換する。JSON内の改行は
  ブロック境界として扱わない。
- `frontend/ast.zig` は全ノードに開始・終了位置を持たせ、値、子ノード、関数引数、ループ方向を
  arena所有の共通表現として保持する。意味解析はこのASTをHIRへ変換する。
- `frontend/parser.zig` はPratt式パーサと再帰下降の文・ブロックパーサを組み合わせる。代入、関数、
  条件・反復・例外、配列・辞書・参照、連文、DNCL変換後構文を扱い、公式parser corpus全67件を
  追加ケースとともに `tools/compare_parser_oracle.mjs` で構造照合する。
- 構文エラーは `frontend/diagnostic.zig` の安定した診断コード、元入力のバイト範囲、行・列を持つ。
  `lnako check` と差分診断テストは同じ診断データを使用する。

## 意味解析とモジュール

- `semantic/analyzer.zig` はモジュール・関数スコープを作り、グローバル名を `module__name` へ修飾する。
  関数引数とローカル変数を分離し、公開シンボルの非修飾・修飾参照、厳チェック、重複定義、
  定数再代入、曖昧な取り込みを診断する。
- `semantic/builtin_catalog.zig` は互換表の標準cnako命令527件から生成した索引である。
  `tools/check_builtin_catalog.mjs` が固定カタログとの全件一致をCIで検証する。
- `semantic/module_graph.zig` は相対 `.nako3` を再帰的に読み、同一実体の重複取り込みと循環を抑止する。
  `.js` / `.mjs` は明示的な互換モードなしでは診断し、通常モードのモジュールグラフへ混入させない。
- `lnako check` はエントリだけでなくモジュールグラフ全体を構文・意味解析する。

## HIRとNako SSA IR

- `ir/hir.zig` は名前解決済みASTを、グローバル・ローカル参照、分割代入、増減、関数、構造化制御を
  明示したHIRへ変換する。元ソース位置、ループ方向、分割代入先、関数引数のシンボルを保持する。
- `ir/lower_ssa.zig` はHIRをSSA値と基本ブロックへ変換する。条件・反復・条件分岐・例外経路には
  明示的な分岐先を持たせ、式の評価順を命令順として固定する。
- `ir/verifier.zig` は基本ブロックID、終端命令、分岐先、SSA値の一意性・定義優位性、phi入力、
  例外分岐先を検証する。不正なIRはLLVMへ渡さない。
- `ir/printer.zig` は回帰テストと調査用の安定したテキスト表現を出力する。この表現は公開ABIではない。
- `lnako check` は構文・意味解析に加えてHIR/SSA生成とIR検証まで実行する。

## 互換性の原則

- JavaScriptの `Number` に合わせ、通常数値をIEEE 754 binary64として扱う。
- 文字列操作はUTF-16コード単位を基準にする。
- 通常モードはJSエンジンを含めない。
- JS固有命令は `--compat-js` 指定時だけQuickJSへ接続する。
- 対応していない機能を暗黙に代替せず、互換表と診断に理由を出す。

## 動的な値

- `runtime/string.zig` は文字列をUTF-16コード単位列として保持する。補助平面文字の長さ・添字・部分列は
  ECMAScriptと同じになり、UTF-8出力時だけ孤立サロゲートをU+FFFDへ置換する。
- `runtime/bigint.zig` はZig標準ライブラリの多倍長整数を所有し、10/2/8/16進解析、四則、剰余、累乗、
  符号付きビット演算とシフトを精度損失なしで実行する。
- `runtime/value.zig` は `undefined`、`null`、真偽値、binary64、BigInt、文字列をタグ付き値として表し、
  JS互換の真偽・数値・文字列変換、厳密同値・SameValue・抽象同値を提供する。
- `runtime/operators.zig` はNumberとBigIntの混在を拒否し、Numberのビット演算をToInt32/ToUint32へ正規化する。
  固定ケースと決定的に生成したbinary64ケースを `tools/compare_value_oracle.mjs` でNode 24へ照合する。

## コレクション、関数、GC

- 配列は動的なValue列として伸長、挿入、削除を行い、辞書はUTF-16文字列の内容をキーとする
  `ArrayHashMap` で平均O(1)検索と挿入順列挙を両立する。同値キーの更新では最初の挿入位置を維持する。
- 関数値はIR関数IDまたはネイティブコールバック、引数数、属性、名前付き捕捉値を持つ。ネイティブ呼び出し中は
  関数と全引数を自動的にルートへ登録する。
- ランタイムヒープは全オブジェクトを追跡し、生成コードがValueのアドレスを登録するルートフレームから
  mark-and-sweepを行う。配列・辞書・クロージャを反復的なgrey stackで走査するため、循環参照と深いグラフを
  再帰スタックに依存せず回収できる。GCストレスモードでは各オブジェクト割り当て前に回収を実行する。
