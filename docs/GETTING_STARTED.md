# lnakoを使い始める

`lnako` は、日本語プログラミング言語「なでしこ3」を高速に実行し、単一のネイティブ実行ファイルへコンパイルできるCLIツールです。
互換基準はなでしこ3 v3.7.24です。[保証範囲](COMPATIBILITY.md)と[未対応境界](TODO.md)も合わせて確認してください。

## 1. インストール

利用環境に合わせて、HomebrewまたはGitHub Releasesからのアーカイブ導入を選択してください。

### macOS：Homebrewでインストール（推奨）

[Homebrew](https://brew.sh/) を導入済みの環境では、次のコマンドで簡単にインストールできます。

```sh
brew tap soramikan/tap
brew install lnako
lnako --version
```

- Apple Silicon（macOS arm64）を正式検証対象としています。
- 更新は `brew update && brew upgrade lnako`、アンインストールは `brew uninstall lnako` です。
- インストール直後から `lnako run` でプログラムを実行できます。ネイティブ実行ファイルを作る場合は初回に後述の `lnako toolchain install` を実行してください。

### Linux・Windows・手動アーカイブ導入

[GitHub Releases](https://github.com/soramikan/lnako/releases) から、お使いのOS・環境に合ったアーカイブをダウンロードします。

#### standard版とfull版の選び方

- **standard版**：プログラムの実行（`run`）や構文検査（`check`）を手軽に始めたい方向けの軽量版です。コンパイルに必要なLLVM/LLDは後から `lnako toolchain install` で自動ダウンロード・管理できます。
- **full版**：LLVM/LLDを同梱しています。追加のダウンロードなしで、オフライン環境でもすぐにネイティブ実行ファイルの生成（`build`）を行いたい方におすすめです。

| OS / CPU | standard版 | full版（LLVM/LLD同梱） |
| --- | --- | --- |
| macOS arm64 | `lnako-0.2.4-macos-arm64.tar.gz` | `lnako-0.2.4-macos-arm64-full.tar.gz` |
| Linux x86_64 GNU | `lnako-0.2.4-linux-x64.tar.gz` | `lnako-0.2.4-linux-x64-full.tar.gz` |
| Windows x86_64 MSVC | `lnako-0.2.4-windows-x64.zip` | `lnako-0.2.4-windows-x64-full.zip` |

#### 展開とPATHの設定

アーカイブと同名で配布されている `.sha256` ファイルを取得し、展開前にハッシュ値を確認することを推奨します。

```sh
# macOSの例（ダウンロードファイルと照合）
shasum -a 256 -c lnako-0.2.4-macos-arm64.tar.gz.sha256
tar -xzf lnako-0.2.4-macos-arm64.tar.gz

# Linuxの例
sha256sum -c lnako-0.2.4-linux-x64.tar.gz.sha256
tar -xzf lnako-0.2.4-linux-x64.tar.gz
```

```powershell
# Windows PowerShellの例（ハッシュ値を確認して展開）
Get-FileHash .\lnako-0.2.4-windows-x64.zip -Algorithm SHA256
Expand-Archive .\lnako-0.2.4-windows-x64.zip -DestinationPath .\lnako
```

展開したフォルダ全体を任意の場所（例: `~/lnako` や `C:\tools\lnako`）に配置し、その中の `bin` フォルダを環境変数 `PATH` に追加してください。

> [!NOTE]
> `bin/lnako` 単体を取り出さず、展開されたフォルダ構造（`bin/`, `lib/`, full版の場合は `llvm/`）を維持してください。コンパイルに必要なライブラリが解決できなくなります。
> macOSのReleaseアーカイブはAppleの公証を通過していますが、初回起動時にGatekeeperの確認画面が表示される場合があります。

## 2. プログラムを実行する

UTF-8のテキストファイル `hello.nako3` を作成します。

```nako3
「こんにちは、世界！」と表示する。
```

ターミナルで以下のコマンドを実行します。

```sh
# 構文・意味の事前チェック（実行はしません）
lnako check hello.nako3

# プログラムをインタープリターで直接実行
lnako run hello.nako3
```

コンソールに `こんにちは、世界！` と表示されれば成功です。

## 3. ネイティブ実行ファイルを生成する（コンパイル）

lnakoは、なでしこ3プログラムをLLVM経由で最適化されたスタンドアロンのネイティブ実行ファイルへコンパイル（AOTコンパイル）できます。

### ツールチェーンの準備（standard版・Homebrew版のみ）

full版をご利用の場合はこの手順は不要です。standard版またはHomebrew版で初めてコンパイルを行う場合、一度だけツールチェーンを導入します。

```sh
# LLVM/LLDツールチェーンをインストール（OS標準キャッシュ領域に配置されます）
lnako toolchain install

# 状態を確認
lnako toolchain status
```

### コンパイルと実行

```sh
# 最適化レベル -O2 で実行ファイルを生成
lnako build hello.nako3 -o hello -O2

# 生成されたバイナリを実行
./hello
```

Windows環境では `-o hello.exe` を指定し、`.\hello.exe` で実行します。

> [!TIP]
> 生成された実行ファイルは単体で動作します。実行する環境にlnako、Zig、Node.js、LLVMなどを別途インストールする必要はありません（OS標準ライブラリや使用する外部ファイル等は必要です）。

既存のLLVMを使用したい場合は、`--llvm-dir /path/to/llvm` オプションまたは環境変数 `LNAKO_LLVM_DIR` で指定することも可能です（基準バージョンはLLVM 22.1.8）。

## 4. DNCL（情報入試手順記述言語）の実行

lnakoは大学入学共通テスト「情報I」で用いられる手順記述標準言語「DNCL」および「DNCL2」の実行・コンパイルに完全対応しています。

ファイル拡張子（`.dncl` / `.dncl2`）、ファイル先頭の指示（`!DNCLモード` / `!DNCL2`）、またはコマンドライン引数でモードを指定できます。

```sh
# DNCLファイルの実行・ビルド
lnako run program.dncl
lnako build program.dncl -o program -O2

# テスト実行
lnako test program.dncl

# .nako3 ファイルをDNCL2として強制実行
lnako run program.nako3 --dncl2
```

配列添字の開始番号（1始まり）など、モードごとの詳細な挙動は[Parser・構文のquirks](compatibility/PARSER.md)を参照してください。

## 5. パッケージを使う

`nako.toml` を持つディレクトリをプロジェクトと呼びます。依存は `nako.toml` の `[dependencies.<種別>]` に宣言し、`nako.lock` に固定したうえで、`.nako/` に構築した環境から取り込みます。`run` / `test` / `build` はプロジェクト内の入力を実行する前に、必要な lock 更新と環境準備を自動で行います。

### プロジェクトを作る

```sh
lnako init myapp            # nako.toml を作成
lnako init mylib --lib      # ライブラリ用の [[exports]] と src/・examples/・tests/ を作成
```

パッケージ名は `[a-z][a-z0-9-]{0,63}` です。ディレクトリ名が規則に合わない場合は `--name` で指定します。`init` が生成する `nako.toml` は `[package]` の `name`・`version`・`license` だけの最小構成です。`--lib` を付けると `src/lib.nako3` を指す `[[exports]]` と、動作確認用のサンプル・テストも生成します。

### 依存を追加する

```sh
lnako add util --path ../util                # ローカルの path 依存
lnako add text --git https://github.com/example/text --commit <commitハッシュ>
lnako add data --http https://example.com/data.tar.gz --hash sha256:<64桁hex>
lnako add sqlite@^1.2.0 --registry https://registry.example.com   # 配布済みパッケージ
lnako remove util
```

`add` は `nako.toml` へ依存を追記し、その場で lock を更新します。manifest を変更するため `add` / `remove` / `update` では `--locked` を使えません。`add` は依存解決まで行うため、追加先は対象 runtime で解決できる公開 export を持つ必要があります（例: `lnako init --lib` の生成物）。

`--npm` は現行 CLI では未対応です。npm 依存は `nako.toml` に直接書いて `lnako lock` で解決します。

#### nako.toml の依存宣言

```toml
[package]
name = "myapp"
version = "0.1.0"
license = "MIT"

[dependencies.path]
util = { path = "../util" }

[dependencies.npm]
left-pad = "^1.0.0"

[dependencies.pkg]
sqlite = { version = "^1.2.0" }

[dependencies.git]
text = { url = "https://github.com/example/text", commit = "<commitハッシュ>" }

[dependencies.http]
data = { url = "https://example.com/data.tar.gz", hash = "sha256:<64桁hex>" }
```

- path: 同じリポジトリやローカルで開発中のパッケージ。lock には規範化したパスと `mutable` フラグを記録します。`mutable = false`（既定）は内容 hash で pin し、`mutable = true` は内容 digest を記録して変更時に lock と環境の再生成を駆動します。
- npm: npm の ESM package。`--compat-js` の実行時だけ bare import として解決します。
- pkg: 配布済みパッケージ。`--registry <url>` または環境変数 `LNAKO_REGISTRY` で静的レジストリを指定します。
- git: commit で固定する Git リポジトリの依存。
- http: hash で固定する tarball の依存。

npm 依存の取得先は `LNAKO_NPM_REGISTRY`（既定 `https://registry.npmjs.org`）で差し替えられます。外部ネットワークを使わずに試す場合、後述の `tests/fixtures/package-plugin-npm/` は loopback の fixture registry を使います。

### lock・sync・実行

```sh
lnako lock                # 依存を解決して nako.lock を更新
lnako sync                # lock から .nako/ 環境を構築
lnako run main.nako3      # 必要なら lock/sync を自動実行してから実行
lnako tree                # 解決済み依存のツリー
lnako why util            # 依存理由
lnako check               # プロジェクトの依存・環境・命令メタデータを検査
```

プロジェクト内の入力を `run` / `test` / `build` すると、準備が必要なときに自動で lock 更新と環境構築が走り、`run: 依存環境を準備しました（profile: default）` のようなメッセージが stderr に出ます。すでに環境が最新のときはメッセージが出ません。プロジェクト外のファイルを実行するときは準備を行いません。

準備を制御するフラグ:

| フラグ | 動作 |
| --- | --- |
| `--locked` | `nako.lock` を変更しない。不足・陳腐なら失敗する |
| `--offline` | ネットワーク取得を禁止し、取得済み cache だけで解決する |
| `--no-sync` | `run` / `test` / `build` で `.nako` の自動準備をしない。既存環境だけを使う |
| `--profile <name>` | 使用する profile。省略時は `default`、無ければ唯一の profile |
| `--features <a,b>` / `--no-default-features` | 有効化する feature を選ぶ |

`--no-sync` は、環境が削除されている場合や lock と一致しない場合に失敗します。`--locked` は `sync` / `lock` / `tree` / `why` / `check` でも使えます。cache の場所は `lnako cache dir`、削除は `lnako cache clean`、プロジェクト単位の指定は `--package-cache-dir <path>` です。

### パッケージを取り込む

```nako3
!「パッケージ:util」を取り込む
util__二倍(21)を表示。
```

上の `util` は `lnako init --lib` が生成する `二倍` 関数を公開しているパッケージです。実際の公開名は依存先の export に合わせてください。

- 標準表記は `パッケージ:`、後方互換の別名が `pkg:` です。両者は同じ参照へ正規化されます。
- `パッケージ:util/calc` のように subpath で export を選べます。export の `alias` も subpath として使えます。
- 公開名には取り込んだ alias の接頭辞が付きます（`util__二倍`、subpath は `util__calc__計算`）。
- 依存に無い alias、非公開の subpath、`パッケージ:util@1.0.0` のような version 指定は拒否されます。
- パッケージ内の相対取り込みは境界の内側に限定され、境界外へ出る取り込みは拒否されます。

### 外部ネットワークなしで試す

`tests/fixtures/package-common/` は path 依存だけで構成されており、オフラインで実行できます。

```sh
cd tests/fixtures/package-common/app
../../../../zig-out/bin/lnako run main.nako3
```

この実行で fixture 内に `.nako/` と `nako.lock` が作られます（`.gitignore` 済み）。この fixture の `util` は `道具` を公開しているため、呼び出しは `util__道具()` です。期待出力は `tests/fixtures/package-common/expected-stdout.txt` です。AOT の fixture は `tests/fixtures/package-aot/app`、ESM plugin と npm の併用は `tests/fixtures/package-plugin-npm/` を使います。

パッケージの作成・公開・配布は[パッケージの作成・公開・配布](package-system/PUBLISHING.md)、仕様の詳細は[パッケージシステム仕様案](package-system/SPECIFICATION.md)、cnako からの移行は[cnakoからの移行](compatibility/CNAKO_MIGRATION.md)を参照してください。

## 6. JavaScript互換モード（`--compat-js`）

公式なでしこ3のうち、JavaScript固有の命令（`JS実行`、`JSオブジェクト取得`、`JS関数実行`、`JSメソッド実行`）に依存するコードを実行する場合は、明示的に `--compat-js` フラグを付与します。

```sh
lnako run program.nako3 --compat-js
lnako build program.nako3 --compat-js -o program -O2
```

`build --compat-js` の既定は従来の同梱実行ファイル方式（embedded）です。
LLVM AOT＋QuickJS runtime は `--backend aot` の明示opt-inで、通常AOTとは別の
`liblnako_runtime_compat.a` をリンクします。

lnakoの配布バイナリには軽量JavaScriptエンジン（QuickJS）が組み込まれていますが、通常モードでは使用されず、余分なオーバーヘッドは発生しません。詳細は[互換モードの説明](compatibility/COMPAT_JS.md)を参照してください。

## 7. よくある質問・トラブルシューティング

- **`lnako` コマンドが見つからない**
  - アーカイブ内の `bin` フォルダへのパスが環境変数 `PATH` に正しく追加されているか確認してください。設定後はターミナルを再起動してください。
- **`build` 時にLLVMが見つからないエラーが出る**
  - standard版またはHomebrew版をご利用の場合は、まず `lnako toolchain install` を実行してください。オフライン環境の場合は最初からfull版をご利用いただくか、`--llvm-dir` でローカルのLLVMを指定してください。
- **公式cnakoと実行結果や挙動が異なる**
  - lnakoは標準cnako 527命令の網羅的な互換性検証を行っていますが、ブラウザ専用命令や未定義の例外挙動など一部差異があります。[互換性の保証範囲](COMPATIBILITY.md)および[既知の境界・TODO](TODO.md)をご確認ください。
  - cnako からの移行時の差異は[cnakoからの移行](compatibility/CNAKO_MIGRATION.md)にまとめています。
- **パッケージ取り込みでエラーになる**
  - `nako.toml` の依存 alias、export の subpath、version 指定の有無を確認してください。`lnako check` で依存・環境・命令メタデータの状態を確認できます。`run --offline` で失敗する場合は cache が不足しています。
- **npm 依存を `add` で追加できない**
  - `lnako add --npm` は未対応です。`nako.toml` の `[dependencies.npm]` へ直接書き、`lnako lock` を実行してください。
- **バグと思われる挙動を発見した場合**
  - 再現コードとOS、`lnako --version` を添えて [GitHub Issues](https://github.com/soramikan/lnako/issues) へご報告ください。
