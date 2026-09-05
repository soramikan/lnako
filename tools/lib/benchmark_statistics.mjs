/**
 * Statistics and output helpers shared by the comparison benchmark runner and
 * its result checker.
 *
 * Samples are observations in the order in which the processes completed.
 * Functions in this module never sort the caller's array in place.
 */

export const PROFILE_PRESETS = Object.freeze({
  smoke: Object.freeze({ warmup: 1, samples: 3 }),
  normal: Object.freeze({ warmup: 3, samples: 10 }),
  full: Object.freeze({ warmup: 5, samples: 25 }),
});

export const PROFILE_NAMES = Object.freeze(Object.keys(PROFILE_PRESETS));

export const EXECUTION_MEASUREMENTS = Object.freeze([
  "startup",
  "steady_state",
  "compile",
]);

export function resolveProfileOptions(profile = "normal", overrides = {}) {
  if (!Object.hasOwn(PROFILE_PRESETS, profile)) {
    throw new Error(`未知のbenchmark profileです: ${profile}`);
  }
  const preset = PROFILE_PRESETS[profile];
  const warmup = overrides.warmup === undefined ? preset.warmup : parseNonNegativeInteger(overrides.warmup, "warmup");
  const samples = overrides.iterations === undefined
    ? preset.samples
    : parsePositiveInteger(overrides.iterations, "iterations");
  return { profile, warmup, samples };
}

export function parsePositiveInteger(value, label = "値") {
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(number) || number <= 0) {
    throw new Error(`${label}には正の整数が必要です: ${value}`);
  }
  return number;
}

export function parseNonNegativeInteger(value, label = "値") {
  const number = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(number) || number < 0) {
    throw new Error(`${label}には0以上の整数が必要です: ${value}`);
  }
  return number;
}

/**
 * Return a linearly interpolated quantile. The input must be sorted by the
 * caller or be a sorted copy. Timing quantiles follow the native runner's
 * convention: a fractional nanosecond is rounded to the nearest integer and
 * an exact half is rounded upward.
 */
export function quantile(sortedSamples, probability) {
  if (!Array.isArray(sortedSamples) || sortedSamples.length === 0) {
    throw new Error("quantileには1件以上のサンプルが必要です");
  }
  if (!Number.isFinite(probability) || probability < 0 || probability > 1) {
    throw new Error(`quantileの確率が不正です: ${probability}`);
  }
  const position = (sortedSamples.length - 1) * probability;
  const lowerIndex = Math.floor(position);
  const upperIndex = Math.ceil(position);
  const lower = sortedSamples[lowerIndex];
  const upper = sortedSamples[upperIndex];
  return Math.floor(lower + (upper - lower) * (position - lowerIndex) + 0.5);
}

export function median(samples) {
  const sorted = copyAndSortSamples(samples);
  return quantile(sorted, 0.5);
}

export function summarizeSamples(samples) {
  const observed = validateSamples(samples);
  const sorted = [...observed].sort((left, right) => left - right);
  const mean = observed.reduce((total, value) => total + value, 0) / observed.length;
  const variance = observed.reduce((total, value) => total + ((value - mean) ** 2), 0) / observed.length;
  const standardDeviation = Math.sqrt(variance);
  const sampleMedian = quantile(sorted, 0.5);
  const deviations = observed.map((value) => Math.abs(value - sampleMedian)).sort((left, right) => left - right);
  const p25 = quantile(sorted, 0.25);
  const p75 = quantile(sorted, 0.75);

  return {
    samples_ns: [...observed],
    count: observed.length,
    min_ns: sorted[0],
    p25_ns: p25,
    median_ns: sampleMedian,
    p75_ns: p75,
    max_ns: sorted[sorted.length - 1],
    iqr_ns: p75 - p25,
    mad_ns: quantile(deviations, 0.5),
    mean_ns: mean,
    stddev_ns: standardDeviation,
    cv: mean === 0 ? 0 : standardDeviation / mean,
  };
}

export function validateSamples(samples) {
  if (!Array.isArray(samples) || samples.length === 0) {
    throw new Error("サンプルが空です");
  }
  for (const sample of samples) {
    if (!Number.isSafeInteger(sample) || sample < 0) {
      throw new Error(`サンプル値が不正です: ${sample}`);
    }
  }
  return samples;
}

export function copyAndSortSamples(samples) {
  return [...validateSamples(samples)].sort((left, right) => left - right);
}

export function normalizeOutput(output) {
  if (typeof output !== "string") return "";
  return output.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
}

export function outputsMatch(actual, expected) {
  return normalizeOutput(actual) === normalizeOutput(expected);
}
