# Third-party notices

バージョン、取得元、配布物のSHA-256は `toolchain.lock.json` と `compat/upstream.lock.json` に固定します。
上流の命令カタログに添付されるMITライセンスは `compat/v3.7.24/UPSTREAM_LICENSE` に保存します。

| Component | Version | License | Use |
| --- | --- | --- | --- |
| LLVM / LLD | 22.1.8 | Apache-2.0 WITH LLVM-exception | IR最適化、オブジェクト生成、リンク |
| Zig | 0.16.0 | MIT | コンパイラ実装とビルド |
| Nadesiko 3 | 3.7.24 | MIT | 仕様・差分テストオラクル |
| QuickJS | 2026-06-04 | MIT | 配布バイナリへ静的リンク（明示的なJS互換モード `--compat-js`） |

QuickJSは配布する `lnako` 実行ファイルへ静的リンクします。native AOTの生成物には、利用者が `--compat-js` を指定した場合にのみ含まれ、通常のAOT生成物と `liblnako_runtime.a` には含まれません。

## QuickJS license

QuickJS Javascript Engine

Copyright (c) 2017-2021 Fabrice Bellard
Copyright (c) 2017-2021 Charlie Gordon

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
