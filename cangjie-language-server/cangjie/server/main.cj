package cangjie_lsp

import std.collection.*
import std.console.Console
import std.convert.*
import std.fs.*
import stdx.encoding.json.*
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*
import cjcj::basic.DiagSeverity

// Linux host stdio reads bytes, not ConsoleReader's line-oriented buffer.
foreign func read(fd: Int32, buffer: CPointer<UInt8>, count: UIntNative): IntNative

func readInput(buffer: Array<UInt8>): Int64 {
    let handle = unsafe { acquireArrayRawData(buffer) }
    try {
        let count = unsafe { read(0, handle.pointer, UIntNative(buffer.size)) }
        if (count < 0) { throw IllegalStateException("stdin read failed") }
        return Int64(count)
    } finally { unsafe { releaseArrayRawData(handle) } }
}


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
    let workspaceRoots = HashSet<String>()
    var compilationDatabase = ""
    var initialized = false
    var stopped = false
    var exiting = false
    var exitCode: Int64 = 1
    init(sdk: String) { this.sdk = sdk }

    func publish(path: String, version: Int64, items: Array<JsonValue>): Unit {
        send(object([("jsonrpc", JsonString("2.0")), ("method", JsonString("textDocument/publishDiagnostics")),
            ("params", object([("uri", JsonString(fileUri(path))), ("version", JsonInt(version)), ("diagnostics", JsonArray(items))]))]))
    }
    func addWorkspace(uri: String): Unit {
        let directory = canonicalize(filePath(uri)).toString()
        if (!FileInfo(directory).isDirectory()) { throw IllegalArgumentException("Workspace is not a directory") }
        workspaceRoots.add(directory.trimEnd("/") + "/")
    }
    func inWorkspace(path: String): Bool {
        let directory = parent(path)
        if (!exists(directory)) { return false }
        let actual = canonicalize(directory).toString().trimEnd("/") + "/"
        for (root in workspaceRoots) { if (actual.startsWith(root)) { return true } }
        return false
    }
    func projectDiagnostic(message: String): JsonValue {
        return object([("range", rangeJson(ProtocolPosition(0, 0), ProtocolPosition(0, 0))), ("severity", JsonInt(1)),
            ("source", JsonString("cangjie")), ("message", JsonString(message))])
    }
    func configure(value: JsonValue): Unit {
        if (let Some(database) <- value.asObject().get("compilationDatabase")) { compilationDatabase = database.asString().getValue() }
    }
    func projectLocations(key: String, declarationsOnly!: Bool = false, includeDeclaration!: Bool = false): Array<SemanticLocation> {
        let result = ArrayList<SemanticLocation>(); let seen = HashSet<String>()
        for (semantic in semantics.values() where semantic.succeeded) {
            for (found in semantic.ExportedOccurrences(key, declarationsOnly: declarationsOnly, includeDeclaration: includeDeclaration)) {
                let identity = found.path + ":" + found.start.line.toString() + ":" + found.start.character.toString()
                if (seen.add(identity)) { result.add(found) }
            }
        }
        return result.toArray()
    }
    func analyze(): Unit {
        semantics.clear()
        let opened = documents.Snapshots()
        let sources = HashMap<String, DocumentSnapshot>()
        let openVersions = HashMap<String, Int64>()
        var project: Option<ProjectGraph> = None
        if (!compilationDatabase.isEmpty()) {
            try { project = Some(ProjectGraph(compilationDatabase)) }
            catch (exception: Exception) {
                Console.stdErr.writeln("LSP_PROJECT_ERROR " + exception.message)
                for (snapshot in opened) { publish(snapshot.uri, snapshot.version, [projectDiagnostic(exception.message)]) }
                return
            }
        }
        // The compiler's source package consists of ordinary sibling .cj
        // files. Open buffers override disk, never the other way round.
        // Imported package/build configuration remains a separate project edge.
        if (let Some(graph) <- project) {
            for (path in graph.files.keys()) {
                sources[path] = DocumentSnapshot(path, 0, String.fromUtf8(File.readFrom(path)))
            }
        }
        for (snapshot in opened) {
            if (project.isNone() && inWorkspace(snapshot.uri)) {
                for (entry in Directory.readFrom(parent(snapshot.uri))) {
                    if (entry.isRegular() && entry.name.endsWith(".cj") && !entry.name.endsWith("_test.cj")) {
                        // parent already ends in a separator. FileInfo may retain
                        // the extra separator inserted by directory enumeration;
                        // use the open buffer's lexical parent for one source key.
                        let path = parent(snapshot.uri) + entry.name
                        sources[path] = DocumentSnapshot(path, 0, String.fromUtf8(File.readFrom(path)))
                    }
                }
            }
        }
        for (snapshot in opened) {
            if (let Some(graph) <- project) {
                if (!graph.files.contains(snapshot.uri)) { publish(snapshot.uri, snapshot.version, [projectDiagnostic("Document is outside the selected compilation database")]); continue }
            }
            sources[snapshot.uri] = snapshot; openVersions[snapshot.uri] = snapshot.version
        }
        let snapshots = sources.values().toArray()
        for (snapshot in snapshots) {
            let peers = ArrayList<DocumentSnapshot>()
            var arguments: Array<String> = []
            if (let Some(graph) <- project) {
                let command = graph.files[snapshot.uri]
                arguments = command.semanticArguments()
                for (peer in snapshots) { if (command.files.contains(peer.uri)) { peers.add(peer) } }
            } else {
                for (peer in snapshots) { if (parent(peer.uri) == parent(snapshot.uri)) { peers.add(peer) } }
            }
            let semantic = try { SemanticDocument(snapshot, sdk, companions: peers.toArray(), compilerArguments: arguments) }
                catch (exception: Exception) {
                    Console.stdErr.writeln("LSP_PROJECT_ANALYSIS_ERROR " + exception.message)
                    if (let Some(version) <- openVersions.get(snapshot.uri)) { publish(snapshot.uri, version, [projectDiagnostic(exception.message)]) }
                    continue
                }
            semantics[snapshot.uri] = semantic
            let items = ArrayList<JsonValue>()
            var hasError = false
            Console.stdErr.writeln("LSP_ANALYSIS sdk=" + sdk + " file=" + snapshot.uri +
                " succeeded=" + semantic.succeeded.toString() + " errors=" + semantic.diagnostics.GetErrorCount().toString())
            for (diag in semantic.records) {
                let begin = if (diag.isRefactor) { diag.mainHint.range.begin } else { diag.start }
                let end = if (diag.isRefactor) { diag.mainHint.range.end } else { diag.end }
                // Configuration/import failures may have no source location.
                // Publish their real message on the document whose analysis
                // failed; never turn that failure into an empty diagnostic set.
                var first = ProtocolPosition(0, 0)
                var last = ProtocolPosition(0, 0)
                if (begin.fileID != 0) {
                    let source = semantic.compiler.GetSourceManager().GetSource(begin.fileID)
                    if (source.path != snapshot.uri) { continue }
                    let beginOffset = source.PosToOffset(begin)
                    let endOffset = if (end.fileID == begin.fileID) { source.PosToOffset(end) } else { beginOffset }
                    first = ProtocolPositionAt(source.buffer, beginOffset)
                    last = ProtocolPositionAt(source.buffer, max(beginOffset, endOffset))
                }
                let message = if (diag.isRefactor) { diag.errorMessage } else { diag.diagMessage }
                if (begin.fileID == 0) {
                    Console.stdErr.writeln("LSP_ANALYSIS_DIAGNOSTIC sdk=" + sdk + " file=" + snapshot.uri +
                        " succeeded=" + semantic.succeeded.toString() + " message=" + message)
                }
                let severity: Int64 = match (diag.diagSeverity) {
                    case DiagSeverity.DS_ERROR => 1
                    case DiagSeverity.DS_WARNING => 2
                    case DiagSeverity.DS_NOTE => 3
                    case _ => 4
                }
                if (severity == 1) { hasError = true }
                items.add(object([("range", rangeJson(first, last)),
                    ("severity", JsonInt(severity)), ("source", JsonString("cangjie")), ("message", JsonString(message))]))
            }
            if (!semantic.succeeded && !hasError) {
                // This reports the actual Compile result, not a guessed type
                // error. A failure located in another file still invalidates
                // this snapshot and must not look like successful analysis.
                items.add(object([("range", rangeJson(ProtocolPosition(0, 0), ProtocolPosition(0, 0))),
                    ("severity", JsonInt(1)), ("source", JsonString("cangjie")),
                    ("message", JsonString("Frontend analysis failed; see compiler diagnostics for this snapshot"))]))
            }
            if (let Some(version) <- openVersions.get(snapshot.uri)) { publish(snapshot.uri, version, items.toArray()) }
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
            let key = id.getOrThrow()
            if (let Some(params) <- request.get("params")) {
                if (let Some(folders) <- params.asObject().get("workspaceFolders")) {
                    if (let Some(list) <- (folders as JsonArray)) {
                        for (folder in list.getItems()) { addWorkspace(string(folder, "uri")) }
                    }
                }
                if (workspaceRoots.isEmpty()) {
                    if (let Some(root) <- params.asObject().get("rootUri")) {
                        if (let Some(uri) <- (root as JsonString)) { addWorkspace(uri.getValue()) }
                    }
                }
            }
            if (let Some(params) <- request.get("params")) {
                if (let Some(options) <- params.asObject().get("initializationOptions")) { configure(options) }
            }
            initialized = true
            response(key, object([("capabilities", object([("positionEncoding", JsonString("utf-16")),
                ("textDocumentSync", object([("openClose", JsonBool(true)), ("change", JsonInt(2))])),
                ("definitionProvider", JsonBool(true)), ("referencesProvider", JsonBool(true)),
                ("documentHighlightProvider", JsonBool(true))])),
                ("serverInfo", object([("name", JsonString("cangjie-lsp")), ("version", JsonString("0.1.0"))]))]))
            return
        }
        if (!initialized) { if (let Some(key) <- id) { error(key, -32002, "Server not initialized") }; return }
        if (method == "shutdown") { response(id.getOrThrow(), JsonNull()); stopped = true; return }
        if (method == "initialized" || method == "$/cancelRequest") { return }
        let params = request.get("params").getOrDefault({ => JsonObject() })
        if (method == "workspace/didChangeConfiguration") { configure(field(params, "settings")); analyze(); return }
        if (method == "workspace/didChangeWatchedFiles") {
            // Re-read unopened siblings after the client's real file event;
            // the immutable open overlays still win during analysis.
            analyze(); return
        }
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
        if (method == "textDocument/definition" || method == "textDocument/references" ||
            method == "textDocument/documentHighlight") {
            let path = filePath(string(field(params, "textDocument"), "uri")); let semantic = match (semantics.get(path)) { case Some(value) => value; case None =>
                if (compilationDatabase.isEmpty()) { throw IllegalArgumentException("Document has no semantic snapshot") }
                response(id.getOrThrow(), JsonNull()); return }
            if (!semantic.succeeded) { response(id.getOrThrow(), JsonNull()); return }
            let pos = position(field(params, "position"))
            if (method == "textDocument/documentHighlight") {
                let highlights = ArrayList<JsonValue>()
                // References resolves declaration identity, including shadowing.
                // LSP highlights belong only to the requested document.
                for (found in semantic.References(pos, includeDeclaration: true)) {
                    if (found.path == path) {
                        highlights.add(object([("range", rangeJson(found.start, found.end)), ("kind", JsonInt(1))]))
                    }
                }
                response(id.getOrThrow(), JsonArray(highlights))
            } else if (method == "textDocument/definition") {
                let key = semantic.ExportedTarget(pos)
                if (!compilationDatabase.isEmpty() && !key.isEmpty()) {
                    let found = projectLocations(key, declarationsOnly: true)
                    response(id.getOrThrow(), if (found.size == 1) { locationJson(found[0]) } else { JsonNull() })
                } else if (let Some(found) <- semantic.Definition(pos)) { response(id.getOrThrow(), locationJson(found)) }
                else { response(id.getOrThrow(), JsonNull()) }
            } else {
                let include = field(field(params, "context"), "includeDeclaration").asBool().getValue()
                let results = ArrayList<JsonValue>()
                let key = semantic.ExportedTarget(pos)
                let found = if (!compilationDatabase.isEmpty() && !key.isEmpty()) { projectLocations(key, includeDeclaration: include) }
                    else { semantic.References(pos, includeDeclaration: include) }
                for (location in found) { results.add(locationJson(location)) }
                response(id.getOrThrow(), JsonArray(results))
            }
            return
        }
        if (let Some(key) <- id) { error(key, -32601, "Method not found: " + method) }
    }
}

main(args: Array<String>): Int64 {
    if (args.size != 2 || args[0] != "--sdk") { Console.stdErr.writeln("Usage: cangjie-lsp --sdk <target SDK>"); return 2 }
    let server = Server(args[1]); let framer = MessageFramer(); let buffer = Array<UInt8>(4096, repeat: 0)
    try {
        while (!server.exiting) {
            let count = readInput(buffer)
            if (count == 0) { framer.EndOfInput(); return if (server.stopped) { 0 } else { 1 } }
            for (text in framer.Feed(buffer[0..count])) {
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
