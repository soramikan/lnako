# 配布物とリリース手順

この文書は、`lnako` の配布仕様、パッケージング構成、および保守者向けのリリース手順をまとめたドキュメントです。エンドユーザー向けのインストールと使い方は[使い始める](GETTING_STARTED.md)を参照してください。

## リリース状況と配布方針

- 現在、`v0.2.1` が最新リリースです（過去のリリース: `v0.1.0`、`v0.1.1`、`v0.2.0`）。
- 配布アーカイブには、利用案内（`GETTING_STARTED.md`）、保証範囲（`COMPATIBILITY.md`）、未対応・後続課題一覧（`TODO.md`）、ライセンス、SPDX 2.3 SBOM、SHA-256チェックサムを必ず同梱します。
- macOS環境では、[Homebrew tap](https://github.com/soramikan/homebrew-tap) による手軽なインストールを提供しています。
- 配布物はmacOS arm64、Linux x86_64 GNU、Windows x86_64 MSVCの3正式環境を対象とします。

## 配布バリアント（standard版とfull版）

lnakoは利用シーンに合わせて2種類の配布バリアントを提供しています。

| 配布版 | 特徴・同梱内容 | 主な用途 |
| --- | --- | --- |
| **standard版** | 本体バイナリ＋AOTランタイムライブラリ＋ヘッダ | スクリプト直接実行（`run`）、構文チェック（`check`）。AOTコンパイルは後から `lnako toolchain install` でLLVMを導入可能 |
| **full版** | standard版の内容＋ピン留め済みLLVM/LLDツールチェーン最小セット | オフライン環境や、追加ダウンロードなしですぐにネイティブ実行ファイルをビルド（`build`）したい場合 |

### ツールチェーン管理（`lnako toolchain`）

standard版やHomebrew環境では、`lnako toolchain install` を実行することで、公式推奨のピン留め済みLLVM/LLD（基準バージョン: 22.1.8）をOS標準のキャッシュディレクトリへ自動導入・管理できます。

- **キャッシュ配置先**：
  - macOS: `~/Library/Caches/lnako/toolchains`
  - Linux: `$XDG_CACHE_HOME/lnako/toolchains`（既定: `~/.cache/lnako/toolchains`）
  - Windows: `%LOCALAPPDATA%\lnako\Cache\toolchains`
  - 環境変数 `LNAKO_TOOLCHAIN_DIR` で上書き可能
- **LLVM解決の優先順位**：
  1. `lnako build --llvm-dir <path>`
  2. 環境変数 `LNAKO_LLVM_DIR`
  3. full版の同梱 `llvm/` ディレクトリ
  4. `lnako toolchain` 管理ディレクトリ
  5. システム標準のLLVM

## リリース手順（バージョン更新フロー）

正式なリリースを行う際の手順は以下のとおりです。

1. **バージョンの同期**：
   - `build.zig.zon` の `.version` と `src/root.zig` の `pub const version` を更新対象バージョン（例: `0.2.1`）へ揃えます（`lnako --version` が一致すること）。
2. **互換性証拠の再生成**：
   - ソース変更に伴いsource manifestが更新されるため、`node tools/sync_compat_evidence.mjs` を実行して証拠を現行manifestに同期します。
3. **CI全job成功の確認**：
   - mainブランチへ取り込み、CI（39 matrix job＋変更分類・軽量検証・compiler producer・後段3 job、**合計45 job**）がfull相当ですべて成功するのを待ちます。
4. **GitHub Attestationsの確認**：
   - 同じsource commitのCIが `attest-dispatch-evidence` でcanonical証拠17件とsource manifest宣言を署名していることを確認します。Release preflightが `check_github_attestation.mjs` で公式 `gh attestation verify` と導出 `verified: 527` を要求します。gitへsnapshotをコピーする必要はありません。
5. **署名済みタグの作成とpush**：
   - CIが成功した最終コミットに対し、GPG署名付きannotated tag（例: `git tag -s v0.2.1 -m "v0.2.1"`) を作成してpushします。
6. **Release workflowの実行と公開**：
   - タグpushをトリガーに `.github/workflows/release.yml` が起動します。
   - preflightジョブが、タグ署名・バージョン一致・同一commitのCI 45 job構成でfull matrix全成功（軽量runのskippedは成功とみなさない）・canonical attestation完全検証を確認した上で、3 OSのstandard/full両バリアントおよびベンチマーク結果をビルド・検証し、GitHub Releaseとして公開します。

### ローカルでの配布物生成・検証

保守者が手動で配布物を検証・作成する場合は以下のツールを使用します。

```sh
# 依存ツールの準備
node tools/setup_llvm.mjs
node tools/setup_quickjs.mjs

# コンパイラのビルド
zig build -Doptimize=ReleaseSafe -Dcompat-js=true

# standard版の作成
node tools/create_distribution.mjs \
  --version 0.2.1 \
  --variant standard \
  --output /absolute/path/dist-standard

# full版の作成（LLVMディレクトリを指定）
node tools/create_distribution.mjs \
  --version 0.2.1 \
  --variant full \
  --llvm-dir "$LNAKO_LLVM_DIR" \
  --require-llvm \
  --output /absolute/path/dist-full

# 配布アーカイブ構造とSBOMの検証
node tools/check_distribution.mjs \
  --archive /absolute/path/dist-standard/lnako-0.2.1-macos-arm64.tar.gz
node tools/check_distribution.mjs \
  --archive /absolute/path/dist-full/lnako-0.2.1-macos-arm64-full.tar.gz
```

## macOS Developer ID署名とApple公証

macOS用バイナリは、Gatekeeperの警告なく安全に実行できるようにするため、Release workflow内でDeveloper ID Application署名とApple公証（notarization）を自動実施しています。

- **署名プロセス**：
  - `create_distribution.mjs --sign-macos` により、dylib、補助実行ファイル、lnako本体の順でsecure timestamp付き署名を実施。
  - Hardened Runtimeを有効化し、本体Identifierには `io.github.soramikan.lnako` を設定。
  - 第三者ネイティブプラグインや外部LLVMのロードを許可するため、`com.apple.security.cs.disable-library-validation` エンタイトルメントを本体に付与。
- **公証プロセス**：
  - 生成したアーカイブを一時ZIP化し、Appleの `notarytool` 経由で提出。Acceptedを確認した後、`codesign --verify --strict -R=notarized` で検証。
  - 公証ログはGitHub Actionsのartifactとして保存されます。
