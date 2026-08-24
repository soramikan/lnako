import "./fixed_host.mjs";

const originalLog = console.log.bind(console);
console.log = (...values) => {
  // `__DEBUG`が出すNakoGlobalのNode util.inspect表現は、生成JS全文、循環参照、
  // Map内部などを含みNodeの版にも依存する。言語の標準出力とは分離して比較する。
  if (values.length === 1 && values[0]?.__varslist instanceof Array && values[0]?.isDebug === true) return;
  if (values.length === 1 && typeof values[0] === "string" && /^@__DEBUG_BP_WAIT\([0-9]+\)$/.test(values[0])) return;
  originalLog(...values);
};
