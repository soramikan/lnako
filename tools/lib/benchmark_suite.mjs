import { readFileSync } from "node:fs";

import {
  EXECUTION_MEASUREMENTS,
  PROFILE_NAMES,
} from "./benchmark_statistics.mjs";

export const RUNTIME_NAMES = Object.freeze([
  "cnako",
  "gonako",
  "python",
  "c",
  "rust",
  "lnako",
]);

export const NADESIKO_RUNTIMES = Object.freeze(["cnako", "gonako", "lnako"]);
export const CROSS_LANGUAGE_RUNTIMES = Object.freeze(["python", "c", "rust"]);

const CASE_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

export function loadBenchmarkSuite(path) {
  let raw;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`benchmark suiteを読み込めません: ${path}: ${error.message}`);
  }
  return normalizeBenchmarkSuite(raw, path);
}

/**
 * Validate and normalize both the historical comparison suite and suite v2.
 * The returned object is a new object and may safely be enriched by the
 * runner. Unknown optional fields are retained so a suite can evolve without
 * making the runner discard provenance supplied by the case author.
 */
export function normalizeBenchmarkSuite(raw, sourcePath = "suite") {
  if (!isPlainObject(raw)) throw new Error(`${sourcePath}: suiteはJSON objectである必要があります`);
  if (raw.schema_version === 1) return normalizeV1Suite(raw, sourcePath);
  if (raw.schema_version === 2) return normalizeV2Suite(raw, sourcePath);
  throw new Error(`${sourcePath}: 未対応のsuite schema_versionです: ${raw.schema_version}`);
}

export function validateBenchmarkSuite(raw, sourcePath = "suite") {
  return normalizeBenchmarkSuite(raw, sourcePath);
}

function normalizeV1Suite(raw, sourcePath) {
  assertSuiteHeader(raw, sourcePath);
  const cases = normalizeCases(raw.cases, sourcePath, (item, index) => {
    if (!isPlainObject(item)) throw new Error(`${sourcePath}: cases[${index}]はobjectである必要があります`);
    if (!nonEmptyString(item.id)) throw new Error(`${sourcePath}: cases[${index}].idが不正です`);
    if (typeof item.expected_stdout !== "string") {
      throw new Error(`${sourcePath}: case ${item.id}.expected_stdoutはstringである必要があります`);
    }
    if (!isPlainObject(item.sources) || Object.keys(item.sources).length === 0) {
      throw new Error(`${sourcePath}: case ${item.id}.sourcesが空です`);
    }
    const sources = normalizeSources(item.sources, item.id, sourcePath, false);
    return {
      ...item,
      id: item.id,
      category: item.category ?? "legacy",
      kind: item.kind ?? "legacy",
      description: item.description ?? "legacy comparison benchmark",
      measurement: item.measurement ?? "startup",
      profiles: PROFILE_NAMES,
      tags: Array.isArray(item.tags) ? [...item.tags] : ["legacy"],
      source: item.source ?? sources.lnako ?? sources.cnako ?? null,
      sources,
      input: normalizeInput(item.input, item.id, sourcePath),
      input_variants: normalizeInputVariants(item, item.id, sourcePath),
      expected_stdout_variants: normalizeExpectedVariants(item, item.id, sourcePath),
      legacy: true,
    };
  });
  return {
    ...raw,
    schema_version: 1,
    name: raw.name,
    cases,
    legacy: true,
  };
}

function normalizeV2Suite(raw, sourcePath) {
  assertSuiteHeader(raw, sourcePath);
  const cases = normalizeCases(raw.cases, sourcePath, (item, index) => {
    if (!isPlainObject(item)) throw new Error(`${sourcePath}: cases[${index}]はobjectである必要があります`);
    if (!nonEmptyString(item.id) || !CASE_ID_PATTERN.test(item.id)) {
      throw new Error(`${sourcePath}: cases[${index}].idが不正です: ${item.id}`);
    }
    for (const key of ["category", "kind", "description"]) {
      if (typeof item[key] !== "string" || item[key].trim() === "") {
        throw new Error(`${sourcePath}: case ${item.id}.${key}が不正です`);
      }
    }
    if (!EXECUTION_MEASUREMENTS.includes(item.measurement)) {
      throw new Error(`${sourcePath}: case ${item.id}.measurementが不正です: ${item.measurement}`);
    }
    if (!Array.isArray(item.profiles) || item.profiles.length === 0 || item.profiles.some((profile) => !PROFILE_NAMES.includes(profile))) {
      throw new Error(`${sourcePath}: case ${item.id}.profilesが不正です`);
    }
    if (new Set(item.profiles).size !== item.profiles.length) {
      throw new Error(`${sourcePath}: case ${item.id}.profilesに重複があります`);
    }
    if (!Array.isArray(item.tags) || item.tags.some((tag) => typeof tag !== "string" || tag.trim() === "") || new Set(item.tags).size !== item.tags.length) {
      throw new Error(`${sourcePath}: case ${item.id}.tagsが不正です`);
    }
    if (typeof item.expected_stdout !== "string") {
      throw new Error(`${sourcePath}: case ${item.id}.expected_stdoutはstringである必要があります`);
    }
    const commonSource = item.source === undefined ? null : validateSourcePath(item.source, `${sourcePath}: case ${item.id}.source`, ".nako3");
    const rawSources = isPlainObject(item.sources)
      ? Object.fromEntries(Object.entries(item.sources).map(([runtime, value]) => [runtime, value === "same" ? commonSource : value]))
      : item.sources;
    if (isPlainObject(item.sources) && Object.values(item.sources).some((value) => value === "same") && commonSource === null) {
      throw new Error(`${sourcePath}: case ${item.id}.sourcesのsameにはcommon sourceが必要です`);
    }
    const sources = normalizeSources(rawSources, item.id, sourcePath, true);
    if (commonSource !== null) {
      for (const runtime of ["cnako", "lnako"]) {
        if (sources[runtime] === undefined) sources[runtime] = commonSource;
      }
    }
    if (sources.cnako === undefined || sources.lnako === undefined) {
      throw new Error(`${sourcePath}: case ${item.id}にはcommon .nako3 sourceまたはcnako/lnako sourceが必要です`);
    }
    if (commonSource !== null && (sources.cnako !== commonSource || sources.lnako !== commonSource)) {
      throw new Error(`${sourcePath}: case ${item.id}.sourceとsourcesのcnako/lnakoが一致しません`);
    }
    return {
      ...item,
      id: item.id,
      category: item.category,
      kind: item.kind,
      description: item.description,
      measurement: item.measurement,
      profiles: [...item.profiles],
      tags: [...item.tags],
      source: commonSource ?? sources.cnako,
      sources,
      input: normalizeInput(item.input, item.id, sourcePath),
      input_variants: normalizeInputVariants(item, item.id, sourcePath),
      expected_stdout_variants: normalizeExpectedVariants(item, item.id, sourcePath),
      legacy: false,
    };
  });
  return {
    ...raw,
    schema_version: 2,
    name: raw.name,
    cases,
    legacy: false,
  };
}

function assertSuiteHeader(raw, sourcePath) {
  if (!nonEmptyString(raw.name)) throw new Error(`${sourcePath}: suite.nameが不正です`);
  if (!Array.isArray(raw.cases) || raw.cases.length === 0) throw new Error(`${sourcePath}: suite.casesが空です`);
}

function normalizeCases(rawCases, sourcePath, normalizeCase) {
  const ids = new Set();
  return rawCases.map((item, index) => {
    const normalized = normalizeCase(item, index);
    if (ids.has(normalized.id)) throw new Error(`${sourcePath}: 重複したcase idです: ${normalized.id}`);
    ids.add(normalized.id);
    return normalized;
  });
}

function normalizeSources(rawSources, caseId, sourcePath, requireNadesiko) {
  if (rawSources === undefined) return {};
  if (!isPlainObject(rawSources)) throw new Error(`${sourcePath}: case ${caseId}.sourcesが不正です`);
  const sources = {};
  for (const [runtime, value] of Object.entries(rawSources)) {
    if (!RUNTIME_NAMES.includes(runtime)) throw new Error(`${sourcePath}: case ${caseId}.sourcesに未知のruntimeがあります: ${runtime}`);
    const extension = runtime === "cnako" || runtime === "gonako" || runtime === "lnako" ? ".nako3" : null;
    sources[runtime] = validateSourcePath(value, `${sourcePath}: case ${caseId}.sources.${runtime}`, extension);
  }
  if (requireNadesiko && (sources.cnako !== undefined && !sources.cnako.endsWith(".nako3") || sources.lnako !== undefined && !sources.lnako.endsWith(".nako3"))) {
    throw new Error(`${sourcePath}: case ${caseId}のcnako/lnako sourceは.nako3である必要があります`);
  }
  return sources;
}

function validateSourcePath(value, label, requiredExtension = null) {
  if (typeof value !== "string" || value.trim() === "") throw new Error(`${label}が不正です`);
  if (value.includes("\0") || value.startsWith("-")) throw new Error(`${label}に安全でないpathがあります`);
  if (requiredExtension !== null && !value.toLowerCase().endsWith(requiredExtension)) {
    throw new Error(`${label}は${requiredExtension}である必要があります`);
  }
  return value;
}

function normalizeInput(rawInput, caseId, sourcePath) {
  if (rawInput === undefined) return { args: [] };
  if (!isPlainObject(rawInput)) throw new Error(`${sourcePath}: case ${caseId}.inputが不正です`);
  const args = rawInput.args ?? [];
  if (!Array.isArray(args) || args.some((arg) => typeof arg !== "string")) {
    throw new Error(`${sourcePath}: case ${caseId}.input.argsはstring配列である必要があります`);
  }
  return { ...rawInput, args: [...args] };
}

function normalizeInputVariants(item, caseId, sourcePath) {
  const candidate = item.input_variants ?? item.input?.variants ?? item.input?.profiles ?? item.inputs;
  if (candidate === undefined) return {};
  if (!isPlainObject(candidate)) throw new Error(`${sourcePath}: case ${caseId}のinput variantsが不正です`);
  const variants = {};
  for (const [profile, raw] of Object.entries(candidate)) {
    if (!PROFILE_NAMES.includes(profile)) throw new Error(`${sourcePath}: case ${caseId}のinput variant profileが不正です: ${profile}`);
    const input = Array.isArray(raw) ? { args: raw } : raw;
    variants[profile] = normalizeInput(input, caseId, sourcePath);
  }
  return variants;
}

function normalizeExpectedVariants(item, caseId, sourcePath) {
  let candidate = item.expected_stdout_variants ?? item.expected_stdout_by_profile;
  if (candidate === undefined && isPlainObject(item.expected)) {
    candidate = item.expected.profiles ?? item.expected;
  }
  if (candidate === undefined) return {};
  if (!isPlainObject(candidate)) throw new Error(`${sourcePath}: case ${caseId}のexpected profile mapが不正です`);
  const variants = {};
  for (const [profile, expected] of Object.entries(candidate)) {
    if (!PROFILE_NAMES.includes(profile) || typeof expected !== "string") {
      throw new Error(`${sourcePath}: case ${caseId}のexpected stdout variantが不正です: ${profile}`);
    }
    variants[profile] = expected;
  }
  return variants;
}

export function selectBenchmarkCases(suite, { profile = "normal", caseIds = null } = {}) {
  if (!PROFILE_NAMES.includes(profile)) throw new Error(`未知のbenchmark profileです: ${profile}`);
  const requested = caseIds === null ? null : new Set(caseIds);
  if (requested !== null) {
    for (const id of requested) {
      if (!suite.cases.some((item) => item.id === id)) throw new Error(`指定されたcaseがsuiteにありません: ${id}`);
    }
  }
  return suite.cases.filter((item) => (requested === null || requested.has(item.id)) && (suite.schema_version === 1 || item.profiles.includes(profile)));
}

export function resolveCaseInvocation(item, profile) {
  const input = item.input_variants?.[profile] ?? item.input ?? { args: [] };
  const expected = item.expected_stdout_variants?.[profile] ?? item.expected_stdout;
  return { args: [...(input.args ?? [])], expected_stdout: expected };
}

export function sourceForRuntime(item, runtime) {
  return item.sources?.[runtime] ?? ((runtime === "cnako" || runtime === "lnako") ? item.source : undefined);
}

export function runtimeComparisonGroup(runtime) {
  return NADESIKO_RUNTIMES.includes(runtime) ? "nadesiko-implementation" : "cross-language-reference";
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() !== "";
}
