# なでしこ3互換性資料

`v3.7.24/command_list.json` は、なでしこ3 v3.7.24の公式命令カタログの固定スナップショットです。
`matrix.json` は全1,145件の分類、`standard-cnako.json` はv1で実装する標準cnako命令527件、
`summary.json` は集計値です。

生成物は次のコマンドで検証できます。

```sh
node tools/sync_compat.mjs --check
```

上流を再取得して生成物を更新する場合だけ、`--refresh` を使います。取得元とSHA-256は
`upstream.lock.json` に固定されています。

## 状態

- `blocked`: v1対象だが未実装または未検証
- `native`: 純LLVM AOTで公式処理系と等価
- `compat-js`: `--compat-js` で公式処理系と等価
- `excluded-browser`: 標準cnakoの対象外で、ブラウザ等の別ホスト専用
- `excluded-extension`: 外部拡張プラグイン

`plannedMode` は実装予定経路、`status` はテスト証拠を伴う現在状態です。対応テストが成功するまで
`blocked` から対応済みへ変更しません。
