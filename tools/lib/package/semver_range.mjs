// nako.toml の semverRange 制約を解析し、2つの範囲の交差判定を行う。
// src/package/semver.zig の範囲機構（node-semver 互換）を JS に移植したもの。
// E003_CONFLICTING_VERSIONS の「common 範囲を持たない」判定に使用する。

const MAX_COMPONENT = 9007199254740991;

function numericPart(text) {
  if (text.length === 0) return null;
  if (text.length > 1 && text[0] === "0") return null;
  if (!/^\d+$/.test(text)) return null;
  const value = Number(text);
  if (!Number.isSafeInteger(value) || value > MAX_COMPONENT) return null;
  return value;
}

function isWildcard(text) {
  return text === "x" || text === "X" || text === "*";
}

function isIdentChar(byte) {
  return /[0-9a-zA-Z-]/.test(byte);
}

function validateIdentifiers(text, strictNumeric) {
  if (text.length === 0) return false;
  for (const part of text.split(".")) {
    if (part.length === 0) return false;
    let numeric = true;
    for (const byte of part) {
      if (!isIdentChar(byte)) return false;
      if (!/[0-9]/.test(byte)) numeric = false;
    }
    if (strictNumeric && numeric && part.length > 1 && part[0] === "0") return false;
  }
  return true;
}

function orderPrerelease(a, b) {
  if (a.length === 0 && b.length === 0) return 0;
  if (a.length === 0) return 1;
  if (b.length === 0) return -1;
  const aParts = a.split(".");
  const bParts = b.split(".");
  const len = Math.max(aParts.length, bParts.length);
  for (let i = 0; i < len; i++) {
    const aPart = aParts[i];
    const bPart = bParts[i];
    if (aPart === undefined && bPart === undefined) return 0;
    if (aPart === undefined) return -1;
    if (bPart === undefined) return 1;
    const aNumeric = /^\d+$/.test(aPart);
    const bNumeric = /^\d+$/.test(bPart);
    if (aNumeric && bNumeric) {
      const na = aPart.replace(/^0+/, "");
      const nb = bPart.replace(/^0+/, "");
      if (na.length !== nb.length) return na.length < nb.length ? -1 : 1;
      if (na !== nb) return na < nb ? -1 : 1;
    } else if (aNumeric) {
      return -1;
    } else if (bNumeric) {
      return 1;
    } else if (aPart !== bPart) {
      return aPart < bPart ? -1 : 1;
    }
  }
  return 0;
}

function compareVersion(a, b) {
  if (a.major !== b.major) return a.major < b.major ? -1 : 1;
  if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
  if (a.patch !== b.patch) return a.patch < b.patch ? -1 : 1;
  return orderPrerelease(a.prerelease, b.prerelease);
}

function parsePartial(text) {
  let rest = text;
  // `v` 前置のみ剥がす。バージョン位置の `=` は意図的に受理しない
  // （node-semver 7.x の `[v=\s]*` 前置より厳しい。npm/node-semver#691 で
  // 提案される次期メジャーの `v?` のみ前置と一致。Zig 側 parsePartial と同じ）。
  if (rest.length > 0 && rest[0] === "v") rest = rest.slice(1);
  const plus = rest.indexOf("+");
  if (plus >= 0) {
    if (!validateIdentifiers(rest.slice(plus + 1), false)) return null;
    rest = rest.slice(0, plus);
  }
  let prerelease = "";
  const dash = rest.indexOf("-");
  if (dash >= 0) {
    prerelease = rest.slice(dash + 1);
    rest = rest.slice(0, dash);
    if (!validateIdentifiers(prerelease, true)) return null;
  }
  const parts = rest.split(".");
  if (parts.length > 3) return null;
  const result = { major: null, minor: null, patch: null, prerelease };
  if (isWildcard(parts[0])) {
    if (parts.length > 1) return null;
    return result;
  }
  result.major = numericPart(parts[0]);
  if (result.major === null) return null;
  if (parts.length > 1) {
    if (isWildcard(parts[1])) {
      if (parts.length > 2) return null;
      return result;
    }
    result.minor = numericPart(parts[1]);
    if (result.minor === null) return null;
  }
  if (parts.length > 2) {
    if (isWildcard(parts[2])) return result;
    result.patch = numericPart(parts[2]);
    if (result.patch === null) return null;
  }
  if (prerelease.length > 0 && (result.minor === null || result.patch === null)) return null;
  return result;
}

function partialToVersion(partial) {
  return {
    major: partial.major ?? 0,
    minor: partial.minor ?? 0,
    patch: partial.patch ?? 0,
    prerelease: partial.prerelease,
  };
}

function caretUpper(partial) {
  const major = partial.major;
  if (major === null) return null;
  if (partial.minor === null) return { major: major + 1, minor: 0, patch: 0, prerelease: "" };
  const minor = partial.minor;
  if (partial.patch === null) {
    if (major > 0) return { major: major + 1, minor: 0, patch: 0, prerelease: "" };
    return { major: 0, minor: minor + 1, patch: 0, prerelease: "" };
  }
  const patch = partial.patch;
  if (major > 0) return { major: major + 1, minor: 0, patch: 0, prerelease: "" };
  if (minor > 0) return { major: 0, minor: minor + 1, patch: 0, prerelease: "" };
  if (patch > 0) return { major: 0, minor: 0, patch: patch + 1, prerelease: "" };
  return { major: 0, minor: 0, patch: 1, prerelease: "" };
}

function tildeUpper(partial) {
  const major = partial.major;
  if (major === null) return null;
  if (partial.minor === null) return { major: major + 1, minor: 0, patch: 0, prerelease: "" };
  return { major, minor: partial.minor + 1, patch: 0, prerelease: "" };
}

function wildcardUpper(partial) {
  const major = partial.major;
  if (major === null) return null;
  if (partial.minor === null) return { major: major + 1, minor: 0, patch: 0, prerelease: "" };
  return { major, minor: partial.minor + 1, patch: 0, prerelease: "" };
}

function expandToken(list, token) {
  if (token.length === 0) return true;
  if (isWildcard(token)) return true;
  let op = "";
  let rest = token;
  for (const prefix of [">=", "<=", "~>", ">", "<", "=", "~", "^"]) {
    if (rest.startsWith(prefix)) {
      op = prefix;
      rest = rest.slice(prefix.length);
      break;
    }
  }
  return expandOp(list, op, rest);
}

function expandOp(list, op, rest) {
  const partial = parsePartial(rest);
  if (partial === null) return false;

  if (op === "^") {
    const upper = caretUpper(partial);
    if (upper === null) return true;
    list.push({ op: "gte", version: partialToVersion(partial) }, { op: "lt", version: upper });
    return true;
  }
  if (op === "~" || op === "~>") {
    const upper = tildeUpper(partial);
    if (upper === null) return true;
    list.push({ op: "gte", version: partialToVersion(partial) }, { op: "lt", version: upper });
    return true;
  }
  if (op === ">=" || op === ">") {
    if (partial.major === null) {
      // node-semver は `>*` を `<0.0.0-0`（空範囲）、`>=*` を `*` に写す。
      if (op === ">") list.push({ op: "lt", version: { major: 0, minor: 0, patch: 0, prerelease: "0" } });
      return true;
    }
    if (partial.minor !== null && partial.patch !== null) {
      list.push({ op: op === ">=" ? "gte" : "gt", version: partialToVersion(partial) });
    } else if (op === ">=") {
      list.push({ op: "gte", version: partialToVersion(partial) });
    } else {
      list.push({ op: "gte", version: wildcardUpper(partial) });
    }
    return true;
  }
  if (op === "<=" || op === "<") {
    if (partial.major === null) {
      // node-semver は `<*` を `<0.0.0-0`（空範囲）、`<=*` を `*` に写す。
      if (op === "<") list.push({ op: "lt", version: { major: 0, minor: 0, patch: 0, prerelease: "0" } });
      return true;
    }
    if (partial.minor !== null && partial.patch !== null) {
      list.push({ op: op === "<=" ? "lte" : "lt", version: partialToVersion(partial) });
    } else if (op === "<=") {
      list.push({ op: "lt", version: wildcardUpper(partial) });
    } else {
      list.push({ op: "lt", version: partialToVersion(partial) });
    }
    return true;
  }
  if (partial.major === null) return true;
  if (partial.minor === null || partial.patch === null) {
    list.push({ op: "gte", version: partialToVersion(partial) }, { op: "lt", version: wildcardUpper(partial) });
    return true;
  }
  list.push({ op: "eq", version: partialToVersion(partial) });
  return true;
}

const LONE_OPERATORS = new Set([">=", "<=", "~>", ">", "<", "=", "~", "^"]);

function parseSet(alternative) {
  const tokens = alternative.split(/[ \t]+/).filter((t) => t.length > 0);
  if (tokens.length === 0) return null;
  const list = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token === "-") return null;
    if (i + 2 < tokens.length && tokens[i + 1] === "-") {
      if (!expandHyphen(list, token, tokens[i + 2])) return null;
      i += 2;
      continue;
    }
    if (LONE_OPERATORS.has(token)) {
      if (i + 1 >= tokens.length || tokens[i + 1] === "-") return null;
      if (!expandOp(list, token, tokens[i + 1])) return null;
      i += 1;
      continue;
    }
    if (!expandToken(list, token)) return null;
  }
  return list;
}

function expandHyphen(list, lowerText, upperText) {
  const lower = parsePartial(lowerText);
  const upper = parsePartial(upperText);
  if (lower === null || upper === null) return false;
  if (lower.major !== null) list.push({ op: "gte", version: partialToVersion(lower) });
  if (upper.major === null) return true;
  if (upper.minor === null) {
    list.push({ op: "lt", version: { major: upper.major + 1, minor: 0, patch: 0, prerelease: "" } });
  } else if (upper.patch === null) {
    list.push({ op: "lt", version: { major: upper.major, minor: upper.minor + 1, patch: 0, prerelease: "" } });
  } else {
    list.push({ op: "lte", version: partialToVersion(upper) });
  }
  return true;
}

// npm(node-semver)互換の範囲を OR された AND 比較子集合へ解析する。
// 空文字・空の `||` 選択肢は全バージョン一致（空集合）となる。
export function parseRange(text) {
  // Zig 側（semver.zig）と同じく空白トリムは space/tab のみ。
  const trimTab = (s) => s.replace(/^[ \t]+|[ \t]+$/g, "");
  if (trimTab(text).length === 0) return [[]];
  const sets = [];
  for (const alternative of text.split("||")) {
    if (trimTab(alternative).length === 0) {
      sets.push([]);
      continue;
    }
    const set = parseSet(alternative);
    if (set === null) return null;
    sets.push(set);
  }
  return sets;
}

function opMatches(op, ord) {
  switch (op) {
    case "lt": return ord < 0;
    case "lte": return ord <= 0;
    case "gt": return ord > 0;
    case "gte": return ord >= 0;
    case "eq": return ord === 0;
  }
  return false;
}

function isLowerStronger(candidate, current) {
  const ord = compareVersion(candidate.version, current.version);
  return ord > 0 || (ord === 0 && candidate.op === "gt" && current.op === "gte");
}

function isUpperStronger(candidate, current) {
  const ord = compareVersion(candidate.version, current.version);
  return ord < 0 || (ord === 0 && candidate.op === "lt" && current.op === "lte");
}

// 2つの AND 比較子集合の共通部分が空でないかを上下限から判定する。
function setsIntersect(a, b) {
  let lower = null;
  let upper = null;
  let exact = null;
  for (const set of [a, b]) {
    for (const comparator of set) {
      switch (comparator.op) {
        case "eq":
          if (exact !== null && compareVersion(exact.version, comparator.version) !== 0) return false;
          exact = comparator;
          break;
        case "gt":
        case "gte":
          if (lower === null || isLowerStronger(comparator, lower)) lower = comparator;
          break;
        case "lt":
        case "lte":
          if (upper === null || isUpperStronger(comparator, upper)) upper = comparator;
          break;
      }
    }
  }
  if (exact !== null) {
    if (lower !== null && !opMatches(lower.op, compareVersion(exact.version, lower.version))) return false;
    if (upper !== null && !opMatches(upper.op, compareVersion(exact.version, upper.version))) return false;
    if (exact.version.prerelease.length > 0) {
      // prerelease 版は各集合に同タプルの prerelease 比較子を要求する。
      const v = exact.version;
      for (const set of [a, b]) {
        const gated = set.some((c) => {
          const other = c.version;
          return other.prerelease.length > 0 && other.major === v.major && other.minor === v.minor && other.patch === v.patch;
        });
        if (!gated) return false;
      }
    }
    return true;
  }
  if (lower !== null && upper !== null) {
    const ord = compareVersion(lower.version, upper.version);
    if (ord > 0) return false;
    if (ord === 0) return lower.op === "gte" && upper.op === "lte";
  }
  return true;
}

// 2つの範囲の積集合が空でないか。`setsIntersect` と同じ上下限近似判定。
export function rangesIntersect(aSets, bSets) {
  if (aSets === null || bSets === null) return false;
  if (aSets.length === 0 || bSets.length === 0) return true;
  for (const setA of aSets) {
    for (const setB of bSets) {
      if (setsIntersect(setA, setB)) return true;
    }
  }
  return false;
}
