# 配布物

> この文書は配布フェーズの設計・検証手順です。v0.1.0が初回の配布リリースです。

## v0.1.0リリース手順

1. バージョンを `build.zig.zon` の `.version` と `src/root.zig` の `pub const version` の両方で `0.1.0` へ揃える（`lnako --version` が `lnako 0.1.0` を返すこと）。
2. manifest入力の変更でsource manifestが変わるため、`compat/v3.7.24/attestations/current.json` は取り外し、`node tools/update_current_evidence.mjs` で証拠を現行manifestで再生成する。この時点のcanonicalはunattested。
3. mainへ取り込み、同じsource commitのCI runが54 job全成功するのを待つ。成功runが生成するattestation artifactを `compat/v3.7.24/attestations/<run>/` へ追跡し、`current.json` を更新して `evidence.json` を `verified: 527` へ再生成する。
4. 追跡snapshotを含むcommitがmainへ入ったら、そのcommitに署名済みannotated tag `v0.1.0` を作成してpushする。
5. Release workflowのpreflightが、tag署名・source version一致・同commitのCI 54 job全成功・canonical attestation全検証（current pointer存在・証拠再生成一致・追跡snapshotの公式 `gh attestation verify` と `verified: 527`）を確認してからbuild/publishへ進む。

manifest入力を変更するどの後続commitでも、tag push前に同じ再attestation手順が必要です。

配布物は、対応OSごとにビルド済みの`lnako`本体とAOTランタイム静的ライブラリ、公開ネイティブプラグインヘッダ、ライセンス、互換性資料を一つのアーカイブへまとめます。`lnako`本体はQuickJSを静的リンクした`-Dcompat-js`ビルドで、`run --compat-js`・`build --compat-js`がそのまま動作します。AOTランタイムライブラリはQuickJS stubのみを持ち、通常のAOT生成物にはQuickJSを含めません。配布時は`Verify bundled QuickJS packaging boundaries`で、compat-js実行・compat生成物への同梱・runtimeライブラリへの非同梱を3 OSで検証します。

配布variantは2種類です。**standard版** `lnako-<version>-<target>.<ext>` はLLVMを同梱しません。ユーザーは`lnako toolchain install`でpin済みLLVM 22.1.8をOS標準データdirへ導入するか、`LNAKO_LLVM_DIR`で既存LLVMを指定します。**full版** `lnako-<version>-<target>-full.<ext>` は実行時に必要なLLVM C API共有ライブラリと、AOTリンクに使うClang/LLDの最小セットを`llvm/`へ同梱し、導入直後からオフラインで`lnako build`できます。配布時は`Verify toolchain command manages LLVM`で、`toolchain dir`・`status`・`install --from-dir`・管理toolchain解決によるAOTビルド・`remove`を3 OSで検証します。

`lnako toolchain`サブコマンドの管理rootは、再download可能なキャッシュ扱いで、macOSが`~/Library/Caches/lnako/toolchains`、Linuxが`$XDG_CACHE_HOME/lnako/toolchains`（既定`~/.cache`）、Windowsが`%LOCALAPPDATA%\lnako\Cache\toolchains`です。`LNAKO_TOOLCHAIN_DIR`で上書きできます。`install`は`toolchain.lock.json`のURLを取得してSHA-256を検証し、macOS/Linuxでは同梱`llvm-config`＋`clang++`で`libLLVM-C`共有ライブラリを構築します。`--archive`（ローカルtarball）、`--from-dir`（既存LLVM treeの複製登録）、`--url`/`--sha256`（mirror向けoverride）を受け付けます。`lnako build`のLLVM解決順は`--llvm-dir` → `LNAKO_LLVM_DIR` → 同梱`llvm/`（full版）→ 管理toolchain → システムLLVMです。upstreamの完全archiveは容量が大きいため、将来的にはRelease CI側でprune済みの`lnako-toolchain-llvm-<version>-<target>` artifactを生成し、`--url`/`--sha256`で参照できる運用を想定しています。

生成器はアーカイブ内のファイルを固定順で並べ、tar.gzまたはzipを生成し、SPDX 2.3 SBOMとSHA-256 sidecarを同時に出力します。通常の開発ビルドではLLVM/LLDを同梱しません。公開用のfull版では、固定lockfileのLLVM/LLDを必ず指定します。

```sh
node tools/setup_llvm.mjs
zig build -Doptimize=ReleaseSafe
node tools/create_distribution.mjs \
  --version 1.0.0 \
  --variant standard \
  --output /absolute/path/dist-standard
node tools/create_distribution.mjs \
  --version 1.0.0 \
  --variant full \
  --llvm-dir "$LNAKO_LLVM_DIR" \
  --require-llvm \
  --output /absolute/path/dist-full
node tools/check_distribution.mjs \
  --archive /absolute/path/dist-standard/lnako-1.0.0-macos-arm64.tar.gz
node tools/check_distribution.mjs \
  --archive /absolute/path/dist-full/lnako-1.0.0-macos-arm64-full.tar.gz
```

クロスtargetを作る場合は、そのtarget用の`lnako`実行ファイルと`liblnako_runtime.a`または`lnako_runtime.lib`を`--binary`と`--runtime`で明示します。配布targetは`macos-arm64`、`linux-x64`、`windows-x64`です。生成物の`manifest.json`にはvariant、target、source commit、dirty状態、固定toolchain、各payloadのSHA-256を記録します。full版では、macOSのLLVM C API共有ライブラリが`@rpath`でlibc++／libc++abi／libunwindを参照するため、配布物へ`libc++.1.dylib`、`libc++abi.1.dylib`、`libunwind.1.dylib`も同梱します。

## 3正式OSの候補生成

`.github/workflows/release.yml`は、通常の51 matrix CIへ負荷を追加せず、タグpushまたは手動実行でmacOS arm64、Linux x86_64、Windows x86_64をそれぞれbuildします。手動実行は指定versionの配布物・性能結果を検証してartifactへ保存するだけで、GitHub Releaseを作成しません。

正式な`vX.Y.Z`タグpushでは、先にannotated tagとGitHubの署名検証、source version、同じcommitのCI成功runを確認します。CIは現行の51 matrix jobに加えてdispatch coverage verifier、native AOT aggregate verifier、attestationを含む**54 jobすべてが成功**しているrunだけを受理し、job不足・失敗・skipを許可しません。その後、各OSでReleaseSafe compiler／AOT runtimeをbuildし、`lnako benchmark --suite benchmarks/suites/v2.json --profile full`のJSON/Markdownとstandard・full両variantの配布物を生成します。aggregate jobは`tools/check_benchmark_set.mjs`で3 OSの計測条件とtargetを、`tools/create_release_checksums.mjs`と`tools/check_release_assets.mjs`で6 archive・sidecar・SPDX 2.3 SBOM・`SHA256SUMS`を相互検証します。publish jobはタグpush時だけ、検証済みbundleを`gh release create --verify-tag`で公開します。

このworkflowはタグやReleaseを自動で先行作成しません。source versionが`build.zig.zon`と一致しない、同じcommitの54 job全成功CI runがない、署名を検証できない場合は配布build前に停止します。

`check_distribution.mjs --self-test`は実バイナリを生成せず、両形式のアーカイブ構造、manifest、SPDX SBOM、外部checksumの検証経路に加え、tar/ZIPのメタデータ改変、manifest外entry、tar終端の改変を拒否する経路を確認します。リリース前にはこれに加えて、3正式OSの全CI、互換性証拠、性能結果、署名済みタグを確認し、CIが未完了または失敗の状態でタグを作成しません。
