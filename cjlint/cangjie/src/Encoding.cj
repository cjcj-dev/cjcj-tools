package cjlint

// Validate the actual source bytes before constructing String or invoking the
// frontend. Reject overlong encodings, surrogates, truncation and values > U+10FFFF.
func validSourceUtf8(bytes: Array<UInt8>): Bool {
    var index: Int64 = 0
    while (index < bytes.size) {
        let first = bytes[index]
        if (first < 0x80) { index++; continue }
        var length: Int64 = 0
        if (first >= 0xc2 && first <= 0xdf) { length = 2 }
        else if (first >= 0xe0 && first <= 0xef) { length = 3 }
        else if (first >= 0xf0 && first <= 0xf4) { length = 4 }
        else { return false }
        if (index + length > bytes.size) { return false }
        for (next in 1..length) {
            if (bytes[index + next] < 0x80 || bytes[index + next] > 0xbf) { return false }
        }
        let second = bytes[index + 1]
        if ((first == 0xe0 && second < 0xa0) || (first == 0xed && second >= 0xa0) ||
            (first == 0xf0 && second < 0x90) || (first == 0xf4 && second >= 0x90)) { return false }
        index += length
    }
    return true
}
