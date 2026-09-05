# CIの現行構成

CIは、互換性検証の意味を保ったまま、AOTをfixture shardと最適化レベル単位のjobへ分割しています。定義の正本は [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) です。

## job構成

現行workflowは **51 matrix job＋3後段job、合計54 job**です。matrixの失敗は別OS・別suiteの結果を隠さないよう `fail-fast: false`、同一branchの古いrunは `cancel-in-progress: true` です。

| job | 内訳 | 主な検証 |
| --- | ---: | --- |
| `test` | 10 | core、standard、host、QuickJS/AOT smoke、macOS統合suite |
| `parser_fuzz` | 2 | Linux/Windowsの文法生成fuzz |
| `aot` native | 27 | Linux 12、macOS 3、Windows 12。O0〜O3とfixture shard |
| `aot` support | 12 | Linux/Windows各6。HTTP、dispatch evidence、coverage 3 shard、smoke |
| 後段 | 3 | coverage集約、AOT artifact集約、dispatch attestation |

job数を増やすことで、1つの巨大なAOT stepに検証を集中させず、失敗箇所と所要時間をjob単位で確認できます。検証suite、O0〜O3、QuickJS、3 OSのいずれも省略しません。

## macOSの5枠制限

macOS runnerは同時実行枠が5つなので、macOS jobは常に次の5件に収めます。

| job | 分担 |
| --- | --- |
| `mac-core-standard-support` | core、standard、fuzz相当の統合support、AOT HTTP、normal smoke |
| `mac-host-compat` | Node host、QuickJS、plugin ABI、dispatch trace/security |
| `AOT native routes O0+O1` | native route O0/O1、coverage shard 2 |
| `AOT native routes O2` | native route O2、coverage shard 1 |
| `AOT native routes O3` | native route O3、coverage shard 3 |

macOSのjobをさらに増やすと実行待ちが発生するため、分割はLinux/Windowsのnative AOTを中心に行い、macOSでは5枠内で責務を割り当てます。

## AOTの分割単位

LinuxとWindowsのnative AOTは、fixtureを3 shardに分け、各shardをO0、O1、O2、O3の4 jobで実行します。macOSはfixtureを増やさず、O0＋O1、O2、O3の3 jobで全routeを検証します。

support jobはnative AOTの代替ではありません。HTTP server、dispatch trace、dispatch coverage、smokeという別の証拠経路を担当します。後段jobはmatrix artifactと結果を集約し、欠落・重複・失敗を検査してからattestationを実行します。

## artifactとcache

- AOT各jobは、公式oracle比較結果、compile manifest、runtime traceをOS・shard・optimization単位でartifactへ保存します。
- dispatch evidence、coverage shard、native AOT aggregateは、後段jobでpartitionとprovenanceを再検査します。
- toolchainはZig 0.16.0、LLVM/LLD 22.1.8、QuickJS 2026-06-04、Node.js 24.15.0を固定します。
- Zig cacheはjobごとに意味のあるhost/AOT対象だけを保存し、toolchain cacheとは分離します。cacheサイズを変える場合は、cache clear、固定toolchain退避、job時間、wall clock、runner合計、総cache容量をcold/warm両方で記録します。

参考として、run [`33748912548`](https://github.com/soramikan/lnako/actions/runs/33748912548) は54/54成功でした。wall clockとrunner合計は別指標で、前者は利用者の待ち時間、後者は各jobの実行時間合計です。

## push前後の確認

push前はworkflow構成と互換性正本を確認します。

```sh
node tools/check_ci_workflow.mjs
node tools/check_docs_current.mjs
node tools/sync_compat.mjs --check
node tools/sync_compat_evidence.mjs --check
node tools/check_compat_report.mjs
```

push時は、まず直前のmain runを確認し、失敗runがあればログを取得して原因を切り分けます。新runを無期限に待つ必要はありません。次回pushまたは作業の区切りで、前回runの結果と新runのjob状態を再確認します。

```sh
gh run list --workflow CI --branch main --limit 5
gh run view <run-id> --json conclusion,status,jobs,headSha,updatedAt
gh run view <run-id> --log-failed
```

失敗が見つかった場合は、失敗jobのstepログとartifact不足を先に確認し、再現可能なローカル検査を追加してから修正します。macOSの待機時間をjob実行時間と混同せず、job単位の実行時間とrun全体のwall clockを別々に記録します。

## 関連文書

- [`COMPATIBILITY.md`](COMPATIBILITY.md): 分類、canonical証拠、CI artifactの読み方
- [`COMPATIBILITY_EVIDENCE.md`](COMPATIBILITY_EVIDENCE.md): 証拠stateとattestationの規則
- [`docs/history/CI_PERFORMANCE_2026.md`](history/CI_PERFORMANCE_2026.md): 過去run、cache調整、分割の経緯

## 性能の継続測定

`comparison-benchmark.yml` は本体54-job CIとは別に、正式3 OSで共通のv2 suiteを測定します。PRはsmoke（warmup 1・3 samples）、main更新と夜間はnormal（3・10）、手動実行はfull（5・25）も選択できます。cnakoは互換基準3.7.24、Nodeは24.15.0に固定します。必須処理系の失敗や期待出力の不一致は失敗とし、短時間測定や速度のばらつきは警告として記録します。前回成功したmainのartifactを取得できる場合は、条件が一致する測定の中央値を比較して退行候補を警告します。artifactが期限切れ、または入力・環境などの条件が異なる場合は比較を見送ります。共有runnerの時間だけで性能退行を断定せず、同一環境での再測定を行います。

JSONの生サンプルとMarkdownは90日保持します。リリース用のfull測定はリリース配布物に含めます。詳細な条件・ローカル実行方法は[`benchmarks/README.md`](../benchmarks/README.md)を参照してください。
