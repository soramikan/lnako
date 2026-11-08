// 参照 plugin: plugin 登録（`整形` 命令）と npm ESM library の bare import
// を同時に満たす。`left-pad` は lnako の npm resolver が lock/cache から
// package tree を復元し、QuickJS の bare alias 経由でこの module へ解決する。
import leftPad from "left-pad";

export default {
  meta: {
    type: "const",
    value: {
      pluginName: "leftpad_reference",
      description: "参照 plugin+npm E2E fixture",
      pluginVersion: "1.0.0",
      nakoRuntime: ["lnako"],
      nakoVersion: "3.7.24",
    },
  },
  整形: {
    type: "func",
    josi: [["を"]],
    pure: true,
    fn: (text) => leftPad(String(text), 6),
  },
};
