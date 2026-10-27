// Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
// Licensed under Apache-2.0 with Runtime Library Exception.
package cangjie_lsp_core

import std.collection.*
import std.convert.*

// The byte framing layer deliberately does not parse JSON or pretend to be a
// semantic server. It accepts fragmented/coalesced stdio reads and emits only
// complete payloads. The existing transport's 2^25 byte body limit is retained.
public class MessageFramer {
    private var pending = ArrayList<UInt8>()
    private var contentLength: Int64 = -1
    public init() {}

    public func Feed(bytes: Array<UInt8>): Array<String> {
        pending.add(all: bytes)
        let messages = ArrayList<String>()
        while (true) {
            if (contentLength < 0) {
                var boundary: Int64 = -1
                var separator: Int64 = 0
                var idx: Int64 = 0
                while (idx + 1 < pending.size) {
                    if (pending[idx] == 10 && pending[idx + 1] == 10) { boundary = idx; separator = 2; break }
                    if (idx + 3 < pending.size && pending[idx] == 13 && pending[idx + 1] == 10 && pending[idx + 2] == 13 && pending[idx + 3] == 10) {
                        boundary = idx; separator = 4; break
                    }
                    idx++
                }
                if (boundary < 0) { break }
                let header = String.fromUtf8(pending.toArray()[0..boundary])
                var length: Int64 = 0
                for (line in header.split("
")) {
                    let trimmed = line.trimAscii()
                    if (trimmed.startsWith("#")) { continue }
                    if (trimmed.startsWith("Content-Length:")) {
                        let raw = trimmed[15..trimmed.size].trimAscii()
                        if (raw.isEmpty()) { throw IllegalArgumentException("Missing Content-Length") }
                        for (byte in raw.toArray()) {
                            if (byte < 48 || byte > 57) { throw IllegalArgumentException("Invalid Content-Length") }
                        }
                        length = Int64.parse(raw)
                    }
                }
                if (length <= 0 || length > 33554432) { throw IllegalArgumentException("Invalid Content-Length") }
                pending = ArrayList<UInt8>(pending.toArray()[(boundary + separator)..pending.size])
                contentLength = length
            }
            if (pending.size < contentLength) { break }
            messages.add(String.fromUtf8(pending.toArray()[0..contentLength]))
            pending = ArrayList<UInt8>(pending.toArray()[contentLength..pending.size])
            contentLength = -1
        }
        return messages.toArray()
    }

    public func EndOfInput(): Unit {
        if (contentLength >= 0 || !pending.isEmpty()) { throw IllegalArgumentException("Truncated protocol frame") }
    }
}

public func EncodeMessage(json: String): Array<UInt8> {
    return ("Content-Length: "+json.size.toString()+"

"+json).toArray()
}
