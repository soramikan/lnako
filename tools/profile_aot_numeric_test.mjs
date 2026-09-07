import assert from "node:assert/strict";
import { summarizeCode } from "./profile_aot_numeric.mjs";

const summary = summarizeCode(`define internal double @lnako.number.1(double %a) {
  %r = call double @llvm.sqrt.f64(double %a)
  call void @lnako_aot_index_get(ptr null)
  call void @lnako_aot_index_get(ptr null)
}`, "callq __chkstk\nvsqrtsd %xmm0, %xmm0, %xmm1\n");
assert.equal(summary.static_call_sites.lnako_aot_index_get, 2);
assert.equal(summary.static_call_sites["llvm.sqrt.f64"], 1);
assert.deepEqual(summary.typed_definitions, ["lnako.number.1"]);
assert.equal(summary.stack_probe_mentions, 1);
assert.equal(summary.sqrt_mentions, 1);
assert.deepEqual(summarizeCode("", "").static_call_sites, {});
console.log("numeric profile code classification: PASS");
