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
| macOS arm64 | `lnako-0.2.0-macos-arm64.tar.gz` | `lnako-0.2.0-macos-arm64-full.tar.gz` |
| Linux x86_64 GNU | `lnako-0.2.0-linux-x64.tar.gz` | `lnako-0.2.0-linux-x64-full.tar.gz` |
| Windows x86_64 MSVC | `lnako-0.2.0-windows-x64.zip` | `lnako-0.2.0-windows-x64-full.zip` |

#### 展開とPATHの設定

アーカイブと同名で配布されている `.sha256` ファイルを取得し、展開前にハッシュ値を確認することを推奨します。

```sh
# macOSの例（ダウンロードファイルと照合）
shasum -a 256 -c lnako-0.2.0-macos-arm64.tar.gz.sha256
tar -xzf lnako-0.2.0-macos-arm64.tar.gz

# Linuxの例
sha256sum -c lnako-0.2.0-linux-x64.tar.gz.sha256
tar -xzf lnako-0.2.0-linux-x64.tar.gz
```

```powershell
# Windows PowerShellの例（ハッシュ値を確認して展開）
Get-FileHash .\lnako-0.2.0-windows-x64.zip -Algorithm SHA256
Expand-Archive .\lnako-0.2.0-windows-x64.zip -DestinationPath .\lnako
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

## 5. JavaScript互換モード（`--compat-js`）

公式なでしこ3のうち、JavaScript固有の機能（`JS実行`、`JSコード追加`、`JSグローバル取得`、`JSグローバル設定`）に依存するコードを実行する場合は、明示的に `--compat-js` フラグを付与します。

```sh
lnako run program.nako3 --compat-js
lnako build program.nako3 --compat-js -o program -O2
```

lnakoの配布バイナリには軽量JavaScriptエンジン（QuickJS）が組み込まれていますが、通常モードでは使用されず、余分なオーバーヘッドは発生しません。詳細は[互換モードの説明](compatibility/COMPAT_JS.md)を参照してください。

## 6. よくある質問・トラブルシューティング

- **`lnako` コマンドが見つからない**
  - アーカイブ内の `bin` フォルダへのパスが環境変数 `PATH` に正しく追加されているか確認してください。設定後はターミナルを再起動してください。
- **`build` 時にLLVMが見つからないエラーが出る**
  - standard版またはHomebrew版をご利用の場合は、まず `lnako toolchain install` を実行してください。オフライン環境の場合は最初からfull版をご利用いただくか、`--llvm-dir` でローカルのLLVMを指定してください。
- **公式cnakoと実行結果や挙動が異なる**
  - lnakoは標準cnako 527命令の網羅的な互換性検証を行っていますが、ブラウザ専用命令や未定義の例外挙動など一部差異があります。[互換性の保証範囲](COMPATIBILITY.md)および[既知の境界・TODO](TODO.md)をご確認ください。
  - バグと思われる挙動を発見した場合は、再現コードとOS、`lnako --version` を添えて [GitHub Issues](https://github.com/soramikan/lnako/issues) へご報告ください。
