const std = @import("std");
const builtin = @import("builtin");
const aot_abi = @import("../aot_abi.zig");
const aot_builtin = @import("../aot_builtin.zig");
const BigInt = @import("../bigint.zig").BigInt;
const error_message = @import("../error_message.zig");
const unicode_case = @import("../generated/unicode_case");
const number_mod = @import("../number.zig");
const string_mod = @import("../string.zig");
const system_constant = @import("../system_constant.zig");
const crypto = @import("../../plugins/crypto.zig");
const encoding = @import("../../plugins/encoding.zig");
const zip_archive = @import("../../archive/zip.zig");
const regexp = @import("../../plugins/system/regexp.zig");
const markup = @import("../../plugins/markup.zig");
const lexer = @import("../../frontend/lexer.zig");
const josi = @import("../../frontend/josi.zig");
const builtin_catalog = @import("../../semantic/builtin_catalog.zig");
const dynamic_ir = @import("../../ir/nako_ir.zig");
const dynamic_interpreter = @import("../interpreter.zig");
const dynamic_value = @import("../value.zig");
const toml_temporal = @import("../toml_temporal.zig");

pub const AotWindowsStdout = if (builtin.os.tag == .windows) struct {
    extern "c" fn _setmode(file_descriptor: c_int, mode: c_int) c_int;

    const stdout_file_descriptor: c_int = 1;
    const binary_mode: c_int = 0x8000;

    fn configure() void {
        // AOT output can contain CRLF bytes originating in a Nako string.
        // The Windows CRT text mode would translate the LF again and emit
        // CRCRLF, so keep stdout byte-oriented like Node's stream output.
        _ = _setmode(stdout_file_descriptor, binary_mode);
    }
} else struct {
    fn configure() void {}
};

pub const Tag = aot_abi.Tag;
pub const AotPrimitiveHint = enum { string, number };

pub const safe_array_element_limit: usize = 1_000_000;
pub const aot_timer_event_limit: usize = 100_000;

/// AOT dispatch tracing is opt-in through LNAKO_DISPATCH_TRACE. It records
/// only static dispatch metadata; arguments, values, and addresses never
/// cross this boundary. C stdio keeps the helper available to generated
/// executables on POSIX and Windows without requiring a runtime Io object.
pub const no_dispatch_call_id = std.math.maxInt(u64);
