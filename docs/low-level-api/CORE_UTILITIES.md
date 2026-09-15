# Core Utilities 逆引き表

Core Utilities系コマンドが、どの低レイヤー命令と capability を必要とするかの逆引きを固定する。機械可読な正本は [`catalog.json`](catalog.json) の `coreUtilities` であり、本書はその一覧を示す。

表の見方: 「必要な命令」は `plugin_lowlevel` の命令ID。「必要なcapability」はそのユーティリティの実装が依存するcapability。`conditional` なcapability（reflink等）に依存するユーティリティは、非対応環境では fallback または `ENOTSUP` 捕捉で動作を変える。

## 一覧

| Core Utility | 必要なcapability | 必要な命令 |
| --- | --- | --- |
| `cat` | raw_stdio, stream_file_io | 標準入力バイト読む, 標準出力バイト書く, ファイル開く, ファイルバイト読む, ファイル閉じる |
| `tee` | raw_stdio, stream_file_io | ファイル開く, ファイルバイト読む, ファイルバイト書く, ファイル同期, 標準出力バイト書く, ファイル閉じる |
| `dd` | stream_file_io | ファイル開く, ファイルバイト読む, ファイルバイト書く, ファイル閉じる, ファイル位置変更, ファイル位置取得 |
| `md5sum` / `sha*sum` | incremental_hash, stream_file_io, raw_stdio | ハッシュ開始, ハッシュ追加, ハッシュ完了, ハッシュ破棄, ファイル開く, ファイルバイト読む, ファイル閉じる, 標準入力バイト読む |
| `ls` | dir_iterator, lstat | ディレクトリ開く, ディレクトリ次取得, ディレクトリ閉じる, シンボリックリンク情報取得 |
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

## 使い方

- あるCore Utilitiesコマンドをなでしこ側で実装するときは、この表の命令IDを `低レイヤー機能対応判定` で確認し、必要なcapabilityが成立する場合にのみ専用実装を選ぶ。
- `conditional` なcapability（reflink等）に依存するユーティリティは、非対応環境で通常実装へfallbackする分岐をなでしこ側に持つ。分岐の条件は `低レイヤー機能対応判定(NAME)` を利用する。
- 逆引きの誤り（未知の命令ID・capability IDの参照）は [`check_low_level_spec.mjs`](../../tools/check_low_level_spec.mjs) がCIで検出する。