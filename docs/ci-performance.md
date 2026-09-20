# CI performance baseline

CI高速化・効率化の改善前ベースライン。`tools/collect_ci_metrics.mjs` で
GitHub Actions APIから収集する。

```sh
# 再計測（job logまで解析してtoolchain cache状態を含める）。
# --outputは生成markdownで上書きするため、baseline節を残す本ファイルではなく
# 別ファイルへ出力して所見を追記する運用とする。
node tools/collect_ci_metrics.mjs --runs 5 --output docs/ci-performance-latest.md

# 時刻情報のみの高速計測（log解析なし）
node tools/collect_ci_metrics.mjs --runs 5 --no-logs
```

## 改善前ベースライン（2026-09-18計測）

対象: soramikan/lnako / workflow: ci.yml
分析run数: 3（成功した完了runのみ）

### 対象run

| run id | event | branch | wall time | queue | jobs |
| --- | --- | --- | ---: | ---: | ---: |
| 35302262432 | push | main | 26m58s | 0s | 54 |
| 35302044551 | pull_request | attestation/run-35273460694 | 22m19s | 0s | 54 |
| 35294330398 | pull_request | attestation/run-35273460694 | 20m07s | 0s | 54 |

### Wall time

| metric | median | p90 | p95 | min | max |
| --- | ---: | ---: | ---: | ---: | ---: |
| workflow wall time | 22m19s | 26m02s | 26m30s | 20m07s | 26m58s |
| job queue time | 0s | 0s | 0s | 0s | 0s |

### OS別 runner time（分析run合計）

| OS | runner-minutes |
| --- | ---: |
| Windows | 388.2 |
| Linux | 445.7 |
| macOS | 169.5 |
| other | 2.8 |
| **total** | **1006.2** |

### 最長job（median上位10）

| job | median | p95 |
| --- | ---: | ---: |
| Windows x86_64 / core | 18m22s | 19m37s |
| macOS arm64 / mac-core-standard-support | 17m56s | 18m04s |
| Windows x86_64 / compat-aot | 15m00s | 15m30s |
| Linux x86_64 / core | 11m21s | 13m41s |
| Linux x86_64 / host | 11m07s | 11m19s |
| macOS arm64 / mac-host-compat | 10m39s | 10m40s |
| macOS arm64 / AOT native routes O0+O1 | 10m32s | 13m53s |
| macOS arm64 / AOT native routes O3 | 8m20s | 9m22s |
| macOS arm64 / AOT native routes O2 | 8m18s | 9m06s |
| Linux x86_64 / AOT support dispatch coverage shard 3/3 | 7m27s | 7m36s |

### 主要step（median上位15）

| step | count | median | p95 |
| --- | ---: | ---: | ---: |
| Build AOT verification compiler | 117 | 2m28s | 3m16s |
| Set up pinned LLVM and LLD | 147 | 1m54s | 4m24s |
| Verify artifact attestations and catalog promotion | 1 | 1m07s | 1m07s |
| Differential native AOT verification (fixture/route shard) | 117 | 58s | 2m47s |
| Grammar-generating parser fuzz test | 6 | 15s | 23s |
| Run mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 | 153 | 9s | 14s |
| Verify tracked attestation history | 1 | 9s | 9s |
| Run actions/setup-node@a0853c24544627f65ddf259abe73b1d18a591444 | 159 | 6s | 13s |
| Set up job | 160 | 4s | 7s |
| Verify native AOT artifact attestation | 1 | 3s | 3s |
| Run actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 | 190 | 2s | 10s |
| Run actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 | 300 | 2s | 4s |
| Post Run mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29 | 153 | 2s | 5s |
| Prune LLVM toolchain cache | 147 | 2s | 3s |
| Download native AOT artifacts | 3 | 2s | 2s |

### LLVM toolchain cache

計測job数: 147

| metric | value |
| --- | ---: |
| cache hit | 147 |
| cache miss | 0 |
| LLVM reinstall | 147 |
| LLVM reuse | 0 |

reason内訳: unknown=147（改善前のlogにはreason分類出力が無い）

### ベースライン所見

- toolchain cacheは147/147 jobでhitするが、`setup_llvm.mjs`の`isCurrent()`
  がmarker欠落を検出し全jobでLLVM再install（macOSはlibLLVM-C.dylib再
  linkまで）が発生していた。`Set up pinned LLVM and LLD`のmedian
  1m54s×49 job/runがほぼ全て無駄な再setupである。
- `Build AOT verification compiler`が1 runあたり39回実行され、同一
  commitのDebug compilerを各shardが重複buildしている。
- 最長jobは`Windows x86_64 / core`（median 18m22s）と
  `macOS arm64 / mac-core-standard-support`（17m56s）で、これらが
  workflow wall timeのクリティカルパスを構成する。

## Stage 2: 変更分類による軽量CI

`changes`ジョブが変更パスをallow-listで分類し、docs・attestation
snapshotのみの変更では重いmatrix（test/parser_fuzz/AOT/attest）を起動しない。

- light対象（allow-list）: `docs/**`、リポジトリ直下の`*.md`、
  `compat/*/attestations/**`。これ以外はすべてfull。
- 判定不能（diff失敗・base欠落・空diff・`pull_request`/`push`以外の
  event）は常にfullへ倒す。renameは`--no-renames`でdelete+addへ分解し、
  heavy→light移動を取りこぼさない。
- 分類器はbase側（`pull_request.base.sha`またはpushの`before`）の
  信頼済み版を`git show`で取り出して実行する。PR側checkoutの改変済み
  実装を信用しないため、分類器自身を改変して軽量CIを騙す経路はない。
- skippedなrequired checkはbranch protection上success扱いになるため、
  light相当のPRでもmerge gateは満たされる。
- light相当でも`lightweight`ジョブがworkflow schema・追跡attestation・
  docs表・canonical evidenceの整合性を必ず検査する（build不要な
  checkerのみ、所要2〜3分）。`check_package_isolation.mjs`のように
  zigをspawnして実buildするcheckerは除外し、含めないことを
  `check_ci_workflow.mjs`の禁止リストで強制する。

### releaseとの関係

docs専用commitがmainへpushされるとattestation jobもskipされ、そのcommit
にはGitHub Attestationが存在しない。release gateは`Attest and verify
dispatch evidence`がsuccessのrunを要求するため、そのcommitへのtag付けは
失敗する。docs専用commitをrelease対象にする場合は、先にCI workflowを
mainで`workflow_dispatch`実行する（dispatchは常にfull相当で走り
attestationが発行される）か、full run済みのcommitをtag付けする。

### light経路の実機検証

本節の追記自体がdocs専用変更であり、`improve-ci-stage2`向けPRで
`changes`→`lightweight`のみが走り重いmatrixがskipされることを
確認するための検証用commitでもある。期待する観測:

- `Classify changes`が`level=light`を出力する
- test/parser_fuzz/AOT/verify/attestの各ジョブがskipされる
- `Lightweight verification`がbuildなしのchecker群を実行してpassする

初回検証では`check_package_isolation.mjs`がzigをspawnして失敗したため、
軽量jobから除外し`check_ci_workflow.mjs`の禁止リストへ追加した。

## Stage 3: macOSクリティカルパスの再配分

`Differential Node host test`（約5分）はこれまでmacOS最長jobの
`mac-core-standard-support`で実行していたが、`mac-host-compat`の末尾へ移動した。

- `mac-core-standard-support`から当該stepを除去し、クリティカルパスを短縮
- `mac-host-compat`ではcanonical freshnessとDebug buildの完了後に配置し、
  証拠生成順（normal RS→dispatch→QuickJS RS→compat-js→freshness）を維持
- 配置順は`check_ci_workflow.mjs`の`macHostCompatOrder`で強制する
- Linux／Windowsの`host`は従来通り同job内で実行（位置変更の影響なし）

## Stage 4: Windows native AOT compilerの共有

`aot` matrixのWindows native shard（3 fixture shard × O0〜O3 = 12ジョブ）は
それぞれが同じcommitのDebug compilerを`zig build`していた。`aot_compiler`
jobで1回だけbuildし、metadata＋SHA-256付きartifact
（`lnako-aot-compiler-windows-x64`）として共有することで、
12回分の重複buildを1回へ集約する。

### 設計

- `aot_compiler`はfull経路でのみ実行（`changes`のlevelゲートと同じ条件）
- Windows native 12 shardは専用consumer job `aot_windows`へ分離し、
  そのjobのみ`needs: [changes, aot_compiler]`でproducerを待つ。
  `needs`はjob全体に効くため、`aot`へ依存させるとLinux・macOS・supportの
  27 shardまで直列化されproducer失敗で全てskipされる。`aot`は
  `needs: [changes]`のまま並行起動する
- `aot_windows`の各shardは`zig build`をskipしてartifactをdownload・
  検証・installする
- `tools/aot_compiler_artifact.mjs verify`が
  commit／platform／arch／Zig version／build mode／compat-JS構成／SHA-256を
  照合してから`zig-out/bin`へinstallする。誤commitや改変されたbinaryは
  install前にrejectされる
- compilerは`<exe>/../lib/`のAOTランタイム静的ライブラリ
  （`lnako_runtime.lib`）を必要とするため、binaryとruntime libを
  1組の成果物としてhash照合・installする（binの兄弟`lib/`へ展開）
- Linux／macOS nativeとWindows support jobは従来通り各ジョブがbuildする
  （Linux coverage shardのReleaseSafe buildも変更なし）

### 保証

- `retention-days: 1`の一時artifactで、永続成果物やreleaseへ混入しない
- shard側は`--no-build`の`compare_native_oracle.mjs`を従来通り実行し、
  AOT差分テストと集約artifact uploadは維持される

## Phase 1〜4実施後の計測（2026-09-18、run 35322133137）

実測列は上記baseline集計（複数runのmedian）に対する**単一run**の値であり、
run間ばらつきを含まない点に注意する。

| 指標 | baseline（median） | run 35322133137（単一run） |
| --- | ---: | ---: |
| workflow wall time | 22m19s | 17m23s |
| 最長job | Windows core 18m22s | Windows core 16m44s |
| mac-core-standard-support | 17m56s | 9m46s（Node host差分を移出） |
| mac-host-compat | 10m39s | 12m13s（Node host差分を末尾で吸収） |
| LLVM再インストール率 | 100%（147/147 jobがcache hitでも再install） | 0%（hit時は0.2sで検証のみ） |
| Windows native AOT shardのcompiler build | 12回（各shard個別） | 1回（producer 60s、12 shardが検証済みartifactをinstall） |

### Windows native AOT shardのstep内訳（shard 1/3 / O0）

setup系（checkout・zig・node・LLVM・QuickJS・oracle・artifact検証install）計約37s、
差分テスト91s。producer側はcache hit時60sでcompilerをbuildしuploadする。

### Phase 5・6の計測判断

計画の判断基準に基づき実測で評価した：

- **Phase 5（native AOT粒度12→6）**: AOT shardは80〜160sで、最長job
  （Windows core 16m44s）の約1/10。2 optimization/groupへまとめても
  runner-minutesは約5〜8分/run削減できる一方、job単位のwallは悪化し
  flake時の再試行範囲も倍になる。AOT経路はクリティカルパス外のため
  全体wallへの効果なし → **現行12 shard構成を維持**
- **Phase 6（LNAKO_NATIVE_ORACLE_JOBS 1→2）**: shard時間は短縮するが
  同様にクリティカルパス外のため全体wallへ効果なし。並列化の
  fixture出力・一時ファイル安全性の確認コストに見合わない → **見送り**

### Phase 7のボトルネック記録（Windows core、1004s）

setup系は40s未満へ収束済みで、残存コストはテストハーネス本体：

- `Zig package isolation check` 340s（consumer packageを`zig fetch`＋`zig build`）
- `Test`（`zig build test`）334s
- `Differential interpreter test` 212s

これらはワークフロー重複ではなく実行コスト本体のため、Phase 7（P3）の
対象として記録する。package isolationがzig global cacheを共有できるか、
差分テストのworker並列化は別途計測が必要。

---

# 改善計画2 Phase 1: cache identity分離と計測基盤

## 実測した欠陥（改善前）

run 35448509540（main push）の Linux x86_64 AOT native shard 1/3 O0 では、
Zig cacheが同一suite名だけをidentityにしていたため次の連鎖が起きていた。

| 観測 | 値 |
| --- | --- |
| 復元key | `setup-zig-cache-v2-aot-zig-x86_64-linux-0.16.0-aot-native-35448509540-1` |
| 復元したcacheの生成元 | 同一run（`35448509540-1`）の別shard |
| 復元サイズ | `Cache Size: ~0 MB (186 B)`（実質空） |
| 保存結果 | `Failed to save: Unable to reserve cache with key ..., another job may be creating this cache.` |
| 保存時cache dir | 253,011,854 bytes（上限1,610,612,736 bytes未満） |

`mlugg/setup-zig` は保存keyへ `runId-attempt` を付け、復元はkeyのprefix一致で
行う。cache-keyが `aot-native` の1種類しかないと、12個のLinux native shardが
同じprefixを共有し、**先行shardが保存した未完成cacheを後続shardが復元**する。
後続shardの保存はreservation競合で失敗し、cache lineageが育たない。

Windows AOT consumer shard（compiler共有後は `zig build` しない）は
`Cache miss: leaving Zig cache directory ... unpopulated` の後
`Zig cache directory is inaccessible; nothing to save` となり、
同一prefixの復元だけが残る。

## 実装（Phase 1）

### AOT Zig cache keyの分離

AOT native shardのcache-keyを `suite` から
`aot-native-v2-s{shardIndex}of{shardCount}-{optimizationKey}` へ変更した
（`aot` と `aot_windows` の両方）。OS・arch・Zig versionはsetup-zig側のkeyに
含まれるため重複させない。世代marker `-v2-` により、分離前のpoisonedな
cacheは復元されない。

### cache telemetry

`tools/collect_ci_metrics.mjs` がjob logから次を解析し、performance reportの
`## Cache` 節へ出す。

- 復元key（`restoredKey`）と、それが**同一run由来か**（`zigSameRunRestores`）
- Zig cache hit / miss
- Zig cache directory size（median / max）と上限（MiB）
- size limit超過によるcache clear（`zigCleared`）
- 保存成功 / 失敗 / 不明（`zigSaved` / `zigSaveFailures` / `zigSaveUnknown`）
- actions/cache（toolchain・oracle）のrestore / miss / 保存失敗
- Zig cache hit（warm）とmiss（cold）で層別したjob実行時間

`zigSameRunRestores` はPhase 1の分離が効いていれば0になる。

### fixture timing telemetry

`tools/compare_native_oracle.mjs` がfixture別に
`officialSourceMs` / `officialGeneratedMs` / `interpreterMs` /
`native[{optimization,buildMs,runMs}]` / `totalMs` を計測し、
`LNAKO_NATIVE_ORACLE_TIMING`（または `--timing`）の文書へ出力する。

- schema: `lnako.native-oracle-timing.v1`
- canonical artifact（`lnako.native-oracle-artifact.v3`）とは別document・別artifact
- artifact名は `lnako-native-timing-*` とし、集約検証が使う
  `lnako-native-oracle-*` globへ混入させない
- 性能値は変動するためattestation対象へ含めない

fixture × platform × optimization の代表値は `buildTimingAggregate()` が
medianで求める（Phase 3のshard weight tableの入力）。

### Windows AOT shardのZig cache保存を止める

同じrunの実測で、`aot_windows` のnative shardは `zig build` を一切実行せず
（`Build AOT verification compiler` ステップが存在しない）、producer jobの
共有compiler artifactをinstallしてfixtureのAOT buildだけを行っていた。
それでも `use-cache: true` だったため、shard別に約64 MBのZig cacheを
毎run保存していた。

| 項目 | 値 |
| --- | --- |
| shard別cacheサイズ | 62,090,000〜64,640,000 bytes |
| 12 shard合計（毎run） | 約770 MB |
| 保存したcacheの再利用 | なし（shardはcompilerをbuildしない） |
| 既存cache総量 | 11,770,382,922 bytes（上限10 GiBを超過） |

`aot_windows` のsetup-zigを `use-cache: false` に変更した。Zig compiler自体は
setup-zigがtool cacheから供給するため、cache無効でもセットアップは成功する
（実測9秒）。Linux側の `aot` は `zig build` で検証compilerを作るため保存を
継続する。

### 現在の静的weight分布（参考）

`--shard-count 3` の静的weight（source長＋command数×8）は
max/median = 1.000 と見積り上は均等である。したがってPhase 3の課題は
「見積りの偏り」ではなく「見積りと実測の乖離」であり、実測weightでの
再配分が必要になる。

## 計測手順

```sh
# cache / timing telemetryを含むCI性能レポート
node tools/collect_ci_metrics.mjs --runs 5 --output docs/ci-performance-latest.md

# fixture timing artifactの集約（downloadしたディレクトリを渡す）
node tools/aggregate_native_timing.mjs --directory .cache/native-timing
```

## 実測: cache identity分離の効果（改善後 run 35452640573）

改善前後で同じ12個のLinux AOT native shardを比較した。

| 観測 | 改善前（35448509540） | 改善後（35452640573） |
| --- | --- | --- |
| 復元prefix | `...-aot-native-`（12 shardで共有） | `...-aot-native-v2-s{0..2}of3-O{0..3}-`（12通り） |
| 復元したcache | 同一runの別shardが保存した186 bytes | すべてmiss（新prefixのため初回） |
| 保存結果 | `Failed to save: ... another job may be creating this cache.` | 12 shardすべて `Saving Zig cache with key ...` |
| 保存時のcache dir | 253,011,854 bytes | 253,011,854〜253,024,582 bytes |
| reservation競合 | あり | 0件 |

分離の直接効果は「保存が成功するようになった」ことである。同一prefixを共有する
並行shardが互いの未完成cacheを復元し合う経路が閉じたため、次run以降は各shardが
自分のcacheを復元できる。`zigSameRunRestores`（performance report）は分離後0になる。

なお初回runは全shardがmissのため、効果は2回目以降のrunで現れる。

## 実測: fixture timingとshard再配分の評価（Phase 3の判定）

run 35452640573のtiming artifact（Linux 12 shard、342 fixture × 4 optimization）を
`aggregate_native_timing.mjs` で集約した。

| 指標 | 値 |
| --- | --- |
| fixture数 | 342 |
| 計測document | 12（shard 3 × optimization 4） |
| Pearson r（静的weight, 実測median totalMs） | **0.956** |
| 現行静的配分の実測コスト | 56.5s / 58.2s / 60.9s（max/median = 1.047） |
| 実測medianで再配分した場合 | 58.5s / 58.7s / 58.3s（max/median = 1.003） |
| AOT fixture jobの実測コスト | 55〜65s（job全体の約1/4） |

現行の静的weight（source長＋command数×8）は実測コストと r=0.956 で相関し、
現行配分の偏りは4.7%である。実測medianで再配分すると1.003まで均等化できるが、
AOT fixture jobはクリティカルパス上に無く（最長jobはWindows core）、job全体の
1/4程度でしかない。**短縮は最大でも約2〜4s/job**であり、実測weightを
リポジトリへ固定して保守するコストに見合わない。

→ **Phase 3のLPT重み固定は見送り**。計測基盤（timing telemetry + aggregate）は
残し、将来fixture追加で偏りが拡大した場合に再評価する。

## クリティカルパスの再測定（改善後）

run 35452640573のjob実行時間（上位）とworkflow wall time 848s。

| job | 実行時間 |
| --- | ---: |
| Windows x86_64 / core | 809s |
| macOS arm64 / mac-host-compat | 755s |
| Windows x86_64 / compat-aot | 739s |
| macOS arm64 / mac-core-standard-support | 548s |
| Linux x86_64 / core | 509s |

クリティカルパスは **Windows x86_64 / core（809s）** で、これは
`use-cache` 対象外（`host` のみ対象）のため **Zigグローバルcacheを一切使っていない**。
Windowsでの主要コストは `Test`（`zig build test`）と `Zig package isolation check`
（consumer packageの `zig fetch`＋`zig build`）である。cache導入の可否は
「`zig build test` の再ビルドがZigグローバルcacheで短縮できるか」で決まるため、
次段で実測する。

## 実測: Zigグローバルcacheの効果測定（Windows core検討の前提）

クリティカルパス（Windows x86_64 / core、1074s）は `use-cache` 対象外であり、
Zigグローバルcacheを使っていない。そこでcache導入の効果をローカルで実測した。

| 条件 | `zig build test` | 差分 |
| --- | ---: | ---: |
| cold（global＋local cacheを新規作成） | 233.3s | - |
| warm（同一cache dirを再利用） | 209.4s | **-23.9s（-10.2%）** |

`zig build test` のコストはコンパイル主体（テスト実行は7s）だが、Zigは
ファイル単位の内容hashでcacheするため、coldでも大半の成果物は再生成される。
グローバルcacheの復元で削減できるのは `deps`／compiler-rt等の共通部分
（実測 45 MB / 217 MB）に限られ、**約24s（job全体の約2%）**にとどまる。

cacheを有効にした場合のコスト：

- cache size: `zig build test` 後に約217 MB。`host` は既に373 MBのcacheを持つため、
  仮に `core` を追加すると**約590 MB/run**の追加保存となる。
- リポジトリのcache総量は既に10 GiB上限を超過しており、Phase 1の分離で
  shard別cacheは6run程度でevictされる（`host` は毎runhitしているが、
  それは `host` が1 jobしかないため）。

→ **Windows coreへのZig cache追加は見送り**。24s/jobの短縮に対し、
  約590 MB/runのcache保存とeviction圧力の増加が見合わない。

## クリティカルパスの構造

改善後の2 run（848s / 1112s）でクリティカルパスは一貫して
**Windows x86_64 / core**（809s / 1074s）である。内訳は
`Test` 378s、`Zig package isolation check` 342s、`Differential interpreter test` 212s。

この3ステップは、いずれも**Windowsでの実ビルド／実実行コスト**であり、
ワークフロー側の重複実行ではない。

- `Test`: `zig build test`。cache導入効果は上記のとおり約24s。
- `Zig package isolation check`: consumer packageの `zig fetch` ＋ `zig build`。
  専用の一時cacheで検証するため、グローバルcacheとは独立。
- `Differential interpreter test`: 公式cnako3との差分実行。

したがって、この job の短縮にはワークフロー変更ではなく
**ビルド時間そのものの削減**（コンパイル単位の見直し等）が必要であり、
改善計画2のCI効率化の範囲外として記録する。

## 実測: Windows AOT support jobsのcompiler build重複（Phase 4）

run 35453416527のWindows AOT support系jobは、いずれもjob内で
`zig build`（Debug compiler）を実行していた。

| job | job全体 | うちBuild AOT verification compiler |
| --- | ---: | ---: |
| Windows x86_64 / AOT support HTTP | 269s | 189s |
| Windows x86_64 / AOT support dispatch evidence | 240s | 191s |
| Windows x86_64 / AOT support dispatch coverage shard 1/3 | 252s | 191s |
| Windows x86_64 / AOT support dispatch coverage shard 2/3 | 311s | 190s |
| Windows x86_64 / AOT support dispatch coverage shard 3/3 | 325s | 231s |

5 job × 約190s ＝ **約15分/run** が同一compilerの再buildであった。

### 実装

WindowsのAOT support系5 jobを、producer jobの共有compiler artifactを
installする consumer job（`aot_windows`）へ移設した。artifactは
commit・OS・arch・Zig version・build mode・compat-js・SHA-256を照合して
からinstallされるため、誤commit・別構成のcompilerは使われない。

計画の注意に従い、**共有しないもの**は移設していない。

- `AOT support smoke` はReleaseSafe compilerを検証するため、`aot` job側に
  残して従来どおり自前buildする（Debug compilerをReleaseSafe検証へ
  流用するとテスト意味が変わる）。
- Linux・macOSのsupport shardは`aot` job側のまま並行起動し、producer失敗時も
  各shardの結果を返せる。
- dispatch coverageの集約jobは、Windows artifactの供給元が`aot_windows`へ
  移ったため`needs`と条件へ`aot_windows`を追加した。

検証量は変えていない（同じ検証を同じOSで実行し、compiler buildだけを共有する）。

## 実測: Windows AOT jobのcompilerがrunner非依存でない（重大）

### 症状

run 35456603123 / 35458680454 で、WindowsのAOT native shard 11件とsupport系が
失敗した（15 / 13 job）。全fixtureで公式経路は成功しているのに
`lnakoRun`（インタープリタ）と`lnakoNativeO0` の両方が落ちていた。

| route | exit code | 意味 |
| --- | ---: | --- |
| `lnakoRun` | 3221225477 = 0xC0000005 | STATUS_ACCESS_VIOLATION |
| `lnakoNativeO0` | 3221225501 = 0xC000001D | STATUS_ILLEGAL_INSTRUCTION |

AOT成果物側の `0xC000001D`（Illegal instruction）は、**そのrunnerのCPUが
実行できない命令が生成物に含まれている**ことを示す。

### 原因

`build.zig` は `b.standardTargetOptions(.{})` を既定引数で呼んでいる。
Zigは `-Dtarget` も `-Dcpu` も指定されない場合、`args.default_target`
（`std.Build.standardTargetOptions` の既定は `.{}`）を返し、`resolveTargetQuery` は
`query.isNative()` でホスト自身（`b.graph.host`）へ解決する。つまり
**`zig build` はrunnerのCPU機能をそのまま有効にしてコンパイルする**。

GitHubの `windows-2025` runnerは同一ラベルでも世代の異なるCPUが混在する。
producer jobが新しいCPU（例: AVX-512対応）でbuildし、consumer jobが
古いCPUで実行すると、producerのsmoke test（producer自身のrunner）は通り、
artifactのSHA-256照合も一致するが、consumerでは実行できない。

### 実測（artifactサイズの分布）

| run | event | compiler artifact | 結果 |
| --- | --- | ---: | --- |
| 35455870091 | pull_request | 9,871,000 B | Windows全job成功 |
| 35457590285 | workflow_dispatch | 9,870,993 B | Windows全job成功 |
| 35458680454 | pull_request | **9,882,319 B** | 13 job失敗 |
| 35456603123 | pull_request | **9,823,566 B** | 15 job失敗 |

成功runのサイズは3〜8 Bの差に収まる（同一CPU機能）のに対し、失敗runは
+11 KB / -47 KBと別物である。同一commit 6a2891ef でも、pull_request実行では
失敗し workflow_dispatch実行では成功した（runner割り当ての差）。

### 確定した証拠（逆アセンブル）

失敗runと成功runのartifact `lnako.exe`（いずれもCOFF x86-64）を
`llvm-objdump -d --triple=x86_64-pc-windows-msvc` で逆アセンブルし、
AVX-512（EVEX）命令の出現数を数えた。

| 命令 | 成功run 35457590285 | 失敗run 35458680454 |
| --- | ---: | ---: |
| `vmovdqu64` | 0 | **8,212** |
| `vmovdqa64` | 0 | **882** |
| `vpternlogq` | 0 | **30** |
| `vpternlogd` | 0 | **18** |
| `vpxord` | 0 | **21** |
| `vpandq` | 0 | **12** |
| `vpandd` | 0 | **7** |
| `vpbroadcastq` | 2 | 29 |

失敗artifactはAVX-512（AVX512BW等）命令を含み、成功artifactは含まない。
AVX-512非対応のrunnerで実行すると `STATUS_ILLEGAL_INSTRUCTION`
(0xC000001D) / `STATUS_ACCESS_VIOLATION` (0xC0000005) になる。これが
`lnakoRun`と`lnakoNativeO0`の両方が落ちた理由である。

### 対応

`aot_compiler`（とPhase 6で追加した`aot_compiler_linux`）の `zig build` に
`-Dcpu=baseline` を明示した。固定ISAを指定することでrunner CPU依存命令の混入を防ぐ
（`baseline`はx86_64の最小ISA。本ブランチでは当初`-Dcpu=x86_64_v2`で検証し、
mainへ同等の修正（`-Dcpu=baseline`）が入ったため、マージ後に両producerで
`baseline`へ統一した）。ローカルで固定ISAを指定してbuildした成果物を逆アセンブルし、
AVX-512命令が0件になることを確認した（`vmovdqu64`/`vmovdqa64`/
`vpternlogq`/`vpxord`/`vpandq` すべて0）。

`check_ci_workflow.mjs` で両producerが `-Dcpu=baseline` 付きでbuildし、
素の `zig build` へ戻っていないことを検査する。

### 撤回した誤った原因推定

先行して入れた「producerのZig cache無効化」は**原因ではなかった**
（cache無効の35458680454でも同じ失敗が再現した）。cache無効化自体は
被害を広げないための保守的判断として残すが、原因ではない。

## （撤回）実測: producerのZig cacheが壊れたcompilerを混入させる

**この節の結論は誤りだったため撤回する。** 当時は「producerのZig cache
hit」と「失敗」が同時に観測されたためcacheを原因と推定したが、cacheを
無効化したrun 35458680454でも同じ失敗が再現した。実際の原因は
上記のとおりrunner間のCPU機能差である（cacheは無関係）。

以下は当時の記録として残す（結論は上記で否定済み）。

### A/B（同一commit 75b7c651）

| run | producerのZig cache | compiler build | compiler artifact | 結果 |
| --- | --- | ---: | ---: | --- |
| 35456603123 | **hit**（`...aot-compiler-35455870091-1`） | 221s | 9,823,566 bytes | Windows shard 11件＋support系が`Illegal instruction`で失敗（15 job） |
| 35457590285 | **miss**（`leaving ... unpopulated`） | 191s | 正しいbinary | Windows全job成功（0 failure） |

失敗runでは、公式経路は成功しているのに `lnakoRun`（**インタープリタ**）と
`lnakoNativeO0` の両方が `exitCode: 3 / stderrClass: runtime-error` になった。
compiler本体（interpreterを含む）が壊れていたことを示す。producer自身の
smoke testは `zig-out/bin/lnako.exe`（producerがbuildしたbinary）に対して
実行されるため通り、artifactのSHA-256も一致していた。つまり
**壊れた成果物が正しいものとして27 jobへ配布された**。

cacheを無効化した再実行（35457590285）では同じcommitでWindows全jobが成功した。

### 対応

`aot_compiler` のsetup-zigを `use-cache: false` に変更した。このjobの成果物は
27 jobのAOT検証が使うため、Zig cache経由で壊れた成果物が混入する余地を
残さない。compiler buildは約190sで、失敗時の再実行コスト（15 job × 数分＋
reviewerの調査）に比べて無効化のコストは小さい。

`check_ci_workflow.mjs` でproducerがcache-keyを持たず `use-cache: false` で
あることを検査する。

**未解明**: Zigグローバルcacheのどの部分が壊れたcompilerを生むのかは特定して
いない。cacheの内容と生成物の対応は再現手順が重く、まず「壊れた成果物を
配布しない」ことを優先した。同種のリスクは他jobにもあるが、成果物を
artifactとして配布するのはこのjobだけである。

### 修正の検証（run 35460438958）

固定ISA指定（`-Dcpu`）を入れた後のrunで確認した。

| 確認項目 | 結果 |
| --- | --- |
| Windows AOT native shard 12件 | すべて success |
| Windows AOT support 6件（HTTP・dispatch evidence・coverage 3・smoke） | すべて success |
| Windows AOT compiler producer | success |
| workflow全体 | success（failure 0件、wall 876s、runner minutes 188） |
| 成果物のAVX-512命令 | `vmovdqu64`/`vmovdqa64`/`vpternlogq`/`vpxord`/`vpandq`/`vpbroadcastq` すべて **0件** |

修正前のrun（35456603123 / 35458680454 / 35459423674）では、いずれも
Windows AOT系が8〜15件失敗し、artifactにAVX-512命令が含まれていた。
修正後は同一のfixture・shard構成で全件成功しており、原因の同定と修正が
一致している。

### 計測値の比較（同一構成のrun）

| run | 状態 | wall | runner minutes |
| --- | --- | ---: | ---: |
| 35453416527 | 修正前（Phase 1のみ） | 1112s | 213 |
| 35460438958 | 本修正後（Phase 1＋4＋CPU固定） | 876s | 188 |

wallは1112s→876s（-21%）、runner minutesは213→188（-12%）。
wall短縮の主因はPhase 4（Windows AOT support系5 jobのcompiler build共有）で、
runner minutes削減の内訳はPhase 4の約15分とWindows AOT shardのcache保存停止である。

---

# 改善計画2 Phase 2: Native AOT worker数の実測比較

## 条件

同一commit 8e88164c・同一fixture・同一optimizationで、`LNAKO_NATIVE_ORACLE_JOBS`
だけを変えた2 runを比較した。

- worker=1: run 35460438958（`default: "1"`相当）
- worker=2: run 35462752842（dispatch入力 `native_oracle_jobs=2`）

## 結果（24 shardすべてで短縮）

| 指標 | worker=1 | worker=2 | 差 |
| --- | ---: | ---: | ---: |
| Differential AOT検証ステップ合計（24 shard） | 1,896s | 1,163s | **-733s（-38.7%）** |
| 同ステップ median（Linux） | 58.5s | 34.0s | -42% |
| 同ステップ median（Windows） | 102.0s | 62.5s | -39% |
| job全体 median（Linux、queue外れ値除く） | 88.5s | 69.5s | -21% |
| job全体 median（Windows） | 151.5s | 110.5s | -27% |
| AOT job合計（median基準） | 48.0min | 36.0min | **-12.0 min/run** |
| failure | 0 | 0 | 悪化なし |
| timeout | 0 | 0 | 悪化なし |

macOS（AOT native routes）も同じ傾向だった。

| route | worker=1 | worker=2 | 差 |
| --- | ---: | ---: | ---: |
| O0+O1 | 225s | 133s | -41% |
| O2 | 167s | 130s | -22% |
| O3 | 179s | 133s | -26% |

計画が求めるWindows・Linux・macOSの3正式OSすべてで短縮を確認した。

worker=2で遅くなったshardは24件中0件だった。計画が警告する
「並列度を増やすとZig compilationが競合して逆に遅くなる」現象は、
並列度2では観測されなかった。

## 採用基準の判定

| 計画の基準 | 判定 | 根拠 |
| --- | --- | --- |
| wall clock time が明確に短縮 | **満たさない** | AOT jobはクリティカルパス外（最長はWindows core）。wallはrun間のqueue変動に埋もれる |
| failure rate が悪化しない | 満たす | 両runともfailure 0 |
| runner time が極端に増加しない | 満たす | median基準で -12 min/run |
| reproducibility に影響しない | 満たす | fixtureごとに専用一時ディレクトリを使用。集約検証（verify_native_aot_artifacts）も成功 |

wall clockの基準は、Phase 3・4・5と同様に「AOT経路がクリティカルパス外」という
構造的理由で満たせない。一方でjob時間・runner時間・failure率はすべて改善するため、
計画のPhase 2判断（「問題がなければworker=2を標準化する」）に従い
**worker=2を標準化**した。`workflow_dispatch` 入力で `1` を選べばA/B比較できる。

# 改善計画2 Phase 5: optimization matrix grouping の実測比較

## 実測に基づく推定

run 35460438958のfixture別timing（Linux・Windows 12 shard分）とjob実測overhead
（Linux 27s、Windows 47s/job）から、3案のrunner時間を計算した。oracle
（officialSource＋officialGenerated＋interpreter）はjob内でfixtureごとに1回だけ
実行されるため、同じshardのoptimizationを統合するとoracle実行回数が減る。

| 案 | 構成 | Linux | Windows | 合計 | 現行比 |
| --- | --- | ---: | ---: | ---: | ---: |
| Case A（現行） | O0 / O1 / O2 / O3 独立（12 job/OS） | 1,017s | 1,754s | 2,771s | - |
| Case B | O0+O1 / O2 / O3（9 job/OS） | 810s | 1,427s | 2,237s | -534s（-8.9 min） |
| Case C | O0+O1 / O2+O3（6 job/OS） | 604s | 1,101s | 1,705s | **-1,066s（-17.8 min）** |

oracle＋interpreterはshardあたり Linux 125s / Windows 186s（4 optimization合計）で、
統合によりこの一部がjob数分だけ削減される。

## 判定

Case Cはrunner minutesを約17.8分/run（全体の約9%程度）削減できる一方、

- job wallは増える（Windowsの2 optimization統合jobで約+38s。ただし
  クリティカルパス1074sに対して十分小さい）
- flake時の再試行範囲が2倍になる
- matrix定義の変更とcheck_ci_workflowの追従が必要

wall clockへの効果はない（AOTはクリティカルパス外）。Phase 4で同じ性質の
「重複build削減」を既に実施しており、Phase 5はその残り（oracle再実行とfixed
overhead）を削る施策である。worker=2の標準化でAOT経路の効果を確定させた後、
**Case Cを実施**した（実測-17.8 min/runはrunner minutes目標に対して有意）。

### 実装

Linux・WindowsのAOT native jobを O0+O1／O2+O3 の2 groupへ統合した
（24 job → 12 job、matrix全体では57→45 job）。`optimizationKey` は `O0-O1`、
`optimizations` は `O0,O1`、job名は `AOT native shard 1/3 / O0+O1` とし、
macOSが既に使っている統合group方式（`O0-O1`）と揃えた。検証量は不変で、
O0〜O3の全optimizationと公式oracle比較・interpreter比較を維持する。

`check_ci_workflow.mjs` と `check_native_aot_artifacts.mjs` の期待groupも
O0-O1／O2-O3へ更新し、artifact partition検証（fixtureが各optimizationで
ちょうど1回被覆されること）は統合後も機能する。

#### 併せて修正した不整合: attestation verifierのgroup定義

同group定義は集約検査（`check_native_aot_artifacts.mjs`）だけでなく、
attestation検証（`verify_native_aot_attestation.mjs`）にもある。Phase 5では
集約側だけを更新し、**verifier側が旧`O0`／`O1`／`O2`／`O3`の4 group定義のまま
残っていた**。そのため`validateAggregate`がLinux/Windowsのartifact数（6 対 期待12）
で必ず失敗し、main push時の`attest-dispatch-evidence`が完走せず、release pinに
必要な署名済み証拠も生成できない状態だった（PR #104のレビューで検出）。

verifier側を`O0-O1`／`O2-O3`へ修正し、artifact総数15と各platformがO0〜O3を
ちょうど1回被覆することをモジュール内で検査するようにした。さらに
`check_ci_workflow.mjs`が**CI matrix・集約検査・attestation検証の3箇所のgroup
定義を機械的に照合**するようにし、片側だけ更新して食い違う事故を構造的に防ぐ。

### 運用上の注意（重要）

job名が変わるため、**mainのブランチ保護にある required status checks のうち
AOT native shard 24件を削除し、新しい12件を追加する必要がある**。保護設定を
更新しないままマージすると、以後のPRがrequired check未充足でブロックされる。

削除対象（例）: `Linux x86_64 / AOT native shard 1/3 / O0` 〜 `... / O3`
（Linux・Windows × 3 shard × O0〜O3 = 24件）

追加対象: `Linux x86_64 / AOT native shard {1..3}/3 / O0+O1`、
`... / O2+O3`、およびWindowsの同12件（計12件）

手順は本PRの説明に記載した `gh api` コマンドで行う。

## 実測: Phase 5適用後（run 35465334491）

| 指標 | 適用前 35460438958 | 適用後 35465334491 | 差 |
| --- | ---: | ---: | ---: |
| job数 | 57 | 45 | -12 |
| 全job runner minutes | 188 min | **166 min** | **-22 min（-11.7%）** |
| AOT native job数 | 24 | 12 | -12 |
| AOT native runner時間 | 3,007s（50 min） | 2,182s（36 min） | -825s（-13.8 min） |
| 最長job（Windows core） | 1,074s | 1,075s | ±0（クリティカルパス不変） |
| failure | 0 | 0 | 悪化なし |
| `Verify native AOT artifacts` | success | success | 統合groupでもpartition検証が成立 |

推定（-17.8 min）に対し実測はAOT分で-13.8 min、全体では-22 minだった。
最長jobが変わらないためwall clockへの影響はなく、予測どおりAOTは
クリティカルパス外である。統合後も`verify_native_aot_artifacts`が成功しており、
fixture × optimization の被覆（各optimizationでちょうど1回）は維持されている。

## Linux AOT jobsのcompiler build重複の解消

Phase 4はWindowsのsupport系5 jobを共有compiler artifactへ寄せたが、**Linux側は
依然として各jobがcompilerをbuildしていた**。run 35465334491の実測:

| job | job全体 | うちBuild AOT verification compiler |
| --- | ---: | ---: |
| Linux x86_64 / AOT native shard 1/3 / O0+O1 | 236s | 172s（73%） |
| Linux x86_64 / AOT support HTTP | 183s | 125s（68%） |
| Windows x86_64 / AOT native shard 1/3 / O0+O1 | 131s | 0s（共有artifact） |

補足: Phase 1のcache key分離（`aot-native-v2-s{shard}of{count}-{optimization}`）後は、
Linux AOT nativeのbuildがcache hitで0〜1sになる場合もある。ただしcache総量が
上限10 GiBを超えるためevictionが起き、run 35466605404では6 job中3 jobが
cold（171〜177s）だった。共有artifactはこのcold buildを構造的に無くす。

### 実装: Linux専用producer＋consumer job

Windowsと同じproducer/consumer方式をLinuxへ広げた。

- `aot_compiler_linux`（producer）: ubuntu-24.04でDebug compilerを1回buildし、
  `aot_compiler_artifact.mjs create`でcommit・os・arch・Zig version・buildMode・
  各SHA-256を持つartifactとしてuploadする。成果物はproducerと別のrunnerで実行される
  ため`-Dcpu=baseline`を明示し、runner CPU依存命令の混入を防ぐ（Windowsで実測した
  AVX-512混入と同じ問題の再発防止）。`use-cache: false`。
- `aot_linux`（consumer）: Linux native 6 shard（O0+O1／O2+O3×3 shard）と、Debug
  compilerで動作するLinux support 2 job（HTTP・dispatch evidence）を集約する。
  artifactを`aot_compiler_artifact.mjs verify --install-to zig-out/bin`で検証・
  installし、各jobの`zig build`（実測125〜172s）を0sにする。`use-cache: false`に
  してshard別Zig cache（1 lineage 約64 MiB × 6 shard）も作らない。

### job分割で維持した性質

`needs`はjob全体へ効くため、producer依存はconsumer jobだけに置いた。`aot`
（macOS native routes 3＋Linux dedicated coverage 3 shard＋Linux/Windows smoke）は
`needs: [changes]`のままとし、producer失敗で他platform・support shardの検証を
巻き込まない（`aot_windows`と同じ方針）。canonical正本を供給するLinux
`support-dispatch-coverage`はReleaseSafeが必須で共有Debug artifactを流用できないため、
従来どおり`aot`側で自前buildする。macOS nativeも同様に`aot`側で自前buildする。

### 付随して修正した不整合

Releaseのpreflightは「同一commitのCI全job成功」をjob数の一致で判定するが、
`release.yml`の`CI_EXPECTED_JOB_COUNT`は57（Phase 5前の値）のままで、Phase 5後の
CI（45 job）とは恒久的に不一致だった。本変更で正しい46 jobへ更新し、
`check_release_workflow.mjs`が**CI定義から総job数を導出して**release側の固定値と
照合するようにした（matrix行数＋matrixを持たないjob数）。job構成の変更に固定値が
追従しない事故を構造的に防ぐ。

### 検証中に発見・修正した不具合: artifact install後の実行ビット欠落

run 35469356296で`aot_linux`の8 jobが `spawn .../zig-out/bin/lnako EACCES` で
失敗した。原因は**upload-artifact／download-artifactが実行ビットを保証しない**
ことだった。producerがbuildしたcompilerを`verify --install-to`でinstallしても
非実行ファイルになり、Linuxではexecに失敗する。Windows consumerは実行ビットが
不要なため、同じ共有artifactを使うPhase 4では顕在化していなかった。

`aot_compiler_artifact.mjs verify --install-to` がPOSIX（`platform !== 'win32'`）で
install直後に`chmod 0o755`するようにし、単体テストで実行ビットを固定、
`check_ci_workflow.mjs`にもchmod実装の存在を検査として追加した。

### 実測結果（run 35469955469・35471297565・35473939691・35476491104。いずれも46 job・failure 0）

Linux AOTの対象job群（native 6 shard＋support HTTP＋support dispatch evidence＋
新規producer）をまとめたrunner minutesは、先行7 runの **21.0〜32.2 min（median 26.6）**
から **11.3〜11.8 min（median 11.4）** へ減った。個別jobの内訳は次のとおり。

| job | Phase 6前（run 35465334491） | Phase 6後（run 35469955469） | 差 |
| --- | ---: | ---: | ---: |
| Linux / AOT native shard 1/3 / O0+O1 | 236s | 66s | -170s |
| Linux / AOT native shard 2/3 / O0+O1 | 243s | 68s | -175s |
| Linux / AOT native shard 3/3 / O0+O1 | 209s | 71s | -138s |
| Linux / AOT native shard 1/3 / O2+O3 | 247s | 70s | -177s |
| Linux / AOT native shard 2/3 / O2+O3 | 242s | 76s | -166s |
| Linux / AOT native shard 3/3 / O2+O3 | 213s | 67s | -146s |
| Linux / AOT support HTTP | 183s | 58s | -125s |
| Linux / AOT support dispatch evidence | 155s | 31s | -124s |
| Linux / AOT verification compiler（新規producer） | — | 202s | +202s |
| **対象8 job群の合計（producerを除く）** | **1,728s（28.8 min）** | **507s（8.4 min）** | **-1,221s（-20.4 min）** |
| **正味（producerを含む）** | **1,728s（28.8 min）** | **709s（11.8 min）** | **-1,019s（-17.0 min）** |

producerの`+202s`（3.4 min）を含めても**正味-17.0 min/run**（run 35465334491比）。
先行7 runの対象job群はcache hitの状況により21.0〜32.2 minで変動していたため、
median基準では **26.6→11.4 min（-15.2 min/run）** となる。

run全体のrunner minutesも、Phase 6後の4 runでは**166.4 / 151.6 / 152.4 / 169.1 min
（median 159.4）**で、先行7 runの**median 174.8 min（範囲166.9〜191.3）**から
**-15.4 min/run**減った（改善前の213 min比 **-25.2%**）。AOT job群の削減は
4 runいずれも11.3〜11.8 minで安定している一方、run全体は上記のとおり
`test` job行の変動に大きく左右される。
ただしrun全体は本変更が触れていない`test` job行の変動が大きいため、単一run比較では
判断しない（下記）。

#### run全体の値は無関係jobの変動が支配する

`test` job行（Phase 6の変更対象外）はrun間で大きく変動する。

| job | 先行7 run の範囲 |
| --- | ---: |
| Windows x86_64 / host | 193〜860s |
| Linux x86_64 / host | 133〜512s |

特に`Windows x86_64 / host`は193〜860s（4.5倍）で変動し、run全体の差を
単独で覆す。したがって総runner minutesは**対象job群（構造的に変わった部分）と
複数runのmedianで評価**する。run全体を20〜30 runで評価する長期計測（計画§10）は
別途継続する。

job名（`Linux x86_64 / AOT native shard 1/3 / O0+O1` 等）は変えていないため、
**mainのブランチ保護のrequired status checksの更新は不要**である。

### 検証

- run 35469955469 / 35471297565 / 35473939691 / 35476491104（いずれも46 job）が**failure 0**で成功。
  Linux AOTの8 consumer、`aot_compiler_linux`、`verify_native_aot_artifacts`
  （3 OS分のartifact partition検証）、`verify_dispatch_coverage`
  （3 OSのcoverage shard partition検証）がすべて成功した。
- `attest-dispatch-evidence`はPR runではattestation発行条件（mainへのpush／
  workflow_dispatch）を満たさないためskipされる（従来どおり）。


## 改善計画2 の最終結果

| 指標 | 改善前 | Phase 1〜5後（7 run） | Phase 6後（4 run） | wall律速job分割後（n=4） |
| --- | ---: | ---: | ---: | ---: |
| workflow wall clock | 1,112s | 876〜1,462s（median 約1,113s） | 1,071〜1,141s（median 約1,130s）※ | **818〜1,173s（median 830s＝13m50s）※※** |
| 全job runner minutes | 213 min | 166〜191 min（median 174.8） | 151.6〜169.1（median 159.4） | 146.1〜163.6 min（median 154.2） |
| matrix job数 | 57 | 45 | 総47（matrix 40＋producer／後段7）※ | 総47（同左） |
| AOT検証ステップ（24 shard合計） | 1,896s | 1,163s | -38.7% | -38.7%（不変） |
| Linux AOT job群（8 consumer＋producer） | — | 21.0〜32.2 min（median 26.6） | 11.3〜11.8 min（median 11.4） | 11.5〜12.6 min（median 11.9） |

計画の短期目標に対する到達状況:

- Wall clock 20〜30%削減 → **wall律速jobの分割で目標帯へ到達（n=4、medianで-25.3%）**。
  46 job構成のmedian（17m51s）までしか下がっていなかったwallは、`Windows x86_64 / core`
  （median 17m12s）が律速していたためである。分割後は律速が `Windows compat-aot`
  （12m59s〜13m15s）と `macOS host-compat`（10m34s〜13m00s）へ移り、wallは
  818〜1,173s（median 830s＝13m50s、run 35487256825・35488606007・35489573736・
  35502310307）となった。改善前比では -25.3%（57 job基準、median 830s）／
  -38.0%（54 jobベースライン基準）。**n=4のため系列を蓄積して確認する**。
  途中で「wall 1,112s→876s（-21%）」と記録したが、その876sは速い側の外れ値runで
  あり代表値ではない。**この-21%は誤った一般化として撤回する**（Phase 4・5の
  セクションの当時の記録はそのまま残す）。
- Runner minutes → **Phase 1〜5で-22%**（213→median 174.8 min）、**Phase 6で
  追加-15.4 min/run**（median 174.8→159.4、改善前比 **-25.2%**）。wall分割後も
  runner minutes median 152.5（46 job、n=9）→154.2（47 job、n=4）で**-25%以上を維持**する。
  残りは Windows coreの実ビルド／実実行コスト（CI構造では削減不可）に由来する。
- Physical上「検証量を減らさず」を維持（Phase 4・5・6とwall分割はビルドと実行の
  重複のみ除去し、jobを分けただけである）。

※ run 35476491104のwallは1,511sだが、branchのconcurrency操作（旧run再実行による
   cancel）でqueueが延びた参考値であり、wallの集計からは除外している。
※ Windows専用の`win-package-isolation` jobを追加したため総job数は47（matrix 40）。
   この変更はwall clockの律速jobを分離するもので、上表のPhase 6評価（46 job構成）
   とは別の変更である。
※※ wallのmax 1,173s（19m33s）はmacOSの5枠制限による`mac-host-compat`の484s
   queue待ちと`Windows x86_64 / host`の853sが重なったrunであり、medianの評価には
   影響しない（§10スナップショットに内訳を記載）。

## 計測の限界と継続課題

run全体のrunner minutesは、Phase 6の変更対象外である`test` job行の変動
（`Windows x86_64 / host`は193〜860s、`Linux x86_64 / host`は133〜512s）が支配的で、
**単一run比較では施策の効果を判定できない**。計画§10の長期計測（20〜30 runの
median/p75/p90/p95の蓄積）は別途継続する。本節のPhase 6評価は、構造的に変わった
Linux AOT job群の実測と複数runのmedianに基づく。

### 長期計測スナップショット（ローリング）

計画§10の統計を蓄積する。2026-09-20時点の構成別の採用runは次のとおり
（少数標本ではp90/p95が最大値へ寄るため、標本数と併記する）。

#### 46 job構成（wall律速jobの分割前。n=9）

| 指標 | n | median | p75 | p90 | p95 | min | max |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| workflow wall clock（分） | 9 | 17.9 | 19.0 | 20.2 | 22.2 | 12.7 | 24.1 |
| 全job runner minutes | 9 | 152.5 | 161.9 | 166.9 | 167.8 | 146.2 | 168.7 |
| Linux AOT job群（8 consumer＋producer、分） | 9 | 11.7 | 11.8 | 12.0 | 12.0 | 11.3 | 12.0 |

#### 47 job構成（wall律速jobの分割後。n=4）

n=4ではp90/p95が標本の線形補間になり意味を持たないため、median/min/maxのみ示す。

| 指標 | n | median | min | max |
| --- | ---: | ---: | ---: | ---: |
| workflow wall clock（分） | 4 | 13.8 | 13.6 | 19.6 |
| 全job runner minutes | 4 | 154.2 | 146.1 | 163.6 |
| Linux AOT job群（8 consumer＋producer、分） | 4 | 11.9 | 11.5 | 12.6 |

- wallのmax 19.6分（run 35502310307）は、macOSの5枠制限による`mac-host-compat`の
  **queue待ち484s（8分）** と、`Windows x86_64 / host`が853s（同job行の通常範囲
  193〜860sの上限側）へ振れたことが重なったrunである。このrunでも律速job以外の
  実行は通常どおりで、wallはqueue待ちに支配された。

- 全job runner minutesのmin 146.2は、`test` job行が速い側へ振れたrunである
  （同job行は193〜860sで変動する）。
- Linux AOT job群は全runが11.3〜12.0 minで、施策の効果が最も安定して
  観測できる指標である。
- 系列を揃えるため`collect_ci_metrics.mjs`に構成境界のフィルタを追加した。
  `--branch`は他branchを除外するが、**同じbranch内の構成変更（job数の違う旧run）は
  区別できない**ため、`--jobs`（期待job数）と`--since`（開始日時）でも絞る。
  構成の異なるrunは採用せず、採用数が要求に届かない場合は出力へ明示する
  （旧構成の値で要求数を穴埋めしない）。run一覧は採用数が要求に達するまで
  ページングし、探索上限（10ページ）に達した場合も**未探索があること**を
  出力へ明示して静かに取りこぼさない。同じコマンドで更新する:

```sh
node tools/collect_ci_metrics.mjs --branch improve/ci --jobs 46 --runs 30 --no-logs
node tools/collect_ci_metrics.mjs --branch improve/ci --jobs 47 --runs 30 --no-logs
```

#### 部分再実行runを除外する修正

`run_attempt > 1`のrun（部分再実行）は、**再実行されなかったjobが前attemptの
started_at/completed_atのまま返る**ため、job一覧がattempt間で混在する。一方
`/actions/runs/{id}/timing`の`run_duration_ms`は最新attemptしか指さない。実測では
run 35472553438がwall 6m18sに対して最長job 17m26sとなり、**jobがrunより長い**
矛盾した観測になった。この状態ではwall／runner minutes／step統計が単一の実行区間を
表さないため、`collect_ci_metrics.mjs`は`run_attempt > 1`のrunを系列から除外し、
出力に除外件数を明示する（単体テストで担保）。46 job構成の系列は11 run中2件
（35472553438・35476491104）が該当し、**n=9**となった。

サンプル数を20〜30へ増やして再評価するのは継続課題である（本節はその途中経過）。

#### Windowsのtest stepに出るpanic痕跡（`--summary all`で判定済み）

Windowsの`Test`／`Test QuickJS build` stepのlogには、Zigのtest runnerが出力する
**panic痕跡**が含まれる（Linux／macOSの同stepには出ない）。痕跡の起点は
`std.Io.Threaded.netReadWindows`の`unexpectedStatus`で、`LOCAL_DISCONNECT`
（0xc000013b）と`CONNECTION_RESET`（0xc000020d）の2つのNTSTATUSを契機とする。

| 実測（run 35487256825） | 対象step | logの痕跡 | step所要 | step結論 |
| --- | --- | --- | ---: | --- |
| Windows `core` | `Test` | あり（3件、03:52:21） | 329s | success |
| Windows `compat-aot` | `Test QuickJS build` | あり（3件、03:47:58） | 397s | success |
| Linux `compat-aot` | `Test QuickJS build` | なし | 176s | success |
| macOS `mac-host-compat` | `Test QuickJS build` | なし | 235s | success |

痕跡の直後には`failed command: ...test.exe ... --listen=-`が出る。step結論がsuccessで
あることから、痕跡の有無だけでは実害を判断できない。そこで両test stepへ
`--summary all`（出力のみ。テスト意味は不変）を追加し、run 35489573736で集計を確認した。

| OS（run 35489573736） | Build Summary | test binary別 |
| --- | --- | --- |
| Windows `core` | `11/11 steps succeeded; 1685/1724 tests passed (39 skipped)` | 797＋840＋48 pass、17＋22 skip、**failed／crashed／timed outは0** |
| macOS `mac-core-standard-support` | `11/11 steps succeeded; 1717/1724 tests passed (7 skipped)` | 810＋859＋48 pass、4＋3 skip、**failed／crashed／timed outは0** |

**登録されるテスト数は両OSで同じ1724**で、Windowsは39件（macOS比+32件）をskipする。
panic痕跡は**どのテストにも帰属されず`crash_count`は0**なのでstepは成功する（panicは
test関数の完了後に残ったspawn thread内で起き、子processはexit 0で終わるため、というのが
観測とZigの`std/Build/Step/Run.zig`の分岐から導ける説明である）。

したがってCIは「失敗したテスト」を隠してはいないが、**panicがテスト結果へ現れない盲点**が
ある。後続課題として、std側のNTSTATUSマッピングとlnako側のthread joinを検討する
（[TODO.md](TODO.md) に記録）。


#### step統計の忠実性（skipされたstepを除外する修正）

GitHubは実行しなかったstepも`conclusion: "skipped"`として返し、そのstarted_atと
completed_atは同時刻（0秒）になる。当初これを除外していなかったため、1 runあたり
1,370 step中**480 step（35%）**の0秒観測が混入し、step別のmedianが0sへ潰れていた
（例: `Test QuickJS build` がmedian 0s・p95 384s）。`conclusion === "skipped"`を
除外して修正し、回帰テストを追加した。修正後の現行構成（10 run）のstep中央値:

| step | n | median | p95 |
| --- | ---: | ---: | ---: |
| Test QuickJS build | 30 | 267s | 397s |
| Test | 30 | 257s | 364s |
| Build ReleaseSafe compiler | 20 | 234s | 339s |
| Build QuickJS compiler | 30 | 205s | 393s |
| Build AOT verification compiler (ReleaseSafe) | 30 | 190s | 213s |
| Zig package isolation check | 30 | 181s | 386s |
| Differential interpreter test | 30 | 151s | 207s |
| Differential Node host test | 30 | 145s | 309s |
| Build AOT verification compiler | 100 | 1s | 3m12s |

`Build AOT verification compiler`がmedian 1s（p95 3m12s）であることが、Phase 6の
共有artifact化が効いている証拠である（残る裾はmacOS native等の自前build）。

### 次段階の検討: QuickJSビルドとsuite間Zig cache（実測により見送り）

step統計で目立つ`Test QuickJS build`（267s）と`Build QuickJS compiler`（205s）は
3 job/run（Linux/Windowsのcompat-aot、macOSのmac-host-compat）で実行され、
合計**約23.6 min/run**を占める。削減余地を実測で確認した結果、**いずれの案も
見送る**。

1. **QuickJSコンパイルの共有**: `zig build -Dcompat-js=true -Doptimize=ReleaseSafe
   --summary all`（ローカル、コールドcache）の内訳は`compile exe lnako ReleaseSafe
   native 1m`と`compile lib lnako_runtime ReleaseSafe native 54s`の2 stepのみで、
   **QuickJSのコンパイルは独立stepではなくlnakoのcompileへ統合**されている。
   共有するにはビルドシステムを変更してQuickJSを静的ライブラリとして事前ビルドし、
   `-Dcpu`等のCPU依存（Phase 4で実測したAVX-512混入の教訓）を管理する必要がある。
   検証構成（Debug・compat-js・ReleaseSafe compat-js）は変えられないため、
   費用対効果が合わない。
2. **suite間でのZig cache共有**: 現行はsuite別key（`cache-key: ${{ matrix.suite }}`）
   で、suite間で共有すればcompile objectを再利用できる可能性があった。しかし同一
   cacheで`zig build test`（コールド）→`zig build -Dcompat-js=true test`を実測すると
   **232.2s → 226.6s（-2.5%）**しか短縮せず、compat-js構成はほぼ全objectを作り直す
   ため**cache lineageを共有しても効果がない**。加えて並行suiteが同一keyへ保存すると
   未完成cacheの復元・予約競合（Phase 1で実測した問題）が再発するため、現行の
   suite別keyが妥当である。

結論として、`test` jobの残存コストは**要求された構成での実ビルドと実テスト実行
そのもの**であり、Phase 4・6で除去した「重複ビルド」に相当する構造的な重複は
残っていない。

### compat-aotのZig cache保存（実測の結果、見送り）

wall律速が`Windows compat-aot`（12m59s〜13m15s）へ移ったため、`use-cache: false`
だった`compat-aot`をcache保存の対象へ加えて実測した（利用者判断で
「実測して効果とcache容量を比較し、効果が無い／他suiteがcold化するなら撤回」）。

`compat-aot`は`zig build -Dcompat-js=true test`と
`zig build -Dcompat-js=true -Doptimize=ReleaseSafe`を毎回フルコンパイルしており、
後者はWindowsで356s・Linuxで175sだった。cache有効な`mac-host-compat`は同じ
ReleaseSafe compat-js構成のビルドが1sで終わるため、cacheの有無が効いていると
見て3 run比較した。

| run | 条件 | Windows compat-aot（job／step合計） | Linux compat-aot |
| --- | --- | ---: | ---: |
| 35487256825（cache無効） | — | 795s／753s | 351s |
| 35502310307（cache無効） | — | 783s／— | — |
| 35503960505（有効・初回） | cache **miss**（cold） | 610s／572s | 375s |
| 35506831210（有効・2回目） | cache **hit**（ただしmainマージでソース変更） | 499s／456s | 369s |
| 35507540242（有効・3回目） | cache **hit**（**ソースは2回目と同一**） | **807s／731s** | 470s |

**同一ソースでのcache hitでもビルドは短縮しなかった**（step合計731sはcache無効時の
753sと同水準。2回目の456sはrunner変動）。`core`で測った先行実測
（cold 233.3s→warm 209.4s、-10%程度。Zigはファイル単位の内容hashでcacheするため
復元しても大半の成果物は再生成される）と同じ結論である。

容量面でも不利だった。保存されるZig cacheはrunを重ねるごとに増え、
Windows 412 MB→728 MB→**1,044 MB**、Linux 862 MB→**1,248 MB**と`cache-size-limit`
1.5 GiBへ近づいた。リポジトリのcache総量は10 GiB上限に近く、Phase 6でAOT shardの
cache保存を止めて緩めた経緯があるため、効果のない保存を続ける理由はない。

→ **`compat-aot`のcache保存は撤回**（`use-cache`対象外へ戻した）。
`check_ci_workflow.mjs`の検査も元の対象へ戻している。
なお、この実験中も`mac-host-compat`のZig cacheは各runでhitしており、
**他suiteをcold化させるevictionは観測されなかった**（撤回は効果が無いため）。

### wall clockの残存レバー: 最長jobの分割（実施済み・初回実測で目標帯へ）

計画§10のwall clockは未達（実質不変）のままだった。原因を再測定したところ、
**wallはほぼ最長jobそのもの**で、46 job構成の11 run中9 runで `Windows x86_64 / core`
が律速していた（wallは`run_duration_ms`、すなわち`run_started_at→updated_at`。部分再実行run
2件は後述の理由で除外）。

| run | wall | 最長job | 律速job | wall−最長job |
| --- | ---: | ---: | --- | ---: |
| 35486004917 | 12m42s | 12m02s | macOS host-compat | 40s |
| 35484046897 | 24m07s | 18m33s | Windows core | 5m34s |
| 35483104649 | 17m25s | 16m14s | Windows core | 1m11s |
| 35481889139 | 19m12s | 17m54s | Windows core | 1m18s |
| 35480137046 | 14m10s | 13m34s | Windows core | 36s |
| 35477810503 | 15m54s | 15m15s | Windows compat-aot | 39s |
| 35473939691 | 17m51s | 17m12s | Windows core | 39s |
| 35471297565 | 18m50s | 17m38s | Windows core | 1m12s |
| 35469955469 | 19m01s | 18m17s | Windows core | 44s |

wallは最長jobに加えて後段の集約job（`Verify dispatch coverage shards`。PR runでは
`Attest and verify dispatch evidence`はskip）だけを含む。律速run以外のwall−最長jobが
36〜44sなのに対し、35484046897の5m34sはrun開始後にjobが起動するまでのrunner確保待ち
（最初のjobはrun開始から2m46s後）である。

`Windows x86_64 / core` の中身は独立した3つの検証である（実測例: `Test` 213〜390s、
`Zig package isolation check` 239〜377s、`Differential interpreter test` 134〜204s。
job内のsetup系は合計43s）。そこで最大の独立検証である `Zig package isolation check` を
Windows専用job（`suite: win-package-isolation`）へ分離し、Windows `core`では同stepを
skipする。**検証量は変えず、実行するjobだけを分ける**。

#### 実測（run 35487256825・35488606007・35489573736・35502310307。47 job・failure 0）

| 指標 | 分割前（46 job、n=9） | 分割後（47 job、n=4） |
| --- | ---: | ---: |
| workflow wall clock | median 17m51s（12m42s〜24m07s） | 13m49s／13m52s／13m38s／19m33s※ |
| 律速job | `Windows core` median 17m12s（p75 17m54s） | `Windows compat-aot` 13m11s／13m15s／12m59s／13m03s |
| `Windows x86_64 / core` | median 17m12s（p75 17m54s） | 10m51s／12m38s／6m54s／9m02s |
| `Windows x86_64 / win-package-isolation`（新規） | — | 6m34s／6m52s／5m37s／5m51s |
| 全job runner minutes | median 152.5（n=9） | 152.4／155.9／146.1／163.6 |

※ run 35502310307の19m33sはmacOSの5枠制限による`mac-host-compat`の484s queue待ちと
`Windows x86_64 / host`の853s（通常193〜860sの上限側）が重なったrunである。

queue待ちの無い3 run は wall が最長job＋38s以内（38s／37s／38s）である。律速は
`Windows compat-aot`（791s／795s／779s／783s）と `macOS host-compat`（634s／671s／780s／648s）が
入れ替わるようになり、**上位2 jobが16s差まで並んだ**（run 35489573736の最長は
macOS host-compat 780s、Windows compat-aot 779s）。これが当面のwall下限（約13分）に
なる。wallをさらに下げるには両方を同時に短縮する必要がある。
`Windows core` 自体も414〜758sとrun間で1.8倍振れるため、柱の特定は複数runのmedianで行う。

計画§14のwall clock目標（full CI baseline比-20〜30%）に対する到達状況は、基準の取り方で
次のとおり。**分割後はn=4のため、目標帯に入ったという観測であり、系列を蓄積して確認する**
（§10は少数サンプルでの判断を禁じている）。

| 基準 | wall | 分割後（median 830s＝13m50s）との差 |
| --- | ---: | ---: |
| 改善前ベースライン節（54 job、n=3、median） | 22m19s | -38.0% |
| 最終結果表の改善前（57 job、run 35453416527） | 18m32s | -25.3% |
| 直近の46 job構成（n=9、median） | 17m51s | -22.5% |

同runのstep実測からの算術では、分割前なら `Windows x86_64 / core` が
10m51s＋5m47s＝**16m38s**となり、`Windows compat-aot`（13m11s）より長いまま律速していた。
すなわちこの分割は、実行条件を揃えた同一run内でも律速を約3.5分下げる効果を持つ。

コストは小さい。jobあたりsetupは約45s（checkout 13s、setup-zig 8s、setup-node 8s、
LLVM／QuickJS／oracleはcache hitで数秒）なので、専用job 1つ分の増加でも**runner minutes
+0.75 min/run（+0.5%）**に留まり、計画のrunner minutes目標（-25%以上）は
維持できる（実測でも n=9 median 152.5 → 152.4 min）。

この分割は計画のPhase 5（runner minutesを優先して統合し、wallは変わらないと判断）
とは逆向きのトレードオフであり、job名が増えるためブランチ保護のrequired status checks
にも影響する。**計画に無い変更のため利用者の判断で実施した**（本節はその実測記録）。


## 参考: 観測されたflaky失敗（本施策とは無関係）

run 35472553438（docs専用commit。直前のrunと`docs/ci-performance.md`のみ差分）で
`macOS arm64 / AOT native routes O0+O1` が1件失敗した。

- 失敗箇所: dispatch coverage auditのfixture
  `node-file-cases.json/plugin-node-process-completion-order`
  （`tools/lib/coverage_process.mjs` の `assertEquivalent`。trace有無で結果が変化）
- 当該fixtureは子processの完了順（25 msポーリング＋2000 ms＋8000 ms deadline）と
  `5秒待` に依存する**タイミング依存**の内容で、失敗時は実行に51 sを要していた。
  macOS runnerの負荷でtrace有効側の出力が変わったものと見られる。
- `task: native`行は本施策の変更対象外（macOS行は`aot` jobのまま）で、直前の2 run
  （35469955469 / 35471297565）では同じコードが成功していた。失敗jobのみ再実行した
  ところ全て成功し、**flaky**であることを確認した。
- fixtureの待ち時間へ余裕を足す等のハードニングは互換oracleの意味を変えない範囲で
  検討すべき別課題のため、本施策では変更していない。

### 2件目の観測（run 35481147659）と原因の確定

同じfixtureが今度は`macOS arm64 / mac-host-compat`の`compare_node_file_oracle.mjs`で
**1件の差分**として失敗した。ログに残った同一job内の比較結果が原因を確定させている。

| optimization | stdout |
| --- | --- |
| 公式oracle（期待値） | `["FAST","SLOW"]` |
| lnako AOT O0 / O1 / O2 | `["FAST","SLOW"]` |
| lnako AOT O3 | `["SLOW","FAST"]` |

**同じfixtureを同じjob内でO0〜O3へコンパイルした結果、O3だけ順序が反転した**。
つまり差は最適化による意味の変化ではなく、子processの完了順という競合の結果である。
fixtureは「child-fastがmarkerを書く→child-slowが25 ms間隔で検出して2000 ms後に
`SLOW`を出力」というraceに依存し、負荷や生成コードの速度差で順序が入れ替わる。

#### 期待値の妥当性を実測で確認（当初の推測は不支持）

当初「公式oracle自身も順序を保証しないため、期待値が順序を固定している点が
不健全ではないか」と推測したが、実測すると**その推測は支持されなかった**。

| 実行者 | 条件 | 結果 |
| --- | --- | ---: |
| 公式cnako3 3.7.24 | アイドル | `["FAST","SLOW"]` 20/20 |
| 公式cnako3 3.7.24 | CPU負荷8並列 | `["FAST","SLOW"]` 10/10 |
| lnako（interpreter） | アイドル | `["FAST","SLOW"]` 12/12 |
| lnako（AOT O3） | アイドル | `["FAST","SLOW"]` 12/12 |

期待値 `["FAST","SLOW"]` は公式・lnakoの双方で安定して観測される。CIでの反転
（lnako AOT O3のみ `["SLOW","FAST"]`）は、`child-slow`が`child-fast`のmarker検出後
2000 msで出力する設計のため、**負荷時にlnako側の完了コールバック配送が2秒以上
遅れた**まれな事象と見るのが妥当である（公式は負荷時も反転しなかった）。

したがって望ましい対応は比較の順序非依存化ではなく、次のいずれかである。

1. fixtureのタイミング余裕を広げる（`2000 ms`／`5秒待`のマージンを増やす）。
2. lnako側の完了コールバック配送が負荷時に遅れる事象を調査する。

#### タイミング余裕の拡大（利用者判断で1を実施）

対象fixtureは本PRの変更外でも再発している。run 35505193318（`feat/file-metadata`の
`macOS arm64 / AOT native routes O0+O1`、workflow_dispatch）では、同じ
`node-file-cases.json/plugin-node-process-completion-order`で
`AOT traceでtrace有無の結果が変化しました` となり、集約job
`Verify native AOT artifacts`が設計どおり失敗を検出した（fixture開始から101sで失敗）。
本節の硬化はこの再発に対する対応でもある。

互換oracleの意味を変えずに余裕だけを広げた（`tests/oracle/node-file-cases.json`）。

| 定数 | 変更前 | 変更後 | 意図 |
| --- | ---: | ---: | --- |
| `child-slow.mjs`のmarker待ちdeadline | 8000 ms | 4000 ms | 外側の待ち時間の中へ収める |
| marker検出後`SLOW`を出すまでの遅延 | 2000 ms | 3000 ms | 「FAST→SLOW」の順序が崩れる余裕を3秒へ拡大 |
| 外側の待ち（`5秒待`） | 5000 ms | 8000 ms | 両方が揃うための余裕を拡大 |

設計上の性質は次のとおり。

- 通常はmarker検出（25 msポーリング）＋3000 msで`SLOW`が出る。
- markerが検出できなくてもdeadline 4000 ms＋3000 ms＝7000 msで`SLOW`が出るため、
  `8000 ms`の待ち時間内に必ず両方のコールバックが揃う（順序はFAST→SLOW）。
- lnako側の配送遅延が3秒を超えない限り順序は崩れない（変更前は2秒）。

ローカル実測（公式cnako3・lnako interpreter・lnako AOT O3の3者一致）:

| 条件 | 結果 |
| --- | --- |
| アイドル 3回 | 3/3一致（`["FAST","SLOW"]`） |
| CPU負荷16並列（8 core×2） 3回 | 3/3一致（`["FAST","SLOW"]`） |

`node tools/compare_node_file_oracle.mjs`もローカルで成功（13ケース・65命令、AOT O0〜O3は5ケース）。
加えて、互換oracleの意味をさらに強くする案として「markerの書き込みをlnako側の
完了コールバック（`F`）へ移す」方法がある（順序raceそのものを消せる）。fixtureの
意味を変えるため、本PRでは採用せず代替案として記録する。
