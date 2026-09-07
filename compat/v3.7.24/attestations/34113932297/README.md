# 現行CI実行証拠 34113932297

このディレクトリは、GitHub Actions run `34113932297`（attempt 2、成功）の外部成果物を、Actions artifactの30日保持期限に依存せず追跡するための現行snapshotです。

- 証拠対象commit: `00dc21517c7cbe68bc4d85262578ee9de0ede110`
- workflow identity: `soramikan/lnako/.github/workflows/ci.yml@refs/heads/main`
- attestation: 公式 `actions/attest@v4.2.2` が生成したSigstore bundle（`sigstore-bundle.json`、21 subject）
- 検証: 公式 `gh attestation verify`（署名、SLSA predicate、workflow、source commit/ref、OIDC issuer、github-hosted runner、subject digest）

署名subjectは3 OSのdispatch証拠（`dispatch/`）＋native AOT aggregate＋`compat/v3.7.24/` のcanonical証拠17件です。`dispatch-attestation.json` は `lnako.dispatch-attestation.v2` で、`subjects`（3 OS）と `trackedSubjects`（canonical証拠のpath＋SHA-256）を記録します。

`manifest.json` は対象commit・run・workflow identity・source manifest SHA-256・各成果物と3 OS dispatch・17件canonical証拠のSHA-256を固定します。`catalog-evidence-verified.json` はこのattestationで `verified: 527` に昇格したcatalogで、追跡中の `compat/v3.7.24/evidence.json` と同一です。

このsnapshotがcanonical `verified` の根拠となるのは、`../current.json` がこのディレクトリを指し、かつ記録されたsource manifestが現行source manifestと一致する間だけです。manifestが変わるソース変更では新しいrunのsnapshotへ更新するまでverifiedは維持されません。
