pub const compile = @import("compiler_pipeline/compile.zig");
pub const embedded = @import("compiler_pipeline/embedded.zig");
pub const bundled = @import("compiler_pipeline/bundled.zig");
pub const sbom = @import("compiler_pipeline/sbom.zig");

pub const compileInput = compile.compileInput;
pub const compileInputTraced = compile.compileInputTraced;
pub const compileInputWithProvider = compile.compileInputWithProvider;
pub const writeCompatExecutable = embedded.writeCompatExecutable;
/// `--compat-js` 生成物へ同梱した package の metadata を IR へ記録する。
pub const collectBundledPackages = bundled.collect;
/// 同梱 package の license 一覧を SPDX 2.3 JSON として出力する。
pub const writeCompatSbom = sbom.write;
