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
  checkerのみ、所要2〜3分）。

### releaseとの関係

docs専用commitがmainへpushされるとattestation jobもskipされ、そのcommit
にはGitHub Attestationが存在しない。release gateは`Attest and verify
dispatch evidence`がsuccessのrunを要求するため、そのcommitへのtag付けは
失敗する。docs専用commitをrelease対象にする場合は、先にCI workflowを
mainで`workflow_dispatch`実行する（dispatchは常にfull相当で走り
attestationが発行される）か、full run済みのcommitをtag付けする。
