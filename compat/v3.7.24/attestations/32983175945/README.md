# CI実行証拠 32983175945

このディレクトリは、GitHub Actions run `32983175945`（2026-08-27、成功）の外部成果物を、Actions artifactの30日保持期限に依存せず追跡するための履歴スナップショットです。

- 証拠対象commit: `1ee47232d34711abaddb28038218258232ac3800`
- workflow identity: `soramikan/lnako/.github/workflows/ci.yml@refs/heads/main`
- attestation: 公式 `actions/attest@v4.2.2` が生成したSigstore bundle
- 検証: 公式 `gh attestation verify`（署名、SLSA predicate、workflow、source commit/ref、OIDC issuer、3 OS subject digest）

証拠対象commitと、この履歴スナップショットを追加する後続commitは別です。このディレクトリの存在は、後続commitが同じAOT実行結果を生成したことを意味しません。追跡中の `compat/v3.7.24/evidence.json` は従来どおり `verified: 0`、`trace-confirmed-unattested: 4` を保持し、ここにある過去runのverified catalogを現在commitの互換証拠へ混ぜません。

`manifest.json` は3 OSのdispatch JSONと4つの成果物ファイルのSHA-256、対象commit、run、workflow identity、3正式OS集合を固定します。`catalog-evidence-unattested.json`は対象run時点の527 entry baseで、
これを署名dispatchから導出した4 entryだけ`verified`へ変換したものが`catalog-evidence-verified.json`です。dispatch JSONとcatalog evidenceは、ソース本文、引数、値、ポインタ、ローカルパス、標準出力を含まない生成物です。
