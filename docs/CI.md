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

## 検証jobの分割

各正式環境（Linux x86_64、macOS arm64、Windows x86_64）で、通常の`test` matrix 10 jobに加えて、AOT専用matrix 35 jobを
並列実行します。全体は45 test job＋1 attestation jobです。Linux／Windowsは4つの通常suite、native 12 job、support 4 jobへ分割し、
macOSは通常suiteを2 jobへ分割してAOT native 3 jobと合わせ、同時実行上限5に収めます。

| job／suite | 検証内容 |
|---|---|
| `core` | 互換台帳、字句・構文変換・構文・文法生成fuzz・意味・動的値・インタープリタ・plugin_system差分、format、全Zig単体テスト |
| `standard` | math・CSV・TOML・Promise、markup・caniuse・kansujiの公式差分と全生成コーパス |
| `host` | QuickJS互換差分（`compat-js` 4 entryの9ケース実行証拠を含む）、ネイティブプラグインABI、ファイル・プロセス・HTTP・暗号・文字コード・圧縮などNodeホスト差分。symlink経由のカレントディレクトリ実パスと失敗時のchdir診断も公式CLI・Interpreter・AOT O0〜O3で確認 |
| `aot-native`（Linux／Windowsはfixture shard 1/3〜3/3 × O0〜O3、macOSはO0+O1／O2／O3） | 各OSでnative fixture 284件を重み付き固定割当し、公式CLI・公式生成JavaScript・`lnako run`と選択したLLVM AOT routeを実行。全route groupを合わせてO0〜O3の7経路を全件実行 |
| `aot-support` `support-http`（Linux／Windows） | HTTP serverの公式処理系対AOT O0〜O3実通信 |
| `aot-support` `support-dispatch-evidence`（Linux／Windows） | canonical dispatch evidenceとdispatch security。evidence artifactを保存 |
| `aot-support` `support-dispatch-coverage`（Linux／Windows） | canonical dispatch coverage。coverage artifactを保存 |
| `aot-support` `support-smoke`（Linux／Windows） | ReleaseSafe buildと通常smoke |
| `compat-aot` | QuickJS Debug単体テスト、QuickJS ReleaseSafe compiler build、compat-js smoke |
| `mac-core-standard-support`（macOSのみ） | `core`・`standard`に加えて、macOSのAOT support（HTTP、ReleaseSafe、通常smoke）を実行。dispatch監査は5枠内で早く開始する別jobへ移す |
| `mac-host-compat`（macOSのみ） | `host`・`compat-aot`に加えて、AOT dispatch evidence／coverage／securityとそのartifactを実行 |

`aot-native`は重いfixture shardの中でO0〜O3を直列に処理していたため、Linux／Windowsではfixture集合を3つへ分けたうえで、
O0・O1・O2・O3を別jobに分けます。各OSで12 native job（3 fixture shard × 4 route group）となり、同じfixture集合の公式CLI・
公式生成JavaScript・`lnako run`は各route groupで再実行されます。検証の重複は増えますが、各AOT routeを省略せず、重い1 fixtureが
O0〜O3の全routeを同じjobへ拘束しない構成です。macOSは同時実行上限を超えないよう、全284件をO0+O1、O2、O3の3 jobへ
分けます。重み付きfixture選択はsource長と明示commands数から決定的に計算します。artifactにはfixture選択と実行した最適化レベルを
記録し、部分結果を全件・全route結果と誤認しない`lnako.native-oracle-artifact.v3`とします。

`aot-support`のHTTP、canonical dispatch evidence／security、coverage、ReleaseSafe build／smokeは、Linux／Windowsで目的別の4 jobへ分けます。
これにより同じrunner上での監査・build競合を避けます。macOSではrunner上限5を超えないよう、supportを既存の2通常jobへ分散し、dispatch監査を早く開始する`mac-host-compat`へ移しています。
dispatch evidenceとcoverageの全fixture・全site、HTTP serverの10命令・14リクエスト、tiny fixtureの全security不変条件は維持します。
dispatch evidenceとcoverageはそれぞれ専用jobで独立した出力先へ保存し、検査内容を削減せずにrunner上の競合を解消します。
`tools/check_ci_workflow.mjs`はnative 27 job（Linux／Windows各12、macOS 3）、support 8 job（Linux／Windows各4）、通常10 job、
全45 test job、macOS 5 job、3正式OS、全7経路、O0〜O3、artifact、attestationの構成を固定します。

GitHub ActionsのmacOS runnerは同時に5 jobまでです。現行workflowでは`mac-core-standard-support`、`mac-host-compat`、native route 3 jobの
5 jobだけをmacOSへ割り当て、同一run内で6件目以降が待ち行列へ入らない構成を維持します。dispatch監査は`mac-host-compat`へ置き、通常のcore／standardとHTTP／smokeは`mac-core-standard-support`へ残します。Linux／Windowsのnative route shardに加えて
macOSの通常suiteもjob境界へ分けます。それぞれLinux／Windowsは通常4 job・native 12 job・support 4 job、macOSは通常2 job・native 3 jobを
独立runnerへ割り当てます。別workflowや同時runがrunner枠を使用する場合の
外部queueは残るため、queue時間を含む壁時計、runner合計時間、各job時間は完了済みrunで別途確認します。macOSについてはworkflow自身が
5 jobを超えないことを固定し、6件目以降の待ち行列を作らないことを検証します。

直前の[run 33407218789](https://github.com/soramikan/lnako/actions/runs/33407218789)（`2a9c00a`）では、変更前のmacOS matrixが8 jobあり、
最初の5 jobが15:14:15〜15:14:19Zに開始した後、`AOT native shard 1/3`は15:15:28Z、`compat-aot`は15:17:35Z、
`AOT native shard 2/3`は15:17:47Zまで開始を待っていた。coreの証拠台帳エラーでrun自体は失敗したため、これは性能改善値ではなく、
macOS上限によるqueue発生の観測記録として扱う。現行の5 job構成では、通常suiteを`mac-core-standard-support`と`mac-host-compat`へ分け、
AOT native 3 route jobへ割り当てる。dispatch supportは早く開始する`mac-host-compat`へ移し、全検証内容を維持したまま6件目のqueueを作らない。

分割後の[run 33493025889](https://github.com/soramikan/lnako/actions/runs/33493025889)（`991dd3f`）は、45 test job＋1 attestation jobを全て成功させた。runの壁時計は09:35:34Z〜09:48:38Zの13分04秒、jobの実行時間合計は約283分47秒だった。macOSの5 job（通常2＋AOT native 3）は09:35:37〜09:35:38Zにすべて開始し、6件目の待ち行列は発生しなかった。これはjob分割後の基準値であり、runner合計時間の削減を意味しない。macOSの同時実行上限を超えるjob追加は行わず、Linux／Windows側だけで独立job化の効果を測定する。

2026-09-02の[run 33601966683](https://github.com/soramikan/lnako/actions/runs/33601966683)（`fecd831`）は、45 test job＋1 attestation jobを成功させ、表示上の壁時計は19分36秒だった。公開job時刻ではmacOSの5 jobは、`mac-host-compat` 6分24秒、AOT native O0+O1 11分27秒、O2 9分44秒、O3 9分11秒、`mac-core-standard-support` 15分43秒で、後者はrunner枠の影響でrun開始から3分17秒後に開始した。統合job内ではdispatch evidence／coverage監査が約8分24秒を占めたため、今回のworkflowではその監査とAOT buildを既に早く開始する`mac-host-compat`へ移し、5つのmacOS job数を維持する。検証経路、O0〜O3、全artifact、attestation条件は削減していない。次の完了済みrunで、macOS queue、壁時計、runner合計、各job時間をこの変更前の測定と比較する。

直近の[run 33606373377](https://github.com/soramikan/lnako/actions/runs/33606373377)（`c00f22c`、CI #459）は12分45秒後に`cancel-in-progress`で取消された。公開注記は、同じ`ci-CI-refs/heads/main` concurrency groupに高優先度の後続待機runが存在したためであり、検証stepの失敗ではない。取消時点でAOT 35 jobと通常test 10 jobが完了し、attestationは未実行だった。このrunは失敗原因や性能値として扱わず、後続runの完了結果で3正式OSの成功、macOS 5枠、wall-clock、runner合計、各job時間を確認する。

その後の[run 33610505944](https://github.com/soramikan/lnako/actions/runs/33610505944)（`b853cc4`、CI #461）は15分32秒でFailureとなり、macOS `mac-core-standard-support`とLinux `core`の`Verify compatibility baseline`がexit code 1になった。公開ログのNode.js 20警告は全体のwarningで、失敗原因ではない。履歴artifactを照合すると、canonical dispatch証拠は`54155f6`、coverageは`b6b48f1`、expected-exit・global binding・static constant群は`25c4f7c`のclean provenanceを指したまま、検査対象のfixture／dispatch監査ツールが後続commitで変わっていた。`sync_compat_evidence.mjs --check`のfollow-up規則がこの状態を受理しなかったことが原因であり、runnerや命令実装の失敗ではない。U11では現行HEAD `17df1d1`からcanonical、coverage、expected-exit、global binding、static constant群を再生成し、台帳同期を成功させた。この再発防止の証拠更新を`628e5ce`へ記録する。

その後の[run 33615040065](https://github.com/soramikan/lnako/actions/runs/33615040065)（`24483dc`、CI #462）は15分33秒でFailureとなった。macOS `mac-core-standard-support`とLinux `core`では`check_interpreter_only_classification.mjs --check`が、Linux `host`とmacOS `mac-host-compat`では`update_node_implemented.mjs --check`が、後続のU12証拠台帳更新に追随していない生成物を検出した。Node.js 20の`mlugg/setup-zig`非推奨警告45件は警告であり、失敗原因ではない。現行HEADでは`check_interpreter_only_classification.mjs --generate`、`update_node_implemented.mjs`、`sync_compat_evidence.mjs --generate`を順に実行し、`interpreter-only-classification.json`、`implemented.json`、`evidence.json`を再生成する。これらはNode HTTPの既存AOT証拠と対応する生成台帳の更新であり、製品ランタイムやCIの検証範囲を変更しない。再生成後に各`--check`、compat report、CI構成検査を通し、次のpushで再発がないかを確認する。

その後の[run 33617822391](https://github.com/soramikan/lnako/actions/runs/33617822391)（`1ada8b2`、CI #463）は15分28秒でFailureとなった。Linux `core`とmacOS `mac-core-standard-support`の2 jobだけが、`sync_compat.mjs --check`で`compat/v3.7.24/matrix.json`の古い生成物を検出し、残る43 test jobは成功した。原因は、`plugin-node-http-options-and-promises`をfixtureへ追加した後に、対応する`matrix.json`と`standard-cnako.json`を再生成せずpushしたことである。ツールチェーンcacheの復元とAOT native／support jobは成功しており、Node.js 20警告も失敗原因ではない。現行HEADでは`sync_compat.mjs --generate`を実行し、2生成物を更新したうえで`--check`を通す。fixture、命令実装、job数、AOT／QuickJS経路は削減していない。次回pushではこの生成物同期を含む現HEADの45 test jobを起動し、完了を待たずに実装を継続しながら、次のpush前に完了済みrunの失敗有無を確認する。

## AOT検証の共通buildとjob分割

各AOT jobは自身のrunner上でcompilerを一度だけbuildし、`--no-build`の検査へ渡します。native jobは`LNAKO_NATIVE_ORACLE_JOBS=1`
とし、AOT fixture shardと最適化routeの組み合わせをjob並列化の単位にします。supportも目的別jobごとに必要な先行compilerを一度だけbuildし、
HTTP、dispatch evidence／security、dispatch coverage、ReleaseSafe／smokeの長い処理を別runnerへ分離します。

| job | 主なstep | artifact |
|---|---|---|
| `aot-native` × 3 OS（Linux／Windows各12 job、macOS 3 job） | `zig build` → native oracleのfixture／route shard（全284件の一部または全件、公式3経路＋選択AOT route） | OS・fixture shard・optimization別native oracle artifact |
| `aot-support` × Linux／Windows（4 purpose jobs／OS） | `zig build` → HTTP AOT、dispatch evidence／security、dispatch coverage、ReleaseSafe build／通常smokeを目的別jobで実行 | OS別dispatch evidence／coverage artifact |
| `mac-core-standard-support` × macOS | 通常core／standard → `zig build` → HTTP AOT、ReleaseSafe build、通常smoke | macOS dispatch evidence／coverageは`mac-host-compat`から保存 |

通常の`test` matrixはLinux／Windowsのcore／standard／host／compat-aot 8 jobとmacOSの`mac-core-standard-support`／`mac-host-compat` 2 jobへ分け、AOT nativeの
fixture検証条件を混ぜません。macOSのdispatch support監査だけはrunner上限のため後者へ移し、core／standardとHTTP・smokeは前者へ残します。したがってAOT nativeだけの失敗は
native shardかsupportのどのjob／stepで起きたかを直接確認できます。attestation jobは`test`と`aot` matrixの両方が成功した場合だけ
起動し、3 OSのdispatch evidenceを取得します。job数を増やした結果、setupの重複とrunner合計時間は増える可能性があるため、
壁時計、runner合計、各job時間、cache hit/missは分割後の完了済みrunで別々に記録します。Linux／Windowsのnative route job増加による
setup重複とrunner合計の変化も、macOSのqueueが発生していないことと分けて評価します。

元の検証コマンドを削除せず、AOT専用jobへ移動しただけです。OSごとの互換検証をLinuxだけへ縮小する最適化は行いません。
job上限は50分とし、停止しないホスト・ネットワークテストを検出します。

2026-08-31にmacOS arm64の現行fixtureで並列runnerをローカル実測したところ、dispatch evidence（Interpreter 777イベント、AOT
manifest 779件・runtime 1,554イベント）とcoverage（30 fixture、1,688 unambiguous site、309/523 native entry）を両方成功させて
約3分54秒だった。前回CIの同じmacOS AOT jobでは、この2 stepを直列に実行して約3分54秒＋約4分28秒だったため、対象区間は
同時実行の長い方へ短縮できる見込みである。ただしローカルとCI runnerは性能条件が異なり、3 OSのwall-clock・runner合計時間・cache
hit/missをまだ測っていないため、CI全体の短縮証拠とは扱わない。次回以降のpushでは、AOT並列runnerの各子検査の成功、3 OS artifact、
AOT全体時間、wall-clock、runner合計時間、cache状態を完了済みrunで確認する。

同日、先行`zig build`後のAOT全検査runnerをmacOS arm64でloopback権限付きに実測した。native oracle 284件は795.14秒、HTTP
serverは30.19秒、dispatch securityは1.15秒、dispatch evidence/coverageは340.36秒で、4検査すべて成功した。並列runnerのwall-clockは
795.14秒（13分15.14秒）、単純直列合計は1,166.84秒（19分26.84秒）で、ローカル対象区間では371.70秒（約31.8%）短縮した。
このnative oracleはartifactを含む全7経路・O0〜O3、dispatch側はInterpreter 777イベント・AOT manifest 779件・runtime 1,554イベントと
30 fixture・1,688 siteを検証している。作業機とCI runnerの性能差、cache状態、3 OSの同時実行条件は別なので、正式な改善値は次回pushの
完了済みrunで確定する。

直近の[run 33389904362](https://github.com/soramikan/lnako/actions/runs/33389904362)は32分25秒で、AOT自体は3 OSとも成功した。
ただしmacOS/Linuxの`core`が、浅いcheckoutで証拠生成commitの祖先をたどれず`cleanなdispatch証拠のlnako commitが現行HEADと一致しません`
で失敗し、Windows `core`は成功したため、attestationはskipされた。AOT job時間はLinux 29分10秒、macOS 20分57秒、Windows 31分06秒で、
このrunのAOT検査はnative oracleとdispatch監査を直列に実行していた。次回runではcoreのfull checkoutと全AOT検査runner並列化を同時に検証する。

元の検証コマンドは並列runner内から削除せず、各OSでいずれか1スイートが一度だけ実行します。OSごとの互換検証をLinuxだけへ
縮小する最適化は行いません。ジョブ上限は50分とし、停止しないホスト・ネットワークテストを検出します。

## 同一refの旧run取消

concurrency groupはワークフロー名と完全なGit refから作ります。同じブランチ、または同じPR refへ新しいcommitが
pushされた場合だけ、進行中の古いrunを取り消します。別ブランチ、別PR、タグのrunは互いに取り消しません。

最新commitは古いcommitを祖先として含むため、最新runが累積したソースを全スイートで検証します。一方、取り消された
個々のcommitにはGitHub上の完走記録が残らないため、機能コミット前のローカル検証と署名を省略してよい規則では
ありません。リリース候補やマイルストーンのcommitは、後続pushを止めて全45テストjobとattestation jobの完走を証拠として残します。

追跡中のdispatch証拠が直前のfixture commitを指す場合、`sync_compat_evidence.mjs`はそのcommitから現HEADまでの変更が
CI・文書・証拠検証のallowlistだけであることを`git merge-base`とpath差分で確認します。この検査に必要な履歴を確保するため、
Linux／Windowsの`core`とmacOSの`mac-core-standard-support`の3 jobだけは`actions/checkout`の`fetch-depth: 0`を使い、他の42 test/AOT jobは既定の浅いcheckoutを維持します。full checkoutは証拠追従の
検査範囲を広げるものではなく、fixture・catalog・product sourceの変更を引き続き拒否します。

## キャッシュ

- LLVM/LLD・QuickJSと公式なでしこ3オラクルはOS別の固定バージョン・ハッシュ付きキャッシュを全スイートで共有します。
- Zigのglobal/local cacheは長時間の`host`・`aot-native`だけで保存し、OSに加えてスイート名をキーへ含めます。上限は1,536 MiBです。
- キャッシュmissでもセットアップスクリプトがlockfileのSHA-256を検証します。キャッシュhitを安全性の根拠にはしません。
- 初回またはキャッシュ失効時はダウンロード時間が加わるため、定常時と同じ所要時間にはなりません。

分割した各スイートはセットアップを個別に行うため、単一runだけの総runner時間は直列構成より増える可能性があります。
壁時計時間を短縮し、旧run取消によって複数run全体の無駄なrunner時間を抑える設計です。

### Zig build cacheの保存対象

`mlugg/setup-zig`のbuild cacheは、保存keyへrun IDとattemptが付くため、全45ジョブで有効にすると最大45個の新規cacheが
runごとに増えます。2026-08-27に確認した時点では、Actions cacheが30件・約11.6 GBに達し、固定Linux LLVM cacheが
退避された後のrunで5つのLinuxジョブが同じ配布物の取得・SHA-256検証・展開を約148秒ずつ重複していました。

検証工程を変えずにcacheの増加を抑えるため、cross-runのZig build cacheは`host`とnative fixtureを担当する`aot-native`だけに限定します。
3 OSで最大31個/run（host相当4［Linux／Windowsの`host`＋macOSの`mac-core-standard-support`／`mac-host-compat`］＋`aot-native` 27）となり、`core`・`standard`・`aot-support`・`compat-aot`もjob内のZig cacheは通常どおり使用します。
`use-cache: false`のjobでも、setup actionが管理する固定Zig 0.16.0配布物のcacheは別系統で維持されます。

1,536 MiB上限を超えたbuild cacheはactionの仕様上、部分的なLRU整理ではなく空にして保存されます。このため上限を小さく
しすぎず、今後の実runでcache clear、固定toolchain cacheの残存、壁時計時間を合わせて確認します。固定LLVM/LLD・QuickJS・
公式オラクルの実体hash検証は、cache hit時も従来どおり毎jobで実行します。

### 1,536 MiBへの調整

2026-08-30の`5a76445`までは上限1,024 MiBで運用していた。直近runではhost/aotの6件で約328.9 MBの新規Zig cacheを保存した一方、Actions cache全体は35件・約11.16 GBとなり、macOS host・Windows host・Windows aotでは上限超過後の空ディレクトリに近い184〜191 byteのcacheが残った。

このため検証範囲とcache対象jobを変えず、上限だけを1,536 MiBへ引き上げる。調整後のrunでは、cold/warm双方についてcache clearの有無、固定Zig toolchain cacheの残存、各job時間、壁時計、runner合計時間、Actions cache総容量を記録する。これらを実測するまで、1,536 MiBへの変更を性能改善の証拠とは扱わない。

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

`tools/compare_native_oracle.mjs` は、検証対象fixtureをfixture単位で最大4 workerに割り当てます。各fixture内の
公式CLI、公式JavaScript生成・実行、`lnako run`、AOTのO0・O1・O2・O3生成・実行は従来どおり直列です。そのため、
検証経路（公式CLI、公式生成JavaScript、インタープリタ、AOT 4段階）の7経路、全ケース、全最適化レベルは削減していません。
`LNAKO_NATIVE_ORACLE_JOBS=1` を指定すると従来相当の直列実行へ戻せます。値は1〜4を受け付け、未指定時は2です。
CIのAOT oracle stepも`LNAKO_NATIVE_ORACLE_JOBS=2`を明示し、ローカルの既定値と揃えます。native oracleとdispatch監査を同時に
実行するため、過密なrunnerでworkerを増やしてもwall-clockが短くならず、時間依存の外部プロセスfixtureを不安定にする場合があります。

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

## AOT oracle 4 workerの再測定

前回の[run 33381540990](https://github.com/soramikan/lnako/actions/runs/33381540990)では、同じ284 fixtureを既定の2 workerで実行し、
native oracle stepはLinux 19分06秒、macOS 13分14秒、Windows 9分34秒だった。dispatch evidenceとcoverageを含むAOT jobは、
それぞれ34分30秒、23分27秒、18分01秒である。coreの2件は証拠commit検証の不具合で失敗したが、AOT 3環境の比較結果自体は成功した。

同じ284 fixture・7経路・O0〜O3をmacOS arm64で`LNAKO_NATIVE_ORACLE_JOBS=4`にしてローカル実測した結果は、11分52.93秒、
全284件成功（user 15分20.75秒、sys 1分36.37秒）だった。実行環境がCI runnerと異なるため、この1回だけで性能改善とは判定せず、
次回pushで3環境の各step時間、壁時計、runner合計、cache hit/miss、失敗有無を記録する。4 workerでメモリ・競合・差分が発生した場合は2 workerへ戻し、
fixture・7経路・O0〜O3の検証範囲は変更しない。

## Windows AOTの一時ディレクトリと公式取込path

2026-08-30の[run 33331298915](https://github.com/soramikan/lnako/actions/runs/33331298915)と
[run 33333195998](https://github.com/soramikan/lnako/actions/runs/33333195998)では、Windows `aot`の
`compare_native_oracle.mjs`で`native-caniuse-browsers`の公式生成JavaScriptが見つからない事象が発生した。
Windows runnerでは公式オラクルが`D:`、`os.tmpdir()`が`C:`となり、`path.relative()`がドライブ跨ぎの
`D:/...`を返す。なでしこ3 v3.7.24のJSプラグイン検索は`X:\`（バックスラッシュ）だけをドライブ付き
フルパスとして認識するため、`D:/...`をfixtureからの相対pathとして連結し、公式compileがエラーを握って
終了コード0を返し、生成ファイルだけが作られなかった。この仕様境界は
[`COMPATIBILITY_QUIRKS.md`](COMPATIBILITY_QUIRKS.md)へ記録した。

`tools/compare_native_oracle.mjs`の一時ディレクトリをリポジトリ側へ移し、オラクルと同じドライブで
相対plugin pathを生成するよう修正した。後者のrunでは新たに追加したdispatch coverage auditが
`plugin-csv-all`のWindows結果差も報告したが、macOSの同じ26 fixture監査では再現していない。次回pushの
Windows `aot`で両方を再確認し、失敗時は出力値を含む診断から追加修正する。CIの完了を待つ運用には変えず、
pushごとに完了済みrunをスナップショット確認する。

その後の[run 33567310023](https://github.com/soramikan/lnako/actions/runs/33567310023)（`3e1e75a`）では、
`compare_native_oracle.mjs`側の修正済み経路とは別に、dispatch coverage auditが`plugin-markup-all`で同じ
ドライブ跨ぎの公式plugin path失敗を報告した。`check_dispatch_coverage.mjs`も一時領域をリポジトリ側へ移し、
監査開始前のGit状態を証拠へ保存するよう修正する。coverage artifactの再生成後、次回pushでWindows
`support-dispatch-coverage`を再実行するが、CI完了は待たずに次の実装を進める。

その後の[run 33335610101](https://github.com/soramikan/lnako/actions/runs/33335610101)（`2057d2d`）では、
`native-caniuse-browsers`の生成JavaScript欠落は再発しなかった。一方、Windows `aot`の比較artifactには
`native-csv-commands`、`native-system-debug-display`、`native-system-hatena-default`、
`native-node-stdin-lines`の4件が残った。いずれも終了コード・stderr・Interpreter結果は一致し、AOT標準出力の
一部だけがWindowsの`CRLF`になっていた。さらにdispatch coverage auditも`plugin-csv-all`で同じ出力改行差を
報告していたため、実行結果の意味を変えない比較境界として、`compare_native_oracle.mjs`と
`check_dispatch_coverage.mjs`の標準出力・stderrを`CRLF`および単独`CR`から`LF`へ正規化する修正を追加した。
次回pushでは、この修正後のWindows `aot`とdispatch coverageを完了待ちせずに開始し、後続の区切りで完了済み
runだけを確認する。

その後の[run 33336662774](https://github.com/soramikan/lnako/actions/runs/33336662774)（`525e33c`）では、改行正規化後も
Windows `aot`が同じ4 fixtureで失敗した。`native-csv-commands`と`native-node-stdin-lines`では、AOTがNako文字列内の
`CRLF`をWindows CRTの`putchar`へ1バイトずつ渡していたため、テキストモードの`LF`変換が重なり`CRCRLF`となっていた。
`native-system-debug-display`と`native-system-hatena-default`では、公式処理系とInterpreterがWindowsドライブ文字の
コロン前（`D`）を表示する一方、AOTだけが一時fixtureのフルパスを表示していた。いずれもAOT標準出力の実装差であり、
比較側の改行正規化を広げて隠すべき差ではない。

AOT runtime初期化時にWindows stdoutをbinary mode（`_setmode(1, 0x8000)`）へ切り替え、埋め込み`CRLF`をそのまま
出力するようにした。またAOTのデバッグ表示でもInterpreterと同じドライブ文字境界を適用した。macOSの769単体テストと
`x86_64-windows-msvc` cross compileは通過している。次回pushのWindows `aot`とdispatch coverageで実行結果を再確認するが、
CIの完了は待たずに次の実装を進める。

その後の[run 33340403645](https://github.com/soramikan/lnako/actions/runs/33340403645)（`a630b56`）では、Windowsの
`core`と`compat-aot`が同じLLVM IR単体テストで失敗した。Windows生成入口を`main`から`wmain`へ切り替えた実装に対し、
テストが`main`とbyte argv初期化の呼出しを固定期待していたためで、Windows AOT差分自体は成功していた。テストの入口名と
argv初期化呼出しをtarget-awareな期待値へ修正し、次のpushで通常AOT・QuickJS build・全15テストjobを再確認する。

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

`compat-aot`は公式オラクルもNodeスクリプトも使わないため、オラクルcache、`tools/setup_oracle.mjs`、Nodeのsetupを条件付きで省略する。
LLVM/LLDとQuickJSの固定版・SHA-256検証、Zigのsetupは省略しない。Zig cacheは`cache-key: matrix.suite`のため、`aot`と
`compat-aot`は別cache名前空間になる。これは並列jobのcache保存競合を避ける一方、初回の`compat-aot`ではコンパイルcacheが
冷えて追加時間になる分かりにくい挙動である。ツールチェーンcacheは従来どおりOS・arch・固定版キーを共有し、setup scriptの
ハッシュ検証を必ず通す。

直前の[run 33349400116](https://github.com/soramikan/lnako/actions/runs/33349400116)では、macOS arm64の`compat-aot`が
`actions/setup-node`でNode 24.15.0を取得する際、`api.github.com`と`nodejs.org`のDNS解決に失敗した。QuickJS単体テストや
コンパイラbuildは実行前だったため、これは製品のテスト失敗ではなく、不要な外部取得経路の失敗である。以後はこのsuiteでNode
setupを行わず、同suiteのQuickJS Debug単体テスト、ReleaseSafe build、compat-js smokeは維持する。

分離後は、通常AOTとQuickJS AOTが並列に走るため、Windowsの壁時計時間は分離前9分50秒から、各jobのセットアップとsmokeを
含む長い方（予測6〜8分台）へ近づく見込みである。3つの追加jobによりrunner使用時間とcache保存処理は増える。初回runでは
成功率、cache hit/miss、各step時間を記録し、予測が外れた場合は分離を戻す判断材料にする。GitHub Actionsログから
得られないCPU/RSSを推測値で補わない。

失敗時は、`aot`失敗なら通常AOT差分・LLVMリンク・通常smoke、`compat-aot`失敗ならQuickJS Debug/ReleaseSafe buildまたは
compat smokeに絞って診断できる。片方のsuiteが成功しても他方の検証を成功扱いにはしない。`check_ci_workflow.mjs`のmatrix・
条件・smoke検査を先に通過させるため、suite条件の書き間違いで検証を静かに省略することも防ぐ。

### AOT差分artifact

`aot-native`の各fixture／route shardは、公式CLI・公式生成JavaScript・`lnako run`・選択したLLVM AOT routeの比較を実行した同じ1回の結果から、
`${{ runner.temp }}/lnako-native-oracle-${{ matrix.fixtureShardIndex }}-${{ matrix.optimizationKey }}.json`を生成し、Linux x86_64・macOS arm64・Windows x86_64の
各jobで`lnako-native-oracle-${{ matrix.os }}-shard-${{ matrix.fixtureShardIndex }}-${{ matrix.optimizationKey }}`というOS・fixture shard・optimization別名へ保存する。
artifact保存のためにAOT差分テストを追加実行したり、経路・fixtureを減らしたりはしない。保持期間は30日である。

各native artifactの`selection`は`weighted-source-command`または`all`、fixture shard番号・shard数・全fixture数、実行した最適化レベルを示す。
1つのartifactは284件全体・全routeの結果ではなく、fixture／route選択の一部である。全件・全routeのCI成功は各OSの全native jobが成功したことと、
個々のartifactのfixture数・route・選択情報を合わせて判定する。Linux／Windowsは3 fixture shard × 4 route group、macOSは全件の3 route groupであり、
schemaを`lnako.native-oracle-artifact.v3`へ上げて旧v1/v2のartifactと混同しないようにした。

比較失敗時も、比較処理が最後までfixture結果を書けた場合は`status: comparison-failure`のartifactを保存する。
セットアップ、ビルド、または比較基盤の失敗でartifactが生成されない場合は、uploadを`if-no-files-found: ignore`かつ
`continue-on-error: true`で扱う。これにより成果物サービスの欠損・障害が元の検証失敗を別の失敗へ上書きせず、AOT比較の終了状態を
正本として残す。artifact uploadは追加の検証結果ではない。

保存されたartifactの全fixture・全経路は、実行証拠を保存しただけの`unverified`として扱う。artifactの存在やupload成功だけで
互換性をverifiedと判定せず、互換台帳と公式差分の成功結果を別途確認する。
`comparisonSucceeded`とfixtureの`equivalent`は、成功終了だけを表す値ではない。意図した失敗を含め、終了コード・signal・
正規化stdout/stderrが採用した公式経路と等価であったことを表す。

### dispatch evidenceの外部attestation

Linux／Windowsの`support-dispatch-evidence` jobは同じ検証runで`${{ runner.temp }}/dispatch-evidence-${{ matrix.os }}.json`を生成し、OS別artifactへ保存する。
`support-dispatch-coverage` jobは対応するcoverage JSONを別artifactへ保存する。dispatch JSONは
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

## AOT並列化後のWindows失敗とworker再調整

`37cefbde` の[run 33393547459](https://github.com/soramikan/lnako/actions/runs/33393547459)は、14/15のmatrix jobが成功したが、
Windows x86_64のAOTだけが失敗し、壁時計は20分43秒だった。AOT jobはLinux 20分37秒、macOS 17分29秒、Windows 20分37秒で、
Linux/macOSのAOT差分は成功した。Windowsではnative oracle 18分27秒、HTTP 32秒、security 3秒、dispatch evidence/coverage 9分07秒だった。
native oracle（284 fixture・7経路・O0〜O3）とHTTP・security・dispatch evidence自体は成功したが、coverage監査の
`node-file-cases.json/plugin-node-process-completion-order`で、AOT trace有無の結果が変化した。失敗時はattestation jobがskipされた。

これはfixture・最適化レベル・OS検証を削った結果ではない。4 workerのnative oracleとdispatch監査を同一runnerで同時に実行したことで、
Windowsの外部Nodeプロセス起動と350msの待機窓がrunner負荷の影響を受けた可能性が高い。直前の2 worker・直列AOT検査だった
[run 33381540990](https://github.com/soramikan/lnako/actions/runs/33381540990)では、Windows native oracleは9分34秒、dispatch evidenceは2分03秒、
coverageは2分27秒で完了しており、4 workerがこの並列構成でwall-clockを改善したとは扱えない。

当時の次のpushでは、AOT runnerの`LNAKO_NATIVE_ORACLE_JOBS`を2へ戻す計画とした。native oracleの各fixture内の7経路・O0〜O3と、dispatch監査の全fixture・
全siteは維持し、worker数だけをrunner負荷に合わせる。また、完了順を検証するfixtureの待機を0.35秒から1秒へ広げる。fast側5ms・slow側200msの
相対的な完了順は変えず、外部プロセス起動の揺らぎだけに余裕を持たせるためである。実際にはこの1秒待機・5ms対200msの差でも、macOS 5 job同時実行時の
`mac-host-compat`でInterpreterの順序が`SLOW,FAST`へ反転した（[run 33467401327](https://github.com/soramikan/lnako/actions/runs/33467401327)）。
その後、worker内並列化では壁時計の改善が再現しなかったため、現行workflowはnative routeをjobへ分割し、各native jobの
`LNAKO_NATIVE_ORACLE_JOBS`を1としている。検証を削らずに起動揺らぎの余裕をさらに広げるため、現在のfixtureはfast側を即時出力、slow側を1秒遅延、
待機を2秒へ変更する。次回以降、3 OSのAOT子検査、現行の39 test job＋attestation、artifact、壁時計、runner合計時間、cache hit/missを
完了済みrunで記録し、macOS 5 job枠内での再現性を確認する。

ローカルmacOS arm64で同じ2 worker設定を使ったAOT runnerでは、native oracleが796.92秒、dispatch evidence/coverageが283.75秒、
securityが1.02秒で成功した。通常sandboxではHTTPのloopback bindだけが`EPERM`になったため、loopback権限付きの単独検査でHTTPの
10命令・O0〜O3・各14リクエスト成功を確認した。この測定は実CIの壁時計やrunner合計時間とは分け、正式な短縮値は次回pushの完了済みrunで判定する。

## AOT native fixtureの独立job分割（前回構成）

worker=2へ戻した`17c073b`後も、native oracleとdispatch監査を同一runnerで実行する構造では、workerを増やした時と同じ負荷競合を
避けられない。そこでAOTを`aot-native`と`aot-support`へ分けた。`aot-native`は3正式OSそれぞれをさらに3 shardへ
分け、native-cases.jsonの284 fixtureを重み付き固定割当した。各shardのworkerは1で、fixture内の公式CLI・生成JavaScript・Interpreter・
AOT O0〜O3の7経路と、O0〜O3の順序は維持する。

`aot-support`はOSごとに1 jobとし、HTTP server AOT差分、canonical dispatch evidence、dispatch coverage、dispatch security、
ReleaseSafe build、通常smokeを実行する。従って通常の`test` 12 job、native 9 job、support 3 jobの計21 test jobとなり、
各OSでnativeの長い処理がsupportの追加監査を待たない。dispatch evidence／coverage artifactはsupport jobから、native oracle artifactは
OS・shard別に保存し、attestationは`test`とAOT matrix全体の成功後だけ実行する。

この変更で検証対象を削減していないことを、`tools/check_ci_workflow.mjs`がmatrixの実job数、OS集合、各shard、全7経路、O0〜O3、
artifact、attestation依存関係として検査する。job分割はrunnerの同時実行枠とsetup重複を増やすため、実CIで成功を確認するまで短縮効果とは
扱わない。次のpush時には、前回の完了済みCIの結論と失敗ログを先に確認し、その後新CI runは完了待ちせず、次の実装を進めながら次回push前に
完了済みrunの各native shard／support job、wall-clock、runner合計、cache hit/missを確認する。

## Linux／Windowsのfixture／route job増加とmacOS上限の維持（前回構成）

前回の[run 33436723428](https://github.com/soramikan/lnako/actions/runs/33436723428)（`d7a4886`）は27 test jobとattestationを
成功させ、wall-clockは20:34:00Z〜20:55:34Zの約21分34秒だった。macOSは`mac-bundle`、native 3 shard、supportの5 jobが
20:34:03〜20:34:04Zに開始しており、このrunではmacOSの6件目以降のqueueは観測されなかった。

一方、AOT native shard 1の差分検査だけでLinux約21分、macOS約16分、Windows約19分を要し、他のnative shardは約5分で完了した。
`native-cut-commands`のような重いfixtureはfixture単位では分割できないため、6 shardへ増やしてもそのfixtureが含まれるjobが
クリティカルパスに残った。これは検証失敗ではなく、成功runのstep時間に
基づく構成上のボトルネックである。

現行構成では、Linux／Windowsを3 fixture shard × O0〜O3の12 native jobへ分け、各route groupで公式CLI・公式生成JavaScript・
`lnako run`と選択したAOT routeを実行する。これにより各OSの全284 fixture、全7経路、O0〜O3は維持しつつ、重いfixtureの4最適化を
同じjobへ拘束しない。macOSはrunner上限を超えないよう、全284 fixtureをO0+O1、O2、O3のnative 3 jobへ分け、`mac-bundle`とsupportを
合わせて常に5 job以内に収める。supportの
dispatch evidenceとcoverageは`tools/check_dispatch_audits_parallel.mjs`で独立出力へ同時起動し、HTTP、security、ReleaseSafe build、
通常smokeは従来どおり実行する。

この変更後の期待値は、Linux／Windowsではfixture shardと最適化routeのjob分離、macOSでは5 job上限内でのroute分離による壁時計短縮である。
その後の[run 33440557705](https://github.com/soramikan/lnako/actions/runs/33440557705)（`058bf90`）は、旧構成の27 test job＋attestationを
21分17秒（21:17:14Z〜21:38:31Z）で成功させた。macOS 5 jobは21:17:17〜21:17:18Zに開始してqueueはなく、Linuxの重いnative shard 1は
20分35秒、Windows shard 1は16分42秒、macOS shard 1は13分34秒を要した。fixture shardを6へ増やしても重いfixtureが含まれるjobは
クリティカルパスに残ったため、これはroute分割前の基準値である。

この作業ツリーでLinux／Windowsを3 fixture shard × 4 optimization routeの12 native job、macOSをO0+O1／O2／O3の3 native jobへ変更した結果、
[run 33443631136](https://github.com/soramikan/lnako/actions/runs/33443631136)（`3c44949`）は40 job（test 39＋attestation 1）を成功させた。
作成21:53:58Zから更新22:07:37Zまでのwall-clockは13分39秒で、旧構成run 33440557705の21分17秒から7分38秒（約35.9%）短縮した。
runner合計は4時間36分26秒で、旧構成の3時間21分21秒より1時間15分05秒増えた。これはLinux／Windowsのnative route分割によるsetupと公式3経路の
再実行コストであり、壁時計短縮とのトレードオフとして記録する。

macOSは`mac-bundle`、native route 3 job、supportの5 jobが21:54:02〜21:54:03Zにすべて開始し、6件目以降のqueueは発生しなかった。macOSの
native routeはO0+O1が11分44秒、O2が9分12秒、O3が9分13秒、supportが10分06秒で、Linux／Windowsを含む最長test jobはWindows supportの12分56秒だった。
全OSのnative artifact、support artifact、attestationを含めて成功しているため、現行の5 job制約内route分割と検証完全性を確認できた。次回push時はこのrunを
前回完了runとして先に確認し、新runの完了は待たず、失敗があれば`gh run view --log-failed`で原因を調査・修正する。

## macOS通常suiteの2 job分割（実測）

直前の[run 33452654559](https://github.com/soramikan/lnako/actions/runs/33452654559)（`e20872e`）は、39 test jobとattestationを
すべて成功させた。作成23:55:00Zから更新00:12:33Zまでのwall-clockは約17分33秒だった。macOSの5 jobは23:55:03〜23:55:05Zに
すべて開始しており、このrunでは6件目以降のqueueは発生していない。

一方、macOSの`mac-bundle`は約16分51秒かかり、通常4 suiteとcompat-js検証を一つのrunnerで逐次実行したことがwall-clockのcritical pathに
なった。これはqueueによる遅延ではなく、job内の逐次実行時間である。

次の構成では、macOSの通常検証を`mac-core-standard-support`（core／standard＋AOT support）と`mac-host-compat`（host＋compat-aot）の
2 jobへ分け、AOT nativeのO0+O1／O2／O3の3 jobと合わせて5 jobに固定する。AOT supportのHTTP、dispatch evidence／coverage／security、
ReleaseSafe、通常smokeはmacOSの前者へ移すため、検証項目・3 OSのattestation対象・全7経路・O0〜O3を削減しない。

この変更後は、push時にまず直前の完了済みrunの結論と失敗ログを確認する。新runの完了は待たずに実装を継続し、次回push前にmacOS 5 jobの
開始時刻、queueの有無、各job／step時間、wall-clock、runner合計、cache hit/miss、3 OS artifactとattestationの成否を確認して記録する。

直後の[run 33454974826](https://github.com/soramikan/lnako/actions/runs/33454974826)（`e078c00`）は、39 test jobとattestationの
計40 jobをすべて成功させた。作成00:29:46Zから更新00:45:23Zまでのwall-clockは15分37秒で、直前のrun 33452654559の17分33秒から
1分56秒（約11.0%）短縮した。runner時間はjob実測の合計で4時間53分46秒（直前は5時間01分45秒）となり、wall-clockだけでなく
合計も7分59秒（約2.6%）減少した。全284 fixture、全7経路、O0〜O3、3 OS artifact、attestationは維持されている。

macOSの5 jobは00:29:49〜00:29:50Zにすべて開始し、6件目以降のqueueは観測されなかった。job別の実測は次のとおりである。

| macOS job | 所要時間 |
|---|---:|
| `mac-core-standard-support` | 14分10秒 |
| `mac-host-compat` | 9分04秒 |
| `AOT native routes O0+O1` | 10分34秒 |
| `AOT native routes O2` | 8分23秒 |
| `AOT native routes O3` | 8分33秒 |

macOSでは分割後の通常jobとnative route jobが同時に進み、通常検証を1 runnerへ拘束しなくなった。全体の最長test jobはLinux
`AOT support`の14分55秒で、今回の全体wall-clock 15分37秒のcritical pathはmacOSのqueueではない。attestationは00:44:47〜00:45:22Zの
35秒で完了した。

Actions cacheはrun後に33件・10,604,474,798 bytes（約10.60 GB）だった。macOSのOracle／LLVM cacheは5 jobすべてでhitし、Zig build
cacheは各jobで上限1,536 MiB以内だったため、上限超過によるclearは発生していない。

| macOS job | Zig cache（展開後） |
|---|---:|
| `mac-core-standard-support` | 298,865,393 bytes（約299 MB） |
| `mac-host-compat` | 374,241,852 bytes（約374 MB） |
| `AOT native routes O0+O1`／`O2`／`O3` | 各303,866,433 bytes（約304 MB） |

cache hit/miss、固定toolchainの残存、cache上限判定は各jobログで確認し、検証範囲を削減していない。このrunで3 OSのartifact uploadと
attestationが成功したため、macOS 5 job制約を守ったjob分割の短縮効果を実測で確定する。

次のpush時も、まずこのrunのように直前の完了済みCIの結論と失敗ログを確認する。新runの完了は待たずに実装を進め、次回push前に
完了済みrunの各job、wall-clock、runner合計、cache hit/miss、artifact、attestationを確認する。

## Linux／WindowsのAOT support目的別job分割

worker数を増やしても壁時計の改善が再現しなかったため、supportの同一runner内並列をjob境界へ移した。Linux／Windowsそれぞれで、
`support-http`、`support-dispatch-evidence`、`support-dispatch-coverage`、`support-smoke`の4 jobを起動する。これによりAOT matrixは
native 27 job＋support 8 job、通常test 10 jobの計45 test jobとなる。

各support jobの検証内容は維持する。HTTP jobは先行`zig build`後に公式HTTP serverとの差分をO0〜O3で実行し、evidence jobは
先行build後にcanonical dispatch traceとtiny fixtureのsecurity不変条件を検査してevidence artifactを保存する。coverage jobは先行build後に
全fixture・全siteのdispatch coverageを検査してcoverage artifactを保存する。smoke jobはReleaseSafe compilerをbuildし、`--version`、compat report、
2件の`check`、通常`run`、`test`を実行する。dispatch evidence artifactは従来どおりattestation jobの3 OS subjectへ使い、coverage artifactも保存する。

目的別jobではsetup、固定LLVM／QuickJS、公式オラクル取得、必要なcompiler buildが重複するため、単一runのrunner合計時間は増える可能性がある。
一方、長いdispatch監査とReleaseSafe buildを同じrunnerのCPU・I/Oへ拘束せず、Linux／Windowsの壁時計改善を測定できる。macOSは
`mac-core-standard-support`、`mac-host-compat`、native route 3 jobの5件を維持し、supportを追加して6件目のqueueを発生させない。

この変更のCI性能値は未確定であり、次のpushでは先に直前の完了済みrunの結論と失敗ログを確認する。新runの完了は待たずに実装を続け、
次回push前にLinux／Windowsの4 support jobの開始待ち、各step時間、run全体のwall-clock、runner合計、cache hit/miss、3 OS artifact、attestationを確認する。

## 直近CIの待機とmacOS 5枠（run 33505339154）

[run 33505339154](https://github.com/soramikan/lnako/actions/runs/33505339154)（`ecb93ac`）は45 test job＋attestationをすべて成功させた。作成
12:00:10Zから更新12:17:09Zまでのwall-clockは1,019秒（16分59秒）、job実測のrunner合計は17,448秒（4時間50分48秒）だった。
失敗jobはなく、attestationも成功したため、検証範囲の削減やCI失敗とは扱わない。

macOSは5 jobを作成し、4 jobは12:00:14〜12:00:18Zに開始したが、5件目の`AOT native routes O2`は12:02:17Z開始だった。
このrunではmacOS runnerの同時実行枠によるものと判断される約2分03秒の待機を観測した。5件目を追加して6件へ増やす変更は行わず、macOSは常に5件以内へ制限する。

| macOS job | 開始から完了まで |
|---|---:|
| `mac-core-standard-support` | 10分18秒 |
| `mac-host-compat` | 5分29秒 |
| `AOT native routes O0+O1` | 15分29秒 |
| `AOT native routes O2` | 14分17秒（開始待機約2分03秒を別計上） |
| `AOT native routes O3` | 9分25秒 |

今回のcritical pathは`O0+O1`の15分29秒と、その後のattestation 31秒であり、Linux／Windowsのjob追加だけでmacOSの長いrouteを短縮できるとは判断しない。
macOS native routeをさらにjob分割する場合は、通常2 jobの統合などで5枠を超えない代替構成を先に実測し、全O0〜O3・全fixture・attestationを維持できる場合だけ採用する。

macOS 5 jobのZig tarball、Zig build、LLVM／QuickJS、公式oracle cacheは全jobでhitした。終了時のZig cache保存は同一run内のjob競合で一部がreserve失敗したが、検証結果には影響せず、次回runのrestore keyには前回成功cacheを使えている。従ってこのrunの遅延要因はcache missではなく、macOS O2の枠待ちと`O0+O1`の実行時間増加として記録する。

次のpush時も、まずこのrunの結論と`gh run view --log-failed`を確認する。新runの完了は待たず、次回push前にmacOSの5 job開始時刻・queue、各native route、wall-clock、runner合計、cache hit/miss、3 OS artifact、attestationを再確認する。

## U22前後の直近失敗と再発防止

[run 33648917928](https://github.com/soramikan/lnako/actions/runs/33648917928)（`a353145`）は、macOS `mac-core-standard-support`とLinux `core`の2 jobが、偽造bundleを拒否するsecurity回帰検査の途中で失敗した。`sync_compat_evidence.mjs`が参照する`static-datetime-plugin-era-constant-evidence.json`がcommitへ含まれておらず、期待する偽造bundle拒否ではなく`ENOENT`になったことが原因である。artifactを現行証拠へ追加し、`0f19894`で追跡した。

[run 33655328680](https://github.com/soramikan/lnako/actions/runs/33655328680)（`0f19894`）は、macOS `mac-core-standard-support`とLinux `core`の2 jobが、`evidence.json`更新後の`interpreter-only-classification.json`未再生成を検出して失敗した。これは製品実装やAOT／QuickJS経路の失敗ではなく、台帳から生成する派生artifactの同期漏れである。現行作業では`node tools/check_interpreter_only_classification.mjs --generate`後の`--check`を通し、U22の`compat-js-evidence.json`とともに派生artifactを同じ単位で更新する。

両runとも他の検証jobはこの原因で停止した範囲を除き成功しており、Node 20移行警告は失敗原因ではない。次回以降もpush前に最新完了runの失敗jobと`gh run view --log-failed`を確認し、進行中runの完了は待たずに実装を継続する。macOSは5 job上限を維持し、job追加で6件目のqueueを作らない。
