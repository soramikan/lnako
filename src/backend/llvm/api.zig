const std = @import("std");
const builtin = @import("builtin");

pub const ContextRef = ?*anyopaque;
pub const ModuleRef = ?*anyopaque;
pub const MemoryBufferRef = ?*anyopaque;
pub const TargetRef = ?*anyopaque;
pub const TargetMachineRef = ?*anyopaque;
pub const TargetDataRef = ?*anyopaque;
pub const PassBuilderOptionsRef = ?*anyopaque;
pub const ErrorRef = ?*anyopaque;
pub const Message = ?[*:0]u8;
pub const Bool = c_int;

const FnGetVersion = *const fn (*c_uint, *c_uint, *c_uint) callconv(.c) void;
const FnContextCreate = *const fn () callconv(.c) ContextRef;
const FnContextDispose = *const fn (ContextRef) callconv(.c) void;
const FnCreateMemoryBuffer = *const fn ([*]const u8, usize, [*:0]const u8) callconv(.c) MemoryBufferRef;
const FnParseIr = *const fn (ContextRef, MemoryBufferRef, *ModuleRef, *Message) callconv(.c) Bool;
const FnDisposeModule = *const fn (ModuleRef) callconv(.c) void;
const FnVerifyModule = *const fn (ModuleRef, c_uint, *Message) callconv(.c) Bool;
const FnPrintModule = *const fn (ModuleRef) callconv(.c) [*:0]u8;
const FnDisposeMessage = *const fn ([*:0]u8) callconv(.c) void;
const FnSetTarget = *const fn (ModuleRef, [*:0]const u8) callconv(.c) void;
const FnSetDataLayout = *const fn (ModuleRef, [*:0]const u8) callconv(.c) void;
const FnInitializeTarget = *const fn () callconv(.c) void;
const FnGetDefaultTargetTriple = *const fn () callconv(.c) [*:0]u8;
const FnGetTargetFromTriple = *const fn ([*:0]const u8, *TargetRef, *Message) callconv(.c) Bool;
const FnCreateTargetMachine = *const fn (TargetRef, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_uint, c_uint, c_uint) callconv(.c) TargetMachineRef;
const FnDisposeTargetMachine = *const fn (TargetMachineRef) callconv(.c) void;
const FnCreateTargetDataLayout = *const fn (TargetMachineRef) callconv(.c) TargetDataRef;
const FnCopyDataLayout = *const fn (TargetDataRef) callconv(.c) [*:0]u8;
const FnDisposeTargetData = *const fn (TargetDataRef) callconv(.c) void;
const FnEmitToFile = *const fn (TargetMachineRef, ModuleRef, [*:0]u8, c_uint, *Message) callconv(.c) Bool;
const FnCreatePassBuilderOptions = *const fn () callconv(.c) PassBuilderOptionsRef;
const FnPassBuilderSetVerifyEach = *const fn (PassBuilderOptionsRef, Bool) callconv(.c) void;
const FnRunPasses = *const fn (ModuleRef, [*:0]const u8, TargetMachineRef, PassBuilderOptionsRef) callconv(.c) ErrorRef;
const FnDisposePassBuilderOptions = *const fn (PassBuilderOptionsRef) callconv(.c) void;
const FnGetErrorMessage = *const fn (ErrorRef) callconv(.c) [*:0]u8;
const FnDisposeErrorMessage = *const fn ([*:0]u8) callconv(.c) void;

pub const Api = struct {
    library: NativeLibrary,
    getVersion: FnGetVersion,
    contextCreate: FnContextCreate,
    contextDispose: FnContextDispose,
    createMemoryBuffer: FnCreateMemoryBuffer,
    parseIr: FnParseIr,
    disposeModule: FnDisposeModule,
    verifyModule: FnVerifyModule,
    printModule: FnPrintModule,
    disposeMessage: FnDisposeMessage,
    setTarget: FnSetTarget,
    setDataLayout: FnSetDataLayout,
    initializeTargetInfo: FnInitializeTarget,
    initializeTarget: FnInitializeTarget,
    initializeTargetMc: FnInitializeTarget,
    initializeAsmPrinter: FnInitializeTarget,
    getDefaultTargetTriple: FnGetDefaultTargetTriple,
    getTargetFromTriple: FnGetTargetFromTriple,
    createTargetMachine: FnCreateTargetMachine,
    disposeTargetMachine: FnDisposeTargetMachine,
    createTargetDataLayout: FnCreateTargetDataLayout,
    copyDataLayout: FnCopyDataLayout,
    disposeTargetData: FnDisposeTargetData,
    emitToFile: FnEmitToFile,
    createPassBuilderOptions: FnCreatePassBuilderOptions,
    passBuilderSetVerifyEach: FnPassBuilderSetVerifyEach,
    runPasses: FnRunPasses,
    disposePassBuilderOptions: FnDisposePassBuilderOptions,
    getErrorMessage: FnGetErrorMessage,
    disposeErrorMessage: FnDisposeErrorMessage,

    pub fn open(allocator: std.mem.Allocator) !Api {
        return openAt(allocator, null, null);
    }

    pub fn openAt(allocator: std.mem.Allocator, llvm_root: ?[]const u8, llvm_library: ?[]const u8) !Api {
        var library = try NativeLibrary.openCandidates(allocator, llvm_root, llvm_library);
        errdefer library.close();
        const target_prefix = switch (builtin.cpu.arch) {
            .aarch64 => "AArch64",
            .x86, .x86_64 => "X86",
            else => return error.UnsupportedHostArchitecture,
        };
        const target_info = try std.fmt.allocPrintSentinel(allocator, "LLVMInitialize{s}TargetInfo", .{target_prefix}, 0);
        defer allocator.free(target_info);
        const target = try std.fmt.allocPrintSentinel(allocator, "LLVMInitialize{s}Target", .{target_prefix}, 0);
        defer allocator.free(target);
        const target_mc = try std.fmt.allocPrintSentinel(allocator, "LLVMInitialize{s}TargetMC", .{target_prefix}, 0);
        defer allocator.free(target_mc);
        const asm_printer = try std.fmt.allocPrintSentinel(allocator, "LLVMInitialize{s}AsmPrinter", .{target_prefix}, 0);
        defer allocator.free(asm_printer);

        var api = Api{
            .library = library,
            .getVersion = try library.require(FnGetVersion, "LLVMGetVersion"),
            .contextCreate = try library.require(FnContextCreate, "LLVMContextCreate"),
            .contextDispose = try library.require(FnContextDispose, "LLVMContextDispose"),
            .createMemoryBuffer = try library.require(FnCreateMemoryBuffer, "LLVMCreateMemoryBufferWithMemoryRangeCopy"),
            .parseIr = try library.require(FnParseIr, "LLVMParseIRInContext"),
            .disposeModule = try library.require(FnDisposeModule, "LLVMDisposeModule"),
            .verifyModule = try library.require(FnVerifyModule, "LLVMVerifyModule"),
            .printModule = try library.require(FnPrintModule, "LLVMPrintModuleToString"),
            .disposeMessage = try library.require(FnDisposeMessage, "LLVMDisposeMessage"),
            .setTarget = try library.require(FnSetTarget, "LLVMSetTarget"),
            .setDataLayout = try library.require(FnSetDataLayout, "LLVMSetDataLayout"),
            .initializeTargetInfo = try library.require(FnInitializeTarget, target_info),
            .initializeTarget = try library.require(FnInitializeTarget, target),
            .initializeTargetMc = try library.require(FnInitializeTarget, target_mc),
            .initializeAsmPrinter = try library.require(FnInitializeTarget, asm_printer),
            .getDefaultTargetTriple = try library.require(FnGetDefaultTargetTriple, "LLVMGetDefaultTargetTriple"),
            .getTargetFromTriple = try library.require(FnGetTargetFromTriple, "LLVMGetTargetFromTriple"),
            .createTargetMachine = try library.require(FnCreateTargetMachine, "LLVMCreateTargetMachine"),
            .disposeTargetMachine = try library.require(FnDisposeTargetMachine, "LLVMDisposeTargetMachine"),
            .createTargetDataLayout = try library.require(FnCreateTargetDataLayout, "LLVMCreateTargetDataLayout"),
            .copyDataLayout = try library.require(FnCopyDataLayout, "LLVMCopyStringRepOfTargetData"),
            .disposeTargetData = try library.require(FnDisposeTargetData, "LLVMDisposeTargetData"),
            .emitToFile = try library.require(FnEmitToFile, "LLVMTargetMachineEmitToFile"),
            .createPassBuilderOptions = try library.require(FnCreatePassBuilderOptions, "LLVMCreatePassBuilderOptions"),
            .passBuilderSetVerifyEach = try library.require(FnPassBuilderSetVerifyEach, "LLVMPassBuilderOptionsSetVerifyEach"),
            .runPasses = try library.require(FnRunPasses, "LLVMRunPasses"),
            .disposePassBuilderOptions = try library.require(FnDisposePassBuilderOptions, "LLVMDisposePassBuilderOptions"),
            .getErrorMessage = try library.require(FnGetErrorMessage, "LLVMGetErrorMessage"),
            .disposeErrorMessage = try library.require(FnDisposeErrorMessage, "LLVMDisposeErrorMessage"),
        };
        var major: c_uint = 0;
        var minor: c_uint = 0;
        var patch: c_uint = 0;
        api.getVersion(&major, &minor, &patch);
        if (major != 22 or minor != 1 or patch != 8) return error.UnsupportedLlvmVersion;
        return api;
    }

    pub fn close(self: *Api) void {
        self.library.close();
        self.* = undefined;
    }
};

const NativeLibrary = if (builtin.os.tag == .windows) WindowsLibrary else PosixLibrary;

const PosixLibrary = struct {
    inner: std.DynLib,

    fn openCandidates(allocator: std.mem.Allocator, llvm_root: ?[]const u8, llvm_library: ?[]const u8) !PosixLibrary {
        if (llvm_library) |path| return .{ .inner = std.DynLib.open(path) catch return error.LlvmLibraryNotFound };
        if (llvm_root) |root| {
            const rooted_candidates: []const []const u8 = switch (builtin.os.tag) {
                .macos => &.{ "lib/libLLVM.dylib", "lib/libLLVM-22.dylib" },
                else => &.{ "lib/libLLVM.so.22.1", "lib/libLLVM.so.22", "lib/libLLVM-22.so", "lib/libLLVM.so" },
            };
            for (rooted_candidates) |relative| {
                const candidate = try std.fs.path.join(allocator, &.{ root, relative });
                defer allocator.free(candidate);
                const inner = std.DynLib.open(candidate) catch continue;
                return .{ .inner = inner };
            }
            return error.LlvmLibraryNotFound;
        }
        const candidates: []const []const u8 = switch (builtin.os.tag) {
            .macos => &.{
                "/opt/homebrew/opt/llvm/lib/libLLVM.dylib",
                "/usr/local/opt/llvm/lib/libLLVM.dylib",
                "libLLVM-22.dylib",
                "libLLVM.dylib",
            },
            else => &.{
                "libLLVM.so.22.1",
                "libLLVM.so.22",
                "libLLVM-22.so",
                "/usr/lib/llvm-22/lib/libLLVM.so",
                "/usr/local/lib/libLLVM.so",
            },
        };
        for (candidates) |candidate| {
            const inner = std.DynLib.open(candidate) catch continue;
            return .{ .inner = inner };
        }
        return error.LlvmLibraryNotFound;
    }

    fn require(self: *PosixLibrary, comptime T: type, name: [:0]const u8) !T {
        return self.inner.lookup(T, name) orelse error.LlvmSymbolNotFound;
    }

    fn close(self: *PosixLibrary) void {
        self.inner.close();
    }
};

const WindowsLibrary = struct {
    handle: *anyopaque,

    fn openCandidates(allocator: std.mem.Allocator, llvm_root: ?[]const u8, llvm_library: ?[]const u8) !WindowsLibrary {
        if (llvm_library) |path| {
            const path_z = try allocator.dupeZ(u8, path);
            defer allocator.free(path_z);
            return .{ .handle = LoadLibraryA(path_z) orelse return error.LlvmLibraryNotFound };
        }
        const candidates = [_][]const u8{ "LLVM-C.dll", "LLVM.dll", "libLLVM.dll" };
        if (llvm_root) |root| {
            for (candidates) |name| {
                const path = try std.fs.path.join(allocator, &.{ root, "bin", name });
                defer allocator.free(path);
                const path_z = try allocator.dupeZ(u8, path);
                defer allocator.free(path_z);
                if (LoadLibraryA(path_z)) |handle| return .{ .handle = handle };
            }
            return error.LlvmLibraryNotFound;
        }
        for (candidates) |candidate| {
            const path = try allocator.dupeZ(u8, candidate);
            defer allocator.free(path);
            if (LoadLibraryA(path)) |handle| return .{ .handle = handle };
        }
        return error.LlvmLibraryNotFound;
    }

    fn require(self: *WindowsLibrary, comptime T: type, name: [:0]const u8) !T {
        const address = GetProcAddress(self.handle, name) orelse return error.LlvmSymbolNotFound;
        return @ptrCast(address);
    }

    fn close(self: *WindowsLibrary) void {
        _ = FreeLibrary(self.handle);
    }

    extern "kernel32" fn LoadLibraryA(path: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.winapi) c_int;
};

test "LLVM 22.1.8のC APIを動的に読み込む" {
    var api = Api.open(std.testing.allocator) catch |failure| switch (failure) {
        error.LlvmLibraryNotFound => return error.SkipZigTest,
        else => return failure,
    };
    defer api.close();
}
