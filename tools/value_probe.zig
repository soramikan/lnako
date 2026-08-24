const std = @import("std");
const lnako = @import("lnako");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);
    var stdout_buffer: [16384]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    var runtime = lnako.runtime.value.Runtime.init(allocator);
    defer runtime.deinit();
    for (process_args[1..]) |encoded| {
        const separator = std.mem.indexOfScalar(u8, encoded, ':') orelse return error.InvalidCase;
        const kind = encoded[0..separator];
        const input = encoded[separator + 1 ..];
        var output: []const u8 = undefined;
        if (std.mem.eql(u8, kind, "number-to-string")) {
            const number = parseNumberInput(input) catch return error.InvalidCase;
            output = try lnako.runtime.value.numberToStringAlloc(allocator, number);
        } else if (std.mem.eql(u8, kind, "string-to-number")) {
            const string_value = try runtime.stringUtf8(input);
            const number = try string_value.toNumber(allocator);
            output = if (number == 0 and @as(u64, @bitCast(number)) >> 63 != 0)
                "-0"
            else
                try lnako.runtime.value.numberToStringAlloc(allocator, number);
        } else if (std.mem.eql(u8, kind, "string-units")) {
            const string_value = try runtime.stringUtf8(input);
            var buffer: std.Io.Writer.Allocating = .init(allocator);
            for (string_value.string.units, 0..) |unit, index| {
                if (index > 0) try buffer.writer.writeByte(',');
                try buffer.writer.print("{d}", .{unit});
            }
            output = try buffer.toOwnedSlice();
        } else if (std.mem.eql(u8, kind, "bigint-normalize")) {
            const string_value = try runtime.stringUtf8(input);
            const bigint = runtime.bigIntString(string_value.string) catch {
                try std.json.Stringify.value("error", .{}, stdout);
                try stdout.writeByte('\n');
                continue;
            };
            output = try bigint.bigint.toString(allocator, 10);
        } else if (std.mem.eql(u8, kind, "operator")) {
            const first_separator = std.mem.indexOfScalar(u8, input, '|') orelse return error.InvalidCase;
            const second_separator = std.mem.indexOfScalarPos(u8, input, first_separator + 1, '|') orelse return error.InvalidCase;
            const operator = std.meta.stringToEnum(lnako.runtime.operators.Binary, input[0..first_separator]) orelse return error.InvalidCase;
            var frame = runtime.rootFrame();
            defer frame.deinit();
            var left = try parseValue(&runtime, input[first_separator + 1 .. second_separator]);
            try frame.protect(&left);
            var right = try parseValue(&runtime, input[second_separator + 1 ..]);
            try frame.protect(&right);
            const result = lnako.runtime.operators.binary(&runtime, operator, left, right) catch {
                try std.json.Stringify.value("error", .{}, stdout);
                try stdout.writeByte('\n');
                continue;
            };
            output = try describeValue(allocator, result);
        } else return error.InvalidCase;
        try std.json.Stringify.value(output, .{}, stdout);
        try stdout.writeByte('\n');
    }
}

fn parseValue(runtime: *lnako.runtime.value.Runtime, encoded: []const u8) !lnako.runtime.value.Value {
    const separator = std.mem.indexOfScalar(u8, encoded, '=');
    const kind = if (separator) |index| encoded[0..index] else encoded;
    const payload = if (separator) |index| encoded[index + 1 ..] else "";
    if (std.mem.eql(u8, kind, "number")) return .{ .number = try parseNumberInput(payload) };
    if (std.mem.eql(u8, kind, "string")) return runtime.stringUtf8(payload);
    if (std.mem.eql(u8, kind, "bigint")) return runtime.bigIntLiteral(payload);
    if (std.mem.eql(u8, kind, "boolean")) return .{ .boolean = std.mem.eql(u8, payload, "true") };
    if (std.mem.eql(u8, kind, "array")) {
        const result = try runtime.createArray();
        if (payload.len > 0) {
            var values = std.mem.splitScalar(u8, payload, ',');
            while (values.next()) |number| _ = try result.array.push(.{ .number = try parseNumberInput(number) });
        }
        return result;
    }
    if (std.mem.eql(u8, kind, "dictionary")) return runtime.createDictionary();
    if (std.mem.eql(u8, kind, "null")) return .null_value;
    if (std.mem.eql(u8, kind, "undefined")) return .undefined;
    return error.InvalidCase;
}

fn describeValue(allocator: std.mem.Allocator, value: lnako.runtime.value.Value) ![]u8 {
    return switch (value) {
        .undefined => allocator.dupe(u8, "undefined"),
        .null_value => allocator.dupe(u8, "null"),
        .boolean => |boolean| allocator.dupe(u8, if (boolean) "boolean:true" else "boolean:false"),
        .number => |number| blk: {
            const text = if (number == 0 and @as(u64, @bitCast(number)) >> 63 != 0)
                try allocator.dupe(u8, "-0")
            else
                try lnako.runtime.value.numberToStringAlloc(allocator, number);
            break :blk std.fmt.allocPrint(allocator, "number:{s}", .{text});
        },
        .bigint => |bigint| blk: {
            const text = try bigint.toString(allocator, 10);
            break :blk std.fmt.allocPrint(allocator, "bigint:{s}", .{text});
        },
        .string => |string| blk: {
            const text = try string.toUtf8Lossy(allocator);
            break :blk std.fmt.allocPrint(allocator, "string:{s}", .{text});
        },
        .bytes => allocator.dupe(u8, "bytes"),
        .array => allocator.dupe(u8, "array"),
        .dictionary => allocator.dupe(u8, "dictionary"),
        .function => allocator.dupe(u8, "function"),
        .promise => allocator.dupe(u8, "promise"),
    };
}

fn parseNumberInput(input: []const u8) !f64 {
    if (std.mem.eql(u8, input, "NaN")) return std.math.nan(f64);
    if (std.mem.eql(u8, input, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, input, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, input);
}
