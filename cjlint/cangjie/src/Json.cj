package cjlint

import std.collection.*

// JSON belongs to the tool configuration/report layer. Source analysis uses cjcj ASTs.
class JsonValue {
    let kind: String
    var scalar: String = ""
    let fields = HashMap<String, JsonValue>()
    let items = ArrayList<JsonValue>()
    init(kind: String) { this.kind = kind }
    func field(name: String): JsonValue {
        if (let Some(value) <- fields.get(name)) { return value }
        throw Exception("Missing JSON field: " + name)
    }
    func text(): String {
        if (kind != "string") { throw Exception("Expected JSON string") }
        return scalar
    }
}

func jsonQuote(text: String): String {
    let result = ArrayList<UInt8>()
    result.add(34)
    let hex = "0123456789abcdef".toArray()
    for (c in text.toArray()) {
        if (c == 34 || c == 92) { result.add(92); result.add(c) }
        else if (c < 32) {
            for (part in "\\u00".toArray()) { result.add(part) }
            result.add(hex[Int64(c / 16)]); result.add(hex[Int64(c % 16)])
        } else { result.add(c) }
    }
    result.add(34)
    return String.fromUtf8(result.toArray())
}

class JsonReader {
    let bytes: Array<UInt8>
    var offset: Int64 = 0
    init(text: String) { bytes = text.toArray() }
    func error(): Nothing { throw Exception("Invalid JSON at byte ${offset}") }
    func peek(): UInt8 { return if (offset < bytes.size) { bytes[offset] } else { 0 } }
    func spaces(): Unit {
        while (peek() == 32 || peek() == 9 || peek() == 10 || peek() == 13) { offset++ }
    }
    func take(c: UInt8): Unit {
        spaces()
        if (peek() != c) { error() }
        offset++
    }
    func hex4(): UInt32 {
        var value: UInt32 = 0
        for (_ in 0..4) {
            let c = peek()
            let digit = if (c >= 48 && c <= 57) { UInt32(c - 48) }
                else if (c >= 65 && c <= 70) { UInt32(c - 55) }
                else if (c >= 97 && c <= 102) { UInt32(c - 87) }
                else { error() }
            value = value * 16 + digit
            offset++
        }
        return value
    }
    func appendCodepoint(out: ArrayList<UInt8>, cp: UInt32): Unit {
        if (cp <= 0x7f) { out.add(UInt8(cp)) }
        else if (cp <= 0x7ff) {
            out.add(UInt8(0xc0 | (cp >> 6)))
            out.add(UInt8(0x80 | (cp & 63)))
        } else if (cp <= 0xffff) {
            out.add(UInt8(0xe0 | (cp >> 12)))
            out.add(UInt8(0x80 | ((cp >> 6) & 63)))
            out.add(UInt8(0x80 | (cp & 63)))
        } else {
            out.add(UInt8(0xf0 | (cp >> 18)))
            out.add(UInt8(0x80 | ((cp >> 12) & 63)))
            out.add(UInt8(0x80 | ((cp >> 6) & 63)))
            out.add(UInt8(0x80 | (cp & 63)))
        }
    }
    func stringValue(): String {
        take(34)
        let out = ArrayList<UInt8>()
        while (peek() != 34) {
            let c = peek()
            if (c < 32) { error() }
            offset++
            if (c != 92) { out.add(c); continue }
            let escaped = peek()
            offset++
            match (escaped) {
                case 34 | 47 | 92 => out.add(escaped)
                case 98 => out.add(8)
                case 102 => out.add(12)
                case 110 => out.add(10)
                case 114 => out.add(13)
                case 116 => out.add(9)
                case 117 =>
                    var cp = hex4()
                    if (cp >= 0xd800 && cp <= 0xdbff) {
                        // No whitespace is permitted inside an escape sequence.
                        if (peek() != 92) { error() }; offset++
                        if (peek() != 117) { error() }; offset++
                        let low = hex4()
                        if (low < 0xdc00 || low > 0xdfff) { error() }
                        cp = 0x10000 + ((cp - 0xd800) << 10) + low - 0xdc00
                    } else if (cp >= 0xdc00 && cp <= 0xdfff) { error() }
                    appendCodepoint(out, cp)
                case _ => error()
            }
        }
        offset++
        return String.fromUtf8(out.toArray())
    }
    func value(depth: Int64): JsonValue {
        if (depth > 128) { throw Exception("JSON nesting limit exceeded") }
        spaces()
        if (peek() == 34) {
            let result = JsonValue("string"); result.scalar = stringValue(); return result
        }
        if (peek() == 123) {
            offset++
            let result = JsonValue("object")
            spaces()
            if (peek() == 125) { offset++; return result }
            while (true) {
                let key = stringValue()
                take(58)
                if (result.fields.contains(key)) { throw Exception("Duplicate JSON field: " + key) }
                result.fields[key] = value(depth + 1)
                spaces()
                if (peek() == 125) { offset++; return result }
                take(44)
            }
        }
        if (peek() == 91) {
            offset++
            let result = JsonValue("array")
            spaces()
            if (peek() == 93) { offset++; return result }
            while (true) {
                result.items.add(value(depth + 1))
                spaces()
                if (peek() == 93) { offset++; return result }
                take(44)
            }
        }
        for (literal in ["true", "false", "null"]) {
            let expected = literal.toArray()
            if (peek() != expected[0]) { continue }
            for (c in expected) { if (peek() != c) { error() }; offset++ }
            let result = JsonValue(literal); result.scalar = literal; return result
        }
        let start = offset
        if (peek() == 45) { offset++ }
        if (peek() == 48) { offset++ }
        else {
            if (peek() < 49 || peek() > 57) { error() }
            while (peek() >= 48 && peek() <= 57) { offset++ }
        }
        if (peek() == 46) {
            offset++
            if (peek() < 48 || peek() > 57) { error() }
            while (peek() >= 48 && peek() <= 57) { offset++ }
        }
        if (peek() == 69 || peek() == 101) {
            offset++
            if (peek() == 43 || peek() == 45) { offset++ }
            if (peek() < 48 || peek() > 57) { error() }
            while (peek() >= 48 && peek() <= 57) { offset++ }
        }
        let result = JsonValue("number")
        result.scalar = String.fromUtf8(bytes[start..offset])
        return result
    }
    func parse(): JsonValue {
        let result = value(0)
        spaces()
        if (offset != bytes.size) { error() }
        return result
    }
}
