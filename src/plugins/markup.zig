const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const source = common.argument(arguments, 0);
    if (!std.mem.eql(u8, name, "マークダウンHTML変換") and !std.mem.eql(u8, name, "HTML整形")) return null;
    const utf8 = try common.toUtf8Alloc(runtime, source);
    defer runtime.allocator().free(utf8);
    const output = if (std.mem.eql(u8, name, "マークダウンHTML変換"))
        try markdown(runtime.allocator(), utf8)
    else
        try prettyHtml(runtime.allocator(), utf8);
    defer runtime.allocator().free(output);
    return @as(?Value, try runtime.stringUtf8(output));
}

pub fn markdownUtf8(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return markdown(allocator, source);
}

pub fn prettyHtmlUtf8(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    return prettyHtml(allocator, source);
}

fn markdown(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const normalized = try normalizeNewlines(allocator, source);
    defer allocator.free(normalized);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var iterator = std.mem.splitScalar(u8, normalized, '\n');
    while (iterator.next()) |line| try lines.append(allocator, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0 and normalized.len > 0 and normalized[normalized.len - 1] == '\n') _ = lines.pop();
    var definitions: std.ArrayList(Definition) = .empty;
    defer definitions.deinit(allocator);
    var content_lines: std.ArrayList([]const u8) = .empty;
    defer content_lines.deinit(allocator);
    var active_fence: ?Fence = null;
    for (lines.items) |line| {
        if (active_fence) |fence| {
            try content_lines.append(allocator, line);
            if (fenceEnd(line, fence)) active_fence = null;
            continue;
        }
        if (fenceStart(line)) |fence| {
            active_fence = fence;
            try content_lines.append(allocator, line);
            continue;
        }
        if (definition(line)) |item| {
            try definitions.append(allocator, item);
        } else try content_lines.append(allocator, line);
    }
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try renderBlocks(allocator, content_lines.items, definitions.items, &output.writer);
    return output.toOwnedSlice();
}

const Definition = struct { label: []const u8, destination: []const u8, title: ?[]const u8 };

fn definition(line: []const u8) ?Definition {
    const source = std.mem.trim(u8, line, " \t");
    if (source.len < 4 or source[0] != '[') return null;
    const label_end = std.mem.indexOfScalar(u8, source, ']') orelse return null;
    if (label_end == 1 or label_end + 1 >= source.len or source[label_end + 1] != ':') return null;
    var rest = std.mem.trim(u8, source[label_end + 2 ..], " \t");
    if (rest.len == 0) return null;
    var destination: []const u8 = undefined;
    if (rest[0] == '<') {
        const close = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        destination = rest[1..close];
        rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
    } else {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        destination = rest[0..end];
        rest = std.mem.trim(u8, rest[end..], " \t");
    }
    var title: ?[]const u8 = null;
    if (rest.len > 0 and ((rest[0] == '"' and rest[rest.len - 1] == '"') or (rest[0] == '\'' and rest[rest.len - 1] == '\''))) title = rest[1 .. rest.len - 1] else if (rest.len > 0) return null;
    return .{ .label = source[1..label_end], .destination = destination, .title = title };
}

fn renderBlocks(allocator: std.mem.Allocator, lines: []const []const u8, definitions: []const Definition, output: *std.Io.Writer) !void {
    var index: usize = 0;
    while (index < lines.len) {
        const line = lines[index];
        if (std.mem.trim(u8, line, " \t").len == 0) {
            index += 1;
            continue;
        }
        if (fenceStart(line)) |fence| {
            var end = index + 1;
            while (end < lines.len and !fenceEnd(lines[end], fence)) end += 1;
            try output.writeAll("<pre><code");
            const info = std.mem.trim(u8, line[fence.info_start..], " \t");
            if (info.len > 0) {
                const language = info[0 .. std.mem.indexOfAny(u8, info, " \t") orelse info.len];
                try output.writeAll(" class=\"language-");
                try escapeAttribute(output, language);
                try output.writeAll("\"");
            }
            try output.writeByte('>');
            for (lines[index + 1 .. end], 0..) |code_line, line_index| {
                if (line_index > 0) try output.writeByte('\n');
                try escapeHtml(output, code_line, false);
            }
            if (end > index + 1) try output.writeByte('\n');
            try output.writeAll("</code></pre>\n");
            index = if (end < lines.len) end + 1 else end;
            continue;
        }
        if (heading(line)) |heading_info| {
            try output.print("<h{d}>", .{heading_info.level});
            try renderInline(allocator, heading_info.text, definitions, output);
            try output.print("</h{d}>\n", .{heading_info.level});
            index += 1;
            continue;
        }
        if (index + 1 < lines.len) if (setextLevel(lines[index + 1])) |level| {
            try output.print("<h{d}>", .{level});
            try renderInline(allocator, std.mem.trim(u8, line, " \t"), definitions, output);
            try output.print("</h{d}>\n", .{level});
            index += 2;
            continue;
        };
        if (isHorizontalRule(line)) {
            try output.writeAll("<hr>\n");
            index += 1;
            continue;
        }
        if (blockquoteLine(line) != null) {
            var nested: std.ArrayList([]const u8) = .empty;
            defer nested.deinit(allocator);
            while (index < lines.len) : (index += 1) {
                if (blockquoteLine(lines[index])) |content| {
                    try nested.append(allocator, content);
                } else if (std.mem.trim(u8, lines[index], " \t").len == 0) {
                    try nested.append(allocator, "");
                } else break;
            }
            try output.writeAll("<blockquote>\n");
            try renderBlocks(allocator, nested.items, definitions, output);
            try output.writeAll("</blockquote>\n");
            continue;
        }
        if (index + 1 < lines.len) {
            if (tableDelimiter(allocator, lines[index + 1])) |alignments| {
                defer allocator.free(alignments);
                const headers = try splitTableRow(allocator, line);
                defer freeSlices(allocator, headers);
                if (headers.len == alignments.len) {
                    try output.writeAll("<table>\n<thead>\n<tr>\n");
                    for (headers, alignments) |cell, alignment| {
                        try output.writeAll("<th");
                        try writeAlignment(output, alignment);
                        try output.writeByte('>');
                        try renderInline(allocator, cell, definitions, output);
                        try output.writeAll("</th>\n");
                    }
                    try output.writeAll("</tr>\n</thead>\n");
                    index += 2;
                    var wrote_body = false;
                    while (index < lines.len and std.mem.indexOfScalar(u8, lines[index], '|') != null and std.mem.trim(u8, lines[index], " \t").len > 0) : (index += 1) {
                        const cells = try splitTableRow(allocator, lines[index]);
                        defer freeSlices(allocator, cells);
                        if (!wrote_body) try output.writeAll("<tbody>");
                        try output.writeAll("<tr>\n");
                        for (alignments, 0..) |alignment, cell_index| {
                            try output.writeAll("<td");
                            try writeAlignment(output, alignment);
                            try output.writeByte('>');
                            if (cell_index < cells.len) try renderInline(allocator, cells[cell_index], definitions, output);
                            try output.writeAll("</td>\n");
                        }
                        try output.writeAll("</tr>\n");
                        wrote_body = true;
                    }
                    if (wrote_body) try output.writeAll("</tbody>");
                    try output.writeAll("</table>\n");
                    continue;
                }
            }
        }
        if (listMarker(line)) |marker| {
            index = try renderList(allocator, lines, index, marker, definitions, output);
            continue;
        }
        if (isIndentedCode(line)) {
            try output.writeAll("<pre><code>");
            var first = true;
            while (index < lines.len and (isIndentedCode(lines[index]) or lines[index].len == 0)) : (index += 1) {
                if (!first) try output.writeByte('\n');
                const code_line = if (lines[index].len >= 4) lines[index][4..] else "";
                try escapeHtml(output, code_line, false);
                first = false;
            }
            try output.writeAll("\n</code></pre>\n");
            continue;
        }
        if (isRawHtmlBlock(line)) {
            var first = true;
            while (index < lines.len and std.mem.trim(u8, lines[index], " \t").len > 0) : (index += 1) {
                if (!first) try output.writeByte('\n');
                try output.writeAll(lines[index]);
                first = false;
            }
            continue;
        }

        var paragraph: std.ArrayList([]const u8) = .empty;
        defer paragraph.deinit(allocator);
        while (index < lines.len and std.mem.trim(u8, lines[index], " \t").len > 0) {
            if (paragraph.items.len > 0 and isBlockStart(lines, index)) break;
            try paragraph.append(allocator, std.mem.trim(u8, lines[index], "\t"));
            index += 1;
        }
        try output.writeAll("<p>");
        for (paragraph.items, 0..) |paragraph_line, line_index| {
            const space_break = line_index + 1 < paragraph.items.len and std.mem.endsWith(u8, paragraph_line, "  ");
            const slash_break = line_index + 1 < paragraph.items.len and std.mem.endsWith(u8, paragraph_line, "\\");
            const rendered_line = if (space_break) std.mem.trimEnd(u8, paragraph_line, " ") else if (slash_break) paragraph_line[0 .. paragraph_line.len - 1] else paragraph_line;
            try renderInline(allocator, rendered_line, definitions, output);
            if (line_index + 1 < paragraph.items.len) try output.writeAll(if (space_break or slash_break) "<br>" else "\n");
        }
        try output.writeAll("</p>\n");
    }
}

const Fence = struct { marker: u8, count: usize, info_start: usize };
fn fenceStart(line: []const u8) ?Fence {
    var index: usize = 0;
    while (index < line.len and index < 3 and line[index] == ' ') index += 1;
    if (index >= line.len or (line[index] != '`' and line[index] != '~')) return null;
    const marker = line[index];
    const start = index;
    while (index < line.len and line[index] == marker) index += 1;
    if (index - start < 3) return null;
    return .{ .marker = marker, .count = index - start, .info_start = index };
}

fn fenceEnd(line: []const u8, fence: Fence) bool {
    var index: usize = 0;
    while (index < line.len and index < 3 and line[index] == ' ') index += 1;
    const start = index;
    while (index < line.len and line[index] == fence.marker) index += 1;
    return index - start >= fence.count and std.mem.trim(u8, line[index..], " \t").len == 0;
}

const Heading = struct { level: usize, text: []const u8 };
fn heading(line: []const u8) ?Heading {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed.len > 3) return null;
    var level: usize = 0;
    while (level < trimmed.len and level < 6 and trimmed[level] == '#') level += 1;
    if (level == 0 or (level < trimmed.len and trimmed[level] != ' ' and trimmed[level] != '\t')) return null;
    var text = std.mem.trim(u8, trimmed[level..], " \t");
    var end = text.len;
    while (end > 0 and text[end - 1] == '#') end -= 1;
    if (end < text.len and (end == 0 or text[end - 1] == ' ' or text[end - 1] == '\t')) text = std.mem.trimEnd(u8, text[0..end], " \t");
    return .{ .level = level, .text = text };
}

fn setextLevel(line: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or (trimmed[0] != '=' and trimmed[0] != '-')) return null;
    for (trimmed) |byte| if (byte != trimmed[0]) return null;
    return if (trimmed[0] == '=') 1 else 2;
}

fn isHorizontalRule(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3 or (trimmed[0] != '-' and trimmed[0] != '*' and trimmed[0] != '_')) return false;
    var count: usize = 0;
    for (trimmed) |byte| {
        if (byte == trimmed[0]) count += 1 else if (byte != ' ' and byte != '\t') return false;
    }
    return count >= 3;
}

fn blockquoteLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (line.len - trimmed.len > 3 or trimmed.len == 0 or trimmed[0] != '>') return null;
    return if (trimmed.len > 1 and trimmed[1] == ' ') trimmed[2..] else trimmed[1..];
}

const Alignment = enum { none, left, center, right };
fn tableDelimiter(allocator: std.mem.Allocator, line: []const u8) ?[]Alignment {
    const cells = splitTableRow(allocator, line) catch return null;
    defer freeSlices(allocator, cells);
    if (cells.len == 0) return null;
    const result = allocator.alloc(Alignment, cells.len) catch return null;
    for (cells, result) |cell, *alignment| {
        const trimmed = std.mem.trim(u8, cell, " \t");
        const left = trimmed.len > 0 and trimmed[0] == ':';
        const right = trimmed.len > 0 and trimmed[trimmed.len - 1] == ':';
        const body = std.mem.trim(u8, trimmed, ":");
        if (body.len < 1) {
            allocator.free(result);
            return null;
        }
        for (body) |byte| if (byte != '-') {
            allocator.free(result);
            return null;
        };
        alignment.* = if (left and right) .center else if (left) .left else if (right) .right else .none;
    }
    return result;
}

fn splitTableRow(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var source = std.mem.trim(u8, line, " \t");
    if (source.len > 0 and source[0] == '|') source = source[1..];
    if (source.len > 0 and source[source.len - 1] == '|') source = source[0 .. source.len - 1];
    var result: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (result.items) |cell| allocator.free(cell);
        result.deinit(allocator);
    }
    var start: usize = 0;
    var index: usize = 0;
    while (index <= source.len) : (index += 1) {
        if (index < source.len and (source[index] != '|' or (index > 0 and source[index - 1] == '\\'))) continue;
        const cell = try allocator.dupe(u8, std.mem.trim(u8, source[start..index], " \t"));
        result.append(allocator, cell) catch |err| {
            allocator.free(cell);
            return err;
        };
        start = index + 1;
    }
    return result.toOwnedSlice(allocator);
}

fn freeSlices(allocator: std.mem.Allocator, slices: []const []const u8) void {
    for (slices) |slice| allocator.free(slice);
    allocator.free(slices);
}

fn writeAlignment(output: *std.Io.Writer, alignment: Alignment) !void {
    switch (alignment) {
        .none => {},
        else => try output.print(" align=\"{s}\"", .{@tagName(alignment)}),
    }
}

const ListMarker = struct { ordered: bool, start: usize, indent: usize, content_start: usize };
fn listMarker(line: []const u8) ?ListMarker {
    return listMarkerWithLimit(line, 3);
}

fn listMarkerAnyIndent(line: []const u8) ?ListMarker {
    return listMarkerWithLimit(line, null);
}

fn listMarkerWithLimit(line: []const u8, maximum_indent: ?usize) ?ListMarker {
    var index: usize = 0;
    while (index < line.len and line[index] == ' ') index += 1;
    if ((maximum_indent != null and index > maximum_indent.?) or index == line.len) return null;
    const indent = index;
    if (line[index] == '-' or line[index] == '+' or line[index] == '*') {
        if (index + 1 >= line.len or (line[index + 1] != ' ' and line[index + 1] != '\t')) return null;
        index += 2;
        while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
        return .{ .ordered = false, .start = 1, .indent = indent, .content_start = index };
    }
    const digit_start = index;
    while (index < line.len and std.ascii.isDigit(line[index]) and index - digit_start < 9) index += 1;
    if (index == digit_start or index >= line.len or (line[index] != '.' and line[index] != ')')) return null;
    const number = std.fmt.parseInt(usize, line[digit_start..index], 10) catch return null;
    index += 1;
    if (index >= line.len or (line[index] != ' ' and line[index] != '\t')) return null;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) index += 1;
    return .{ .ordered = true, .start = number, .indent = indent, .content_start = index };
}

fn renderList(allocator: std.mem.Allocator, lines: []const []const u8, start_index: usize, first_marker: ListMarker, definitions: []const Definition, output: *std.Io.Writer) !usize {
    const loose = listIsLoose(lines, start_index, first_marker);
    try output.writeAll(if (first_marker.ordered) "<ol" else "<ul");
    if (first_marker.ordered and first_marker.start != 1) try output.print(" start=\"{d}\"", .{first_marker.start});
    try output.writeAll(">\n");
    var index = start_index;
    while (index < lines.len) {
        const marker = listMarkerAnyIndent(lines[index]) orelse break;
        if (marker.indent != first_marker.indent or marker.ordered != first_marker.ordered) break;
        var content = lines[index][marker.content_start..];
        try output.writeAll("<li>");
        if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
            try output.writeAll("<input checked=\"\" disabled=\"\" type=\"checkbox\"> ");
            content = content[4..];
        } else if (std.mem.startsWith(u8, content, "[ ] ")) {
            try output.writeAll("<input disabled=\"\" type=\"checkbox\"> ");
            content = content[4..];
        }
        if (loose) try output.writeAll("<p>");
        var paragraph_open = loose;
        try renderInline(allocator, content, definitions, output);
        index += 1;
        while (index < lines.len) {
            if (listMarkerAnyIndent(lines[index])) |next_marker| {
                if (next_marker.indent > first_marker.indent) {
                    if (paragraph_open) {
                        try output.writeAll("</p>\n");
                        paragraph_open = false;
                    } else if (std.mem.trim(u8, lines[index - 1], " \t").len == 0) try output.writeByte('\n');
                    index = try renderList(allocator, lines, index, next_marker, definitions, output);
                }
                break;
            }
            if (std.mem.trim(u8, lines[index], " \t").len == 0) {
                index += 1;
                break;
            }
            const continuation = std.mem.trimStart(u8, lines[index], " \t");
            try output.writeByte('\n');
            try renderInline(allocator, continuation, definitions, output);
            index += 1;
        }
        if (paragraph_open) try output.writeAll("</p>\n");
        try output.writeAll("</li>\n");
    }
    try output.writeAll(if (first_marker.ordered) "</ol>\n" else "</ul>\n");
    return index;
}

fn listIsLoose(lines: []const []const u8, start_index: usize, first_marker: ListMarker) bool {
    var index = start_index + 1;
    while (index + 1 < lines.len) : (index += 1) {
        if (std.mem.trim(u8, lines[index], " \t").len != 0) continue;
        var next = index + 1;
        while (next < lines.len and std.mem.trim(u8, lines[next], " \t").len == 0) : (next += 1) {}
        if (next >= lines.len) return false;
        const marker = listMarkerAnyIndent(lines[next]) orelse return false;
        if (marker.indent == first_marker.indent and marker.ordered == first_marker.ordered) return true;
    }
    return false;
}

fn renderInline(allocator: std.mem.Allocator, source: []const u8, definitions: []const Definition, output: *std.Io.Writer) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (source[index] == '\\' and index + 1 < source.len and std.mem.indexOfScalar(u8, "\\`*{}[]()#+-.!_>|", source[index + 1]) != null) {
            try escapeHtml(output, source[index + 1 .. index + 2], true);
            index += 2;
            continue;
        }
        if (source[index] == '`') if (codeSpan(source, index)) |part| {
            try output.writeAll("<code>");
            var code = part.content;
            if (code.len >= 2 and code[0] == ' ' and code[code.len - 1] == ' ' and std.mem.trim(u8, code, " ").len > 0) code = code[1 .. code.len - 1];
            for (code) |byte| switch (byte) {
                '\n' => try output.writeByte(' '),
                '&' => try output.writeAll("&amp;"),
                '<' => try output.writeAll("&lt;"),
                '>' => try output.writeAll("&gt;"),
                else => try output.writeByte(byte),
            };
            try output.writeAll("</code>");
            index = part.end;
            continue;
        };
        if (std.mem.startsWith(u8, source[index..], "![")) if (linkPart(source, index, true)) |part| {
            try output.writeAll("<img src=\"");
            try escapeAttribute(output, part.destination);
            try output.writeAll("\" alt=\"");
            try escapeAttribute(output, part.label);
            try output.writeByte('"');
            if (part.title) |title| {
                try output.writeAll(" title=\"");
                try escapeAttribute(output, title);
                try output.writeByte('"');
            }
            try output.writeByte('>');
            index = part.end;
            continue;
        };
        if (source[index] == '[') if (linkPart(source, index, false)) |part| {
            try output.writeAll("<a href=\"");
            try escapeAttribute(output, part.destination);
            try output.writeByte('"');
            if (part.title) |title| {
                try output.writeAll(" title=\"");
                try escapeAttribute(output, title);
                try output.writeByte('"');
            }
            try output.writeByte('>');
            try renderInline(allocator, part.label, definitions, output);
            try output.writeAll("</a>");
            index = part.end;
            continue;
        };
        if (source[index] == '[') if (referenceLinkPart(source, index, definitions)) |part| {
            try output.writeAll("<a href=\"");
            try escapeAttribute(output, part.destination);
            try output.writeByte('"');
            if (part.title) |title| {
                try output.writeAll(" title=\"");
                try escapeAttribute(output, title);
                try output.writeByte('"');
            }
            try output.writeByte('>');
            try renderInline(allocator, part.label, definitions, output);
            try output.writeAll("</a>");
            index = part.end;
            continue;
        };
        const formats = [_]struct { marker: []const u8, open: []const u8, close: []const u8 }{
            .{ .marker = "***", .open = "<em><strong>", .close = "</strong></em>" },
            .{ .marker = "___", .open = "<em><strong>", .close = "</strong></em>" },
            .{ .marker = "**", .open = "<strong>", .close = "</strong>" },
            .{ .marker = "__", .open = "<strong>", .close = "</strong>" },
            .{ .marker = "~~", .open = "<del>", .close = "</del>" },
            .{ .marker = "*", .open = "<em>", .close = "</em>" },
            .{ .marker = "_", .open = "<em>", .close = "</em>" },
        };
        var formatted = false;
        for (formats) |format| {
            if (!std.mem.startsWith(u8, source[index..], format.marker)) continue;
            if (delimited(source, index, format.marker)) |part| {
                try output.writeAll(format.open);
                try renderInline(allocator, part.content, definitions, output);
                try output.writeAll(format.close);
                index = part.end;
                formatted = true;
                break;
            }
        }
        if (formatted) continue;
        if (isEmailStart(source, index)) if (bareEmailEnd(source, index)) |end| {
            const address = source[index..end];
            try output.writeAll("<a href=\"mailto:");
            try escapeAttribute(output, address);
            try output.writeAll("\">");
            try escapeHtml(output, address, true);
            try output.writeAll("</a>");
            index = end;
            continue;
        };
        if (source[index] == '<') {
            const close = std.mem.indexOfScalarPos(u8, source, index + 1, '>');
            if (close) |end| {
                const inside = source[index + 1 .. end];
                if (std.mem.startsWith(u8, inside, "http://") or std.mem.startsWith(u8, inside, "https://")) {
                    try output.writeAll("<a href=\"");
                    try escapeAttribute(output, inside);
                    try output.writeAll("\">");
                    try escapeHtml(output, inside, true);
                    try output.writeAll("</a>");
                    index = end + 1;
                    continue;
                }
                if (looksLikeEmail(inside)) {
                    try output.writeAll("<a href=\"mailto:");
                    try escapeAttribute(output, inside);
                    try output.writeAll("\">");
                    try escapeHtml(output, inside, true);
                    try output.writeAll("</a>");
                    index = end + 1;
                    continue;
                }
                if (looksLikeHtmlTag(inside)) {
                    try output.writeAll(source[index .. end + 1]);
                    index = end + 1;
                    continue;
                }
            }
        }
        if ((std.mem.startsWith(u8, source[index..], "http://") or std.mem.startsWith(u8, source[index..], "https://") or std.mem.startsWith(u8, source[index..], "www.")) and (index == 0 or std.ascii.isWhitespace(source[index - 1]))) {
            var end = index;
            while (end < source.len and !std.ascii.isWhitespace(source[end]) and source[end] != '<') end += 1;
            while (end > index and std.mem.indexOfScalar(u8, ".,!?;:)", source[end - 1]) != null) end -= 1;
            const label = source[index..end];
            try output.writeAll("<a href=\"");
            if (std.mem.startsWith(u8, label, "www.")) try output.writeAll("http://");
            try escapeAttribute(output, label);
            try output.writeAll("\">");
            try escapeHtml(output, label, true);
            try output.writeAll("</a>");
            index = end;
            continue;
        }
        if (source[index] == ' ') {
            var end = index;
            while (end < source.len and source[end] == ' ') end += 1;
            if (end < source.len and source[end] == '\n' and end - index >= 2) {
                try output.writeAll("<br>");
                index = end + 1;
                continue;
            }
        }
        if (source[index] == '&') if (entityLength(source[index..])) |length| {
            try output.writeAll(source[index .. index + length]);
            index += length;
            continue;
        };
        switch (source[index]) {
            '&' => try output.writeAll("&amp;"),
            '<' => try output.writeAll("&lt;"),
            '>' => try output.writeAll("&gt;"),
            '"' => try output.writeAll("&quot;"),
            else => try output.writeByte(source[index]),
        }
        index += 1;
    }
}

const Delimited = struct { content: []const u8, end: usize };
fn codeSpan(source: []const u8, start: usize) ?Delimited {
    var marker_end = start;
    while (marker_end < source.len and source[marker_end] == '`') marker_end += 1;
    const marker_len = marker_end - start;
    var index = marker_end;
    while (index < source.len) {
        if (source[index] != '`') {
            index += 1;
            continue;
        }
        var end = index;
        while (end < source.len and source[end] == '`') end += 1;
        if (end - index == marker_len) return .{ .content = source[marker_end..index], .end = end };
        index = end;
    }
    return null;
}

fn delimited(source: []const u8, start: usize, marker: []const u8) ?Delimited {
    const content_start = start + marker.len;
    if (content_start >= source.len or std.ascii.isWhitespace(source[content_start])) return null;
    if (marker[0] == '_' and start > 0 and std.ascii.isAlphanumeric(source[start - 1]) and std.ascii.isAlphanumeric(source[content_start])) return null;
    var search = content_start;
    while (std.mem.indexOfPos(u8, source, search, marker)) |relative| {
        if (relative > content_start and !std.ascii.isWhitespace(source[relative - 1])) {
            if (marker[0] != '_' or relative + marker.len >= source.len or !std.ascii.isAlphanumeric(source[relative - 1]) or !std.ascii.isAlphanumeric(source[relative + marker.len])) return .{ .content = source[content_start..relative], .end = relative + marker.len };
        }
        search = relative + marker.len;
    }
    return null;
}

const LinkPart = struct { label: []const u8, destination: []const u8, title: ?[]const u8, end: usize };
fn linkPart(source: []const u8, start: usize, image: bool) ?LinkPart {
    const label_start = start + @as(usize, if (image) 2 else 1);
    const label_end = std.mem.indexOfScalarPos(u8, source, label_start, ']') orelse return null;
    if (label_end + 1 >= source.len or source[label_end + 1] != '(') return null;
    const close = matchingLinkParen(source, label_end + 1) orelse return null;
    var inside = std.mem.trim(u8, source[label_end + 2 .. close], " \t");
    var title: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, inside, '"')) |quote_end| if (quote_end > 0) {
        if (std.mem.lastIndexOfScalar(u8, inside[0..quote_end], '"')) |quote_start| {
            title = inside[quote_start + 1 .. quote_end];
            inside = std.mem.trimEnd(u8, inside[0..quote_start], " \t");
        }
    };
    if (inside.len >= 2 and inside[0] == '<' and inside[inside.len - 1] == '>') inside = inside[1 .. inside.len - 1];
    return .{ .label = source[label_start..label_end], .destination = inside, .title = title, .end = close + 1 };
}

fn matchingLinkParen(source: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var index = open;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\\') {
            index += 1;
            continue;
        }
        if (source[index] == '(') depth += 1 else if (source[index] == ')') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return null;
}

fn referenceLinkPart(source: []const u8, start: usize, definitions: []const Definition) ?LinkPart {
    const label_end = std.mem.indexOfScalarPos(u8, source, start + 1, ']') orelse return null;
    const label = source[start + 1 .. label_end];
    var reference = label;
    var end = label_end + 1;
    if (end < source.len and source[end] == '[') {
        const reference_end = std.mem.indexOfScalarPos(u8, source, end + 1, ']') orelse return null;
        if (reference_end > end + 1) reference = source[end + 1 .. reference_end];
        end = reference_end + 1;
    }
    for (definitions) |item| if (labelsEqual(reference, item.label)) return .{
        .label = label,
        .destination = item.destination,
        .title = item.title,
        .end = end,
    };
    return null;
}

fn labelsEqual(left_raw: []const u8, right_raw: []const u8) bool {
    const left = std.mem.trim(u8, left_raw, " \t\r\n");
    const right = std.mem.trim(u8, right_raw, " \t\r\n");
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        const left_space = std.ascii.isWhitespace(left[left_index]);
        const right_space = std.ascii.isWhitespace(right[right_index]);
        if (left_space or right_space) {
            if (left_space != right_space) return false;
            while (left_index < left.len and std.ascii.isWhitespace(left[left_index])) left_index += 1;
            while (right_index < right.len and std.ascii.isWhitespace(right[right_index])) right_index += 1;
            continue;
        }
        if (std.ascii.toLower(left[left_index]) != std.ascii.toLower(right[right_index])) return false;
        left_index += 1;
        right_index += 1;
    }
    return left_index == left.len and right_index == right.len;
}

fn isEmailStart(source: []const u8, index: usize) bool {
    if (!std.ascii.isAlphanumeric(source[index])) return false;
    return index == 0 or (!std.ascii.isAlphanumeric(source[index - 1]) and std.mem.indexOfScalar(u8, "._+-", source[index - 1]) == null);
}

fn bareEmailEnd(source: []const u8, start: usize) ?usize {
    var index = start;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or std.mem.indexOfScalar(u8, "._+-", source[index]) != null)) index += 1;
    if (index == start or index >= source.len or source[index] != '@') return null;
    index += 1;
    const domain_start = index;
    var dot = false;
    while (index < source.len and (std.ascii.isAlphanumeric(source[index]) or source[index] == '.' or source[index] == '-')) : (index += 1) {
        if (source[index] == '.') dot = true;
    }
    while (index > domain_start and (source[index - 1] == '.' or source[index - 1] == '-')) index -= 1;
    return if (dot and index > domain_start) index else null;
}

fn entityLength(source: []const u8) ?usize {
    if (source.len < 3 or source[0] != '&') return null;
    const semicolon = std.mem.indexOfScalar(u8, source[1..@min(source.len, 34)], ';') orelse return null;
    const body = source[1 .. semicolon + 1];
    if (body.len == 0) return null;
    if (body[0] == '#') {
        const digits = if (body.len > 1 and (body[1] == 'x' or body[1] == 'X')) body[2..] else body[1..];
        if (digits.len == 0) return null;
        for (digits) |byte| if (!std.ascii.isHex(byte)) return null;
    } else for (body) |byte| if (!std.ascii.isAlphanumeric(byte)) return null;
    return semicolon + 2;
}

fn looksLikeEmail(source: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, source, '@') orelse return false;
    return at > 0 and at + 1 < source.len and std.mem.indexOfScalar(u8, source[at + 1 ..], '.') != null;
}

fn looksLikeHtmlTag(source: []const u8) bool {
    if (source.len == 0) return false;
    return std.ascii.isAlphabetic(source[0]) or source[0] == '/' or source[0] == '!' or source[0] == '?';
}

fn isBlockStart(lines: []const []const u8, index: usize) bool {
    const line = lines[index];
    return fenceStart(line) != null or heading(line) != null or isHorizontalRule(line) or blockquoteLine(line) != null or listMarker(line) != null or isRawHtmlBlock(line) or (index + 1 < lines.len and (setextLevel(lines[index + 1]) != null or isTableDelimiter(lines[index + 1])));
}

fn isTableDelimiter(line: []const u8) bool {
    const alignments = tableDelimiter(std.heap.page_allocator, line) orelse return false;
    std.heap.page_allocator.free(alignments);
    return true;
}

fn isIndentedCode(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t");
}

fn isRawHtmlBlock(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const tags = [_][]const u8{ "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul" };
    if (std.mem.startsWith(u8, trimmed, "<!--") or std.mem.startsWith(u8, trimmed, "<!DOCTYPE") or std.mem.startsWith(u8, trimmed, "<?")) return true;
    if (trimmed.len < 3 or trimmed[0] != '<') return false;
    var name = trimmed[1..];
    if (name[0] == '/') name = name[1..];
    for (tags) |tag| if (name.len >= tag.len and std.ascii.eqlIgnoreCase(name[0..tag.len], tag) and (name.len == tag.len or name[tag.len] == ' ' or name[tag.len] == '>' or name[tag.len] == '/')) return true;
    return false;
}

fn prettyHtml(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var formatter = HtmlFormatter{ .allocator = allocator, .source = source };
    defer formatter.deinit();
    try formatter.run();
    return formatter.output.toOwnedSlice(allocator);
}

const HtmlFormatter = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    output: std.ArrayList(u8) = .empty,
    stack: std.ArrayList([]u8) = .empty,
    index: usize = 0,
    indent: usize = 0,
    last: enum { none, start, end, single, content } = .none,
    last_content_empty: bool = true,

    fn deinit(self: *HtmlFormatter) void {
        self.output.deinit(self.allocator);
        for (self.stack.items) |name| self.allocator.free(name);
        self.stack.deinit(self.allocator);
    }

    fn run(self: *HtmlFormatter) !void {
        while (self.index < self.source.len) {
            if (self.source[self.index] != '<') {
                try self.content();
                continue;
            }
            try self.tag();
        }
    }

    fn content(self: *HtmlFormatter) !void {
        const end = std.mem.indexOfScalarPos(u8, self.source, self.index, '<') orelse self.source.len;
        const source = self.source[self.index..end];
        var wrote = false;
        var pending_space = false;
        for (source) |byte| {
            if (std.ascii.isWhitespace(byte)) {
                if (wrote) pending_space = true;
                continue;
            }
            if (pending_space) try self.output.append(self.allocator, ' ');
            pending_space = false;
            try self.output.append(self.allocator, byte);
            wrote = true;
        }
        if (pending_space and wrote and end + 1 < self.source.len and self.source[end] == '<' and self.source[end + 1] != '/') try self.output.append(self.allocator, ' ');
        self.last = .content;
        self.last_content_empty = !wrote;
        self.index = end;
    }

    fn tag(self: *HtmlFormatter) !void {
        const tag_end = findTagEnd(self.source, self.index) orelse self.source.len - 1;
        const raw = self.source[self.index .. tag_end + 1];
        const normalized = try normalizeTag(self.allocator, raw);
        defer self.allocator.free(normalized);
        const info = tagInfo(normalized);
        if (!info.closing and (std.ascii.eqlIgnoreCase(info.name, "script") or std.ascii.eqlIgnoreCase(info.name, "style"))) {
            if (findClosingTagRange(self.source, tag_end + 1, info.name)) |closing| {
                try self.newline(false);
                try self.output.appendSlice(self.allocator, normalized);
                const owned_name = try self.allocator.dupe(u8, info.name);
                errdefer self.allocator.free(owned_name);
                try self.stack.append(self.allocator, owned_name);
                const body = std.mem.trim(u8, self.source[tag_end + 1 .. closing.start], " \t\r\n");
                if (body.len > 0) {
                    try self.output.append(self.allocator, '\n');
                    try self.output.appendNTimes(self.allocator, ' ', (self.indent + 1) * 2);
                    for (body, 0..) |byte, body_index| {
                        try self.output.append(self.allocator, byte);
                        if (byte == '\n' and body_index + 1 < body.len) try self.output.appendNTimes(self.allocator, ' ', (self.indent + 1) * 2);
                    }
                    while (self.output.items.len > 0 and std.ascii.isWhitespace(self.output.items[self.output.items.len - 1])) _ = self.output.pop();
                    try self.output.append(self.allocator, '\n');
                    try self.output.appendNTimes(self.allocator, ' ', self.indent * 2);
                }
                try self.output.appendSlice(self.allocator, self.source[closing.start..closing.end]);
                self.allocator.free(self.stack.pop().?);
                self.last = .end;
                self.last_content_empty = true;
                self.index = closing.end;
                return;
            }
        }
        if (!info.closing and isUnformatted(info.name)) if (findClosingTag(self.source, tag_end + 1, info.name)) |close_end| {
            const full = self.source[self.index..close_end];
            if (!handlerTreatsUnformatted(info.name)) try self.newline(false);
            try self.output.appendSlice(self.allocator, full);
            self.last = .single;
            self.index = close_end;
            return;
        };
        if (info.closing) {
            self.retrieve(info.name);
            if ((self.last == .content and self.last_content_empty and !self.lastOutputStartsTag(info.name)) or self.last == .single or self.last == .end) try self.newline(false);
            if (std.ascii.eqlIgnoreCase(info.name, "html")) try self.newline(true);
            try self.output.appendSlice(self.allocator, normalized);
            self.last = .end;
        } else if (info.single) {
            try self.newline(false);
            try self.output.appendSlice(self.allocator, normalized);
            self.last = .single;
        } else {
            if (std.ascii.eqlIgnoreCase(info.name, "head") or std.ascii.eqlIgnoreCase(info.name, "body")) try self.newline(true) else try self.newline(false);
            try self.output.appendSlice(self.allocator, normalized);
            const owned_name = try self.allocator.dupe(u8, info.name);
            errdefer self.allocator.free(owned_name);
            try self.stack.append(self.allocator, owned_name);
            self.indent += 1;
            self.last = .start;
        }
        self.last_content_empty = true;
        self.index = tag_end + 1;
    }

    fn newline(self: *HtmlFormatter, extra: bool) !void {
        if (self.output.items.len == 0) return;
        while (self.output.items.len > 0 and std.mem.indexOfScalar(u8, "\n\r\t ", self.output.items[self.output.items.len - 1]) != null) _ = self.output.pop();
        try self.output.append(self.allocator, '\n');
        try self.output.appendNTimes(self.allocator, ' ', self.indent * 2);
        if (extra) {
            try self.output.append(self.allocator, '\n');
            try self.output.appendNTimes(self.allocator, ' ', self.indent * 2);
        }
    }

    fn retrieve(self: *HtmlFormatter, name: []const u8) void {
        var index = self.stack.items.len;
        while (index > 0) {
            index -= 1;
            if (std.ascii.eqlIgnoreCase(self.stack.items[index], name)) {
                self.indent = index;
                for (self.stack.items[index..]) |item| self.allocator.free(item);
                self.stack.shrinkRetainingCapacity(index);
                return;
            }
        }
    }

    fn lastOutputStartsTag(self: *HtmlFormatter, name: []const u8) bool {
        const marker = std.fmt.allocPrint(self.allocator, "<{s}", .{name}) catch return false;
        defer self.allocator.free(marker);
        const line_start = (std.mem.lastIndexOfScalar(u8, self.output.items, '\n') orelse 0);
        return std.ascii.startsWithIgnoreCase(std.mem.trimStart(u8, self.output.items[line_start..], "\n "), marker);
    }
};

const TagInfo = struct { name: []const u8, closing: bool, single: bool };
fn tagInfo(tag: []const u8) TagInfo {
    var index: usize = 1;
    const closing = index < tag.len and tag[index] == '/';
    if (closing) index += 1;
    const start = index;
    while (index < tag.len and (std.ascii.isAlphanumeric(tag[index]) or tag[index] == '!' or tag[index] == '?')) index += 1;
    const name = tag[start..index];
    const singles = [_][]const u8{ "br", "input", "link", "meta", "!doctype", "basefont", "base", "area", "hr", "wbr", "param", "img", "isindex", "?xml", "embed", "?php", "?", "?=" };
    var single = tag.len >= 2 and tag[tag.len - 2] == '/';
    if (std.mem.startsWith(u8, tag, "<!")) single = true;
    for (singles) |candidate| if (std.ascii.eqlIgnoreCase(name, candidate)) {
        single = true;
        break;
    };
    return .{ .name = name, .closing = closing, .single = single };
}

fn normalizeTag(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, source, "<![CDATA[")) return allocator.dupe(u8, source);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var quote: ?u8 = null;
    var pending_space = false;
    for (source) |byte| {
        if (quote) |actual| {
            try output.append(allocator, byte);
            if (byte == actual) quote = null;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            if (pending_space and output.items.len > 0 and output.items[output.items.len - 1] != '=' and output.items[output.items.len - 1] != '<') try output.append(allocator, ' ');
            pending_space = false;
            quote = byte;
            try output.append(allocator, byte);
        } else if (std.ascii.isWhitespace(byte)) {
            pending_space = true;
        } else {
            if (byte == '=') {
                while (output.items.len > 0 and output.items[output.items.len - 1] == ' ') _ = output.pop();
            } else if (pending_space and byte != '>' and output.items.len > 0 and output.items[output.items.len - 1] != '=' and output.items[output.items.len - 1] != '<') try output.append(allocator, ' ');
            pending_space = false;
            try output.append(allocator, byte);
        }
    }
    return output.toOwnedSlice(allocator);
}

fn findTagEnd(source: []const u8, start: usize) ?usize {
    if (std.mem.startsWith(u8, source[start..], "<!--")) if (std.mem.indexOfPos(u8, source, start + 4, "-->")) |end| return end + 2;
    var quote: ?u8 = null;
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        if (quote) |actual| {
            if (source[index] == actual) quote = null;
        } else if (source[index] == '\'' or source[index] == '"') quote = source[index] else if (source[index] == '>') return index;
    }
    return null;
}

fn findClosingTag(source: []const u8, start: usize, name: []const u8) ?usize {
    const range = findClosingTagRange(source, start, name) orelse return null;
    return range.end;
}

const ClosingTagRange = struct { start: usize, end: usize };
fn findClosingTagRange(source: []const u8, start: usize, name: []const u8) ?ClosingTagRange {
    var index = start;
    while (index < source.len) : (index += 1) {
        if (source[index] != '<' or index + 2 + name.len > source.len or source[index + 1] != '/') continue;
        if (!std.ascii.eqlIgnoreCase(source[index + 2 .. index + 2 + name.len], name)) continue;
        const end = findTagEnd(source, index) orelse return null;
        return .{ .start = index, .end = end + 1 };
    }
    return null;
}

fn isUnformatted(name: []const u8) bool {
    const tags = [_][]const u8{ "a", "span", "bdo", "em", "strong", "dfn", "code", "samp", "kbd", "var", "cite", "abbr", "acronym", "q", "sub", "sup", "tt", "i", "b", "big", "small", "u", "s", "strike", "font", "ins", "del", "pre", "address", "dt", "h1", "h2", "h3", "h4", "h5", "h6" };
    for (tags) |tag| if (std.ascii.eqlIgnoreCase(name, tag)) return true;
    return false;
}

fn handlerTreatsUnformatted(name: []const u8) bool {
    for (name) |byte| if (!std.ascii.isAlphabetic(byte)) return false;
    return true;
}

fn normalizeNewlines(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < source.len) : (index += 1) {
        if (source[index] == '\r') {
            if (index + 1 < source.len and source[index + 1] == '\n') index += 1;
            try output.append(allocator, '\n');
        } else try output.append(allocator, source[index]);
    }
    return output.toOwnedSlice(allocator);
}

fn escapeHtml(output: *std.Io.Writer, source: []const u8, preserve_entities: bool) !void {
    var index: usize = 0;
    while (index < source.len) {
        if (preserve_entities and source[index] == '&') if (entityLength(source[index..])) |length| {
            try output.writeAll(source[index .. index + length]);
            index += length;
            continue;
        };
        switch (source[index]) {
            '&' => try output.writeAll("&amp;"),
            '<' => try output.writeAll("&lt;"),
            '>' => try output.writeAll("&gt;"),
            '"' => try output.writeAll("&quot;"),
            else => try output.writeByte(source[index]),
        }
        index += 1;
    }
}

fn escapeAttribute(output: *std.Io.Writer, source: []const u8) !void {
    try escapeHtml(output, source, true);
}

test "marked 18互換の主要ブロックとインラインをHTML化する" {
    const source = "# Heading\n\n- [x] done\n- [ ] todo\n\n| A | B |\n| :- | -: |\n| *x* | `y` |\n";
    const actual = try markdown(std.testing.allocator, source);
    defer std.testing.allocator.free(actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "<h1>Heading</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "type=\"checkbox\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "<th align=\"left\">A</th>") != null);
    try std.testing.expect(std.mem.indexOf(u8, actual, "<em>x</em>") != null);
}

test "html 1.0.0互換の2空白インデントで整形する" {
    const actual = try prettyHtml(std.testing.allocator, "<p><h1>hoge</h1></p>");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("<p>\n  <h1>hoge</h1>\n</p>", actual);
}

test "html 1.0.0互換でscriptとコメント・属性を整形する" {
    const script = try prettyHtml(std.testing.allocator, "<div><script>if(a){\n  x();\n}</script><style>a { color: red; }</style></div>");
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("<div>\n  <script>\n    if(a){\n      x();\n    }\n  </script>\n  <style>\n    a { color: red; }\n  </style>\n</div>", script);

    const comment = try prettyHtml(std.testing.allocator, "<!-- a  b --><div x = \"a b\" y=  \"c\"> z </div>");
    defer std.testing.allocator.free(comment);
    try std.testing.expectEqualStrings("<!-- a b -->\n<div x=\"a b\" y=\"c\">z</div>", comment);
}
