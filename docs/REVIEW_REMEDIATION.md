# 2026-09-05 レビュー対応

レビュー対象は `0de02eb6b804b159fed79e0f6269ee3adbfa0259`、改修開始時の HEAD は
`17d5bdf`。添付レビューの再現案を現行実装と照合し、以下を改修した。
互換分類やリリースの完成度を変更するものではない。

| 項目 | 対応と回帰検証 |
| --- | --- |
| R1 | ToPrimitive・文字列化の一時値を root frame で保護。配列の減算・比較、文字列加算、BigInt を返す変換フックを GC stress で検証。 |
| R2 | AOT の文字列の真偽判定を既存ランタイムの長さ判定へ接続。静的 UTF-8 とヒープ UTF-16 の両方を対象とする。 |
| R3 | 動的な単項演算をランタイム ABI へ接続し、ToPrimitive、BigInt、例外を扱う。数値の単項 `+` は恒等操作とし、負のゼロを保持する。算術単項 HIR の直後には例外分岐を生成する。 |
| R4 | HTTP 接続は本文の受信完了後に状態へ移管。接続単位の既知のエラーから回復し、OOM・原因不明の I/O 失敗・内部エラーは伝播する。途中切断、不正 chunk、不正ヘッダーの後の正常要求を実通信で検証する。 |
| R5 | 静的パスの作業バッファとエラー経路を解放。`realPathFileAlloc` の末尾ゼロを含む所有権を保持し、返却後の解放サイズも一致させる。ファイル、404、ディレクトリ、index を検証する。 |
| R6 | ByteBuffer の offset を GC 前に保存。root にない非ゼロ offset の view からさらに view を生成する GC stress テストを追加。 |
| 追加指摘 | 分解代入・増減・捕捉セルの変更を見落として引数のロードを数値へ固定しない。同名でも無関係なスコープの引数の推論は維持する。 |

## 再現条件の補足

- R1 と R6 は、改修前の独立したコピーへ回帰テストを適用すると GC stress で
  解放済み領域を参照してクラッシュした。
- R4 は、改修前の Interpreter が途中切断で `EndOfStream` 終了することを確認した。
- 捕捉引数の型推論は、引数をクロージャーから文字列 `"5"` に変更して `A+1` を返すと、
  改修前の Interpreter は `6`、AOT O2 は `1` になった。
- 現行フロントエンドは公式互換のため単項 `+` を拒否し、変数への単項 `-` は
  `-1 * 値` に変換する。R3 のレビュー例をそのままソース上の再現とは扱わない。
  単項命令自身の検証は HIR / IR / ランタイム ABI の境界でも行う。
- 引数を `変数[A,B]` で再宣言する例は現在 `duplicate_symbol` になる。
  分解代入の型推論は、有効な IR の書き込み命令を用いる防御的な回帰テストで検証する。

## 検証範囲

Zig 0.16.0、LLVM/LLD 22.1.8、macOS arm64 を使用した。
公式差分にはプロジェクト指定の oracle 専用 Node.js 24.15.0 を使用した。
`zig build fmt-check`、`zig build test`、関連公式差分テストの順で実行した。
今回のローカル検証を Linux / Windows の実行結果や CI の成功と読み替えない。

- 整形検査と全単体テスト: 681/681 成功。
- `compare_native_oracle.mjs --no-build`: 空文字列ケース追加前の全293ケースで
  公式CLI・公式生成JavaScript・Interpreter・AOT O0/O1/O2/O3 の比較が成功。
- 最終ビルドでは全294ケースのうち shard index 33/48（64分割）の11ケースを再比較し、
  空文字列と捕捉引数の追加2ケースを含め、同じ7経路すべてで成功。
- `compare_http_server_aot_oracle.mjs --no-build`: 最終ビルドの Interpreter と
  AOT O0/O1/O2/O3 で、回復試験を含む各26リクエストが公式と一致。
- CI構成、現行文書、互換資料・証拠、compat report、native AOT artifact の
  partition/schema/tamper self-test を検証。fixture inventory の更新は2件であり、
  `verified 0 / trace-confirmed-unattested 527 / unverified 0` は変更していない。

R3 の LLVM 命令そのものは、生成 IR の検査とランタイム ABI 単体テストで検証した。
単項 `+/-` の独立 IR を実行ファイルにした O0〜O3 の試験とは区別する。
