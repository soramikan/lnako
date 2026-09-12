# capability matrix と分類

Issue [#37](https://github.com/soramikan/lnako/issues/37) のcapability方針に従い、命令の登録有無をOSごとに変えず、対応状況を capability で機械判定する。機械可読な正本は [`catalog.json`](catalog.json) の `capabilities` であり、本書はその解釈と計画値を示す。

このmatrixは仕様上の計画値である。各OS・各実行経路での実際の成立は [#27](https://github.com/soramikan/lnako/issues/27)〜[#36](https://github.com/soramikan/lnako/issues/36) の実装と [`TEST_HARNESS.md`](TEST_HARNESS.md) のoracleで検証し、実測に合わせて更新する。

## 分類

| 分類 | 件数 | 意味 |
| --- | --- | --- |
| `portable_core` | 18 | Linux / macOS / Windows と lnako Interpreter / AOT で提供。cnakoはNodeが表現できる範囲で同一仕様を目標 |
| `posix_extension` | 7 | POSIXで意味が定まる。Windowsでは偽または `ENOTSUP` になり得る |
| `lnako_native` | 8 | 公式なでしこ3への提案対象外に分離できる拡張 |

- `portable_core`: stream_file_io, raw_stdio, stat, lstat, symlink, readlink, realpath, rename, unlink, rmdir, truncate, utime, incremental_hash, dir_iterator, argv_spawn, signal, tty_isatty, hardlink
- `posix_extension`: chmod, chown, access, uid_gid, priority, statfs, reflink
- `lnako_native`: seek_data, seek_hole, fallocate, termios, nss, acl, xattr, selinux

## OS別matrix（計画値）

値は true / false / `conditional`（FSや環境に依存）。`conditional` は対応環境でのみ成立し、不成立は `ENOTSUP` で返す。

| capability | Linux | macOS | Windows |
| --- | --- | --- | --- |
| stream_file_io | true | true | true |
| raw_stdio | true | true | true |
| stat | true | true | true |
| lstat | true | true | true |
| symlink | true | true | true |
| readlink | true | true | true |
| realpath | true | true | true |
| rename | true | true | true |
| unlink | true | true | true |
| rmdir | true | true | true |
| truncate | true | true | true |
| utime | true | true | true |
| incremental_hash | true | true | true |
| dir_iterator | true | true | true |
| argv_spawn | true | true | true |
| signal | true | true | true |
| tty_isatty | true | true | true |
| hardlink | true | true | true |
| chmod | true | true | false |
| chown | true | true | false |
| access | true | true | false |
| uid_gid | true | true | false |
| priority | true | true | false |
| statfs | true | true | false |
| reflink | conditional | conditional | conditional |
| seek_data | true | true | false |
| seek_hole | true | true | false |
| fallocate | true | conditional | false |
| termios | true | true | false |
| nss | true | true | false |
| acl | true | true | false |
| xattr | true | true | false |
| selinux | true | false | false |

## Runtime別matrix（計画値）

| capability | lnako Interpreter | lnako AOT | cnako (Node) |
| --- | --- | --- | --- |
| stream_file_io | true | true | true |
| raw_stdio | true | true | true |
| stat | true | true | true |
| lstat | true | true | true |
| symlink | true | true | true |
| readlink | true | true | true |
| realpath | true | true | true |
| rename | true | true | true |
| unlink | true | true | true |
| rmdir | true | true | true |
| truncate | true | true | true |
| utime | true | true | true |
| incremental_hash | true | true | true |
| dir_iterator | true | true | true |
| argv_spawn | true | true | true |
| signal | true | true | true |
| tty_isatty | true | true | true |
| hardlink | true | true | true |
| chmod | true | true | true |
| chown | true | true | true |
| access | true | true | true |
| uid_gid | true | true | true |
| priority | true | true | true |
| statfs | true | true | true |
| reflink | conditional | conditional | conditional |
| seek_data | true | true | false |
| seek_hole | true | true | false |
| fallocate | conditional | conditional | false |
| termios | true | true | false |
| nss | true | true | false |
| acl | true | true | false |
| xattr | true | true | false |
| selinux | true | true | false |

注: `posix_extension` のOS別 `false`（Windows）は、lnako実装では命令登録を維持し実行時に `ENOTSUP` を投げる。cnako側で `false` の capability は、Node標準APIで表現できないため実装しない。

## 照会方法

- `低レイヤー機能対応判定(NAME)` は、現在のOS・実行経路で capability が成立するかを boolean で返す。未知NAMEは `false`。
- `低レイヤー機能一覧取得()` は既知capability IDの配列を返す。
- 未対応操作の実行は `ENOTSUP` を投げ、構造化エラーの `capability` にIDを入れる。これにより、対応OSでは通常動作、非対応OSでは `ENOTSUP` を捕捉して通常read/writeへfallbackできる。

## matrixの結合規則

`低レイヤー機能対応判定(NAME)` の真偽は `catalog.json` の `matrixRule` に従い、次式で決まる。

```text
supported = os[実行OS] && runtimes[実行経路]
```

- `os` 軸と `runtimes` 軸は独立で、どちらかが `false` なら結果は `false`（false優先）。
- 両方が `true`/`conditional` のときだけ `conditional` になり、対応環境でのみ動作する。不成立は `ENOTSUP` で返す。
- 例: `chmod` は `os.windows=false`、`runtimes.cnako_node=true` のため、Windows上のcnakoでは `false` になる。Linux上のlnakoでは `true` になる。
- 例: `fallocate` は `os.windows=false` のためWindowsでは常に `false`。macOSでは `conditional` になりFS・API次第で `ENOTSUP` になり得る。Linuxでは `true`。

## 命令とcapabilityの対応

各命令が参照するcapabilityは [`catalog.json`](catalog.json) の `commands[].capability` を正本とする。命令名・助詞・戻り値・エラーの詳細は [`COMMAND_CONTRACTS.md`](COMMAND_CONTRACTS.md) を参照。