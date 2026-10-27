package cangjie_lsp

import std.collection.*
import std.console.Console
import std.convert.*
import std.fs.Path
import stdx.encoding.json.*
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*
import cjcj::basic.DiagSeverity

func object(fields: Array<(String, JsonValue)>): JsonObject {
    let result = JsonObject()
    for ((key, value) in fields) { result.put(key, value) }
    return result
}
func field(value: JsonValue, key: String): JsonValue { return value.asObject()[key] }
func string(value: JsonValue, key: String): String { return field(value, key).asString().getValue() }
func number(value: JsonValue, key: String): Int64 { return field(value, key).asInt().getValue() }
func position(value: JsonValue): ProtocolPosition { return ProtocolPosition(number(value, "line"), number(value, "character")) }
func positionJson(value: ProtocolPosition): JsonValue {
    return object([("line", JsonInt(value.line)), ("character", JsonInt(value.character))])
}
func rangeJson(start: ProtocolPosition, end: ProtocolPosition): JsonValue {
    return object([("start", positionJson(start)), ("end", positionJson(end))])
}
func hex(byte: UInt8): UInt8 {
    if (byte >= 48 && byte <= 57) { return byte - 48 }
    if (byte >= 65 && byte <= 70) { return byte - 55 }
    if (byte >= 97 && byte <= 102) { return byte - 87 }
    throw IllegalArgumentException("Invalid percent encoding")
}
func filePath(uri: String): String {
    if (!uri.startsWith("file:///")) { throw IllegalArgumentException("Only absolute local file URIs are supported") }
    let bytes = uri.toArray(); let decoded = ArrayList<UInt8>(); var idx: Int64 = 7
    while (idx < bytes.size) {
        if (bytes[idx] == 37) {
            if (idx + 2 >= bytes.size) { throw IllegalArgumentException("Truncated URI escape") }
            decoded.add(hex(bytes[idx + 1]) * 16 + hex(bytes[idx + 2])); idx += 3
        } else {
            if (bytes[idx] == 35 || bytes[idx] == 63) { throw IllegalArgumentException("Unexpected URI fragment/query") }
            decoded.add(bytes[idx]); idx++
        }
    }
    let result = String.fromUtf8(decoded.toArray())
    if (result.contains("\u{0}")) { throw IllegalArgumentException("NUL in file URI") }
    return result
}
func fileUri(path: String): String {
    let out = StringBuilder(); out.append("file://")
    let digits = "0123456789ABCDEF".toArray()
    for (byte in path.toArray()) {
        if ((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) ||
            byte == 47 || byte == 45 || byte == 46 || byte == 95 || byte == 126) { out.append(String.fromUtf8([byte])) }
        else { out.append("%" + String.fromUtf8([digits[Int64(byte / 16)], digits[Int64(byte % 16)]])) }
    }
    return out.toString()
}
func parent(path: String): String {
    let bytes = path.toArray(); var idx = bytes.size - 1
    while (idx >= 0 && bytes[idx] != 47) { idx-- }
    return path[0..(idx + 1)]
}
func locationJson(location: SemanticLocation): JsonValue {
    return object([("uri", JsonString(fileUri(location.path))), ("range", rangeJson(location.start, location.end))])
}
func send(value: JsonValue): Unit { Console.stdOut.write(EncodeMessage(value.toString())); Console.stdOut.flush() }
func response(id: JsonValue, result: JsonValue): Unit {
    send(object([("jsonrpc", JsonString("2.0")), ("id", id), ("result", result)]))
}
func error(id: JsonValue, code: Int64, message: String): Unit {
    send(object([("jsonrpc", JsonString("2.0")), ("id", id), ("error", object([("code", JsonInt(code)), ("message", JsonString(message))]))]))
}

class Server {
    let sdk: String
    let documents = DocumentStore()
    let semantics = HashMap<String, SemanticDocument>()
    var initialized = false
    var stopped = false
    var exiting = false
    var exitCode: Int64 = 1
    init(sdk: String) { this.sdk = sdk }

    func publish(path: String, version: Int64, items: Array<JsonValue>): Unit {
        send(object([("jsonrpc", JsonString("2.0")), ("method", JsonString("textDocument/publishDiagnostics")),
            ("params", object([("uri", JsonString(fileUri(path))), ("version", JsonInt(version)), ("diagnostics", JsonArray(items))]))]))
    }
    func analyze(): Unit {
        semantics.clear()
        let snapshots = documents.Snapshots()
        for (snapshot in snapshots) {
            let peers = ArrayList<DocumentSnapshot>()
            for (peer in snapshots) { if (parent(peer.uri) == parent(snapshot.uri)) { peers.add(peer) } }
            let semantic = SemanticDocument(snapshot, sdk, companions: peers.toArray())
            semantics[snapshot.uri] = semantic
            let items = ArrayList<JsonValue>()
            for (diag in semantic.records) {
                let begin = if (diag.isRefactor) { diag.mainHint.range.begin } else { diag.start }
                let end = if (diag.isRefactor) { diag.mainHint.range.end } else { diag.end }
                if (begin.fileID == 0) { continue }
                let source = semantic.compiler.GetSourceManager().GetSource(begin.fileID)
                if (source.path != snapshot.uri) { continue }
                let first = source.PosToOffset(begin)
                let last = if (end.fileID == begin.fileID) { source.PosToOffset(end) } else { first }
                let message = if (diag.isRefactor) { diag.errorMessage } else { diag.diagMessage }
                let severity: Int64 = match (diag.diagSeverity) {
                    case DiagSeverity.DS_ERROR => 1
                    case DiagSeverity.DS_WARNING => 2
                    case DiagSeverity.DS_NOTE => 3
                    case _ => 4
                }
                items.add(object([("range", rangeJson(ProtocolPositionAt(source.buffer, first), ProtocolPositionAt(source.buffer, max(first, last)))),
                    ("severity", JsonInt(severity)), ("source", JsonString("cangjie")), ("message", JsonString(message))]))
            }
            publish(snapshot.uri, snapshot.version, items.toArray())
        }
    }
    func receive(value: JsonValue): Unit {
        let request = value.asObject()
        let id = request.get("id")
        if (string(value, "jsonrpc") != "2.0") { error(id.getOrDefault({ => JsonNull() }), -32600, "Invalid JSON-RPC version"); return }
        let method = string(value, "method")
        if (method == "exit") { exiting = true; exitCode = if (stopped) { 0 } else { 1 }; return }
        if (stopped) { if (let Some(key) <- id) { error(key, -32600, "Server has shut down") }; return }
        if (method == "initialize") {
            if (initialized) { if (let Some(key) <- id) { error(key, -32600, "Already initialized") }; return }
            let key = id.getOrThrow(); initialized = true
            response(key, object([("capabilities", object([("positionEncoding", JsonString("utf-16")),
                ("textDocumentSync", object([("openClose", JsonBool(true)), ("change", JsonInt(2))])),
                ("definitionProvider", JsonBool(true)), ("referencesProvider", JsonBool(true))])),
                ("serverInfo", object([("name", JsonString("cangjie-lsp")), ("version", JsonString("0.1.0"))]))]))
            return
        }
        if (!initialized) { if (let Some(key) <- id) { error(key, -32002, "Server not initialized") }; return }
        if (method == "shutdown") { response(id.getOrThrow(), JsonNull()); stopped = true; return }
        if (method == "initialized" || method == "$/cancelRequest") { return }
        let params = request.get("params").getOrDefault({ => JsonObject() })
        if (method == "textDocument/didOpen") {
            let doc = field(params, "textDocument"); let path = filePath(string(doc, "uri"))
            documents.Open(path, number(doc, "version"), string(doc, "text")); analyze(); return
        }
        if (method == "textDocument/didChange") {
            let doc = field(params, "textDocument"); let changes = ArrayList<TextChange>()
            for (item in field(params, "contentChanges").asArray().getItems()) {
                var range: Option<(ProtocolPosition, ProtocolPosition)> = None
                if (let Some(r) <- item.asObject().get("range")) { range = Some((position(field(r, "start")), position(field(r, "end")))) }
                changes.add(TextChange(string(item, "text"), range: range))
            }
            documents.Change(filePath(string(doc, "uri")), number(doc, "version"), changes.toArray()); analyze(); return
        }
        if (method == "textDocument/didClose") {
            let path = filePath(string(field(params, "textDocument"), "uri")); let old = documents.Get(path)
            documents.Close(path); semantics.remove(path); publish(path, old.version, []); analyze(); return
        }
        if (method == "textDocument/definition" || method == "textDocument/references") {
            let path = filePath(string(field(params, "textDocument"), "uri")); let semantic = semantics.get(path).getOrThrow()
            if (!semantic.succeeded) { response(id.getOrThrow(), JsonNull()); return }
            let pos = position(field(params, "position"))
            if (method == "textDocument/definition") {
                if (let Some(found) <- semantic.Definition(pos)) { response(id.getOrThrow(), locationJson(found)) }
                else { response(id.getOrThrow(), JsonNull()) }
            } else {
                let include = field(field(params, "context"), "includeDeclaration").asBool().getValue()
                let results = ArrayList<JsonValue>()
                for (found in semantic.References(pos, includeDeclaration: include)) { results.add(locationJson(found)) }
                response(id.getOrThrow(), JsonArray(results))
            }
            return
        }
        if (let Some(key) <- id) { error(key, -32601, "Method not found: " + method) }
    }
}

main(args: Array<String>): Int64 {
    if (args.size != 2 || args[0] != "--sdk") { Console.stdErr.writeln("Usage: cangjie-lsp --sdk <target SDK>"); return 2 }
    let server = Server(args[1]); let framer = MessageFramer(); let buffer = Array<UInt8>(1, repeat: 0)
    try {
        while (!server.exiting) {
            let count = Console.stdIn.read(buffer)
            if (count == 0) { framer.EndOfInput(); return if (server.stopped) { 0 } else { 1 } }
            for (text in framer.Feed(buffer)) {
                var parsed: Option<JsonValue> = None
                try { parsed = Some(JsonValue.fromStr(text)) }
                catch (exception: Exception) { error(JsonNull(), -32700, "Parse error"); continue }
                let value = parsed.getOrThrow()
                try { server.receive(value) }
                catch (exception: Exception) {
                    if (let Some(obj) <- (value as JsonObject)) {
                        if (let Some(id) <- obj.get("id")) { error(id, -32602, exception.message) }
                        else { Console.stdErr.writeln(exception.message) }
                    } else { error(JsonNull(), -32600, "Invalid request") }
                }
                if (server.exiting) { break }
            }
        }
    } catch (exception: Exception) { Console.stdErr.writeln(exception.message); return 2 }
    return server.exitCode
}
