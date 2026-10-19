# Core Utilities 逆引き表

Core Utilities系コマンドが、どの低レイヤー命令と capability を必要とするかの逆引きを固定する。機械可読な正本は [`catalog.json`](catalog.json) の `coreUtilities` であり、本書はその一覧を示す。

表の見方: 「必要な命令」は `plugin_lowlevel` の命令ID。「必要なcapability」はそのユーティリティの実装が依存するcapability。`conditional` なcapability（reflink等）に依存するユーティリティは、非対応環境では fallback または `ENOTSUP` 捕捉で動作を変える。`stream_file_io` の真偽は open/close/read/write/sync の提供有無であり、位置系命令の成功は別途失敗処理で確認する（`dd` の位置変更・位置取得を含む）。

## 一覧

| Core Utility | 必要なcapability | 必要な命令 |
| --- | --- | --- |
| `cat` | raw_stdio, stream_file_io | 標準入力バイト読む, 標準出力バイト書く, ファイル開く, ファイルバイト読む, ファイル閉じる |
| `tee` | raw_stdio, stream_file_io | ファイル開く, ファイルバイト読む, ファイルバイト書く, ファイル同期, 標準出力バイト書く, ファイル閉じる |
| `dd` | stream_file_io | ファイル開く, ファイルバイト読む, ファイルバイト書く, ファイル閉じる, ファイル位置変更, ファイル位置取得 |
| `md5sum` / `sha*sum` | incremental_hash, stream_file_io, raw_stdio | ハッシュ開始, ハッシュ追加, ハッシュ完了, ハッシュ破棄, ファイル開く, ファイルバイト読む, ファイル閉じる, 標準入力バイト読む |
| `ls` | dir_iterator, lstat, display_width | ディレクトリ開く, ディレクトリ次取得, ディレクトリ閉じる, シンボリックリンク情報取得, 文字表示幅取得 |
| `du` | dir_iterator, lstat, stat | ディレクトリ開く, ディレクトリ次取得, ディレクトリ閉じる, シンボリックリンク情報取得, ファイル詳細情報取得 |
| `rm -r` | dir_iterator, unlink, rmdir | ディレクトリ開く, ディレクトリ次取得, ディレクトリ閉じる, ファイルリンク削除, 空フォルダ削除 |
| `cp -r` | stream_file_io, stat, dir_iterator, realpath, readlink | ファイル開く, ファイルバイト読む, ファイルバイト書く, ファイル閉じる, ファイル詳細情報取得, ディレクトリ開く, ディレクトリ次取得, ディレクトリ閉じる, 実体パス取得, シンボリックリンク先取得 |
| `cp -p/-a` | utime, chmod, chown, stat | ファイル時刻設定, ファイル権限設定, ファイル所有者設定, ファイル詳細情報取得 |
| `touch` | utime, truncate | ファイル時刻設定, ファイルサイズ変更 |
| `truncate` | truncate | ファイルサイズ変更, ファイル切詰 |
| `install` | chmod, chown, utime, truncate, stream_file_io | ファイル権限設定, ファイル所有者設定, ファイル時刻設定, ファイルサイズ変更, ファイル開く, ファイルバイト書く, ファイル閉じる |
| `df` | statfs | ファイルシステム情報取得 |
| `stat` | stat, lstat | ファイル詳細情報取得, シンボリックリンク情報取得 |
| `stat -f` | statfs | ファイルシステム情報取得 |
| `cp --reflink` | reflink | ファイルクローン |
| `cp --sparse` | seek_data, seek_hole, stream_file_io | ファイルデータ領域検索, ファイル空洞領域検索, ファイル開く, ファイルバイト読む, ファイルバイト書く, ファイル閉じる |
| `env` | argv_spawn | プロセス起動, プロセス待機, プロセスID取得 |
| `timeout` | argv_spawn, signal | プロセス起動, プロセス待機, シグナル送信 |
| `nice` | priority | プロセス優先度取得, プロセス優先度設定 |
| `nohup` | argv_spawn, signal | プロセス起動, シグナル送信 |
| `kill` | signal | シグナル送信, プロセスID取得 |
| `tty` | tty_isatty | 端末判定, 端末サイズ取得 |
| `stty` | tty_isatty, termios | 端末サイズ取得 |
| `sort` | locale_collate | ロケール文字列比較 |
| `fmt` | display_width | 文字表示幅取得 |
| `id` | uid_gid | UID取得, GID取得, EUID取得, EGID取得, 所属グループID一覧取得 |
| `groups` | uid_gid | 所属グループID一覧取得 |
| `whoami` | uid_gid | UID取得, 所属グループID一覧取得 |
| `test -rwx` | access, stat | ファイルアクセス可能, ファイル詳細情報取得 |
| `ln` | symlink, hardlink, unlink | シンボリックリンク作成, ハードリンク作成, ファイルリンク削除 |
| `readlink` | readlink | シンボリックリンク先取得 |
| `realpath` | realpath | 実体パス取得 |
| `mv` | rename | パス名変更 |
| `rm` | unlink | ファイルリンク削除 |
| `rmdir` | rmdir | 空フォルダ削除 |

## 現状の制約（命令の実装有無）

この表は「必要な命令・capability」の逆引きであり、列挙した命令がすべて実装済みとは限らない。

| Core Utility | 現状 |
| --- | --- |
| `dd` | **構築可能**。必要命令の `ファイル位置変更` / `ファイル位置取得` を含む stream I/O が揃っている |
| `cp --sparse` | `seek_data` / `seek_hole` は実装済みだが OS・FS 依存（`conditional` / Windows は false）。非対応では通常コピーへ fallback する前提 |
| `ln`（hardlink 経路） | `ハードリンク作成` 可（Windows は NTFS 上の `CreateHardLinkW`。非対応FSは `ENOTSUP`、[#78](https://github.com/soramikan/lnako/issues/78)） |
| `stty` | `termios` は capability のみで命令未実装（[#39](https://github.com/soramikan/lnako/issues/39)） |
| `cp -p/-a` の所有者・権限 | `chmod` / `chown` は POSIX 実装。Windows は ENOTSUP |
| その他（`cat` / `tee` / `md5sum` 等） | 表の主要命令は実装済み。OS 差は各 capability の matrix に従う |

命令ごとの実装フラグは [`catalog.json`](catalog.json) の `implemented` と [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) を参照する。

## 使い方

- あるCore Utilitiesコマンドをなでしこ側で実装するときは、この表の命令IDを `低レイヤー機能対応判定` で確認し、必要なcapabilityが成立する場合にのみ専用実装を選ぶ。未実装命令（`implemented: false`）に依存する経路は選ばない。
- `conditional` なcapability（reflink等）に依存するユーティリティは、非対応環境で通常実装へfallbackする分岐をなでしこ側に持つ。分岐の条件は `低レイヤー機能対応判定(NAME)` を利用する。
- 逆引きの誤り（未知の命令ID・capability IDの参照）は [`check_low_level_spec.mjs`](../../tools/check_low_level_spec.mjs) がCIで検出する。