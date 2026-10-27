import cangjie_lsp_core.*
import cangjie_lsp_protocol.*
import std.collection.*

func check(value: Bool, name: String): Unit {
    if (!value) { throw Exception("LSP_TARGET_FAIL " + name) }
    println("LSP_TARGET_PASS " + name)
}

func framing(): Unit {
    let body = #"{"jsonrpc":"2.0","id":17,"method":"示例😀"}"#
    let encoded = EncodeMessage(body)
    let decoder = MessageFramer()
    let messages = ArrayList<String>()
    for (byte in encoded) { messages.add(all: decoder.Feed([byte])) }
    check(messages.size == 1 && messages[0] == body, "fragmented-utf8-byte-length")
    decoder.EndOfInput()
    let joined = ArrayList<UInt8>(encoded)
    joined.add(all: EncodeMessage("{}"))
    let two = MessageFramer().Feed(joined.toArray())
    check(two.size == 2 && two[0] == body && two[1] == "{}", "coalesced-messages")
    check(MessageFramer().Feed("# log\nContent-Length: 2\n\n{}".toArray())[0] == "{}", "legacy-lf-header")
    var truncated = false
    try { let d = MessageFramer(); d.Feed("Content-Length: 3\r\n\r\n{}".toArray()); d.EndOfInput() }
    catch (_: Exception) { truncated = true }
    check(truncated, "truncated-body-refused")
    for (header in ["0", "-1", "33554433", "bad"]) {
        var rejected = false
        try { MessageFramer().Feed(("Content-Length: "+header+"\r\n\r\n").toArray()) }
        catch (_: Exception) { rejected = true }
        check(rejected, "bad-length-"+header)
    }
}

func documents(): Unit {
    let store = DocumentStore()
    let uri = "file:///workspace/a.cj"
    let old = store.Open(uri, 1, "// 😀中文\r\nmain() { println(7) }\r\n")
    let changed = store.Change(uri, 2, [TextChange("EN", range: (ProtocolPosition(0, 5), ProtocolPosition(0, 7)))])
    check(changed.text == "// 😀EN\r\nmain() { println(7) }\r\n", "utf16-edit-after-supplementary")
    check(old.text == "// 😀中文\r\nmain() { println(7) }\r\n", "snapshot-immutable")
    let parsed = ParsedDocument(store.Get(uri))
    check(parsed.diagnostics.GetErrorCount() == 0 && parsed.ast.decls.size == 1, "real-cangjie-parser")
    let replaced = store.Change(uri, 3, [TextChange("main() { println(8) }"),
        TextChange("9", range: (ProtocolPosition(0, 17), ProtocolPosition(0, 18)))])
    check(replaced.text == "main() { println(9) }", "ordered-full-and-range-changes")
    check(parsed.snapshot.version == 2 && parsed.snapshot.text == changed.text, "parse-snapshot-not-hot-swapped")
    var invalid = false
    try { store.Change(uri, 4, [TextChange("bad", range: (ProtocolPosition(0, 10), ProtocolPosition(0, 2)))]) }
    catch (_: Exception) { invalid = true }
    check(invalid && store.Get(uri).version == 3 && store.Get(uri).text == replaced.text, "invalid-change-atomic")
    var stale = false
    try { store.Change(uri, 3, [TextChange("stale")]) } catch (_: Exception) { stale = true }
    check(stale && store.Get(uri).text == replaced.text, "stale-version-refused")
    store.Change(uri, 4, [TextChange("func broken( { }")])
    check(ParsedDocument(store.Get(uri)).diagnostics.GetErrorCount() > 0, "real-parser-error")
    store.Close(uri)
    var closed = false
    try { store.Get(uri) } catch (_: Exception) { closed = true }
    check(closed, "closed-document-removed")
}

main(args: Array<String>): Int64 {
    try {
        if (args.size == 0 || args[0] == "framing") { framing() }
        if (args.size == 0 || args[0] == "documents") { documents() }
        return 0
    } catch (error: Exception) { eprintln(error.message); return 41 }
}
