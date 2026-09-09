# lnako

`lnako` は、なでしこ3の日本語プログラムを実行し、ネイティブ実行ファイルにも変換できるCLIです。なでしこ3 v3.7.24を互換基準とし、macOS arm64・Linux x86_64 GNU・Windows x86_64 MSVCに対応します。製品バージョンは `0.1.0` です。

## インストール

### macOS：Homebrew

[Homebrew tap](https://github.com/soramikan/homebrew-tap)からインストールできます。

```sh
brew tap soramikan/tap
brew install lnako
lnako --version
```

対応するbottleがあればビルド済みバイナリを利用し、それ以外はソースからビルドします。`lnako run`はインストール直後から使えます。

### Linux・Windows／アーカイブからの導入

[GitHub Releases](https://github.com/soramikan/lnako/releases)から対象OSのアーカイブを取得し、ディレクトリ構造を保って展開して`bin`をPATHへ追加します。macOS/Linuxは`tar.gz`、Windowsは`zip`です。

| 配布版 | 用途 |
| --- | --- |
| standard | 小さな構成で始める。実行ファイルの生成にはLLVM/LLDを追加導入 |
| full（ファイル名末尾が`-full`） | LLVM/LLDを同梱。追加のダウンロードなしで実行ファイルを生成 |

チェックサム確認・OS別手順は[使い始める](docs/GETTING_STARTED.md)を参照してください。

## 使ってみる

`hello.nako3`を次の内容で保存します。

```nako3
「こんにちは」と表示する。
```

```sh
lnako run hello.nako3            # そのまま実行
lnako check hello.nako3          # 構文・意味をチェック
lnako toolchain install          # Homebrew/standard版でAOTを使う場合に一度実行
lnako build hello.nako3 -o hello -O2
./hello                         # Windowsでは .\hello.exe
```

Windowsの生成先は`-o hello.exe`にします。生成した通常の実行ファイルには、実行時のlnako・Zig・Node.js・LLVMのインストールは不要です。OSの標準ライブラリや使用する外部プラグインなどは必要です。

JavaScript固有命令を使う場合は`lnako run hello.nako3 --compat-js`のように明示します。配布版にはQuickJSを同梱していますが、通常実行には使いません。詳しくは[互換モード](docs/compatibility/COMPAT_JS.md)を参照してください。

## 対応範囲

標準cnako 527 entryの実装分類は`native` 523、`compat-js` 4、`blocked` 0です。ブラウザ専用・拡張命令は対象外で、全入力やNode/ECMAScriptの全挙動を保証するものではありません。[互換性と保証範囲](docs/COMPATIBILITY.md)、[未対応境界・後続課題](docs/TODO.md)、[公式処理系との挙動差](docs/COMPATIBILITY_QUIRKS.md)を確認してください。件数と検証状態の正本は[`compat/`](compat/)です。

## 性能比較

2026年9月9日（日本時間）の[リリース候補比較CI](https://github.com/soramikan/lnako/actions/runs/34246129122)、測定commit `5dcf585`の結果です。以下はLinuxの代表9ケースで、warmup 1回・測定3回の中央値（ms）。lnakoはReleaseSafe、AOTはO2です。

cnako・gonako・lnakoを正式比較とします。gonakoは3.8.1配布版をハッシュ固定し、自己表示は3.6.0です。cnako比は「cnakoの中央値 ÷ lnakoの中央値」で、例えば4倍は所要時間が約1/4、1倍未満はcnakoより遅いことを表します。丸め前の値から計算しています。

| 分野 | ケース | cnako 3.7.24 | gonako | lnako Interpreter | cnako比 | lnako AOT | cnako比 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 起動 | `startup-hello` | 106.54 | 6.61 | 2.49 | 42.77倍 | 1.79 | 59.68倍 |
| 関数呼出し | `function-call` | 169.74 | 116.86 | 310.44 | 0.55倍 | 33.02 | 5.14倍 |
| 浮動小数点 | `nbody` | 158.66 | 47.09 | 391.49 | 0.41倍 | 15.05 | 10.54倍 |
| 辞書検索 | `hash-lookup` | 142.23 | 72.51 | 481.68 | 0.30倍 | 50.36 | 2.82倍 |
| 文字列連結 | `string-concat` | 117.76 | 22.75 | 56.51 | 2.08倍 | 28.21 | 4.17倍 |
| Unicode | `unicode-scan` | 128.67 | 58.46 | 337.20 | 0.38倍 | 29.53 | 4.36倍 |
| メモリ・GC | `binary-trees` | 163.48 | 51.74 | 48.76 | 3.35倍 | 17.20 | 9.51倍 |
| 単語集計 | `word-count` | 125.37 | 37.12 | 251.92 | 0.50倍 | 15.20 | 8.25倍 |
| JSON変換 | `json-transform` | 128.48 | 22.97 | 67.21 | 1.91倍 | 7.12 | 18.03倍 |

起動・終了とケース内の初期化を含む時間で、AOTの事前コンパイルは含みません。短時間の測定は共有CIの負荷に左右されます。コンパイル時間、全19ケース・3 OSの結果、生サンプル、C/Rustの参考値は[詳細結果](docs/benchmarks/RESULTS.md)に分けて掲載しています。

## 開発者向け

lnako自体をソースからビルド・変更する場合は[開発・検証手順](docs/DEVELOPMENT.md)を参照してください。Zig 0.16.0、LLVM/LLD 22.1.8、oracle用Node.js 24.15.0、互換モード用QuickJS 2026-06-04を使用します。公式TypeScriptは製品ランタイムへ組み込みません。

- [アーキテクチャ](docs/ARCHITECTURE.md)・[ネイティブプラグインABI](docs/NATIVE_PLUGIN_ABI.md)
- [CIと検証](docs/CI.md)・[互換性証拠](docs/COMPATIBILITY_EVIDENCE.md)
- [配布とリリース手順](docs/RELEASE.md)・[ベンチマーク再測定](benchmarks/README.md)

## ライセンス

MIT License。互換テストで参照するなでしこ3もMIT Licenseです。第三者依存関係は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)に記録しています。
