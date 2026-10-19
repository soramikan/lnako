# 低レイヤー API 実装状況

機械可読な正本は [`catalog.json`](catalog.json)（`src/runtime/low_level_catalog.json` と同一）。実行時の命令表は `src/runtime/low_level_foundation.zig` の `catalog_commands`、dispatch は `src/plugins/lowlevel/call.zig`。公開プラグイン名は `lnako_lowlevel`、内部登録名は `plugin_lowlevel`。

利用者向けページは nadesiko3doc の `data/lnako_lowlevel/`（63 件）。命令名・助詞・戻り・エラー・実装フラグは catalog と一致させる。

## 件数

| 区分 | 件数 |
| --- | --- |
| カタログ命令 | 63 |
| 実装済み | 63 |
| 未実装 | 0 |
| capability | 35（うち命令なしの OS 拡張 5） |

`node tools/check_low_level_spec.mjs` が catalog と foundation の `implemented` 一致を検証する。

## 位置系命令（#27 完了）

| id | 命令 | 備考 |
| --- | --- | --- |
| `ll-file-seek` | ファイル位置変更 | lseek 相当。WHENCE は開始/現在/終端 |
| `ll-file-tell` | ファイル位置取得 | 現在位置（seek 0, 現在） |
| `ll-file-pread` | ファイル位置指定読込 | pread 相当。位置を動かさない |
| `ll-file-pwrite` | ファイル位置指定書込 | pwrite 相当。位置を動かさない |

Interpreter（`src/plugins/lowlevel/stream.zig` + host）と AOT（`src/runtime/aot/low_level/stream.zig`）の両方で実装。I/O 本体は `src/runtime/low_level_io.zig` の `seek` / `tell` / `readAt` / `writeAt`。

`低レイヤー機能対応判定("stream_file_io")` は open/close/read/write/sync が揃うと true になる。詳細は [`STREAM_IO.md`](STREAM_IO.md) と [`COMMAND_CONTRACTS.md`](COMMAND_CONTRACTS.md)。

影響: Core Utilities の `dd` は位置変更・位置取得に依存する。これらは実装済みのため構築可能（[`CORE_UTILITIES.md`](CORE_UTILITIES.md)）。

## 実装済みの要約（Issue 別）

| Issue | 状態 | 命令 | 備考 |
| --- | --- | --- | --- |
| #27 | 完了（位置系含む 10/10） | 10/10 | 読書き同期切詰 + 位置系4 |
| #28 | CLOSED | 5/5 | Raw stdio |
| #29 | CLOSED | 9/9 | hardlink の Windows は #78 |
| #30 | CLOSED | （基盤） | 構造化エラー |
| #31 | CLOSED | 3/3 | utime / truncate |
| #32 | CLOSED | 4/4 | incremental hash |
| #33 | CLOSED | 4/4 | dir iterator |
| #34 | CLOSED | 10/10 | POSIX。Windows は ENOTSUP が多い |
| #35 | CLOSED | 9/9 | spawn / signal / TTY 等 |
| #36 | CLOSED | 5/5 | statfs / reflink / sparse / fallocate |
| #37 | CLOSED | 2/2 | capability 照会 |
| #38 | CLOSED | 2/2 | locale / display width |
| #96 | CLOSED | — | ドメイン分割リファクタ |

## 未実装・制約の Issue

| Issue | 状態 | 内容 |
| --- | --- | --- |
| #78 | OPEN | Windows `CreateHardLinkW`。現状 `hardlink` の `os.windows=false` |
| #39 | OPEN | `termios` / `nss` / `acl` / `xattr` / `selinux`（capability ID のみ・命令なし） |
| #197–#206 | OPEN | Web/Async Runtime Foundation（現行 63 命令カタログの外） |

## OS・経路の制約（よく使うもの）

- Windows `ハードリンク作成`: 常に `ENOTSUP`。capability 照会は false（#78）
- POSIX 系（chmod / chown / uid_gid / priority / statfs 等）: POSIX で実装。Windows は照会 false または実行時 `ENOTSUP`
- `reflink` / `seek_data` / `seek_hole` / `fallocate`: FS・OS 依存。matrix は `conditional` または Windows false
- Interpreter: ホストが callback を渡さないと capability が false（`lnako_interpreter` は多くが `conditional`）
- cnako / wnako: 低レイヤー命令は存在しない
- 非seek可能な fd（pipe 等）: 位置系は `EINVAL`

計画値の表は [`CAPABILITY_MATRIX.md`](CAPABILITY_MATRIX.md)。現在値は catalog の `os` / `runtimes`。

## 文書の対応関係

| 文書 | 役割 |
| --- | --- |
| `catalog.json` | 正本（命令・capability・coreUtilities） |
| `COMMAND_CONTRACTS.md` | 人間向け契約一覧 |
| `STREAM_IO.md` | #27/#28 の実装契約 |
| `CORE_UTILITIES.md` | 逆引き。`dd` 等の構築可否 |
| `CAPABILITY_MATRIX.md` | 計画値の読み方 |
| nadesiko3doc `lnako_lowlevel` | 利用者向け。生成元は `nadesiko3doc/script/generate_lnako_docs.py` |

## 残作業の優先度（文書上のギャップ）

1. #78（Windows hardlink）
2. #39（termios 等の拡張）
3. #197 以降（別カタログ領域）
