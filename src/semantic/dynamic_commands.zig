const std = @import("std");

/// package経由plugin命令のソース上の修飾aliasと、runtime登録名への写像。
/// ソースは `<source_namespace>__<命令>` で束縛するが、実際のdispatch名は
/// `dispatch_namespace` 側を使う。root scope のimportでは両者が一致し、
/// package内scopeの推移importでは所有者keyを含む修飾名になる。
pub const DynamicCommandAlias = struct {
    /// Source-level alias the user writes (e.g. `util`).
    source_namespace: []const u8,
    /// Runtime dispatch prefix the command was registered under
    /// (e.g. `pkg_a__util` for a transitive dependency of package A).
    dispatch_namespace: []const u8,
};

/// 動的builtinとして束縛する命令名か判定する。直接取り込んだnative plugin
/// （`allows_dynamic_commands`）は任意名を受理し、package経由のnative plugin
/// （`dynamic_command_aliases`）は `<alias>__<命令>` の修飾名のみ受理する。
/// 一致した package alias を返す（dispatch namespace への写像用）。
/// package alias 一致は直接plugin fallbackより先に評価する。両方を取り込んだ
/// moduleで `util__命令` が恒等写像へ先に流れると、依存pluginが登録した
/// `{owner}__util__命令` には届かず、直接pluginの同名raw命令へ誤配送される。
pub fn binds(allows_dynamic_commands: bool, aliases: []const DynamicCommandAlias, name: []const u8) ?DynamicCommandAlias {
    for (aliases) |alias| {
        if (std.mem.startsWith(u8, name, alias.source_namespace) and name.len > alias.source_namespace.len + 2 and
            name[alias.source_namespace.len] == '_' and name[alias.source_namespace.len + 1] == '_') return alias;
    }
    if (allows_dynamic_commands) return .{ .source_namespace = name, .dispatch_namespace = name };
    return null;
}

/// `binds` が受理したソース名を runtime 登録名へ変換する。
/// package内scopeの推移importでは `dispatch_namespace` が所有者修飾を含む
/// （例: `util__足す` → `pkg_a__util__足す`）。root scope は alias がそのまま
/// 登録名なので変換しない。
pub fn dispatchName(allocator: std.mem.Allocator, alias: DynamicCommandAlias, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, alias.dispatch_namespace, alias.source_namespace)) return name;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ alias.dispatch_namespace, name[alias.source_namespace.len..] });
}
