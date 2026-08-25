const std = @import("std");
const token_mod = @import("token.zig");

pub const Severity = enum { error_severity, warning };

pub const Code = enum {
    unexpected_token,
    expected_expression,
    expected_name,
    expected_token,
    missing_block_end,
    invalid_assignment,
    invalid_function_definition,
    invalid_control_statement,
    duplicate_symbol,
    undefined_symbol,
    invalid_argument_count,
    assign_to_constant,
    invalid_import,
    import_not_found,
    ambiguous_import,
};

pub const Diagnostic = struct {
    severity: Severity = .error_severity,
    code: Code,
    message: []const u8,
    file: []const u8,
    span: token_mod.Span,

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

fn sourceLine(source: []const u8, offset: usize) SourceLine {
    const safe_offset = @min(offset, source.len);
    var start = safe_offset;
    while (start > 0 and source[start - 1] != '\n' and source[start - 1] != '\r') start -= 1;
    var end = safe_offset;
    while (end < source.len and source[end] != '\n' and source[end] != '\r') end += 1;
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
