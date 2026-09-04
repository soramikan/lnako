pub const std = @import("std");
pub const builtin = @import("builtin");
pub const aot_abi = @import("../aot_abi.zig");
pub const aot_builtin = @import("../aot_builtin.zig");
pub const BigInt = @import("../bigint.zig").BigInt;
pub const error_message = @import("../error_message.zig");
pub const unicode_case = @import("unicode_case");
pub const number_mod = @import("../number.zig");
pub const string_mod = @import("../string.zig");
pub const system_constant = @import("../system_constant.zig");
pub const crypto = @import("../../plugins/crypto.zig");
pub const encoding = @import("../../plugins/encoding.zig");
pub const zip_archive = @import("../../archive/zip.zig");
pub const regexp = @import("../../plugins/system/regexp.zig");
pub const markup = @import("../../plugins/markup.zig");
pub const lexer = @import("../../frontend/lexer.zig");
pub const josi = @import("../../frontend/josi.zig");
pub const builtin_catalog = @import("../../semantic/builtin_catalog.zig");
pub const dynamic_ir = @import("../../ir/nako_ir.zig");
pub const dynamic_interpreter = @import("../interpreter.zig");
pub const dynamic_value = @import("../value.zig");
pub const toml_temporal = @import("../toml_temporal.zig");

pub const AotWindowsStdout = if (builtin.os.tag == .windows) struct {
    extern "c" fn _setmode(file_descriptor: c_int, mode: c_int) c_int;

    const stdout_file_descriptor: c_int = 1;
    const binary_mode: c_int = 0x8000;

    pub fn configure() void {
        // AOT output can contain CRLF bytes originating in a Nako string.
        // The Windows CRT text mode would translate the LF again and emit
        // CRCRLF, so keep stdout byte-oriented like Node's stream output.
        _ = _setmode(stdout_file_descriptor, binary_mode);
    }
} else struct {
    pub fn configure() void {}
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
