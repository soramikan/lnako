# 配布物

この文書は0.1.0の配布契約と保守者向けのリリース手順です。インストールと使い方は[使い始める](GETTING_STARTED.md)を参照してください。

## リリース準備の現状（2026年9月9日）

- バージョンは`0.1.0`で統一済みです。正式GitHub Releaseと`v0.1.0`タグの公開は、下記の最終条件を満たしてから行います。
- `af137cf`の[手動Release検証 34246134617](https://github.com/soramikan/lnako/actions/runs/34246134617)は成功しています。手動検証の成功は正式公開や最終CI 54/54の代わりにはなりません。
- 同commitの[CI 34246129120](https://github.com/soramikan/lnako/actions/runs/34246129120)は失敗しており、修正後の全job成功と現行canonical attestationの追跡が公開前に必要です。
- 全6アーカイブへ利用案内`GETTING_STARTED.md`、保証範囲`COMPATIBILITY.md`、非対応・後続Issue一覧`TODO.md`を同梱します。生成・検査スクリプトで欠落を拒否します。
- macOSの導入案内は[Homebrew tap](https://github.com/soramikan/homebrew-tap)を先頭に掲載します。

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
node tools/setup_quickjs.mjs
zig build -Doptimize=ReleaseSafe -Dcompat-js=true
node tools/create_distribution.mjs \
  --version 0.1.0 \
  --variant standard \
  --output /absolute/path/dist-standard
node tools/create_distribution.mjs \
  --version 0.1.0 \
  --variant full \
  --llvm-dir "$LNAKO_LLVM_DIR" \
  --require-llvm \
  --output /absolute/path/dist-full
node tools/check_distribution.mjs \
  --archive /absolute/path/dist-standard/lnako-0.1.0-macos-arm64.tar.gz
node tools/check_distribution.mjs \
  --archive /absolute/path/dist-full/lnako-0.1.0-macos-arm64-full.tar.gz
```

クロスtargetを作る場合は、そのtarget用の`lnako`実行ファイルと`liblnako_runtime.a`または`lnako_runtime.lib`を`--binary`と`--runtime`で明示します。配布targetは`macos-arm64`、`linux-x64`、`windows-x64`です。生成物の`manifest.json`にはvariant、target、source commit、dirty状態、固定toolchain、各payloadのSHA-256を記録します。full版では、macOSのLLVM C API共有ライブラリが`@rpath`でlibc++／libc++abi／libunwindを参照するため、配布物へ`libc++.1.dylib`、`libc++abi.1.dylib`、`libunwind.1.dylib`も同梱します。

## 3正式OSの候補生成

`.github/workflows/release.yml`は、通常の51 matrix CIへ負荷を追加せず、タグpushまたは手動実行でmacOS arm64、Linux x86_64、Windows x86_64をそれぞれbuildします。手動実行は指定versionの配布物・性能結果を検証してartifactへ保存するだけで、GitHub Releaseを作成しません。

正式な`vX.Y.Z`タグpushでは、先にannotated tagとGitHubの署名検証、source version、同じcommitのCI成功runを確認します。CIは現行の51 matrix jobに加えてdispatch coverage verifier、native AOT aggregate verifier、attestationを含む**54 jobすべてが成功**しているrunだけを受理し、job不足・失敗・skipを許可しません。その後、各OSでReleaseSafe compiler／AOT runtimeをbuildし、`lnako benchmark --suite benchmarks/suites/v2.json --profile full`のJSON/Markdownとstandard・full両variantの配布物を生成します。aggregate jobは`tools/check_benchmark_set.mjs`で3 OSの計測条件とtargetを、`tools/create_release_checksums.mjs`と`tools/check_release_assets.mjs`で6 archive・sidecar・SPDX 2.3 SBOM・`SHA256SUMS`を相互検証します。publish jobはタグpush時だけ、検証済みbundleを`gh release create --verify-tag`で公開します。

このworkflowはタグやReleaseを自動で先行作成しません。source versionが`build.zig.zon`と一致しない、同じcommitの54 job全成功CI runがない、署名を検証できない場合は配布build前に停止します。

`check_distribution.mjs --self-test`は実バイナリを生成せず、両形式のアーカイブ構造、manifest、SPDX SBOM、外部checksumの検証経路に加え、tar/ZIPのメタデータ改変、manifest外entry、tar終端の改変を拒否する経路を確認します。リリース前にはこれに加えて、3正式OSの全CI、互換性証拠、性能結果、署名済みタグを確認し、CIが未完了または失敗の状態でタグを作成しません。


## macOS Developer ID署名とApple公証

Release workflowはstandard/full両版でDeveloper ID Application署名と公証を必須にします。
タグpush・手動実行の両方で実施し、資格情報不足、署名不正、公証がAccepted以外、
Gatekeeper検証失敗のいずれかなら配布assetのuploadへ進みません。手動実行では公開しません。
上記の手動Release検証で署名・公証を含む配布経路は成功済みです。以後の候補でも同じ検証を通します。

GitHub Environment `release-signing` に次のSecretsを登録します。EnvironmentはmacOS jobだけが使用します。

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | 秘密鍵込みのDeveloper ID Application証明書（p12）のBase64 |
| `MACOS_CERTIFICATE_PASSWORD` | p12のパスワード |
| `APPLE_NOTARY_KEY_P8_BASE64` | App Store ConnectのチームAPI秘密鍵（p8）のBase64 |
| `APPLE_NOTARY_KEY_ID` | API Key ID |
| `APPLE_NOTARY_ISSUER_ID` | チームAPI KeyのIssuer ID |

Environmentのdeployment branch/tag制限は信頼するrelease元に限定してください。
証明書は一時Keychainへimportし、秘密鍵ファイル・Keychainは`always()`のcleanupで削除します。
署名identityはimportしたKeychainからDeveloper ID Applicationを一意に選択します。
証明書そのものや秘密鍵はartifactへ含めません。

`create_distribution.mjs --sign-macos` は配布stagingへコピーしたMach-Oを検出し、
dylib、補助実行ファイル、lnako本体の順でsecure timestamp付き署名を行います。
LLVMキャッシュと`zig-out`は変更しません。実行ファイルにはHardened Runtimeを有効にします。
本体Identifierは **`io.github.soramikan.lnako`**、補助コードはその`.toolchain.`配下です。
静的ライブラリはcodesign対象外です。

`packaging/macos/lnako.entitlements` の `com.apple.security.cs.disable-library-validation` を
本体だけに付与し、第三者ネイティブプラグインとstandard版の外部LLVMをロード可能にします。
JIT、未署名実行メモリ、DYLD環境変数、debug用の例外は追加しません。
署名後のbytesからmanifest、SBOM、archive、SHA-256を生成します。

完成したtar.gzを検証・展開し、署名済み本体で既存Native Plugin ABI検査
（Interpreter、AOT O0〜O3、異常系）とQuickJS smokeを実行します。
full版ではLLVM環境変数を外して同梱LLVMを使用します。
同じ展開treeを一時ZIPとして`notarytool submit --wait`へ送り、Acceptedを確認した後、
全Mach-Oを`codesign --verify --strict -R=notarized --check-notarization`で検証します。
参照計画の`spctl --type execute`はapp向けのため、standalone CLI/dylib向けの検査へ置き換えています。
submission IDはActions summary、notary log（成功時のwarningを含む）は別artifactへ30日保存します。
公証ZIPは破棄し、公開するtar.gzの内容や既存のRelease asset数は変更しません。

standalone CLIとtar.gzにはticketをstapleできないため、初回のGatekeeper確認には
ネット接続が必要になる場合があります。pkg/dmg追加とstaplingは未実装です。

根拠: [Appleの公証workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、
[Library Validation例外](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)、
[CLI等の公証確認](https://developer.apple.com/forums/thread/130560)。
