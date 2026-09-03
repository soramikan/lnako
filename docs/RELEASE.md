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

## 3正式OSの候補生成

`.github/workflows/release.yml`は、通常の51 matrix CIへ負荷を追加せず、タグpushまたは手動実行でmacOS arm64、Linux x86_64、Windows x86_64をそれぞれbuildします。手動実行は指定versionの配布物・性能結果を検証してartifactへ保存するだけで、GitHub Releaseを作成しません。

正式な`vX.Y.Z`タグpushでは、先にannotated tagとGitHubの署名検証、source version、同じcommitのCI成功runを確認します。CIは現行の51 matrix jobに加えてdispatch coverage verifier、native AOT aggregate verifier、attestationを含む**54 jobすべてが成功**しているrunだけを受理し、job不足・失敗・skipを許可しません。その後、各OSでReleaseSafe compiler／AOT runtimeをbuildし、`lnako benchmark`のJSON/MarkdownとLLVM/LLD同梱配布物を生成します。aggregate jobは`tools/check_benchmark_set.mjs`で3 OSの計測条件とtargetを、`tools/create_release_checksums.mjs`と`tools/check_release_assets.mjs`で3 archive・sidecar・SPDX 2.3 SBOM・`SHA256SUMS`を相互検証します。publish jobはタグpush時だけ、検証済みbundleを`gh release create --verify-tag`で公開します。

このworkflowはタグやReleaseを自動で先行作成しません。source versionが`build.zig.zon`と一致しない、同じcommitの54 job全成功CI runがない、署名を検証できない場合は配布build前に停止します。

`check_distribution.mjs --self-test`は実バイナリを生成せず、両形式のアーカイブ構造、manifest、SPDX SBOM、外部checksumの検証経路に加え、tar/ZIPのメタデータ改変、manifest外entry、tar終端の改変を拒否する経路を確認します。リリース前にはこれに加えて、3正式OSの全CI、互換性証拠、性能結果、署名済みタグを確認し、CIが未完了または失敗の状態でタグを作成しません。
