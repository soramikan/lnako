const dispatchRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];

// stdout/stderr may legitimately differ between OSes when a fixture exercises
// platform-specific values such as path separators. Each evidence file still
// validates exact route hashes against its own official source; the cross-OS
// identity therefore compares only the route result shape here.
export function platformIndependentOfficialComparison(comparison) {
  return {
    oracle: comparison.oracle,
    routes: comparison.routes,
    equivalent: comparison.equivalent,
    results: Object.fromEntries(dispatchRoutes.map((route) => [route, {
      status: comparison.results[route].status,
      signal: comparison.results[route].signal,
    }])),
  };
}
