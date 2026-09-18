const std = @import("std");
const source_mod = @import("source.zig");
const token_mod = @import("token.zig");

pub const Severity = enum { error_severity, warning };

pub const Code = enum {
    unexpected_token,
    expected_expression,
    expected_name,
    expected_token,
    missing_block_end,
    invalid_assignment,
    invalid_array_access,
    invalid_function_definition,
    invalid_control_statement,
    duplicate_symbol,
    undefined_symbol,
    invalid_argument_count,
    assign_to_constant,
    invalid_import,
    import_not_found,
    ambiguous_import,
    legacy_deprecated,
};

pub const Diagnostic = struct {
    severity: Severity = .error_severity,
    code: Code,
    message: []const u8,
    file: []const u8,
    span: token_mod.Span,

    /// 公式処理系がエラーとして記録しながら構文解析を継続する診断。
    /// 通常のerror severityとは異なり、これだけではコンパイルを失敗させない。
    pub fn blocksCompilation(self: Diagnostic) bool {
        return self.severity == .error_severity and self.code != .legacy_deprecated;
    }

    pub fn render(self: Diagnostic, source: []const u8, writer: *std.Io.Writer) !void {
        const line = sourceLine(source, self.span.source_start);
        try writer.print("{s}:{d}:{d}: {s}[{s}]: {s}\n", .{
            self.file,
            self.span.line + 1,
            self.span.column,
            if (self.severity == .error_severity) "error" else "warning",
            @tagName(self.code),
            self.message,
        });
        if (line.text.len == 0) return;
        try writer.print("  {s}\n  ", .{line.text});
        var index: usize = 1;
        while (index < self.span.column) : (index += 1) try writer.writeByte(' ');
        try writer.writeAll("^\n");
    }
};

const SourceLine = struct { text: []const u8 };

/// ファイル先頭のUTF-8 BOMは本文ではないため、先頭行の診断表示から除外する。
/// 字句解析の行・列はBOMを除いた本文先頭から数えているので、
/// 表示する行本文も同じ基準に揃えてキャレット位置を一致させる。
fn sourceLine(source: []const u8, offset: usize) SourceLine {
    const safe_offset = @min(offset, source.len);
    var start = safe_offset;
    while (start > 0 and source[start - 1] != '\n' and source[start - 1] != '\r') start -= 1;
    if (start == 0 and std.mem.startsWith(u8, source, source_mod.utf8_bom)) start = source_mod.utf8_bom.len;
    var end = safe_offset;
    while (end < source.len and source[end] != '\n' and source[end] != '\r') end += 1;
    if (end < start) end = start;
    return .{ .text = source[start..end] };
}

test "診断をファイル位置とソース行付きで表示する" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const diagnostic: Diagnostic = .{
        .code = .expected_expression,
        .message = "式が必要です",
        .file = "main.nako3",
        .span = .{ .start = 4, .end = 5, .source_start = 4, .source_end = 5, .line = 1, .column = 3 },
    };
    try diagnostic.render("A=1\nB=\n", &output.writer);
    try std.testing.expectEqualStrings(
        "main.nako3:2:3: error[expected_expression]: 式が必要です\n  B=\n    ^\n",
        output.written(),
    );
}

test "BOM付きソースの先頭行はBOMを除いて表示する" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    const diagnostic: Diagnostic = .{
        .code = .expected_expression,
        .message = "式が必要です",
        .file = "bom.nako3",
        .span = .{ .start = 2, .end = 2, .source_start = 5, .source_end = 5, .line = 0, .column = 3 },
    };
    try diagnostic.render(source_mod.utf8_bom ++ "B=", &output.writer);
    try std.testing.expectEqualStrings(
        "bom.nako3:1:3: error[expected_expression]: 式が必要です\n  B=\n    ^\n",
        output.written(),
    );
}
