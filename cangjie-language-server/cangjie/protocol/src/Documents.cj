// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cangjie_lsp_protocol

import std.collection.*

public struct ProtocolPosition {
    public let line: Int64
    public let character: Int64
    public init(line: Int64, character: Int64) {
        if (line < 0 || character < 0) { throw IllegalArgumentException("Negative document position") }
        this.line = line
        this.character = character
    }
}

public struct TextChange {
    public let range: Option<(ProtocolPosition, ProtocolPosition)>
    public let text: String
    public init(text: String, range!: Option<(ProtocolPosition, ProtocolPosition)> = None) {
        this.text = text
        this.range = range
    }
}

// LSP columns are UTF-16 code units; compiler positions are UTF-8 bytes.
// Conversion happens once at the text boundary, before Parser sees a source.
public func ProtocolOffset(text: String, position: ProtocolPosition): Int64 {
    let bytes = text.toArray()
    var offset: Int64 = 0
    var line: Int64 = 0
    while (line < position.line && offset < bytes.size) {
        if (bytes[offset] == 13) {
            offset++
            if (offset < bytes.size && bytes[offset] == 10) { offset++ }
            line++
        } else if (bytes[offset] == 10) { offset++; line++ }
        else { offset++ }
    }
    if (line < position.line) { return bytes.size }
    var units: Int64 = 0
    while (offset < bytes.size && bytes[offset] != 10 && bytes[offset] != 13) {
        if (units == position.character) { return offset }
        let decoded = Rune.fromUtf8(bytes, offset)
        let width: Int64 = if (UInt32(decoded[0]) > 0xffffu32) { 2 } else { 1 }
        if (units + width > position.character) { throw IllegalArgumentException("Position splits a UTF-16 surrogate pair") }
        units += width
        offset += decoded[1]
    }
    return offset
}

public class DocumentSnapshot {
    public let uri: String
    public let version: Int64
    public let text: String
    public init(uri: String, version: Int64, text: String) {
        this.uri = uri; this.version = version; this.text = text
    }
}

public class DocumentStore {
    private let documents = HashMap<String, DocumentSnapshot>()
    public init() {}
    public func Open(uri: String, version: Int64, text: String): DocumentSnapshot {
        let snapshot = DocumentSnapshot(uri, version, text)
        documents[uri] = snapshot
        return snapshot
    }
    public func Get(uri: String): DocumentSnapshot {
        return documents.get(uri).getOrThrow()
    }
    public func Close(uri: String): Unit { documents.remove(uri) }
    public func Change(uri: String, version: Int64, changes: Array<TextChange>): DocumentSnapshot {
        let previous = Get(uri)
        if (version <= previous.version) { throw IllegalArgumentException("Non-increasing document version") }
        var text = previous.text
        // Ordered changes refer to the result of the previous change. Publish
        // only after the whole notification has passed range validation.
        for (change in changes) {
            if (let Some(range) <- change.range) {
                let begin = ProtocolOffset(text, range[0])
                let end = ProtocolOffset(text, range[1])
                if (begin > end) { throw IllegalArgumentException("Reversed document range") }
                text = text[0..begin] + change.text + text[end..text.size]
            } else { text = change.text }
        }
        return Open(uri, version, text)
    }
}
