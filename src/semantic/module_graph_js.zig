//! JavaScript 取り込み走査（import/export/dynamic import のリテラル解析）。

const std = @import("std");
const js_scanner = @import("js_scanner.zig");

const JavaScriptTokenKind = js_scanner.JavaScriptTokenKind;
const JavaScriptToken = js_scanner.JavaScriptToken;
const JavaScriptScanner = js_scanner.JavaScriptScanner;

/// `collectJavaScriptImports` の走査結果。
pub const JavaScriptScan = struct {
    imports: [][]const u8,
    /// 静的に解決できない取り込み指定（非リテラル `import(expr)`、未終了の
    /// 構造、走査不能なtemplate/interpolation等）が存在する。記録されない
    /// importは実行時にQuickJS loaderのFS fallbackを通るため、package所有
    /// moduleでは呼出し側が境界違反として拒否する。
    has_opaque_dynamic: bool = false,
    /// escape列を含む取り込み指定が存在する。復号しないと実pathが定まらず
    /// `pathWithinRoot` 検査をすり抜けるため、所有の有無に関わらず呼出し側
    /// が診断する（nested loadでのerror黙殺によるsilentな成功を生じさせない）。
    has_unsupported_escape: bool = false,
};

/// JS moduleの `import`/`export … from` と動的 `import("…")` のリテラル
/// 指定を収集する。動的formも収集しないとQuickJS側module loaderがFSへ
/// fallbackしてpackage rootの外を読み得るため、リテラル指定は静的同様に
/// 収集対象とする。ただし動的リテラルは `)` または第二引数の `,` で閉じる
/// ものに限る — `import("a" + expr)` は実行時評価で別の指定になり得るため
/// 先頭リテラルを記録すると誤った辺と境界検査のすり抜けになる。
///
/// `import`/`export` をstatementとして読み進める内側loopは、式中に別の
/// `import`/`export` tokenを見つけた時点で巻き戻して外側loopへ返す —
/// `export const p = import('./x')` のような式中の動的formや object key
/// `{import: 1}` 直後の `import()` が内側のskip処理で消えないようにする。
/// `.import` のようなメンバ呼出しはJSとしてmoduleを読み込まないため除外し、
/// 誤ったedge記録とpackage codeの誤拒否を防ぐ。
pub fn collectJavaScriptImports(allocator: std.mem.Allocator, source: []const u8) !JavaScriptScan {
    var scan: JavaScriptScan = .{ .imports = &.{} };
    var result: std.ArrayList([]const u8) = .empty;
    var scanner = JavaScriptScanner{ .source = source };
    // 直前に消費したtokenが `.` か。`o.import(...)` のようなメンバ呼出しを
    // `import` statement/動的formと誤認しないための判定に使う。
    var last_was_dot = false;
    while (scanner.next()) |token| {
        const dot_member = last_was_dot;
        last_was_dot = token.kind == .punctuation and std.mem.eql(u8, token.text, ".");
        if (token.kind != .identifier) continue;
        const is_import = std.mem.eql(u8, token.text, "import");
        const is_export = std.mem.eql(u8, token.text, "export");
        if ((!is_import and !is_export) or dot_member) continue;
        var saw_from = false;
        var dynamic = false;
        var dynamic_literal: ?[]const u8 = null;
        var first = true;
        while (true) {
            const mark = scanner.mark();
            const candidate = scanner.next() orelse {
                // 動的formが閉じずにsource終端へ達した場合も記録不能として
                // 報告する（非package moduleでは従来どおり無視される）。
                if (dynamic) scan.has_opaque_dynamic = true;
                break;
            };
            const candidate_dot = last_was_dot;
            last_was_dot = candidate.kind == .punctuation and std.mem.eql(u8, candidate.text, ".");
            if (dynamic) {
                if (dynamic_literal == null) {
                    // `(` 直後はspecifierリテラル文字列のみ受理する。escape
                    // 列を含む文字列は復号しないと実pathが定まらないため
                    // 収集せず、診断対象として報告する。
                    if (candidate.kind == .string) {
                        if (std.mem.indexOfScalar(u8, candidate.text, '\\') != null) {
                            scan.has_unsupported_escape = true;
                            break;
                        }
                        dynamic_literal = candidate.text;
                        continue;
                    }
                    scan.has_opaque_dynamic = true;
                    break;
                }
                // リテラル直後は `)`（呼出し終了）か `,`（第二引数=options
                // object）のみ受理する。`+`・identifier・連続する文字列などは
                // 式の一部であり、記録済みリテラルは実際の指定と一致しない。
                // 確定した時点で打ち切る（第二引数はspecifierへ影響しない）。
                if (candidate.kind == .punctuation and
                    (std.mem.eql(u8, candidate.text, ")") or std.mem.eql(u8, candidate.text, ",")))
                {
                    try result.append(allocator, try allocator.dupe(u8, dynamic_literal.?));
                    dynamic = false;
                } else {
                    scan.has_opaque_dynamic = true;
                }
                break;
            }
            // 文の内側で別の `import`/`export` を見つけた場合（export式中の
            // `import()`、object key直後の `import()` 等）、そのtoken自体を
            // 外側loopで再走査するため巻き戻して内側を抜ける。消費したまま
            // 進むと式中の動的importが一切記録されない。
            if (candidate.kind == .identifier and !candidate_dot and
                (std.mem.eql(u8, candidate.text, "import") or std.mem.eql(u8, candidate.text, "export")))
            {
                // `next` の内部で行われたtemplate文脈の遷移（`${` push・
                // `}` pop・text消費）ごと巻き戻す — indexのみ戻すと文脈
                // stackが読み位置と不整合になり、後続tokenが誤った文脈で
                // 解釈されてedgeの取りこぼし・誤拒否が起きる。
                scanner.restore(mark);
                break;
            }
            if (candidate.kind == .punctuation and std.mem.eql(u8, candidate.text, ";")) break;
            if (candidate.kind == .punctuation and std.mem.eql(u8, candidate.text, "(")) {
                // `import("…")` の動的formは先頭tokenとして `(` が来る。
                if (is_import and first) {
                    dynamic = true;
                    first = false;
                    continue;
                }
                break;
            }
            if (saw_from) {
                saw_from = false;
                if (candidate.kind == .string) {
                    if (std.mem.indexOfScalar(u8, candidate.text, '\\') != null) {
                        scan.has_unsupported_escape = true;
                        break;
                    }
                    try result.append(allocator, try allocator.dupe(u8, candidate.text));
                    break;
                }
                // `from` 直後が文字列でない場合はspecifierではない。
                // そのtokenを通常どおり評価するため後続の判定へ進む。
            }
            if (candidate.kind == .identifier and !candidate_dot and std.mem.eql(u8, candidate.text, "from")) {
                saw_from = true;
                first = false;
                continue;
            }
            if (candidate.kind != .string) {
                first = false;
                continue;
            }
            // specifier位置の文字列のみ収集する — `from` 直後か `import "…"`
            // の文頭form。`export default "./x"` のような値としての文字列を
            // 辺として記録しない。
            if (is_import and first) {
                if (std.mem.indexOfScalar(u8, candidate.text, '\\') != null) {
                    scan.has_unsupported_escape = true;
                    break;
                }
                try result.append(allocator, try allocator.dupe(u8, candidate.text));
            }
            break;
        }
    }
    // source終端までに閉じない文字列・template・interpolationは残りtokenを
    // 未走査にする — 収集不能なimportが残り得るためopaqueとして報告する。
    if (scanner.truncated) scan.has_opaque_dynamic = true;
    scan.imports = try result.toOwnedSlice(allocator);
    return scan;
}
