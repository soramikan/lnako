# G0 / Foundation API Freeze

低レイヤー命令（Issue [#27](https://github.com/soramikan/lnako/issues/27)〜[#36](https://github.com/soramikan/lnako/issues/36)）が共有する型・エラー・capability・命名・実行経路契約を固定する。機械可読な正本は [`src/runtime/low_level_foundation.zig`](../../src/runtime/low_level_foundation.zig) である。本書は人間向けの契約説明であり、Zig正本と矛盾する場合はZigを優先して修正する。

この文書は命令カタログ全体・OS別matrix・Core Utilities逆引きを含まない。それらはIssue [#37](https://github.com/soramikan/lnako/issues/37)の後続作業である。既存の標準cnako 527命令の互換契約は変更しない。

## 適用範囲

| 項目 | G0で固定する | G0で固定しない |
| --- | --- | --- |
| Bytes型 | 第一級octet列としての意味と生成規則 | 既存`開`/`読`/`バイナリ読`の動作変更 |
| Handle ID型 | 内部ID・公開値・close後検出 | 具体的な開く/閉じる命令の助詞 |
| 64-bit offset | 内部型とNumber/BigInt変換 | seek whenceや位置指定命令名 |
| timestamp | ファイルメタデータのepoch表現 | `今`/`今日`などAsia/Tokyoの既存日時命令 |
| portable error code | 構造化エラーの形と初期code集合 | 527命令の文字列例外 |
| capability | 識別子・分類・照会・失敗形 | 全OSの真偽matrix |
| unsupported | 登録は共通、実行時に機械判定 | コンパイラのIR未対応検出 |
| 命令命名規則 | 衝突禁止・plugin・助詞・語彙 | #27〜#36の命令名一覧 |
| 共通契約 | Interpreter / AOT / cnakoの一致条件 | 各命令のoracle fixture |

対象ランタイムは lnako Interpreter、lnako AOT（O0〜O3）、cnako（Node）である。正式環境は macOS arm64、Linux x86_64 GNU、Windows x86_64 MSVC である。

## Bytes型

低レイヤーI/Oのバイト列は、既存ランタイムの Bytes（`Value.bytes` / AOT `byte_buffer` / plugin `LNAKO_VALUE_BYTES=6`）であり、`createBytes` が生成する Buffer kind を正とする。

固定規則:

- 内容は生のoctet列である。UTF-8検証、NUL終端、文字コード変換をしない。
- 空（0 byte）は正当な値である。ストリーム読込で0 byteを返したときはEOFとする。要求より短いが1 byte以上の読込は部分読込であり、EOFではない。
- String（UTF-16）とBytesは区別する。Bytesを要求する引数へStringを暗黙変換しない。
- Uint8Array / ArrayBuffer kind を低レイヤーI/Oの生成結果にしない。受け取り側がBytes（Buffer kind）以外を見たときは型エラー（portable code `EINVAL`）とする。
- 生成時は入力を複製する。呼び出し元スライスの寿命に依存しない。
- `TYPEOF` は既存Buffer契約どおり `"object"` のままにする。
- cnako対応は Node.js の `Buffer` とする。`Uint8Array` 単体では足りない。
- plugin ABIは既存の `make_bytes` / `get_bytes` を使う。`get_bytes` はBytes専用のままとする。

既存の`開`/`読`（lossy UTF-8のString）と`バイナリ読`（全量Bytes）は維持する。低レイヤーAPIはこれらを置き換えない。

## Handle ID型

OSのファイル記述子やZigの `File` をなでしこ値として公開しない。Runtime/Hostのhandle tableを正本とする。

内部ID:

- 64-bit値 `HandleId` は `index: u32`（bit 0〜31）と `generation: u32`（bit 32〜63）の組である。
- `index == 0` または `generation == 0` は無効である。発行する生ハンドルはどちらも1以上とする。
- close時は同じindexのgenerationを進める。0へ回った場合は1へ飛ばす。
- 生の `HandleId` をなでしこNumberとして公開しない。

公開値:

- Handleはオブジェクト同一性で識別する不透明オブジェクトである。`TYPEOF` は `"object"`。
- Number、BigInt、String、OS fd番号ではない。
- 代入は参照コピーであり、同一Handleである。
- オブジェクトの複製、JSON化、同じ形の辞書の手作りはhandle tableに載らないため無効である。
- close後および二重closeの操作は portable code `EBADF` とする。

cnako対応は、Node `fs.open` が返す生fdをなでしこ値にせず、JSオブジェクトをhandle table（実装はWeakMap等）へ載せる。内部でNode fdを保持してよい。

Handleの種別（file / directory / hash 等）はtable側の属性であり、公開オブジェクトの偽造可能なフィールドを正本にしない。

## 64-bit offset

ファイル位置とサイズは、なでしこNumber（binary64）だけでは2^53を超える整数を失う。低レイヤーAPIは次を正とする。

内部型:

- 位置（seek等）: 符号付き64-bit整数 `i64`（POSIX `off_t` 相当）
- 大きさ（byte数、ファイルサイズ）: 符号無し64-bit整数 `u64`

公開変換（入力）:

- Numberは、有限かつ整数であり、絶対値が2^53-1以下のときだけ受け付ける（ECMAScriptの安全整数）。
- それより大きい整数はBigIntで渡す。内部へ取り込むときは符号付きを `i128`、大きさを `u128` として範囲検査する。
- `i64` に収まらない位置、`u64` に収まらない大きさは拒否する。
- NaN、±Infinity、非整数Number、範囲外BigInt、Stringからの暗黙変換は拒否する。これらの失敗の portable code は `EINVAL` である。Zig正本の `Error.InvalidOffset` / `InvalidSize` / `InvalidTimestamp` も同じく `EINVAL` へ写す。
- 大きさに負数は使えない。

公開変換（出力）:

- 安全整数に収まる値はNumberで返す。
- 収まらない値はBigIntで返す。

cnako対応は Node の `number | bigint` 位置引数と同じ規則にする。

## timestamp表現

低レイヤーが扱うファイル時刻は、既存の`今`/`今日`（Asia/Tokyo表示）とは別契約である。

- 内部正本は Unix epoch（UTC）からの符号付きナノ秒 `i128` とする。Windows FILETIME（1601年起点）を含む実用的なファイル時刻を、i64ナノ秒の1678〜2262年制限へ落とさない。
- 公開する高精度フィールド（`mtimeNs` 等）は常にBigIntナノ秒とする。小さい値でもNumberに落とさない。
- 既存`ファイル情報取得`の `mtimeMs` / `ctimeMs` / `atimeMs` は維持する。これらはミリ秒Numberであり、低レイヤー詳細APIの正本ではない。
- 取得できない時刻の内部型は `?TimeNs`、公開値は `null` とする。`0` は1970-01-01T00:00:00Zを意味する。
- Dateオブジェクトは導入しない。
- OSが秒またはマイクロ秒など粗い精度しか返さない場合は、その整数をナノ秒へ整数倍する。存在しない桁を捏造しない。

cnako対応は Node `fs.Stats` の `mtimeNs`（BigInt）と `mtimeMs`（Number）に合わせる。

## portable error code

低レイヤー命令の失敗は、文字列だけの例外に丸めない。失敗値そのものが構造化情報を持つ。直前エラーを読むグローバルAPIは採用しない。

公開オブジェクト（辞書）のキー:

| キー | 型 | 意味 | cnako / Node SystemError |
| --- | --- | --- | --- |
| `code` | string | portable code | `code` |
| `nativeCode` | number または null | OS固有値 | `errno` |
| `operation` | string | 操作名（ASCII） | `syscall` |
| `path` | string または null | 対象path | `path` |
| `path2` | string または null | 第二path | `dest` |
| `message` | string | 人間向け文言 | `message` |
| `capability` | string または null | 未対応時のcapability ID | なし（追加フィールド） |

固定規則:

- 互換判定と分岐は `code`（必要なら `operation` / `capability`）を使う。`message` はOSやlocaleで変動するためoracleに使わない。
- 例外として投げたとき、既存の`エラーメッセージ`には `message` を入れる。捕捉した値を文字列化した場合も `message` と一致させる。
- 構造化エラーは新規の低レイヤー命令にだけ適用する。527命令の既存文字列例外は維持する。
- InterpreterとAOTで `code` は一致させる。`nativeCode` と `message` はOS差を許す。

初期portable code（削除・改名しない。追加は後続でよい）:

`ENOENT` `EACCES` `EPERM` `EEXIST` `ENOTDIR` `EISDIR` `ENOTEMPTY` `EXDEV` `ELOOP` `EROFS` `ENOSPC` `EMFILE` `ENFILE` `EINVAL` `EPIPE` `EBADF` `ENOTSUP`

`ENOTSUP` はcapability不足に使う。未知コマンドは既存どおり `UnknownCommand` であり、portable code集合に含めない。

## capability表現

命令の登録有無をOSごとに変えない。同じ命令を全OS・全lnako経路へ登録し、対応状況はcapability照会と構造化エラーで機械判定する。

識別子はASCIIの `snake_case` である。分類は次の3種に限る。

| 分類 | 意味 |
| --- | --- |
| `portable_core` | Linux / macOS / Windows と lnako Interpreter / AOT で提供する。cnakoはNodeが表現できる範囲で同一仕様を目標とする |
| `posix_extension` | POSIXで意味が定まる。Windowsでは偽または `ENOTSUP` になり得る |
| `lnako_native` | 公式なでしこ3への提案対象外に分離できる拡張 |

照会命令:

- `低レイヤー機能対応判定`（助詞 `NAMEの` / `NAMEを`）はbooleanを返す。未知のNAMEは `false` を返す。
- `低レイヤー機能一覧取得` は既知IDの配列を返す。真偽ではなく識別子の全集である。

初期IDと分類はZig正本の `Capability` を見る。真偽のOS別matrixはG0の対象外である。

## unsupportedの扱い

- 命令はカタログに存在し、`システム関数存在` はtrueになり得る。
- 未対応操作の実行は成功値や `null` / `false` を返さず、構造化エラー `code=ENOTSUP` を投げる。`capability` にIDを入れる。
- AOTは当該呼出しをコンパイル時拒否しない。Interpreterと同じ実行時失敗にする。LLVM IR未対応検出（`unsupported.zig`）とは別契約である。
- 部分対応（例: 一部whenceだけ不可）も同じ `ENOTSUP` とする。

## 命令命名規則

- 第一名は日本語の動詞またはする名詞とする。英語名を第一名にしない。
- 標準cnako 527件の表示名と衝突させない。既存の`開`/`読`/`バイナリ読`/`保存`/`ファイル情報取得`等は置き換えない。Zig正本の予約名配列は衝突禁止の例示であり、527件の全集は `builtin_catalog` を正本とする。
- 助詞と引数順は命令契約の一部である。実行時dispatchは既存どおり名前で行う。
- 新規命令は `plugin_lowlevel` に登録し、`plugin_node` / `plugin_system` の同名解決を壊さない。
- `portable_core` と `posix_extension` は公式なでしこ3へ提案可能な名にする（`lnako`接頭辞を付けない）。
- `lnako_native` も日本語名でよいが、catalog分類で分離する。
- 可変長引数の名前オーバーロードはしない。省略は既存どおり `undefined`。
- メタ命令は `低レイヤー` で始める。ファイル系は `ファイル`、標準入出力は `標準入力` / `標準出力` / `標準エラー出力` を接頭辞の基本とする。

## Interpreter / AOT / cnako 共通契約

次は3経路で一致させる。

- 命令名、助詞、引数順、arity
- Bytes / Handle / offset / timestamp / 構造化エラー / capability の型契約
- portable `code` とEOF（0 byte）と無効Handle（`EBADF`）の意味
- 同一OS上のlnako InterpreterとAOT（O0〜O3）のcapability真偽とportable `code`

次は差を許す。

- `nativeCode` と `message`
- cnakoが実装しない `lnako_native`（その場合は `ENOTSUP`）
- Handleオブジェクトの内部表現（lnakoの辞書同一性と、cnakoのJSオブジェクト）

通常モードへJavaScriptランタイムを混入させない。cnako実装は公式処理系側の話であり、lnako製品ランタイムの契約をJSに置き換えない。

後続Issueは、同一`.nako3` fixtureをlnako Interpreter / AOT / cnakoへ入力し、stdout / stderr / exit code / 生成FS状態を比較する。G0はその比較が依拠する型とエラーと未対応判定を固定する。
