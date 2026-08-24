# Third-party notices

バージョン、取得元、配布物のSHA-256は `toolchain.lock.json` と `compat/upstream.lock.json` に固定します。
上流の命令カタログに添付されるMITライセンスは `compat/v3.7.24/UPSTREAM_LICENSE` に保存します。

| Component | Version | License | Use |
| --- | --- | --- | --- |
| LLVM / LLD | 22.1.8 | Apache-2.0 WITH LLVM-exception | IR最適化、オブジェクト生成、リンク |
| Zig | 0.16.0 | MIT | コンパイラ実装とビルド |
| Nadesiko 3 | 3.7.24 | MIT | 仕様・差分テストオラクル |
| QuickJS | 2026-06-04 | MIT | 明示的なJS互換モード |
