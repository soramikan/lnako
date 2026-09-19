const context_mod = @import("../runtime/low_level/context.zig");
const shared = @import("lowlevel/shared.zig");
const call_mod = @import("lowlevel/call.zig");

pub const Value = shared.Value;
pub const Runtime = shared.Runtime;
pub const Dictionary = shared.Dictionary;
pub const State = shared.State;
pub const Effects = shared.Effects;

/// 低レイヤーI/O契約は共通基盤層が所有する。既存のインポート元のため
/// ここから再エクスポートする。
pub const low_level_context = context_mod;
pub const Context = context_mod.Context;
pub const FlatContext = context_mod.FlatContext;
pub const StreamContext = context_mod.StreamContext;
pub const HashContext = context_mod.HashContext;
pub const FsContext = context_mod.FsContext;
pub const StdioContext = context_mod.StdioContext;
pub const emptyContext = context_mod.emptyContext;

/// handle表はプラグイン/ドメインで共有する。既存の外部参照（AOTの
/// dynamic bridge等）があるものだけ再輸出し、公開面を増やさない。
pub const lookupHandle = shared.lookupHandle;
pub const handleForId = shared.handleForId;
pub const rememberHandle = shared.rememberHandle;
pub const forgetHandleId = shared.forgetHandleId;

/// ドメイン委譲型ディスパッチ。カタログ検査とENOTSUPフォールバックは
/// `lowlevel/call.zig` が担う。
pub const call = call_mod.call;

test {
    _ = @import("lowlevel/shared.zig");
    _ = @import("lowlevel/capabilities.zig");
    _ = @import("lowlevel/stream.zig");
    _ = @import("lowlevel/stdio.zig");
    _ = @import("lowlevel/hash.zig");
    _ = @import("lowlevel/fs.zig");
    _ = @import("lowlevel/posix.zig");
    _ = @import("lowlevel/call.zig");
}
