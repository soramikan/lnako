// 参照 plugin: `整形` 命令を登録する ESM plugin。npm bare import を含まない
// 自己完結実装（npm 依存を含む公開は E039 で拒否されるため、その経路は
// check_package_plugin_npm_e2e.mjs が担当する）。
export default {
  meta: {
    type: "const",
    value: {
      pluginName: "leftpad_publish_reference",
      description: "参照 publish E2E fixture",
      pluginVersion: "1.0.0",
      nakoRuntime: ["lnako"],
      nakoVersion: "3.7.24",
    },
  },
  整形: {
    type: "func",
    josi: [["を"]],
    pure: true,
    fn: (text) => {
      let result = String(text);
      while (result.length < 6) result = " " + result;
      return result;
    },
  },
};
