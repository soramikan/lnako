const std = @import("std");
const types = @import("types.zig");
const unicode = @import("unicode.zig");
const character_class = @import("character_class.zig");

pub fn findAll(allocator: std.mem.Allocator, source: []const u16, compiled: *const types.Compiled) ![]types.Match {
    var results: std.ArrayList(types.Match) = .empty;
    var position: usize = 0;
    while (position <= source.len) {
        const found = try findOne(allocator, source, compiled, position);
        if (found == null) break;
        try results.append(allocator, found.?);
        if (!compiled.flags.global) break;
        position = if (found.?.span.end > found.?.span.start)
            found.?.span.end
        else
            unicode.advanceStringIndex(source, found.?.span.end, compiled.flags.unicode);
    }
    return results.toOwnedSlice(allocator);
}

pub fn findOne(allocator: std.mem.Allocator, source: []const u16, compiled: *const types.Compiled, from: usize) !?types.Match {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var start = @min(from, source.len);
    const last_start = if (compiled.flags.sticky) start else source.len;
    while (start <= last_start) {
        const initial = types.Candidate{ .position = start, .captures = [_]types.Span{.{}} ** types.max_captures };
        const candidates = try matchExpression(arena.allocator(), source, compiled.expression, initial, compiled.flags);
        if (candidates.len > 0) return .{ .span = .{ .start = start, .end = candidates[0].position, .matched = true }, .captures = candidates[0].captures };
        if (start == last_start) break;
        // RegExp's non-sticky Unicode search advances by StringIndex, so a
        // paired surrogate is never revisited from its low-surrogate code
        // unit. Non-Unicode search remains code-unit based.
        start = unicode.advanceStringIndex(source, start, compiled.flags.unicode);
    }
    return null;
}

fn matchExpression(allocator: std.mem.Allocator, source: []const u16, expression: *const types.Expression, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var output: std.ArrayList(types.Candidate) = .empty;
    for (expression.alternatives) |sequence| {
        const matches = try matchSequence(allocator, source, sequence, initial, flags);
        try output.appendSlice(allocator, matches);
    }
    return output.toOwnedSlice(allocator);
}

fn matchSequence(allocator: std.mem.Allocator, source: []const u16, sequence: types.Sequence, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var current: std.ArrayList(types.Candidate) = .empty;
    try current.append(allocator, initial);
    for (sequence.pieces) |piece| {
        var next: std.ArrayList(types.Candidate) = .empty;
        for (current.items) |candidate| {
            const expanded = try expandPiece(allocator, source, piece, candidate, flags);
            try next.appendSlice(allocator, expanded);
        }
        current = next;
        if (current.items.len == 0) break;
    }
    return current.toOwnedSlice(allocator);
}

pub fn clearCaptureRange(candidate: *types.Candidate, start: usize, end: usize) void {
    const bounded_start = @min(start, types.max_captures);
    const bounded_end = @min(end, types.max_captures);
    if (bounded_start < bounded_end) @memset(candidate.captures[bounded_start..bounded_end], .{});
}

pub fn clearAtomCaptures(candidate: *types.Candidate, atom: types.Atom) void {
    switch (atom) {
        .group => |group| clearCaptureRange(candidate, group.capture_start, group.capture_end),
        .assertion => |assertion| clearCaptureRange(candidate, assertion.capture_start, assertion.capture_end),
        else => {},
    }
}

fn expandPiece(allocator: std.mem.Allocator, source: []const u16, piece: types.Piece, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var output: std.ArrayList(types.Candidate) = .empty;
    // A zero-width atom still counts as a repetition.  The previous
    // source-length bound was enough to prevent consuming atoms from
    // running past the input, but it incorrectly made `(){100,}` unable to
    // satisfy its minimum on a short input.  For an unbounded quantifier,
    // keep enough levels for the minimum and at least one level per input
    // code unit for consuming paths.
    const limit = piece.maximum orelse @max(source.len + 1, piece.minimum);
    try expandPieceOrdered(allocator, source, piece, initial, flags, 0, limit, &output);
    return output.toOwnedSlice(allocator);
}

fn expandPieceOrdered(
    allocator: std.mem.Allocator,
    source: []const u16,
    piece: types.Piece,
    candidate: types.Candidate,
    flags: types.Flags,
    repetition: usize,
    limit: usize,
    output: *std.ArrayList(types.Candidate),
) anyerror!void {
    const can_repeat = repetition < limit;
    if (!piece.lazy and can_repeat) {
        const atom_matches = try matchAtom(allocator, source, piece.atom, candidate, flags);
        for (atom_matches) |atom_match| {
            // An unbounded zero-width quantifier needs only its minimum
            // number of zero-width repetitions.  Beyond that point the
            // same candidate would form an infinite branch.  Finite
            // quantifiers are already bounded, so their zero-width
            // repetitions must be retained through the declared limit.
            if (atom_match.position == candidate.position and
                piece.maximum == null and repetition + 1 > piece.minimum) continue;
            // A greedy quantifier explores the atom's own choices before
            // trying the current repetition as a result.  This preserves
            // the backtracking order of nested quantifiers such as
            // `/(a+)+b/`, where the inner greedy `a+` must win first.
            try expandPieceOrdered(allocator, source, piece, atom_match, flags, repetition + 1, limit, output);
        }
    }
    var stopped = candidate;
    // A zero-occurrence optional group does not participate in the match. If
    // the same candidate came from an earlier repetition of an enclosing
    // group, its old captures must not leak into this non-participating path.
    if (repetition == 0 and piece.minimum == 0) clearAtomCaptures(&stopped, piece.atom);
    if (repetition >= piece.minimum) try output.append(allocator, stopped);
    if (piece.lazy and can_repeat) {
        const atom_matches = try matchAtom(allocator, source, piece.atom, candidate, flags);
        for (atom_matches) |atom_match| {
            if (atom_match.position == candidate.position and
                piece.maximum == null and repetition + 1 > piece.minimum) continue;
            try expandPieceOrdered(allocator, source, piece, atom_match, flags, repetition + 1, limit, output);
        }
    }
}

fn matchExpressionBehind(allocator: std.mem.Allocator, source: []const u16, expression: *const types.Expression, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var output: std.ArrayList(types.Candidate) = .empty;
    for (expression.alternatives) |sequence| {
        const matches = try matchSequenceBehind(allocator, source, sequence, initial, flags);
        try output.appendSlice(allocator, matches);
    }
    return output.toOwnedSlice(allocator);
}

fn matchSequenceBehind(allocator: std.mem.Allocator, source: []const u16, sequence: types.Sequence, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var current: std.ArrayList(types.Candidate) = .empty;
    try current.append(allocator, initial);
    var piece_index = sequence.pieces.len;
    while (piece_index > 0) {
        piece_index -= 1;
        var next: std.ArrayList(types.Candidate) = .empty;
        for (current.items) |candidate| {
            const expanded = try expandPieceBehind(allocator, source, sequence.pieces[piece_index], candidate, flags);
            try next.appendSlice(allocator, expanded);
        }
        current = next;
        if (current.items.len == 0) break;
    }
    return current.toOwnedSlice(allocator);
}

fn expandPieceBehind(allocator: std.mem.Allocator, source: []const u16, piece: types.Piece, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var output: std.ArrayList(types.Candidate) = .empty;
    const limit = piece.maximum orelse @max(source.len + 1, piece.minimum);
    try expandPieceBehindOrdered(allocator, source, piece, initial, flags, 0, limit, &output);
    return output.toOwnedSlice(allocator);
}

fn expandPieceBehindOrdered(
    allocator: std.mem.Allocator,
    source: []const u16,
    piece: types.Piece,
    candidate: types.Candidate,
    flags: types.Flags,
    repetition: usize,
    limit: usize,
    output: *std.ArrayList(types.Candidate),
) anyerror!void {
    const can_repeat = repetition < limit;
    if (!piece.lazy and can_repeat) {
        const atom_matches = try matchAtomBehind(allocator, source, piece.atom, candidate, flags);
        for (atom_matches) |atom_match| {
            if (atom_match.position == candidate.position and
                piece.maximum == null and repetition + 1 > piece.minimum) continue;
            try expandPieceBehindOrdered(allocator, source, piece, atom_match, flags, repetition + 1, limit, output);
        }
    }
    var stopped = candidate;
    if (repetition == 0 and piece.minimum == 0) clearAtomCaptures(&stopped, piece.atom);
    if (repetition >= piece.minimum) try output.append(allocator, stopped);
    if (piece.lazy and can_repeat) {
        const atom_matches = try matchAtomBehind(allocator, source, piece.atom, candidate, flags);
        for (atom_matches) |atom_match| {
            if (atom_match.position == candidate.position and
                piece.maximum == null and repetition + 1 > piece.minimum) continue;
            try expandPieceBehindOrdered(allocator, source, piece, atom_match, flags, repetition + 1, limit, output);
        }
    }
}

fn matchLookbehindCandidates(allocator: std.mem.Allocator, source: []const u16, expression: *const types.Expression, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    return matchExpressionBehind(allocator, source, expression, initial, flags);
}

fn matchAtomBehind(allocator: std.mem.Allocator, source: []const u16, atom: types.Atom, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var output: std.ArrayList(types.Candidate) = .empty;
    switch (atom) {
        .literal => |literal| {
            if (flags.unicode) {
                if (unicode.codePointBefore(source, initial.position)) |actual| {
                    if (unicode.codePointsEqual(actual.value, literal, flags)) {
                        var candidate = initial;
                        candidate.position -= actual.width;
                        try output.append(allocator, candidate);
                    }
                }
            } else if (initial.position > 0 and unicode.unitsEqual(source[initial.position - 1], literal, flags.ignore_case)) {
                var candidate = initial;
                candidate.position -= 1;
                try output.append(allocator, candidate);
            }
        },
        .code_point => |code_point| {
            if (flags.unicode) {
                if (unicode.codePointBefore(source, initial.position)) |actual| {
                    if (unicode.codePointsEqual(actual.value, code_point, flags)) {
                        var candidate = initial;
                        candidate.position -= actual.width;
                        try output.append(allocator, candidate);
                    }
                }
            } else if (code_point <= std.math.maxInt(u16) and initial.position > 0 and source[initial.position - 1] == code_point) {
                var candidate = initial;
                candidate.position -= 1;
                try output.append(allocator, candidate);
            }
        },
        .dot => {
            if (unicode.codePointBefore(source, initial.position)) |actual| {
                const start = initial.position - actual.width;
                if (flags.dot_all or !unicode.isLineTerminator(source[start])) {
                    var candidate = initial;
                    candidate.position = start;
                    try output.append(allocator, candidate);
                }
            }
        },
        .class => |class| {
            if (unicode.codePointBefore(source, initial.position)) |actual| {
                const start = initial.position - actual.width;
                if (character_class.classMatches(class, source, start, flags)) {
                    var candidate = initial;
                    candidate.position = start;
                    try output.append(allocator, candidate);
                }
            }
        },
        .unicode_property => |property| {
            if (unicode.codePointBefore(source, initial.position)) |actual| {
                if (unicode.propertyMatches(property, actual.value, flags)) {
                    var candidate = initial;
                    candidate.position -= actual.width;
                    try output.append(allocator, candidate);
                }
            }
        },
        .start_anchor => if (initial.position == 0 or (flags.multiline and initial.position > 0 and unicode.isLineTerminator(source[initial.position - 1]))) try output.append(allocator, initial),
        .end_anchor => if (initial.position == source.len or (flags.multiline and initial.position < source.len and unicode.isLineTerminator(source[initial.position]))) try output.append(allocator, initial),
        .word_boundary => |expected| {
            const left_word = if (flags.unicode)
                if (unicode.codePointBefore(source, initial.position)) |point| unicode.isWordCodePoint(point.value, flags) else false
            else
                initial.position > 0 and unicode.isWord(source[initial.position - 1]);
            const right_word = if (flags.unicode)
                if (unicode.codePointAt(source, initial.position)) |point| unicode.isWordCodePoint(point.value, flags) else false
            else
                initial.position < source.len and unicode.isWord(source[initial.position]);
            if ((left_word != right_word) == expected) try output.append(allocator, initial);
        },
        .backreference => |capture_index| {
            if (capture_index >= types.max_captures) return output.toOwnedSlice(allocator);
            if (!initial.captures[capture_index].matched) {
                try output.append(allocator, initial);
                return output.toOwnedSlice(allocator);
            }
            const span = initial.captures[capture_index];
            const length = span.end - span.start;
            if (length <= initial.position and unicode.slicesEqual(source[span.start..span.end], source[initial.position - length .. initial.position], flags)) {
                var candidate = initial;
                candidate.position -= length;
                try output.append(allocator, candidate);
            }
        },
        .legacy_octal_escape => |escape| {
            const length = 1 + escape.trailing.len;
            if (initial.position < length) return output.toOwnedSlice(allocator);
            const start = initial.position - length;
            if (!unicode.unitsEqual(source[start], escape.code_unit, flags.ignore_case)) return output.toOwnedSlice(allocator);
            for (escape.trailing, 0..) |literal, offset| {
                if (!unicode.unitsEqual(source[start + 1 + offset], literal, flags.ignore_case)) return output.toOwnedSlice(allocator);
            }
            var candidate = initial;
            candidate.position = start;
            try output.append(allocator, candidate);
        },
        .legacy_decimal_escape => return error.UnresolvedLegacyDecimalEscape,
        .unicode_decimal_escape => return error.UnresolvedUnicodeDecimalEscape,
        .named_backreference => return output.toOwnedSlice(allocator),
        .group => |group| {
            var group_initial = initial;
            clearCaptureRange(&group_initial, group.capture_start, group.capture_end);
            const matches = try matchExpressionBehind(allocator, source, group.expression, group_initial, flags);
            for (matches) |match| {
                var candidate = match;
                if (group.capture) |capture_index| candidate.captures[capture_index] = .{ .start = match.position, .end = initial.position, .matched = true };
                try output.append(allocator, candidate);
            }
        },
        .assertion => |assertion| {
            var assertion_initial = initial;
            clearCaptureRange(&assertion_initial, assertion.capture_start, assertion.capture_end);
            if (!assertion.behind) {
                const assertion_matches = try matchExpression(allocator, source, assertion.expression, assertion_initial, flags);
                if (assertion.positive) {
                    for (assertion_matches) |match| {
                        var accepted = match;
                        accepted.position = initial.position;
                        try output.append(allocator, accepted);
                    }
                } else if (assertion_matches.len == 0) try output.append(allocator, assertion_initial);
            } else {
                const assertion_matches = try matchLookbehindCandidates(allocator, source, assertion.expression, assertion_initial, flags);
                if (assertion.positive) {
                    for (assertion_matches) |match| {
                        var accepted = match;
                        accepted.position = initial.position;
                        try output.append(allocator, accepted);
                    }
                } else if (assertion_matches.len == 0) try output.append(allocator, assertion_initial);
            }
        },
    }
    return output.toOwnedSlice(allocator);
}

pub fn matchAtom(allocator: std.mem.Allocator, source: []const u16, atom: types.Atom, initial: types.Candidate, flags: types.Flags) anyerror![]types.Candidate {
    var output: std.ArrayList(types.Candidate) = .empty;
    switch (atom) {
        .literal => |literal| {
            if (flags.unicode) {
                if (unicode.codePointAt(source, initial.position)) |actual| {
                    if (unicode.codePointsEqual(actual.value, literal, flags)) {
                        var candidate = initial;
                        candidate.position += actual.width;
                        try output.append(allocator, candidate);
                    }
                }
            } else if (initial.position < source.len and unicode.unitsEqual(source[initial.position], literal, flags.ignore_case)) {
                var candidate = initial;
                candidate.position += 1;
                try output.append(allocator, candidate);
            }
        },
        .code_point => |code_point| if (unicode.codePointAt(source, initial.position)) |actual| if (unicode.codePointsEqual(actual.value, code_point, flags)) {
            var candidate = initial;
            candidate.position += actual.width;
            try output.append(allocator, candidate);
        },
        .dot => if (initial.position < source.len and (flags.dot_all or !unicode.isLineTerminator(source[initial.position]))) {
            var candidate = initial;
            candidate.position += unicode.codePointWidth(source, initial.position, flags.unicode);
            try output.append(allocator, candidate);
        },
        .class => |class| if (initial.position < source.len and character_class.classMatches(class, source, initial.position, flags)) {
            var candidate = initial;
            candidate.position += unicode.codePointWidth(source, initial.position, flags.unicode);
            try output.append(allocator, candidate);
        },
        .unicode_property => |property| if (initial.position < source.len) {
            if (unicode.codePointAt(source, initial.position)) |actual| {
                if (unicode.propertyMatches(property, actual.value, flags)) {
                    var candidate = initial;
                    candidate.position += actual.width;
                    try output.append(allocator, candidate);
                }
            }
        },
        .start_anchor => if (initial.position == 0 or (flags.multiline and initial.position > 0 and unicode.isLineTerminator(source[initial.position - 1]))) try output.append(allocator, initial),
        .end_anchor => if (initial.position == source.len or (flags.multiline and initial.position < source.len and unicode.isLineTerminator(source[initial.position]))) try output.append(allocator, initial),
        .word_boundary => |expected| {
            const left_word = if (flags.unicode)
                if (unicode.codePointBefore(source, initial.position)) |point| unicode.isWordCodePoint(point.value, flags) else false
            else
                initial.position > 0 and unicode.isWord(source[initial.position - 1]);
            const right_word = if (flags.unicode)
                if (unicode.codePointAt(source, initial.position)) |point| unicode.isWordCodePoint(point.value, flags) else false
            else
                initial.position < source.len and unicode.isWord(source[initial.position]);
            if ((left_word != right_word) == expected) try output.append(allocator, initial);
        },
        .backreference => |capture_index| {
            if (capture_index >= types.max_captures) return output.toOwnedSlice(allocator);
            if (!initial.captures[capture_index].matched) {
                // ECMAScript backreferences to an unmatched capture consume
                // an empty string rather than failing the candidate.
                try output.append(allocator, initial);
                return output.toOwnedSlice(allocator);
            }
            const span = initial.captures[capture_index];
            const length = span.end - span.start;
            if (initial.position + length <= source.len and unicode.slicesEqual(source[span.start..span.end], source[initial.position .. initial.position + length], flags)) {
                var candidate = initial;
                candidate.position += length;
                try output.append(allocator, candidate);
            }
        },
        .legacy_octal_escape => |escape| {
            var position = initial.position;
            if (position >= source.len or !unicode.unitsEqual(source[position], escape.code_unit, flags.ignore_case)) return output.toOwnedSlice(allocator);
            position += 1;
            for (escape.trailing) |literal| {
                if (position >= source.len or !unicode.unitsEqual(source[position], literal, flags.ignore_case)) return output.toOwnedSlice(allocator);
                position += 1;
            }
            var candidate = initial;
            candidate.position = position;
            try output.append(allocator, candidate);
        },
        .legacy_decimal_escape => return error.UnresolvedLegacyDecimalEscape,
        .unicode_decimal_escape => return error.UnresolvedUnicodeDecimalEscape,
        .named_backreference => return output.toOwnedSlice(allocator),
        .group => |group| {
            var group_initial = initial;
            clearCaptureRange(&group_initial, group.capture_start, group.capture_end);
            const matches = try matchExpression(allocator, source, group.expression, group_initial, flags);
            for (matches) |match| {
                var candidate = match;
                if (group.capture) |capture_index| candidate.captures[capture_index] = .{ .start = initial.position, .end = match.position, .matched = true };
                try output.append(allocator, candidate);
            }
        },
        .assertion => |assertion| {
            var assertion_initial = initial;
            clearCaptureRange(&assertion_initial, assertion.capture_start, assertion.capture_end);
            if (!assertion.behind) {
                const assertion_matches = try matchExpression(allocator, source, assertion.expression, assertion_initial, flags);
                if (assertion.positive) {
                    for (assertion_matches) |match| {
                        var accepted = match;
                        accepted.position = initial.position;
                        try output.append(allocator, accepted);
                    }
                } else if (assertion_matches.len == 0) try output.append(allocator, assertion_initial);
            } else {
                const candidates = try matchLookbehindCandidates(allocator, source, assertion.expression, assertion_initial, flags);
                if (assertion.positive) {
                    for (candidates) |candidate| {
                        var accepted = candidate;
                        accepted.position = initial.position;
                        try output.append(allocator, accepted);
                    }
                } else if (candidates.len == 0) try output.append(allocator, assertion_initial);
            }
        },
    }
    return output.toOwnedSlice(allocator);
}
