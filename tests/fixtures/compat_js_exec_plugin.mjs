// `sys.__exec` から実行時に呼ばれる ESM plugin。各命令は plugin 側の
// `sys.__exec` でビルトイン（足・表示）と別の plugin 命令を呼ぶ。
export default {
  加算: {
    type: "func",
    fn: (sys) => sys.__exec("足", [20, 22]),
  },
  委譲: {
    type: "func",
    fn: (sys) => sys.__exec("加算", []),
  },
  表示委譲: {
    type: "func",
    fn: (sys) => {
      // 先行命令の表示ログを含めないよう、plugin 側で一度クリアする。
      sys.__exec("表示ログクリア");
      sys.__exec("表示", ["plugin"]);
      return sys.__getSysVar("表示ログ");
    },
  },
};
