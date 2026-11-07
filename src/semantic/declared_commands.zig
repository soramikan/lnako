//! package の宣言命令 metadata と、package alias 経由の検査で共有する型。
//! plugin を初期化・ロードせずに環境 snapshot から得た静的索引だけを扱う。

const std = @import("std");
const ast = @import("../frontend/ast.zig");

/// package の宣言命令 metadata（`.nako/environment.json` の `commands`）。
/// plugin を初期化・ロードせずに得られる静的索引であり、`available=false` は
/// その package の命令を静的に検査できないことを表す（成功扱いにしない）。
pub const DeclaredCommand = struct {
    name: []const u8,
    /// 仮引数名。`variable` のときは空。
    args: []const []const u8 = &.{},
    /// `args` と対応する助詞。`args` と同数または空。
    josi: []const []const u8 = &.{},
    variable: bool = false,
};

pub const DeclaredCommands = struct {
    /// 環境 snapshot に命令索引が記録されていたか。false は未検査。
    available: bool = false,
    commands: []const DeclaredCommand = &.{},

    pub fn find(self: DeclaredCommands, name: []const u8) ?DeclaredCommand {
        for (self.commands) |command| {
            if (std.mem.eql(u8, command.name, name)) return command;
        }
        return null;
    }
};

/// `pkg:` import が公開する `{alias}__命令` の宣言 metadata。
/// `declared` が null / `available=false` のとき、その alias 経由の呼出しは
/// 未検査として記録し、検査済みとは表示しない。
pub const PackageCommandAlias = struct {
    source_namespace: []const u8,
    import_position: usize = 0,
    declared: ?DeclaredCommands = null,
    /// 解決先の semantic module index（ソース package のみ）。利用者定義の
    /// 同名シンボルを package 宣言と誤照合しないための照合対象。
    target_module: u32 = std.math.maxInt(u32),
};

/// 宣言 metadata が無い package alias 経由で観測した命令呼出し。
pub const UninspectedPackageCommand = struct {
    namespace: []const u8,
    command_name: []const u8,
    file: []const u8,
    span: ast.Span,
};
