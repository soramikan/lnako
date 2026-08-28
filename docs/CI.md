# CIの構成と所要時間

この文書は、検証範囲を維持したままGitHub Actionsの待ち時間を短縮する構成と、直感だけでは分かりにくい
取消・キャッシュ規則を記録します。

## 変更前の実測

2026-08-25の[run 32818778076](https://github.com/soramikan/lnako/actions/runs/32818778076)では、各OSの全検証を
1ジョブで直列実行していました。

| 環境 | ジョブ時間 | 標準・補助プラグイン差分 | Nodeホスト差分 |
|---|---:|---:|---:|
| Linux x86_64 | 43分50秒 | 24分14秒 | 13分03秒 |
| macOS arm64 | 30分53秒 | 16分38秒 | 9分15秒 |
| Windows x86_64 | 36分36秒でAOT差分失敗 | 18分35秒 | 9分34秒 |

標準・補助プラグイン差分とNodeホスト差分は互いに独立しています。これらが直列だったことが単一runの
クリティカルパスを長くしていました。また、機能単位のpushが続くと、古いcommitの同一検証が複数runで
同時に残り、最新commitの開始・完了を遅らせていました。

Linuxログでは通常のmath・CSV・TOML・Promise差分は約0.8秒で完了し、その後の巨大な漢数字生成fixture
1本だけに24分13秒かかっていました。検証値を削らず、同じ文を最大96文ずつのfixtureへ分け、各fixtureで
公式処理系とlnakoを比較します。公式パーサーへ巨大な1ソースを渡す非線形コストだけを避けます。

## 5スイートへの分割

各正式環境（Linux x86_64、macOS arm64、Windows x86_64）で、次の5スイートを並列実行します。

| スイート | 検証内容 |
|---|---|
| `core` | 互換台帳、字句・構文変換・構文・意味・動的値・インタープリタ・plugin_system差分、format、全Zig単体テスト |
| `standard` | math・CSV・TOML・Promise、markup・caniuse・kansujiの公式差分と全生成コーパス |
| `host` | QuickJS互換差分、ネイティブプラグインABI、ファイル・プロセス・HTTP・暗号・文字コード・圧縮などNodeホスト差分 |
| `aot` | 公式CLI・公式生成JavaScript・インタープリタ・LLVM AOT O0〜O3差分、通常/QuickJSビルドとスモークテスト |
| `compat-aot` | QuickJS Debug単体テスト、QuickJS ReleaseSafe compiler build、compat-js smoke |

`aot` suiteのHTTP server検証は、`plugin-httpserver-all`を使った公式処理系対AOT O0〜O3のlocalhost実通信比較です。
通常の192件AOT artifact／dispatch証拠とは別fixtureですが、HTTP serverの10命令・14リクエストを検証範囲から除外しません。

元のコマンドは削除せず、各OSでいずれか1スイートが一度だけ実行します。OSごとの互換検証をLinuxだけへ
縮小する最適化は行いません。ジョブ上限は50分とし、停止しないホスト・ネットワークテストを検出します。

## 同一refの旧run取消

concurrency groupはワークフロー名と完全なGit refから作ります。同じブランチ、または同じPR refへ新しいcommitが
pushされた場合だけ、進行中の古いrunを取り消します。別ブランチ、別PR、タグのrunは互いに取り消しません。

最新commitは古いcommitを祖先として含むため、最新runが累積したソースを全スイートで検証します。一方、取り消された
個々のcommitにはGitHub上の完走記録が残らないため、機能コミット前のローカル検証と署名を省略してよい規則では
ありません。リリース候補やマイルストーンのcommitは、後続pushを止めて全15ジョブとattestation jobの完走を証拠として残します。

## キャッシュ

- LLVM/LLD・QuickJSと公式なでしこ3オラクルはOS別の固定バージョン・ハッシュ付きキャッシュを全スイートで共有します。
- Zigのglobal/local cacheは長時間の`host`・`aot`だけで保存し、OSに加えてスイート名をキーへ含めます。上限は1,024 MiBです。
- キャッシュmissでもセットアップスクリプトがlockfileのSHA-256を検証します。キャッシュhitを安全性の根拠にはしません。
- 初回またはキャッシュ失効時はダウンロード時間が加わるため、定常時と同じ所要時間にはなりません。

分割した各スイートはセットアップを個別に行うため、単一runだけの総runner時間は直列構成より少し増える可能性があります。
壁時計時間を短縮し、旧run取消によって複数run全体の無駄なrunner時間を抑える設計です。

### Zig build cacheの保存対象

`mlugg/setup-zig`のbuild cacheは、保存keyへrun IDとattemptが付くため、全15ジョブで有効にすると最大15個の新規cacheが
runごとに増えます。2026-08-27に確認した時点では、Actions cacheが30件・約11.6 GBに達し、固定Linux LLVM cacheが
退避された後のrunで5つのLinuxジョブが同じ配布物の取得・SHA-256検証・展開を約148秒ずつ重複していました。

検証工程を変えずにcacheの増加を抑えるため、cross-runのZig build cacheはコンパイル量の大きい`host`と`aot`だけに限定します。
3 OSで最大6個/runとなり、`core`・`standard`・`compat-aot`もjob内のZig cacheは通常どおり使用します。
`use-cache: false`のjobでも、setup actionが管理する固定Zig 0.16.0配布物のcacheは別系統で維持されます。

1,024 MiB上限を超えたbuild cacheはactionの仕様上、部分的なLRU整理ではなく空にして保存されます。このため上限を小さく
しすぎず、今後の実runでcache clear、固定toolchain cacheの残存、壁時計時間を合わせて確認します。固定LLVM/LLD・QuickJS・
公式オラクルの実体hash検証は、cache hit時も従来どおり毎jobで実行します。

## 分割直後の実測

2026-08-25の[run 32823536056](https://github.com/soramikan/lnako/actions/runs/32823536056)（`8f10340`）は、
全12ジョブを16分07秒で完了しました。変更前の最長ジョブ43分50秒に対し、最新commitの結果を待つ壁時計時間は
約63%短縮されています。

| 環境 | `core` | `standard` | `host` | `aot` |
|---|---:|---:|---:|---:|
| Linux x86_64 | 2分28秒・成功 | 1分54秒・成功 | 16分03秒・成功 | 4分57秒・成功 |
| macOS arm64 | 3分00秒・成功 | 2分06秒・成功 | 13分22秒・成功 | 4分34秒・成功 |
| Windows x86_64 | 3分43秒・成功 | 2分25秒・成功 | 15分42秒・成功 | 3分18秒・既知4差分 |

`standard`は変更前の16〜24分から約2分へ短縮されました。クリティカルパスはNodeホスト差分を含む`host`へ
移り、検証範囲を維持した状態で16分台です。今後さらに分割する場合はrunner枠とセットアップの重複が増えるため、
まずこの値を基準とします。

## 初回runに残ったWindows AOT差分

初回runのWindows AOTは、次の4ケースで失敗しました。

- `native-noncapturing-function-value`
- `native-dynamic-function-arity`
- `native-closure-shared-mutable-binding`
- `native-closure-transitive-capture`

これはCI分割による回帰ではありません。変更前の[run 32818778076](https://github.com/soramikan/lnako/actions/runs/32818778076)
にも同じ4差分がありました。分割後は、従来約36分後だった検出が3分18秒後になっています。

原因は、LLVM生成コールバックが16バイトの動的値をC ABI境界で直接返していたことです。Windows x64の集約値返却
規則へ依存しないよう、結果を明示的なポインタへ書き込むABIへ変更しました。ローカルでは全56件・O0〜O3のAOT差分、
256単体テスト、Windows GNU向け通常/QuickJS ReleaseSafeクロスビルドまで確認しました。

修正後の[run 32825322005](https://github.com/soramikan/lnako/actions/runs/32825322005)（`3688e1c`）では、正式な
Windows MSVCを含む全12ジョブが17分27秒で成功しました。変更前の43分50秒に対する壁時計時間の短縮率は約60%です。

| 環境 | `core` | `standard` | `host` | `aot` |
|---|---:|---:|---:|---:|
| Linux x86_64 | 2分13秒 | 1分48秒 | 17分23秒 | 5分29秒 |
| macOS arm64 | 2分48秒 | 1分29秒 | 12分58秒 | 4分46秒 |
| Windows x86_64 | 4分17秒 | 1分56秒 | 15分29秒 | 9分19秒 |

初回のWindows AOTは差分検出後に後続ビルドを行わず3分18秒で終了しました。修正後の9分19秒には、差分成功後の
通常/QuickJS ReleaseSafeビルドとスモークテストも含まれます。失敗時刻と成功時刻だけを比べて性能悪化と判断しません。

続く[run 32828126108](https://github.com/soramikan/lnako/actions/runs/32828126108)（`d8afad6`）も全12ジョブが成功し、
15分20秒で完了しました。機能追加後の再実行でも短縮効果が再現し、最長だったLinux `host`を含めて20分以内を維持しています。

文字列・Unicode AOT命令を追加した後の[run 32860309799](https://github.com/soramikan/lnako/actions/runs/32860309799)
（`1fe39dc`）も、2026-08-25に全12ジョブが16分15秒で成功しました。macOS arm64・Linux x86_64 GNU・
Windows x86_64 MSVCの各`core`・`standard`・`host`・`aot`を省略しておらず、機能追加後も20分以内の
クリティカルパスを維持しています。

## ActionのNodeバージョン警告

初回runでは、`actions/cache@v4`と`mlugg/setup-zig@v2`がNode 20対象で、runnerがNode 24を強制使用したという
警告が出ました。製品テストの失敗ではありませんが、次のように扱います。

- `actions/cache`はNode 24を使う公式v6へ更新し、同じcache keyとハッシュ検証を維持します。
- 公式oracle cache keyは`runner.os`・`runner.arch`・固定archive SHA-256の先頭12桁・oracle buildを含めます。実行ツリー
  （production prune後、npm生成metadataを明示削除した`node_modules`を含む）の決定的hashをmarker以外全て再計算します。
  lockへ3正式環境の同一値を登録していますが、各runnerでの再計算一致が必要で、未登録のOS/archはsetup時に拒否します。
- `mlugg/setup-zig`は2026-08-25時点の最新v2.2.1も`node20`指定です。runner上ではNode 24で正常完了しているため
  `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION`でNode 20へ戻さず、上流の更新を待ちます。
- 警告と検証失敗を混同せず、setup失敗またはキャッシュ破損は従来どおりジョブ失敗として扱います。

## Windowsのオラクルキャッシュ置換

2026-08-26の[run 32914725275](https://github.com/soramikan/lnako/actions/runs/32914725275)では、Windows `core`が
固定オラクルを再構築した後、stagingディレクトリを完成先へ移す`rename`で一時的な`EPERM`になりました。
SHA-256検証、`npm ci`、TypeScriptビルドは完了しており、ソース差分テストへ到達する前のWindowsファイルロックです。
復元したキャッシュキーの版が`v1`、`tools/setup_oracle.mjs`の内容版が`oracleBuild = 2`だったため、古いキャッシュを
毎run再構築していたことも誘因でした。当時のキーを`v2`へ更新し、`tools/check_ci_workflow.mjs`で両方の版を照合しました。

`tools/setup_oracle.mjs`は、Windowsで`EACCES` / `EBUSY` / `EPERM`になった置換だけを、最大4秒の待機を含む
7回まで再試行します。ハッシュ検証やビルドを省略せず、別種のエラーは直ちに失敗させます。stagingから完成先への
置換を維持するため、不完全なオラクルを有効なキャッシュとして扱いません。

## 文字コード生成fixtureの分割

オラクルキャッシュを`v2`へ揃えた後の[run 32917075307](https://github.com/soramikan/lnako/actions/runs/32917075307)
（`f708aa1`）は、全12ジョブが14分28秒で成功しました。各OSの`host`はLinux 13分15秒、Windows 14分02秒、
macOS 14分03秒で、macOSログでは`check_encoding_compat.mjs`だけが9分16秒を占めていました。

この検査はiconv-liteの文字コード名421件について、サポート判定とASCII往復を1つの1,263文ソースへ生成していました。
全件を維持したまま32件ずつ14バッチへ分け、公式`cnako3`と`lnako`の終了コード・標準出力をバッチごとに比較します。
各入力は最大96文となり、巨大な1ソースに対する公式パーサーの非線形コストを避けます。各ケースはリテラル`"A"`だけを
変換する独立検査なので、バッチ間でプロセス状態がリセットされても検証の意味は変わりません。

変更後のローカル実測は421件すべてを含めて5.19秒でした。続く
[run 32919484760](https://github.com/soramikan/lnako/actions/runs/32919484760)（`ce3ee56`）では、正式3環境の
全12ジョブが10分34秒で成功しました。変更直前の14分28秒から約27%短縮され、変更前の最長43分50秒に対しては
約76%短縮されています。

| 環境 | 分割前の`host` | 分割後の`host` |
|---|---:|---:|
| Linux x86_64 | 13分15秒 | 5分00秒 |
| macOS arm64 | 14分03秒 | 3分42秒 |
| Windows x86_64 | 14分02秒 | 4分49秒 |

分割後のクリティカルパスはWindows `aot`の10分13秒です。文字コード検査だけを省略した結果ではなく、421件の
サポート判定・ASCII往復、他のNodeホスト差分、3環境の全スイートがすべて成功したrunを確定値として記録しています。

その後の[run 32923053660](https://github.com/soramikan/lnako/actions/runs/32923053660)も12ジョブすべて成功し、Windows
x86_64の`aot`が約10分42秒のクリティカルパスでした。以下のAOT fixture並列化は、この7経路・O0〜O3・3環境を
維持したまま、このクリティカルパス内のAOT差分処理時間を短縮するものです。

## AOTオラクルfixtureの安全な並列化

`tools/compare_native_oracle.mjs` は、検証対象fixtureをfixture単位で最大2 workerに割り当てます。各fixture内の
公式CLI、公式JavaScript生成・実行、`lnako run`、AOTのO0・O1・O2・O3生成・実行は従来どおり直列です。そのため、
検証経路（公式CLI、公式生成JavaScript、インタープリタ、AOT 4段階）の7経路、全ケース、全最適化レベルは削減していません。
`LNAKO_NATIVE_ORACLE_JOBS=1` を指定すると従来相当の直列実行へ戻せます。値は1または2だけを受け付け、未指定時は2です。

worker間の競合を防ぐため、各fixtureには順序番号とIDからなる一意なディレクトリを割り当て、ソース、生成JavaScript、AOT
実行ファイル、相対パスで作成される将来のfixtureファイルをその配下へ置きます。fixtureの結果は元の配列位置へ保存し、
比較と診断の出力はfixture順に行います。workerで基盤エラーが発生した場合も全workerの完了を待ってから一時ディレクトリを
削除するため、実行中の子プロセスを置き去りにしません。共有される初回の`zig build`はworker開始前に1回だけ行い、
Zigキャッシュへの同時書き込みを発生させません。

この変更のローカル実測（macOS arm64、Node 24、現在の103 fixture、各fixture内は7経路）は次のとおりです。

| 実行 | 結果 | wall time | user | sys |
|---|---|---:|---:|---:|
| `LNAKO_NATIVE_ORACLE_JOBS=1` | 103件成功 | 207.81秒 | 97.64秒 | 28.33秒 |
| `LNAKO_NATIVE_ORACLE_JOBS=2` | 103件成功 | 106.39秒 | 101.10秒 | 28.93秒 |

直列値との差は約49%のwall time短縮です。この値はローカルの各一実行であり、CIの正式な性能基準ではありません。
macOS sandboxでは`ps`および`sysctl`による最大RSS
取得が拒否されたため、上記表にRSSを推測値で補っていません。RSSを含むリソース比較は、正式runnerのジョブ計測で別途記録します。

変更後の[run 32927104194](https://github.com/soramikan/lnako/actions/runs/32927104194)では、3環境の全12ジョブが
9分38秒で成功しました。比較対象のrun 32923053660の10分45秒から1分07秒（約10.4%）短縮しています。
クリティカルパスのWindows x86_64 `aot`ジョブは10分42秒から9分33秒へ1分09秒（約10.7%）短縮し、
同ジョブ内の`Differential native AOT test`は102 fixtureで3分43秒だった旧runに対し、103 fixtureへ増えた状態でも
3分14秒で完了しました。fixture数・7経路・O0〜O3・3環境を維持した実CIで、競合や失敗がないことを確認しています。

## Windows AOTのQuickJSビルド分離

Windows AOTの追加短縮を判断するため、分離前の[run 32932078383](https://github.com/soramikan/lnako/actions/runs/32932078383)
（全12ジョブ、9分50秒）のステップ時刻を記録した。Windows AOTでは、セットアップ完了後の内訳が次のとおりだった。

| 区間 | 所要時間 |
|---|---:|
| LLVM/QuickJS/オラクルのセットアップ完了 → native差分完了 | 2分42秒（04:57:07→04:59:49） |
| `zig build -Dcompat-js=true test` | 2分53秒（04:59:49→05:02:41） |
| 通常ReleaseSafe build | 1分25秒（05:02:41→05:04:06） |
| QuickJS ReleaseSafe compiler build | 1分28秒（05:04:06→05:05:34） |

「QuickJS compiler buildだけが遅い」とは断定できない。QuickJS Debug testとReleaseSafe buildを合わせると4分21秒であり、
native差分と通常buildも含めて複数工程がクリティカルパスを構成している。

このrun以降は、3正式環境に`compat-aot` suiteを追加して15ジョブへ分割する。

| suite | 実行内容 |
|---|---|
| `aot` | 公式CLI・生成JavaScript・`lnako run`・AOT O0〜O3差分、通常ReleaseSafe build、通常smoke |
| `compat-aot` | QuickJS Debug単体テスト、QuickJS ReleaseSafe compiler build、compat-js smoke |

元の7経路、O0〜O3、通常build、QuickJS build、全smokeコマンドは削除せず、2 suiteへ移しただけである。通常jobのsmokeは
`--version`、compat report、2件の`check`、通常`run`、`test`を実行し、`compat-aot`のsmokeは従来の
`compat-js-basic.nako3 --compat-js`を実行する。`tools/check_ci_workflow.mjs`がmatrixを15ジョブとして検査し、両smokeの
コマンド集合が従来の7件と一致することを検証する。

`compat-aot`は公式オラクルを使わないため、オラクルcacheと`tools/setup_oracle.mjs`だけを条件付きで省略する。LLVM/LLDと
QuickJSの固定版・SHA-256検証、Node、Zigのsetupは省略しない。Zig cacheは`cache-key: matrix.suite`のため、`aot`と
`compat-aot`は別cache名前空間になる。これは並列jobのcache保存競合を避ける一方、初回の`compat-aot`ではコンパイルcacheが
冷えて追加時間になる分かりにくい挙動である。ツールチェーンcacheは従来どおりOS・arch・固定版キーを共有し、setup scriptの
ハッシュ検証を必ず通す。

分離後は、通常AOTとQuickJS AOTが並列に走るため、Windowsの壁時計時間は分離前9分50秒から、各jobのセットアップとsmokeを
含む長い方（予測6〜8分台）へ近づく見込みである。3つの追加jobによりrunner使用時間とcache保存処理は増える。初回runでは
成功率、cache hit/miss、各step時間を記録し、予測が外れた場合は分離を戻す判断材料にする。GitHub Actionsログから
得られないCPU/RSSを推測値で補わない。

失敗時は、`aot`失敗なら通常AOT差分・LLVMリンク・通常smoke、`compat-aot`失敗ならQuickJS Debug/ReleaseSafe buildまたは
compat smokeに絞って診断できる。片方のsuiteが成功しても他方の検証を成功扱いにはしない。`check_ci_workflow.mjs`のmatrix・
条件・smoke検査を先に通過させるため、suite条件の書き間違いで検証を静かに省略することも防ぐ。

### AOT差分artifact

`aot` suiteは、公式CLI・公式生成JavaScript・`lnako run`・LLVM AOT O0〜O3の比較を実行した同じ1回の結果から、
`${{ runner.temp }}/lnako-native-oracle.json`を生成し、Linux x86_64・macOS arm64・Windows x86_64の各ジョブで
`lnako-native-oracle-${{ matrix.os }}`というOS別名へ保存する。artifact保存のためにAOT差分テストを追加実行したり、
経路を減らしたりはしない。保持期間は30日である。

比較失敗時も、比較処理が最後までfixture結果を書けた場合は`status: comparison-failure`のartifactを保存する。
セットアップ、ビルド、または比較基盤の失敗でartifactが生成されない場合は、uploadを`if-no-files-found: ignore`かつ
`continue-on-error: true`で扱う。これにより成果物サービスの欠損・障害が元の検証失敗を別の失敗へ上書きせず、AOT比較の終了状態を
正本として残す。artifact uploadは追加の検証結果ではない。

保存されたartifactの全fixture・全経路は、実行証拠を保存しただけの`unverified`として扱う。artifactの存在やupload成功だけで
互換性をverifiedと判定せず、互換台帳と公式差分の成功結果を別途確認する。
`comparisonSucceeded`とfixtureの`equivalent`は、成功終了だけを表す値ではない。意図した失敗を含め、終了コード・signal・
正規化stdout/stderrが採用した公式経路と等価であったことを表す。

### dispatch evidenceの外部attestation

`aot` suiteは同じ検証runで`${{ runner.temp }}/dispatch-evidence-${{ matrix.os }}.json`も生成し、OS別artifactへ保存する。dispatch JSONは
引数・値・source本文・ローカルパス・標準出力を含まない。main pushまたはmainへのworkflow_dispatchだけが、専用の
`attest-dispatch-evidence` job（`contents/actions: read`、`id-token: write`、`attestations/artifact-metadata: write`）へ進む。

専用jobは3 artifactを取得し、公式`actions/attest@v4.2.2`（commit SHA固定）でmulti-subject SLSA provenanceを作成する。その後、生成直後の
Sigstore bundleを明示入力として公式GitHub CLIの
`gh attestation verify`を各JSONへ実行し、`--repo soramikan/lnako`、`--signer-workflow soramikan/lnako/.github/workflows/ci.yml`、`--signer-digest $GITHUB_SHA`、
`--source-digest $GITHUB_SHA`、`--source-ref refs/heads/main`、GitHub OIDC issuer、`--deny-self-hosted-runners`を強制する。
検証器はさらに3正式OS（darwin-arm64、linux-x64、win32-x64）のsubject digestとJSONのSHA-256を照合し、成功時だけ一時catalog
evidenceを生成する。catalog evidence、検証metadata、署名bundleは同じCI artifactへ保存する。`sync_compat_evidence.mjs`もbundleのSHA-256と
署名を独立に再検証するため、metadata JSONだけを偽造しても`verified`へ昇格できない。fork PRや権限不足ではattest job自体をskipし、
追跡中の`trace-confirmed-unattested`を変更しない。
CIが使用するcheckout、Zig/Node setup、cache、artifact upload/download、attestation actionはすべて40桁commit SHAへ固定し、
`check_ci_workflow.mjs`が移動tagの再混入を拒否する。
core suiteはmetadataだけの昇格と偽造bundleを拒否する回帰検査も実行する。

2026-08-26の[run 32978416580](https://github.com/soramikan/lnako/actions/runs/32978416580)（`3971aef`）は新oracle v4のcold cacheで
3環境15ジョブ全成功、壁時計6分05秒（14:08:20Z〜14:14:25Z）、合計runner時間45分47秒だった。これはattestation job追加前の
比較基準である。attestation導入後もこのAOT比較を
追加実行せず、attestationは保存済みdispatch JSONだけを対象にする。

分離後の初回[run 32934552628](https://github.com/soramikan/lnako/actions/runs/32934552628)（`cd65d5e`）は、
3正式環境の全15ジョブが6分29秒で成功した。分離前run 32932078383の9分50秒から3分21秒（約34.1%）短縮した。
新設した`compat-aot`のZig cache keyは初回利用であったが、それを含めても20分以内という従来基準を維持した。

| 環境 | `aot` | `compat-aot` | 長い方 |
|---|---:|---:|---:|
| Linux x86_64 | 4分13秒 | 3分25秒 | 4分13秒 |
| macOS arm64 | 4分26秒 | 5分06秒 | 5分06秒 |
| Windows x86_64 | 5分11秒 | 5分18秒 | 5分18秒 |

分離前のWindows `aot` 9分45秒に対し、同じ検証を担う2ジョブの長い方は5分18秒で、4分27秒（約45.6%）短縮した。
run全体のクリティカルパスはWindows `host`の6分26秒へ移った。全15ジョブの成功を条件とするため、AOTだけの短縮値を
run全体の完了時間として扱わない。

AOT差分artifact保存を追加した後の[run 32963653947](https://github.com/soramikan/lnako/actions/runs/32963653947)
（`0b6263e`）も、3正式環境の全15ジョブが7分38秒で成功した。Linux・macOS・WindowsのAOT artifactはすべて保存され、
各115 fixtureが公式処理系と等価であることを含んでいた。初回分離runより1分09秒長いが、run全体の所要時間にはGitHub側の
runner割当待ちも含まれるため、この1回の差だけをテスト実行時間の回帰とは判定しない。短縮の安全性は全15ジョブの成功、
3環境artifact、元の7経路とO0〜O3の維持を合わせて判断する。
