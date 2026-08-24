const fixedNow = Number.parseInt(process.env.LNAKO_TEST_NOW_MS ?? "1735689845678", 10);
const fixedMonotonic = Number.parseFloat(process.env.LNAKO_TEST_MONOTONIC_MS ?? "123.5");
const RealDate = globalThis.Date;

class FixedDate extends RealDate {
  constructor(...arguments_) {
    super(...(arguments_.length === 0 ? [fixedNow] : arguments_));
  }

  static now() {
    return fixedNow;
  }
}

globalThis.Date = FixedDate;
if (globalThis.performance) {
  Object.defineProperty(globalThis.performance, "now", { configurable: true, value: () => fixedMonotonic });
}

const mask = (1n << 64n) - 1n;
let randomState = BigInt(process.env.LNAKO_TEST_RANDOM_SEED ?? "5573589319906701683") & mask;
if (randomState === 0n) randomState = 0x4d595df4d0f33173n;
Math.random = () => {
  // The official compiler uses Math.random while generating internal names.
  // Those compile-time calls must not consume the program's injected random
  // stream, because lnako keeps compiler and host randomness separate.
  const stack = new Error().stack ?? "";
  if (/nako_(?:indent|gen)\.mjs|wnako3mod\.mjs|node_modules[\\/]shell-quote[\\/]parse\.js/.test(stack)) return 0.5;
  let value = randomState;
  value ^= value >> 12n;
  value ^= (value << 25n) & mask;
  value ^= value >> 27n;
  randomState = value & mask;
  const bits = ((randomState * 0x2545f4914f6cdd1dn) & mask) >> 11n;
  return Number(bits) / 9007199254740992;
};
