# Issue #32 / incremental hash API

`sha256sum` などのチェックサムやパッケージ整合性検証のため、入力全量をメモリへ
展開せず逐次ハッシュを計算する低レイヤー命令群（Issue
[#32](https://github.com/soramikan/lnako/issues/32)）の実装契約。機械可読な正本は
[`src/runtime/low_level_foundation.zig`](../../src/runtime/low_level_foundation.zig)、
[`src/runtime/low_level_hash.zig`](../../src/runtime/low_level_hash.zig)、
[`catalog.json`](catalog.json) である。
[G0 Foundation](G0_FOUNDATION.md) が固定した型・エラー・capability・handle契約の上に実装する。

## 命令一覧

| 命令 | 引数 | 戻り値 | capability | 操作名 | エラー |
| --- | --- | --- | --- | --- | --- |
| `ハッシュ開始(ALGORITHM)` | ALGORITHM: String | Handle | `incremental_hash` | `hash` | EINVAL, ENOTSUP |
| `ハッシュ追加(HANDLE, BYTES)` | Handle、BYTES: Bytes（Buffer kind） | undefined | `incremental_hash` | `hash` | EBADF, EINVAL |
| `ハッシュ完了(HANDLE, ENCODING)` | Handle、ENCODING: String（省略可） | Bytes（raw）またはString（hex等） | `incremental_hash` | `hash` | EBADF, EINVAL |
| `ハッシュ破棄(HANDLE)` | Handle | undefined | `incremental_hash` | `hash` | EBADF |

動的文字列実行（`ナデシコ`/`実行`）の互換のため、送り仮名付きの標準命令と衝突しない
語幹名をdispatch名とする。命令名は `catalog.json` を正本とする。

## Handle

- `ハッシュ開始` の戻り値は `TYPEOF` が `"object"` の不透明オブジェクト（辞書）である。
  ファイルhandleと同じ `HandleId`（`index: u32` / `generation: u32`）の仕組みで
  オブジェクトのポインタと対応付ける。同じ形の辞書を手作りしても無効になる。
- ハッシュhandleのindexはファイルhandle（1からの連番）とraw値が衝突しないよう、
  上位bitを立てた別空間（`hash_handle_index_base`）から払い出す。ハッシュhandleを
  ファイル命令へ、またはファイルhandleをハッシュ命令へ渡すと `EBADF` になる。
- 完了・破棄後は同じindexのgenerationを進めて再利用し、use-after-freeを誤検出しない。
- `ハッシュ完了` はdigestを返した時点でhandleを破棄する。破棄後の追加・再完了は
  `EBADF`、二重破棄も `EBADF`。GCはhandleを自動破棄せず、Runtime終了時に残handleを解放する。

## アルゴリズム

`ハッシュ値計算`（既存Node互換命令）と同じ正規化（英数字以外を除去して小文字化）で
アルゴリズム名を解決する。`src/plugins/crypto.zig` と `src/runtime/low_level_hash.zig`
は同じ `Algorithm.fromName` を参照する。

- 逐次計算対応: MD5、MD5-SHA1、SHA-1、SHA-224/256/384/512、SHA-512/224、SHA-512/256、
  SHA3-224/256/384/512、BLAKE2b-512、BLAKE2s-256、SHAKE128、SHAKE256。
- 未知のアルゴリズム名は `EINVAL`。`ハッシュ値計算` には存在するが逐次stateを持たない
  RIPEMD-160とSM3は `ENOTSUP`（one-shotの `ハッシュ値計算` のみ対応）。
- `ハッシュ追加` はBytes（`ByteKind.buffer`）だけを受け付ける。String、`Uint8Array`、
  `ArrayBuffer` kindは暗黙変換せず `EINVAL`。bytesは無変換でupdateする。
- `ハッシュ完了` のENCODINGは省略時raw bytes。`raw`/`hex`/`base64`/`base64url`/
  `latin1`/`binary`/`utf8` を `ハッシュ値計算` と同じ意味で受け付ける。未知のencodingは
  `EINVAL`。1 byte刻みと複数チャンク供給は同一digestになる。

## 構造化エラー

失敗は文字列だけの例外に丸めない。G0の `error_object_keys` に従い、`code`/`nativeCode`/
`operation`/`path`/`path2`/`message`/`capability` を持つ辞書を投げる。`operation` は
4命令とも `hash`。`ENOTSUP` のときだけ `capability` に `incremental_hash` を入れる。
捕捉時は `エラーメッセージ["code"]` 等で分岐できる。

## ストリームとの組み合わせ

`ファイル開く` + `ファイルバイト読む` + `ハッシュ追加` + `ハッシュ完了` で、大容量ファイルを
メモリへ全量展開せずにチェックサムを計算できる。`md5sum`/`sha*sum` 相当のCore Utilitiesは
`catalog.json` の `coreUtilities` を参照する。`ファイルバイト読む` が0 byteを返したらEOFで、
その時点のdigestが最終値になる。

## Interpreter / AOT

同一 `.nako3` fixture を lnako Interpreter と AOT（O0〜O3）で実行し、stdout / stderr /
生成FS状態が一致する。`nativeCode` と `message` はOS差を許すが、`code` とdigestの意味は
一致させる。

- Interpreter: `src/plugins/lowlevel.zig` が `plugin_lowlevel` としてdispatch。hash stateは
  `src/host/state.zig` の `CliHost` が持つ `HashHandleTable` を介す。
- AOT: `src/runtime/aot/low_level.zig` が `lnako_aot_builtin_call_site` からdispatch。
  hash stateはAOT `Runtime` が持つ `HashHandleTable` を介し、handle値はGCのmark対象になる。
- capability照会 `低レイヤー機能対応判定("incremental_hash")` はcreate/update/digest/discard
  の全callbackが揃っているときだけtrue。

## テスト

- 単体: `low_level_hash.zig`（NIST標準ベクタ、1 byte刻みと一括の一致、handle世代）、
  `plugins/lowlevel.zig`、`aot/low_level.zig`
- Interpreter integration: `src/runtime/interpreter/tests.zig` が1 byte/7 byte/64KiB供給で
  ファイルstreamのSHA-256一致と完了後EBADFを検証する
- AOT integration: `src/runtime/aot/tests.zig` が同一fixtureをstream供給でSHA-256一致まで検証する
- 手動oracle: `lnako run` と `lnako build -O0..O3` のdigest・構造化エラーが一致する
