# lnakoを使い始める

なでしこ3のソースをそのまま実行するには`lnako run`、ネイティブ実行ファイルを生成するには`lnako build`を使います。互換基準はなでしこ3 v3.7.24です。[保証範囲](COMPATIBILITY.md)と[未対応境界](TODO.md)も確認してください。

## macOS：Homebrewでインストール

[Homebrew](https://brew.sh/)を導入した環境で、[soramikanのtap](https://github.com/soramikan/homebrew-tap)を使います。

```sh
brew tap soramikan/tap
brew install lnako
lnako --version
```

対応するbottleがある環境ではビルド済みバイナリを利用し、それ以外ではZigをビルド依存としてソースから構築します。正式検証対象のmacOSはApple Silicon（arm64）です。

更新は`brew update`、`brew upgrade lnako`、削除は`brew uninstall lnako`です。

## アーカイブからインストール

[GitHub Releases](https://github.com/soramikan/lnako/releases)から対象OS・CPUのファイルを選びます。

| OS / CPU | standard版 | full版 |
| --- | --- | --- |
| macOS arm64 | `lnako-0.1.0-macos-arm64.tar.gz` | `lnako-0.1.0-macos-arm64-full.tar.gz` |
| Linux x86_64 GNU | `lnako-0.1.0-linux-x64.tar.gz` | `lnako-0.1.0-linux-x64-full.tar.gz` |
| Windows x86_64 MSVC | `lnako-0.1.0-windows-x64.zip` | `lnako-0.1.0-windows-x64-full.zip` |

standard版はLLVM/LLDを含まず、full版は同梱します。`lnako run`はどちらでも使えます。AOTをすぐ使いたい場合はfull版を選びます。

アーカイブと同名の`.sha256`も取得し、展開前にハッシュを照合します。

```sh
# macOSの例
shasum -a 256 -c lnako-0.1.0-macos-arm64.tar.gz.sha256
tar -xzf lnako-0.1.0-macos-arm64.tar.gz
# Linuxでは sha256sum -c を使用
```

```powershell
# Windows PowerShellの例：出力を.sha256に記載された値と照合
Get-FileHash .\lnako-0.1.0-windows-x64.zip -Algorithm SHA256
Expand-Archive .\lnako-0.1.0-windows-x64.zip -DestinationPath .\lnako
```

展開したディレクトリ全体を任意の場所へ配置し、その中の`bin`をPATHへ追加します。`bin/lnako`だけを取り出すと、AOT用の`lib`やfull版の`llvm`を解決できなくなるため、配置関係を保ってください。

macOSのReleaseアーカイブはDeveloper ID署名・Apple公証を通して配布します。standalone CLIには公証ticketをstapleできないため、初回起動時の確認にネット接続が必要になる場合があります。

## プログラムを実行

UTF-8のテキストファイル`hello.nako3`を作ります。

```nako3
「こんにちは」と表示する。
```

```sh
lnako check hello.nako3
lnako run hello.nako3
```

`こんにちは`と表示されます。`check`は実行せずに構文・意味を検査します。

## ネイティブ実行ファイルを生成

Homebrewまたはstandard版では、最初にLLVM/LLDを導入します。full版ではこの操作は不要です。

```sh
lnako toolchain install
lnako toolchain status
lnako build hello.nako3 -o hello -O2
./hello
```

Windowsでは`lnako build hello.nako3 -o hello.exe -O2`で生成し、`.\hello.exe`を実行します。

既存LLVMを使う場合は`lnako build hello.nako3 --llvm-dir /path/to/llvm -o hello -O2`、または環境変数`LNAKO_LLVM_DIR`で指定できます。基準版はLLVM/LLD 22.1.8です。toolchainはOS標準のキャッシュ領域へ保存され、`lnako toolchain dir`で場所を確認、`lnako toolchain remove`で削除できます。

通常の生成物を動かす側にlnako・Zig・Node.js・LLVMは不要です。対象OSの標準ライブラリ、使用するファイル・外部ツール・動的ネイティブプラグインなどは別途必要です。別OS用の実行ファイルへの自動変換を保証するものではありません。

## JavaScript互換モード

JavaScript固有の4命令が必要なプログラムでは、明示的に`--compat-js`を指定します。配布版とHomebrew版はQuickJSを同梱しています。

```sh
lnako run program.nako3 --compat-js
lnako build program.nako3 --compat-js -o program -O2
```

通常モードはQuickJSを使わず、通常AOT生成物にもQuickJSを含めません。詳細は[互換モードの説明](https://github.com/soramikan/lnako/blob/main/docs/compatibility/COMPAT_JS.md)を参照してください。

## 問題が起きたら

- `lnako`が見つからない：`bin`をPATHへ追加した後、ターミナルを開き直します。
- `build`でLLVMが見つからない：`lnako toolchain status`で確認し、toolchainを導入するかfull版を使います。
- 公式処理系と結果が違う：[互換性の保証範囲](COMPATIBILITY.md)と[既知の境界](TODO.md)を確認してください。報告は[GitHub Issues](https://github.com/soramikan/lnako/issues)へ、OS、`lnako --version`、実行コマンド、最小ソース、期待値と実際の結果を添えてください。
