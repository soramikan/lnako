const std = @import("std");
const unicode_properties = @import("unicode_properties");
const unicode_case = @import("unicode_case");
const types = @import("types.zig");

pub const CodePoint = struct { value: u21, width: usize };

pub fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xd800 and unit <= 0xdbff;
}

pub fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xdc00 and unit <= 0xdfff;
}

pub fn surrogatePairCodePoint(high: u16, low: u16) u21 {
    return @intCast(0x10000 + (@as(u32, high) - 0xd800) * 0x400 + (@as(u32, low) - 0xdc00));
}

pub fn codePointAt(source: []const u16, position: usize) ?CodePoint {
    if (position >= source.len) return null;
    const first = source[position];
    if (isHighSurrogate(first) and position + 1 < source.len and isLowSurrogate(source[position + 1])) {
        return .{ .value = surrogatePairCodePoint(first, source[position + 1]), .width = 2 };
    }
    return .{ .value = first, .width = 1 };
}

pub fn codePointBefore(source: []const u16, position: usize) ?CodePoint {
    const end = @min(position, source.len);
    if (end == 0) return null;
    if (end >= 2 and isHighSurrogate(source[end - 2]) and isLowSurrogate(source[end - 1])) {
        return .{ .value = surrogatePairCodePoint(source[end - 2], source[end - 1]), .width = 2 };
    }
    return .{ .value = source[end - 1], .width = 1 };
}

pub fn codePointWidth(source: []const u16, position: usize, unicode: bool) usize {
    if (!unicode) return 1;
    return (codePointAt(source, position) orelse return 1).width;
}

pub fn advanceStringIndex(source: []const u16, position: usize, unicode: bool) usize {
    if (position >= source.len) return source.len + 1;
    return position + codePointWidth(source, position, unicode);
}

pub fn foldAscii(unit: u16, enabled: bool) u16 {
    if (!enabled) return unit;
    const mapped = unicode_case.lower(@intCast(unit)) orelse return unit;
    return if (mapped.len == 1 and mapped[0] <= std.math.maxInt(u16)) @intCast(mapped[0]) else unit;
}

pub fn foldCodePoint(codepoint: u21, flags: types.Flags) u21 {
    if (flags.ignore_case and flags.unicode) return unicode_case.simpleFold(codepoint);
    if (codepoint <= std.math.maxInt(u16)) return foldAscii(@intCast(codepoint), flags.ignore_case);
    return codepoint;
}

pub fn unitsEqual(left: u16, right: u16, ignore_case: bool) bool {
    return foldAscii(left, ignore_case) == foldAscii(right, ignore_case);
}

pub fn codePointsEqual(left: u21, right: u21, flags: types.Flags) bool {
    return foldCodePoint(left, flags) == foldCodePoint(right, flags);
}

pub fn slicesEqual(left: []const u16, right: []const u16, flags: types.Flags) bool {
    if (!flags.unicode) {
        if (left.len != right.len) return false;
        for (left, right) |a, b| if (!unitsEqual(a, b, flags.ignore_case)) return false;
        return true;
    }
    var left_index: usize = 0;
    var right_index: usize = 0;
    while (left_index < left.len and right_index < right.len) {
        const left_point = codePointAt(left, left_index) orelse return false;
        const right_point = codePointAt(right, right_index) orelse return false;
        if (!codePointsEqual(left_point.value, right_point.value, flags)) return false;
        left_index += left_point.width;
        right_index += right_point.width;
    }
    return left_index == left.len and right_index == right.len;
}

pub fn isDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

pub fn isWord(unit: u16) bool {
    return isAsciiWord(unit);
}

pub fn isAsciiWord(codepoint: u21) bool {
    return (codepoint >= '0' and codepoint <= '9') or
        (codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z') or
        codepoint == '_';
}

pub fn isWordCodePoint(codepoint: u21, flags: types.Flags) bool {
    if (codepoint <= 0x7f and isAsciiWord(codepoint)) return true;
    if (!(flags.unicode and flags.ignore_case)) return false;
    if (unicode_case.simpleFoldVariants(codepoint)) |variants| {
        for (variants) |variant| if (variant <= 0x7f and isAsciiWord(variant)) return true;
    }
    return false;
}

pub fn isWhitespace(unit: u16) bool {
    return switch (unit) {
        0x0009...0x000d, 0x0020, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

pub fn isLineTerminator(unit: u16) bool {
    return unit == '\n' or unit == '\r' or unit == 0x2028 or unit == 0x2029;
}

pub fn propertyMatches(property: types.UnicodeProperty, codepoint: u21, flags: types.Flags) bool {
    // ECMAScript keeps the special `ASCII` property as a literal range in
    // Unicode Sets mode.  The v-mode case-folding pass applies to the
    // property set, but the `ASCII` shorthand is resolved before that pass;
    // this is why `/\p{ASCII}/iv` does not match the Kelvin sign while the
    // same expression with `u` does.
    if (property.property == .ascii and flags.unicode_sets) {
        return unicode_properties.contains(property.property, codepoint) != property.negated;
    }
    if (flags.ignore_case and flags.unicode) {
        if (unicode_case.simpleFoldVariants(codepoint)) |variants| {
            if (property.negated) {
                if (flags.unicode_sets) {
                    // In v mode, case folding happens before complementing
                    // the property set.  A negative property therefore
                    // matches only when no member of the case-fold group has
                    // the property.
                    for (variants) |variant| if (unicode_properties.contains(property.property, variant)) return false;
                    return true;
                }
                // In u mode, complementing happens before case folding.  It
                // is enough for one equivalent code point to be outside the
                // property for the input code point to match.
                for (variants) |variant| if (!unicode_properties.contains(property.property, variant)) return true;
                return false;
            }
            for (variants) |variant| if (unicode_properties.contains(property.property, variant)) return true;
            return false;
        }
    }
    return unicode_properties.contains(property.property, codepoint) != property.negated;
}

pub fn lookupUnicodeProperty(name: []const u16) ?unicode_properties.Property {
    if (asciiEquals(name, "ASCII")) return .ascii;
    if (asciiEquals(name, "Any")) return .any;
    if (asciiEquals(name, "ASCII_Hex_Digit")) return .ascii_hex_digit;
    if (asciiEquals(name, "AHex")) return .ascii_hex_digit;
    if (asciiEquals(name, "Assigned")) return .assigned;
    if (asciiEquals(name, "Alphabetic")) return .alphabetic;
    if (asciiEquals(name, "Alpha")) return .alphabetic;
    if (oneOf(name, &.{ "Bidi_Control", "Bidi_C" })) return .bidi_control;
    if (oneOf(name, &.{ "Bidi_Mirrored", "Bidi_M" })) return .bidi_mirrored;
    if (oneOf(name, &.{ "Case_Ignorable", "CI" })) return .case_ignorable;
    if (asciiEquals(name, "Cased")) return .cased;
    if (oneOf(name, &.{ "Changes_When_Casefolded", "CWCF" })) return .changes_when_casefolded;
    if (oneOf(name, &.{ "Changes_When_Casemapped", "CWCM" })) return .changes_when_casemapped;
    if (oneOf(name, &.{ "Changes_When_Lowercased", "CWL" })) return .changes_when_lowercased;
    if (oneOf(name, &.{ "Changes_When_NFKC_Casefolded", "CWKCF" })) return .changes_when_nfkc_casefolded;
    if (oneOf(name, &.{ "Changes_When_Titlecased", "CWT" })) return .changes_when_titlecased;
    if (oneOf(name, &.{ "Changes_When_Uppercased", "CWU" })) return .changes_when_uppercased;
    if (asciiEquals(name, "Dash")) return .dash;
    if (oneOf(name, &.{ "Default_Ignorable_Code_Point", "DI" })) return .default_ignorable_code_point;
    if (oneOf(name, &.{ "Deprecated", "Dep" })) return .deprecated;
    if (oneOf(name, &.{ "Diacritic", "Dia" })) return .diacritic;
    if (oneOf(name, &.{ "Emoji_Component", "EComp" })) return .emoji_component;
    if (oneOf(name, &.{ "Emoji_Modifier", "EMod" })) return .emoji_modifier;
    if (oneOf(name, &.{ "Emoji_Modifier_Base", "EBase" })) return .emoji_modifier_base;
    if (oneOf(name, &.{ "Extender", "Ext" })) return .extender;
    if (oneOf(name, &.{ "Grapheme_Base", "Gr_Base" })) return .grapheme_base;
    if (oneOf(name, &.{ "Grapheme_Extend", "Gr_Ext" })) return .grapheme_extend;
    if (oneOf(name, &.{ "Hex_Digit", "Hex" })) return .hex_digit;
    if (asciiEquals(name, "Ideographic") or asciiEquals(name, "Ideo")) return .ideographic;
    if (oneOf(name, &.{ "IDS_Binary_Operator", "IDSB" })) return .ids_binary_operator;
    if (oneOf(name, &.{ "IDS_Trinary_Operator", "IDST" })) return .ids_trinary_operator;
    if (oneOf(name, &.{ "Join_Control", "Join_C" })) return .join_control;
    if (oneOf(name, &.{ "Logical_Order_Exception", "LOE" })) return .logical_order_exception;
    if (oneOf(name, &.{ "Lowercase", "Lower" })) return .lowercase;
    if (asciiEquals(name, "Math")) return .math;
    if (oneOf(name, &.{ "Noncharacter_Code_Point", "NChar" })) return .noncharacter_code_point;
    if (oneOf(name, &.{ "Pattern_Syntax", "Pat_Syn" })) return .pattern_syntax;
    if (oneOf(name, &.{ "Pattern_White_Space", "Pat_WS" })) return .pattern_white_space;
    if (oneOf(name, &.{ "Quotation_Mark", "QMark" })) return .quotation_mark;
    if (asciiEquals(name, "Radical")) return .radical;
    if (oneOf(name, &.{ "Regional_Indicator", "RI" })) return .regional_indicator;
    if (oneOf(name, &.{ "Sentence_Terminal", "STerm" })) return .sentence_terminal;
    if (oneOf(name, &.{ "Soft_Dotted", "SD" })) return .soft_dotted;
    if (oneOf(name, &.{ "Terminal_Punctuation", "Term" })) return .terminal_punctuation;
    if (oneOf(name, &.{ "Unified_Ideograph", "UIdeo" })) return .unified_ideograph;
    if (oneOf(name, &.{ "Uppercase", "Upper" })) return .uppercase;
    if (oneOf(name, &.{ "Variation_Selector", "VS" })) return .variation_selector;
    if (asciiEquals(name, "White_Space")) return .white_space;
    if (asciiEquals(name, "WSpace")) return .white_space;
    if (asciiEquals(name, "Emoji")) return .emoji;
    if (asciiEquals(name, "Emoji_Presentation")) return .emoji_presentation;
    if (asciiEquals(name, "Extended_Pictographic")) return .extended_pictographic;
    if (asciiEquals(name, "ID_Start")) return .id_start;
    if (asciiEquals(name, "IDS")) return .id_start;
    if (asciiEquals(name, "ID_Continue")) return .id_continue;
    if (asciiEquals(name, "IDC")) return .id_continue;
    if (oneOf(name, &.{ "XID_Continue", "XIDC" })) return .xid_continue;
    if (oneOf(name, &.{ "XID_Start", "XIDS" })) return .xid_start;

    if (oneOf(name, &.{ "Cased_Letter", "LC", "General_Category=Cased_Letter", "General_Category=LC", "gc=Cased_Letter", "gc=LC" })) return .cased_letter;
    if (oneOf(name, &.{ "Close_Punctuation", "Pe", "General_Category=Close_Punctuation", "General_Category=Pe", "gc=Close_Punctuation", "gc=Pe" })) return .close_punctuation;
    if (oneOf(name, &.{ "Connector_Punctuation", "Pc", "General_Category=Connector_Punctuation", "General_Category=Pc", "gc=Connector_Punctuation", "gc=Pc" })) return .connector_punctuation;
    if (oneOf(name, &.{ "Control", "Cc", "General_Category=Control", "General_Category=Cc", "gc=Control", "gc=Cc" })) return .control;
    if (oneOf(name, &.{ "Currency_Symbol", "Sc", "General_Category=Currency_Symbol", "General_Category=Sc", "gc=Currency_Symbol", "gc=Sc" })) return .currency_symbol;
    if (oneOf(name, &.{ "Dash_Punctuation", "Pd", "General_Category=Dash_Punctuation", "General_Category=Pd", "gc=Dash_Punctuation", "gc=Pd" })) return .dash_punctuation;
    if (oneOf(name, &.{ "Enclosing_Mark", "Me", "General_Category=Enclosing_Mark", "General_Category=Me", "gc=Enclosing_Mark", "gc=Me" })) return .enclosing_mark;
    if (oneOf(name, &.{ "Final_Punctuation", "Pf", "General_Category=Final_Punctuation", "General_Category=Pf", "gc=Final_Punctuation", "gc=Pf" })) return .final_punctuation;
    if (oneOf(name, &.{ "Format", "Cf", "General_Category=Format", "General_Category=Cf", "gc=Format", "gc=Cf" })) return .format;
    if (oneOf(name, &.{ "Initial_Punctuation", "Pi", "General_Category=Initial_Punctuation", "General_Category=Pi", "gc=Initial_Punctuation", "gc=Pi" })) return .initial_punctuation;
    if (oneOf(name, &.{ "Letter_Number", "Nl", "General_Category=Letter_Number", "General_Category=Nl", "gc=Letter_Number", "gc=Nl" })) return .letter_number;
    if (oneOf(name, &.{ "Line_Separator", "Zl", "General_Category=Line_Separator", "General_Category=Zl", "gc=Line_Separator", "gc=Zl" })) return .line_separator;
    if (oneOf(name, &.{ "Math_Symbol", "Sm", "General_Category=Math_Symbol", "General_Category=Sm", "gc=Math_Symbol", "gc=Sm" })) return .math_symbol;
    if (oneOf(name, &.{ "Modifier_Letter", "Lm", "General_Category=Modifier_Letter", "General_Category=Lm", "gc=Modifier_Letter", "gc=Lm" })) return .modifier_letter;
    if (oneOf(name, &.{ "Modifier_Symbol", "Sk", "General_Category=Modifier_Symbol", "General_Category=Sk", "gc=Modifier_Symbol", "gc=Sk" })) return .modifier_symbol;
    if (oneOf(name, &.{ "Nonspacing_Mark", "Mn", "General_Category=Nonspacing_Mark", "General_Category=Mn", "gc=Nonspacing_Mark", "gc=Mn" })) return .nonspacing_mark;
    if (oneOf(name, &.{ "Open_Punctuation", "Ps", "General_Category=Open_Punctuation", "General_Category=Ps", "gc=Open_Punctuation", "gc=Ps" })) return .open_punctuation;
    if (oneOf(name, &.{ "Other", "C", "General_Category=Other", "General_Category=C", "gc=Other", "gc=C" })) return .other;
    if (oneOf(name, &.{ "Other_Letter", "Lo", "General_Category=Other_Letter", "General_Category=Lo", "gc=Other_Letter", "gc=Lo" })) return .other_letter;
    if (oneOf(name, &.{ "Other_Number", "No", "General_Category=Other_Number", "General_Category=No", "gc=Other_Number", "gc=No" })) return .other_number;
    if (oneOf(name, &.{ "Other_Punctuation", "Po", "General_Category=Other_Punctuation", "General_Category=Po", "gc=Other_Punctuation", "gc=Po" })) return .other_punctuation;
    if (oneOf(name, &.{ "Other_Symbol", "So", "General_Category=Other_Symbol", "General_Category=So", "gc=Other_Symbol", "gc=So" })) return .other_symbol;
    if (oneOf(name, &.{ "Paragraph_Separator", "Zp", "General_Category=Paragraph_Separator", "General_Category=Zp", "gc=Paragraph_Separator", "gc=Zp" })) return .paragraph_separator;
    if (oneOf(name, &.{ "Private_Use", "Co", "General_Category=Private_Use", "General_Category=Co", "gc=Private_Use", "gc=Co" })) return .private_use;
    if (oneOf(name, &.{ "Space_Separator", "Zs", "General_Category=Space_Separator", "General_Category=Zs", "gc=Space_Separator", "gc=Zs" })) return .space_separator;
    if (oneOf(name, &.{ "Spacing_Mark", "Mc", "General_Category=Spacing_Mark", "General_Category=Mc", "gc=Spacing_Mark", "gc=Mc" })) return .spacing_mark;
    if (oneOf(name, &.{ "Surrogate", "Cs", "General_Category=Surrogate", "General_Category=Cs", "gc=Surrogate", "gc=Cs" })) return .surrogate;
    if (oneOf(name, &.{ "Titlecase_Letter", "Lt", "General_Category=Titlecase_Letter", "General_Category=Lt", "gc=Titlecase_Letter", "gc=Lt" })) return .titlecase_letter;
    if (oneOf(name, &.{ "Unassigned", "Cn", "General_Category=Unassigned", "General_Category=Cn", "gc=Unassigned", "gc=Cn" })) return .unassigned;
    if (oneOf(name, &.{ "Letter", "L", "General_Category=Letter", "General_Category=L", "gc=Letter", "gc=L" })) return .letter;
    if (oneOf(name, &.{ "Lowercase_Letter", "Ll", "General_Category=Lowercase_Letter", "General_Category=Ll", "gc=Lowercase_Letter", "gc=Ll" })) return .lowercase_letter;
    if (oneOf(name, &.{ "Uppercase_Letter", "Lu", "General_Category=Uppercase_Letter", "General_Category=Lu", "gc=Uppercase_Letter", "gc=Lu" })) return .uppercase_letter;
    if (oneOf(name, &.{ "Mark", "M", "General_Category=Mark", "General_Category=M", "gc=Mark", "gc=M" })) return .mark;
    if (oneOf(name, &.{ "Number", "N", "General_Category=Number", "General_Category=N", "gc=Number", "gc=N" })) return .number;
    if (oneOf(name, &.{ "Decimal_Number", "Nd", "General_Category=Decimal_Number", "General_Category=Nd", "gc=Decimal_Number", "gc=Nd" })) return .decimal_number;
    if (oneOf(name, &.{ "Punctuation", "P", "General_Category=Punctuation", "General_Category=P", "gc=Punctuation", "gc=P" })) return .punctuation;
    if (oneOf(name, &.{ "Symbol", "S", "General_Category=Symbol", "General_Category=S", "gc=Symbol", "gc=S" })) return .symbol;
    if (oneOf(name, &.{ "Separator", "Z", "General_Category=Separator", "General_Category=Z", "gc=Separator", "gc=Z" })) return .separator;

    if (unicode_properties.lookupScript(name)) |property| return property;
    return null;
}

pub fn oneOf(name: []const u16, values: []const []const u8) bool {
    for (values) |value| if (asciiEquals(name, value)) return true;
    return false;
}

pub fn asciiEquals(units: []const u16, text: []const u8) bool {
    if (units.len != text.len) return false;
    for (text, 0..) |unit, index| if (units[index] != unit) return false;
    return true;
}
