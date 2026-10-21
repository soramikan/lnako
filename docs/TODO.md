# 実装状況と未対応境界（TODO）

この文書は、`lnako` の実装状況、現行バージョンにおいて意図的に保証対象外としている境界、および後続Issue・機能拡張計画をまとめた正本です。
互換基準はなでしこ3 v3.7.24（`aa18c7e640523938c680958fe731418cc6f7a58f`）で、標準cnako 527 entryの機械可読な実装・実行証拠は [`compat/v3.7.24/`](../compat/v3.7.24/) を正本とします。

`verified: 527` は、追跡されたfixture・dispatch・公式比較・3 OS attestationに基づく命令entryの実行証拠です。全ての入力値、Node/ECMAScript APIの全境界、実ネットワーク・外部アプリ・任意の外部toolまで完全同値であることを意味しません。未検証境界は本書と [互換性の概要](COMPATIBILITY.md) に明示します。

## リリース済みの状態（v0.1.0 / v0.1.1 / v0.2.0 / v0.2.1 / v0.2.2 / v0.2.3 / v0.2.4）

- **v0.1.0（初回正式リリース）**：
  - 標準cnako 527 entry（native 523、compat-js 4、blocked 0）の実装と、macOS arm64・Linux x86_64・Windows x86_64の3 OSにおけるCI 54/54全job成功・attestation検証を達成。
  - AOT動的値ブリッジのGC root安全性（[#2](https://github.com/soramikan/lnako/issues/2)）、利用者向け導線・配布契約（[#13](https://github.com/soramikan/lnako/issues/13)）、リリースワークフロー（[PR #1](https://github.com/soramikan/lnako/pull/1)）を完了。
- **v0.1.1（入力改善・和文代入拡充）**：
  - 対話型（TTY）における「尋ねる」の一行読み込み・CRLF対応・複数行入力の安定化（[#24](https://github.com/soramikan/lnako/pull/24)）。
  - 連文結果の和文代入、「Aを1に定める」構文、配列・プロパティへの代入の拡充。
- **v0.2.0（パッケージシステム基盤・低レイヤーAPI拡充・証拠管理刷新）**：
  - なでしこ3パッケージシステム仕様案の策定およびZig製PubGrub依存解決器・マニフェスト解析・適合性検証の初期実装（[#66](https://github.com/soramikan/lnako/pull/66), [#67](https://github.com/soramikan/lnako/pull/67), [#69](https://github.com/soramikan/lnako/pull/69), [#79](https://github.com/soramikan/lnako/pull/79)）。
  - 低レイヤーAPIのG0 Foundation、raw標準入出力、ストリームI/O、逐次ハッシュAPI、低層ファイルシステムAPI（stat/lstat/link/rename/unlink）の追加（[#68](https://github.com/soramikan/lnako/pull/68), [#75](https://github.com/soramikan/lnako/pull/75), [#76](https://github.com/soramikan/lnako/pull/76), [#77](https://github.com/soramikan/lnako/pull/77)）。
  - DNCL完全互換と直接コンパイル対応、構造例外責務分割（[#71](https://github.com/soramikan/lnako/pull/71)）。
  - 互換性証拠のcanonical形分離と走査型snapshot解決への移行（[#80](https://github.com/soramikan/lnako/pull/80)）。
  - ドキュメント類の利用者向け全面刷新。
- **v0.2.1（バグ修正リリース）**：
  - HTTPSのAJAX通信およびHTTPリダイレクト時のTLS初期化panicを修正し安定化（[#82](https://github.com/soramikan/lnako/issues/82), [#97](https://github.com/soramikan/lnako/pull/97)）。
  - 先頭のUTF-8 BOM読み飛ばしによるBOM付きソースコード実行への対応（[#94](https://github.com/soramikan/lnako/pull/94)）。
  - インデント構文における『エラーならば』が『違えば』同様にエラー監視スコープを閉じないよう構文解析を修正（[#81](https://github.com/soramikan/lnako/issues/81), [#95](https://github.com/soramikan/lnako/pull/95)）。
  - CI/CDパイプライン改善（変更分類Stage 2、Windows producer最適化、クリティカルパス平準化、GitHub Attestations移行）。
- **v0.2.2（言語互換性・パッケージシステム・低レイヤーAPI拡充）**：
  - **なでしこ3言語構文・セマンティクス改善**：
    - 「それ」の関数ローカルスコープ分離（[#116](https://github.com/soramikan/lnako/issues/116), [#150](https://github.com/soramikan/lnako/pull/150)）、助詞呼出し時の省略引数補完（[#105](https://github.com/soramikan/lnako/issues/105), [#106](https://github.com/soramikan/lnako/pull/106)）、連文伝播と戻り値無し連鎖（[#114](https://github.com/soramikan/lnako/issues/114), [#162](https://github.com/soramikan/lnako/pull/162)）、反復・範囲繰り返しでの束縛とシステム変数復元（[#112](https://github.com/soramikan/lnako/issues/112), [#149](https://github.com/soramikan/lnako/pull/149), [#113](https://github.com/soramikan/lnako/issues/113), [#154](https://github.com/soramikan/lnako/pull/154)）、復元失敗の検出（[#180](https://github.com/soramikan/lnako/pull/180)）。
    - 制御構文の引数助詞照合（[#118](https://github.com/soramikan/lnako/issues/118), [#158](https://github.com/soramikan/lnako/pull/158)）、単文「もし〜ならば」と「違えば」の連結（[#138](https://github.com/soramikan/lnako/pull/138), [#137](https://github.com/soramikan/lnako/pull/137)）、条件式助詞呼出し（[#132](https://github.com/soramikan/lnako/pull/132)）、初期値省略宣言・公開属性（[#122](https://github.com/soramikan/lnako/issues/122), [#135](https://github.com/soramikan/lnako/pull/135)）、区切り式内呼出し（[#143](https://github.com/soramikan/lnako/pull/143)）、「。。。」ブロック終端（[#121](https://github.com/soramikan/lnako/issues/121), [#133](https://github.com/soramikan/lnako/pull/133)）。
    - 「〜こと」語尾（[#116](https://github.com/soramikan/lnako/issues/116), [#150](https://github.com/soramikan/lnako/pull/150)）、「{関数}名」参照（[#124](https://github.com/soramikan/lnako/issues/124), [#145](https://github.com/soramikan/lnako/pull/145)）、暗黙配列『引数』（[#123](https://github.com/soramikan/lnako/issues/123), [#136](https://github.com/soramikan/lnako/pull/136)）、呼出し直後『戻る』（[#151](https://github.com/soramikan/lnako/pull/151)）、値・連鎖位置組み込み命令の暗黙呼出し（[#111](https://github.com/soramikan/lnako/issues/111), [#153](https://github.com/soramikan/lnako/pull/153)）、範囲オブジェクト反復（[#117](https://github.com/soramikan/lnako/issues/117), [#157](https://github.com/soramikan/lnako/pull/157)）、「N回」非数値比較（[#165](https://github.com/soramikan/lnako/issues/165), [#174](https://github.com/soramikan/lnako/pull/174)）、「定める」助詞受理（[#115](https://github.com/soramikan/lnako/pull/115)）、助詞付きcall_value直後『[』（[#163](https://github.com/soramikan/lnako/issues/163), [#171](https://github.com/soramikan/lnako/pull/171)）、多段『(』連鎖（[#128](https://github.com/soramikan/lnako/issues/128), [#160](https://github.com/soramikan/lnako/pull/160)）。
    - 構文診断強化：ループ外『抜ける』『続ける』コンパイル時診断（[#166](https://github.com/soramikan/lnako/issues/166), [#173](https://github.com/soramikan/lnako/pull/173)）、助詞不一致引数の『未解決の単語』診断（[#108](https://github.com/soramikan/lnako/issues/108), [#161](https://github.com/soramikan/lnako/pull/161)）、裸式文エラー（[#125](https://github.com/soramikan/lnako/issues/125), [#156](https://github.com/soramikan/lnako/pull/156)）、命令名代入拒否（[#126](https://github.com/soramikan/lnako/issues/126), [#141](https://github.com/soramikan/lnako/pull/141)）、「!厳しくチェック」警告化（[#127](https://github.com/soramikan/lnako/issues/127), [#144](https://github.com/soramikan/lnako/pull/144)）、合成AST深さ超過拒否（[#109](https://github.com/soramikan/lnako/issues/109), [#159](https://github.com/soramikan/lnako/pull/159)）。
    - 実行エンジン安定化：監視領域脱出時のtry_end emitによる例外ハンドラ残留解消（[#164](https://github.com/soramikan/lnako/issues/164), [#172](https://github.com/soramikan/lnako/pull/172)）、動的IR所有権管理（[#177](https://github.com/soramikan/lnako/pull/177)）、「束」エラー経路のPromise併合state解放済み参照防止（[#179](https://github.com/soramikan/lnako/pull/179)）。
  - **パッケージマネージャー基盤の拡充（`lnako pkg`）**：
    - `nako.lock` の複数profile対応・生成・既存版優先・部分更新・ロック鮮度判定（[#46](https://github.com/soramikan/lnako/issues/46), [#102](https://github.com/soramikan/lnako/pull/102)）。
    - パッケージキャッシュ管理、検証済み実体化、環境同期、環境復旧、CLIフェーズ（[#48](https://github.com/soramikan/lnako/issues/48), [#152](https://github.com/soramikan/lnako/pull/152)）。
    - path・Git・URL・静的registryの取得provider（[#47](https://github.com/soramikan/lnako/issues/47), [#146](https://github.com/soramikan/lnako/pull/146), [#148](https://github.com/soramikan/lnako/pull/148)）。
    - なでしこパッケージアーカイブ `.npkg` の生成・検証、metadata・ファイルhash一覧（[#142](https://github.com/soramikan/lnako/pull/142)）。
  - **低レイヤーAPIの拡充**：
    - ファイル時刻・truncate・高精度メタデータ更新（[#31](https://github.com/soramikan/lnako/issues/31), [#100](https://github.com/soramikan/lnako/pull/100)）。
    - 逐次ディレクトリ列挙（[#33](https://github.com/soramikan/lnako/issues/33), [#101](https://github.com/soramikan/lnako/pull/101)）。
    - POSIX権限・所有者・UID/GID・access判定（[#34](https://github.com/soramikan/lnako/issues/34), [#99](https://github.com/soramikan/lnako/pull/99)）。
    - argv型プロセス起動・signal・priority・TTY（[#35](https://github.com/soramikan/lnako/issues/35), [#103](https://github.com/soramikan/lnako/pull/103)）。
    - ロケール比較・表示幅API（[#38](https://github.com/soramikan/lnako/issues/38), [#178](https://github.com/soramikan/lnako/pull/178)）。
    - 低レベルAPI基盤のリファクタリング・ドメイン分割（[#96](https://github.com/soramikan/lnako/issues/96), [#98](https://github.com/soramikan/lnako/pull/98)）。
  - **CI/CD・開発基盤**：
    - CI改善計画2の全Phase実装（cache identity分離、worker=2、AOT compiler共有等）（[#104](https://github.com/soramikan/lnako/pull/104)）。
    - 非コード変更時のpre-push最適化、Issue/PRテンプレート導入。
- **v0.2.3（依存管理CLI・パッケージimport・低レイヤーAPI全63命令完遂・クロージャ互換修正）**：
  - **依存管理CLIとプロジェクト自動準備（`lnako`）**：
    - `init`（`--lib` 含む）、`add`、`remove`、`lock`、`update`、`tree`、`why`、`check`、`cache dir|clean` の各コマンドと、`run` / `test` / `build` 実行前の自動ロック・環境同期を実装（[#49](https://github.com/soramikan/lnako/issues/49), [#176](https://github.com/soramikan/lnako/pull/176)）。
  - **同期済みパッケージのimport解決**：
    - `パッケージ:` / `pkg:` によるパッケージimport、サブパス解決、公開境界検査、ネイティブプラグイン命令の名前空間修飾、および埋め込みペイロードv4でのパッケージルート保持を実装（[#50](https://github.com/soramikan/lnako/issues/50), [#196](https://github.com/soramikan/lnako/pull/196)）。
  - **低レイヤーAPIカタログ全63命令の実装完了**：
    - ファイルシステム拡張4命令（`ファイルシステム情報取得` / `ファイルクローン` / `ファイルデータ領域検索` / `ファイル空洞領域検索` / `ファイル領域確保`）（[#36](https://github.com/soramikan/lnako/issues/36), [#181](https://github.com/soramikan/lnako/pull/181)）。
    - ストリーム位置指定I/O 4命令（`ファイル位置変更` / `ファイル位置取得` / `ファイル位置指定読込` / `ファイル位置指定書込`）（[#27](https://github.com/soramikan/lnako/issues/27), [#207](https://github.com/soramikan/lnako/pull/207)）。
    - Windows（NTFS）における `CreateHardLinkW` を用いた `ハードリンク作成` 対応（[#78](https://github.com/soramikan/lnako/issues/78), [#208](https://github.com/soramikan/lnako/pull/208)）。
  - **言語互換性・ツールチェーン・リリース基盤の改善**：
    - 無名関数・入れ子関数をまたぐ変数束縛およびクロージャ捕捉の公式なでしこ3互換性を修正（[#194](https://github.com/soramikan/lnako/pull/194)）。
    - `lnako toolchain install` 実行時の進捗表示追加とファイル複製処理の高速化（[#193](https://github.com/soramikan/lnako/pull/193)）。
    - Release公開時のリリースノート自動適用およびHomebrew tap更新ワークフローの自動起動に対応。
- **v0.2.4（npm依存解決・lock npmInstances生成・Zig 0.17対応）**：
  - **パッケージシステムにおけるnpm依存解決（`lnako`）**：
    - `source = "npm"` の依存（ルートおよびアクティブなpkgパッケージからの推移依存）をfixtureカタログまたはregistry packumentから解決し、`nako.lock` の `npmInstances` へ記録する機能を実装（[#53](https://github.com/soramikan/lnako/issues/53), [#214](https://github.com/soramikan/lnako/pull/214)）。
    - tarballのintegrity（`sha512-`）検証とパッケージキャッシュへの格納、peerDependenciesの自動充足・未充足診断（`E017`）、実行コンテキスト不整合診断（`E018`）、および `prefer_locked` 時の既存 `npmInstances` 再利用に対応。
  - **Zig 0.17.0ツールチェーンへの移行とビルド基盤の安定化**：
    - 基準Zigバージョンを `0.17.0` へ移行し、`zig-pubgrub` `v0.1.2` への更新および標準ライブラリAPI移行を完了（[#213](https://github.com/soramikan/lnako/pull/213)）。
    - Windows環境におけるパスダイジェスト算出およびキャッシュ読み込みの非ブロッキングI/Oハングを解消。

## 明示的に非対応とする境界（意図的制限・後続課題）

以下は標準命令そのものを非対応とする意味ではありません。既存fixtureで検証済みの命令経路は動作しますが、記載した一般化された境界を現行バージョンの保証対象外とします。

| 領域 | 現行の保証外 | 後続Issue |
| --- | --- | --- |
| AOT動的値ブリッジ | 一般の循環object graph、alias identity、疎配列hole、全prototype identityを保持する完全clone | [#3](https://github.com/soramikan/lnako/issues/3) |
| RegExp | ECMAScript RegExp全grammar、未fixtureのUnicode set/string property、複雑なbacktracking、V8エラー本文完全一致 | [#4](https://github.com/soramikan/lnako/issues/4) |
| 表・疎配列 | 全表命令のcustom prototype / inherited property / sparse top-level semantics | [#5](https://github.com/soramikan/lnako/issues/5) |
| Node / Host | 任意の実network topology、外部Internet/TLS/proxy、実GUI launcher、任意7z実装、未fixtureのWindows特殊path/argv | [#6](https://github.com/soramikan/lnako/issues/6) |
| Buffer family | descriptor、未束縛method receiver、全view identityを含むNode object model完全互換 | [#7](https://github.com/soramikan/lnako/issues/7) |
| QuickJS | 4 JS固有命令の成功・期待失敗範囲を越えるエラー本文完全互換 | [#8](https://github.com/soramikan/lnako/issues/8) |
| ToPrimitive / Function | 未fixtureのreceiver副作用順序、function文字列化・辞書key化の全境界 | [#9](https://github.com/soramikan/lnako/issues/9) |
| 上流バグ候補 | DNCL寛容構文、TOML異常入力、generated route登録不足等をlnakoの新しい安定仕様として保証すること | [#10](https://github.com/soramikan/lnako/issues/10) |
| native plugin | `.dylib` / `.so` / `.dll` のdynamic ABIは対応。pluginのAOT静的リンク・単一実行ファイル化は非対応 | [#11](https://github.com/soramikan/lnako/issues/11) |

ブラウザ専用429 entryと拡張189 entryは標準cnako 527 entryの外であり、互換対象外です。JavaScript固有4 entryは通常モードでは実行せず、明示的な `--compat-js` でのみ対象とします。

## 既存TODO識別子の対応状況

| TODO識別子 | 分類 | Issue |
| --- | --- | --- |
| `official-dncl-all-elements-tail` | 上流バグ候補。非ブロッカー | #10 |
| `josi-signature-argument-match` | 対応済み（v0.2.2にて助詞不一致引数の『未解決の単語』診断を実装） | #108 |
| `sparse-array-presence` | 部分対応、一般境界は保証外 | #5 |
| `table-inherited-properties` | 保証外 | #5 |
| `regexp-unicode-flags` | 部分対応 | #4 |
| `regexp-js-error-text` | 部分対応 | #4 |
| `regexp-backtracking-edge` | 部分対応 | #4 |
| `toml-temporal-values` | 上流バグ候補／意図的制限 | #10 |
| `catalog-plugin-toml-generated-registration` | upstream generated route差 | #10 |
| `node-path-win32-boundary` | 未検証OS境界 | #6 |
| `node-network-cross-os-attestation` | 実OS依存、保証外 | #6 |
| `node-http-cross-os-attestation` | 実OS／network依存、保証外 | #6 |
| `httpserver-multipart-boundary` | 部分対応 | #6 |
| `aot-node-archive-arbitrary-external-tool-diff` | 外部tool依存、保証外 | #6 |
| `node-exit-cross-os-attestation` | OS依存境界 | #6 |
| `node-http-generated-route-diagnosis` | upstream route差 | #10 |
| `aot-node-windows-wtf8-argv` | 未検証Windows境界 | #6 |
| `aot-byte-buffer-value` | 部分対応 | #7 |
| `aot-object-to-primitive` | 部分対応 | #9 |
| `aot-function-string-name` | 部分対応 | #9 |
| `aot-native-plugin-static-bundle` | 非対応（後続課題） | #11 |
| `compat-js-failure-diagnostic-equivalence` | optional routeの診断改善 | #8 |

## 進行中および今後の継続課題

- **パッケージシステムの実装**（Project [#2](https://github.com/users/soramikan/projects/2)、label `package-system`）:
  - **基盤（CLOSED）**: 仕様・schema・適合例（#43）、manifest/TOML/SemVer/marker/features（#44）、PubGrub（#45）、複数profile `nako.lock`・部分更新（#46）、path/Git/URL/静的registry provider（#47）、cache・検証展開・排他・環境復旧（#48）、`.npkg` 生成/検証（#51）、共通.nako3優先・runtime条件（#69）。
  - **CLI・実行前準備（コード完了・Issue OPEN）**: `init`/`add`/`remove`/`lock`/`update`/`tree`/`why`/`check`/`sync`/`package build|verify|cache` と `run`/`test`/`build` 前の自動準備、`--locked`/`--offline`/`--no-sync`（#49、PR #176）。受け入れcheckbox未更新のため Issue は OPEN のまま。
  - **package import（lnako 実装済・ゲート未了）**: `パッケージ:`/`pkg:` alias・subpath、export 境界、environment scope、Interpreter 経路（#50、PR #196）。未達は cnako 共通fixture（#61 連動）、3 OS での LLVM AOT O0〜O3 実測、共通 E2E。
  - **#52 命令 metadata 静的検査（部分実装・Issue OPEN）**: `command_inspect` + `lnako check` でロードなし検査・衝突/不一致 E029・未検査 `partial`・`--strict-sharing` E033 まで（PR #211）。**残ゲート**: 専用推移依存・選択 feature 影響の表示、parser/semantic への declared command 接続、JS/native 実登録照合、名前空間 check。残ゲート消化後に #52 close。
  - **#53 npm 取得（部分実装・Issue OPEN）**: `src/package/npm.zig` で fixture catalog / registry packument 解決、integrity（`sha512-`）、cache 格納、peer（E017）・context（E018）、lock `npmInstances` 配線。`rejectNpmDeps` 撤去。QuickJS ESM 実行・Node lifecycle script は非対象（#54）。残ゲート: 実 registry E2E、package.json 本格パース、env materialize での npm 実体化。
  - **初回 P0 残主鎖**: #52 残ゲートと並行で #53 残 → QuickJS ESM（#54）→ AOT+QuickJS（#55）→ 依存同梱（#56）→ publish（#57）→ 3 OS E2E/文書（#58）。cnako 上流接続・公開版（#61）は import ゲート兼用。
  - **配布拡張 P1**: native source build（#59）、AOT 静的 plugin 同梱（#11）、workspace（#60）。
  - **他処理系/後続**: wnako（#62）、cnako Node 拡充（#63）、cross build（#64）、WASM PoC（#65）、cnako Node 完結依存管理（#70）、階層名前空間「の」（#182）。
  - **レジストリ**（別リポ [nako-registry](https://github.com/soramikan/nako-registry)）: #1–#6 すべて OPEN。中央サーバー切替は nako-registry#5 が gate。
  - **明示拒否中**: `publish` CLI 未実装（環境 generation の “publish” 語は内部用）。npm 依存の lock 拒否は #53 で撤去済み。
- **低レイヤーAPI・ストリームI/O**：
  - カタログ63命令をすべて実装済み（#27–#38, #36 等）。正本は [`docs/low-level-api/catalog.json`](low-level-api/catalog.json)、現状の一覧は [`docs/low-level-api/IMPLEMENTATION_STATUS.md`](low-level-api/IMPLEMENTATION_STATUS.md)。
  - **実装済み命令（63/63）**: カタログ掲載の全命令を Interpreter / AOT で実装。位置系4命令（`ファイル位置変更` / `ファイル位置取得` / `ファイル位置指定読込` / `ファイル位置指定書込`）は [#27](https://github.com/soramikan/lnako/issues/27) で完了。
  - **OS制約**: Windows の `ハードリンク作成` は NTFS 上で可（非対応FSは `ENOTSUP`、[#78](https://github.com/soramikan/lnako/issues/78)）。`chmod` / `chown` / `uid_gid` / `priority` / `statfs` 等は POSIX 中心で Windows は照会 false または `ENOTSUP`。
  - **拡張未着手**: `termios` / `nss` / `acl` / `xattr` / `selinux`（[#39](https://github.com/soramikan/lnako/issues/39)、capability ID のみ）。Web/Async Runtime Foundation（#197–#206）は現行63命令カタログの外。
  - 構造化エラー、raw stdio、hash、FS、dir iterator、POSIX、spawn/signal/TTY、locale/表示幅、statfs/reflink/sparse は実装済み。
- **性能・最適化の継続管理**：
  - Interpreterの実行速度向上、文字列連結・正規表現の最適化、Windowsバイナリサイズの削減（[#12](https://github.com/soramikan/lnako/issues/12)）。
- **Windowsのsocket teardown時panic（CIのテスト結果では検知できない）**：
  - Windowsの単体テストで、ピアが閉じたsocketのreadが `std.Io.Threaded.netReadWindows` の `unexpectedStatus` により `LOCAL_DISCONNECT`（0xc000013b）／`CONNECTION_RESET`（0xc000020d）でpanicする。`zig build test --summary all` の集計は Windows `11/11 steps succeeded; 1685/1724 tests passed (39 skipped)`、macOS `11/11 steps succeeded; 1717/1724 tests passed (7 skipped)` で、**failed／crashed／timed outはいずれも0**であり、panicはどのテストにも帰属されずstepは成功する（WindowsはmacOSより32件多くskipする）。
  - 痕跡が出るテストは `TLS初期化後のTLS接続失敗はpanicにならない` と `受信engineのstopはqueue内socketを一度だけ閉じてworkerを回収する`。後続課題として、std側のNTSTATUSマッピング（`error.ConnectionResetByPeer` 等）と、lnako側のspawn threadのjoinによりpanicをテスト失敗として顕在化させることを検討する。実測は [ci-performance.md](ci-performance.md) に記録。

## リリース時チェックリスト

1. `zig build fmt-check`、`zig build test`、関連oracle・native plugin・distribution self-testを実行する。
2. 最終source commitでCIをfull相当（attestation発行を含む48 job構成）で成功させる。
3. 同じsource manifestの3 OS attestationを追跡し、現行manifestに一致するsnapshotから導出されるviewを `verified: 527`、`unverified: 0` にする。
4. `lnako --version`、`build.zig.zon`、release versionを対象バージョンへ一致させる。
5. 署名済みannotated tag（`vX.Y.Z`）を最終commitに作成してpushする。
6. release workflowで3 OS archive、SHA-256、SPDX 2.3 SBOMを自動検証してからGitHub Releaseを公開する（release時benchmarkは行わない）。
