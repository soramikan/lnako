// 参照 npm ESM library。テスト/tool が package.json と一緒に tar.gz 化して
// 127.0.0.1 の fixture registry から配信する。
export default function leftPad(text, length, ch) {
  const filler = ch === undefined ? " " : String(ch);
  let result = String(text);
  while (result.length < length) result = filler + result;
  return result;
}
