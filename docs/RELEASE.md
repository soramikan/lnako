# 配布物

配布物は、対応OSごとにビルド済みの`lnako`本体とAOTランタイム静的ライブラリ、公開ネイティブプラグインヘッダ、ライセンス、互換性資料を一つのアーカイブへまとめます。`--llvm-dir`を指定した場合は、実行時に必要なLLVM C API共有ライブラリと、AOTリンクに使うClang/LLDの最小セットも`llvm/`へ同梱します。

生成器はアーカイブ内のファイルを固定順で並べ、tar.gzまたはzipを生成し、SPDX 2.3 SBOMとSHA-256 sidecarを同時に出力します。通常の開発ビルドではLLVM/LLDを同梱しません。公開用の生成では、固定lockfileのLLVM/LLDを必ず指定します。

```sh
node tools/setup_llvm.mjs
zig build -Doptimize=ReleaseSafe
node tools/create_distribution.mjs \
  --version 1.0.0 \
  --llvm-dir "$LNAKO_LLVM_DIR" \
  --require-llvm \
  --output /absolute/path/dist
node tools/check_distribution.mjs \
  --archive /absolute/path/dist/lnako-1.0.0-macos-arm64.tar.gz
```

クロスtargetを作る場合は、そのtarget用の`lnako`実行ファイルと`liblnako_runtime.a`または`lnako_runtime.lib`を`--binary`と`--runtime`で明示します。配布targetは`macos-arm64`、`linux-x64`、`windows-x64`です。生成物の`manifest.json`にはtarget、source commit、dirty状態、固定toolchain、各payloadのSHA-256を記録します。

`check_distribution.mjs --self-test`は実バイナリを生成せず、両形式のアーカイブ構造、manifest、SPDX SBOM、外部checksumの検証経路を確認します。リリース前にはこれに加えて、3正式OSの全CI、互換性証拠、性能結果、署名済みタグを確認し、CIが未完了または失敗の状態でタグを作成しません。
