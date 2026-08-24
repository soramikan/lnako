import { suffix } from "./compat_helper.mjs";

export default {
  meta: {
    type: "const",
    value: {
      pluginName: "compat_imports",
      description: "QuickJS ES module loader test",
      pluginVersion: "1.0.0",
      nakoRuntime: ["lnako"],
      nakoVersion: "3.7.24",
    },
  },
  初期化: {
    type: "func",
    josi: [],
    fn: (sys) => sys.__setSysVar("互換初期化値", 6),
  },
  初期化確認: {
    type: "func",
    josi: [],
    fn: (sys) => sys.__getSysVar("互換初期化値"),
  },
  依存拡張子抽出: {
    type: "func",
    josi: [["の"]],
    pure: true,
    fn: (path) => suffix(String(path)),
  },
  非同期加算: {
    type: "func",
    josi: [["と"], ["を"]],
    asyncFn: true,
    fn: async (left, right) => {
      await Promise.resolve();
      return Number(left) + Number(right);
    },
  },
  コールバック実行: {
    type: "func",
    josi: [["に"], ["を"]],
    fn: (callback, value) => callback(value),
  },
  JS配列変更: {
    type: "func",
    josi: [["を"]],
    fn: (array) => {
      array.push(3);
      return array.length;
    },
  },
};
