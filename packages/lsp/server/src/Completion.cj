package cangjie_lsp
import std.collection.*
import std.fs.*
import std.console.Console
import std.sort.*
import stdx.encoding.json.*
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*

class CompletionRequest {
    let sdk: String
    let original: DocumentSnapshot
    let span: CompletionSpan
    let peers: Array<DocumentSnapshot>
    let arguments: Array<String>
    let marker: String
    let database: String
    let databaseBytes: String
    let projectPackages = HashSet<String>()
    init(sdk: String, semantics: HashMap<String, SemanticDocument>, database: String,
        path: String, point: ProtocolPosition) {
        this.sdk = sdk; this.database = database
        original = semantics.get(path).getOrThrow().snapshot
        span = CompletionSpan(original.text, point)
        var name = "__CangjieCompletionHole"
        while (original.text.contains(name)) { name += "X" }
        marker = name
        databaseBytes = if (database.isEmpty()) { "" } else { String.fromUtf8(File.readFrom(database)) }
        let selected = ArrayList<DocumentSnapshot>()
        if (database.isEmpty()) {
            arguments = []
            for (semantic in semantics.values()) { if (parent(semantic.snapshot.uri) == parent(path)) { selected.add(semantic.snapshot) } }
        } else {
            let graph = ProjectGraph(database)
            let command = graph.files.get(path).getOrThrow()
            arguments = command.semanticArguments()
            // Driver configuration owns the module identity even while source
            // declarations disagree. Only successful commands supply child
            // package identities; no workspace/package-declaration scan occurs.
            for (entry in graph.commands.values()) {
                let module = entry.moduleName()
                if (!module.isEmpty()) { projectPackages.add(module) }
            }
            for (file in command.files) { selected.add(semantics.get(file).getOrThrow().snapshot) }
            for ((file, semantic) in semantics) {
                if (semantic.succeeded) {
                    let module = graph.files[file].moduleName()
                    let packageName = semantic.SourcePackageName()
                    if (module.isEmpty() || packageName == module || packageName.startsWith(module + ".")) {
                        projectPackages.add(packageName)
                    }
                }
                if (!command.files.contains(file) && !semantic.succeeded) { throw IllegalArgumentException("Completion requires valid project dependencies") }
            }
        }
        peers = selected.toArray()
    }
    func changed(name: String): DocumentSnapshot {
        return DocumentSnapshot(original.uri, original.version,
            original.text[0..span.first] + name + original.text[span.last..])
    }
    func compile(text: DocumentSnapshot): SemanticDocument {
        let sources = peers.map { peer => if (peer.uri == original.uri) { text } else { peer } }
        return SemanticDocument(text, sdk, companions: sources, compilerArguments: arguments)
    }
    func sameDeclaration(name: CompletionName, binding: SemanticBinding, probe: DocumentSnapshot,
        candidate: DocumentSnapshot): Bool {
        if (!name.exportKey.isEmpty() && name.exportKey == binding.exportKey) { return true }
        if (let Some(expected) <- name.declaration) {
            if (let Some(actual) <- binding.declaration) {
                if (expected.path != actual.path || name.kind != binding.kind) { return false }
                if (expected.path != original.uri) {
                    return expected.start.line == actual.start.line && expected.start.character == actual.start.character
                }
                var offset = ProtocolOffset(probe.text, expected.start)
                if (offset >= span.first + marker.size) { offset += name.name.size - marker.size }
                let target = ProtocolPositionAt(candidate.text, offset)
                return target.line == actual.start.line && target.character == actual.start.character
            }
        }
        return false
    }
    func validateSnapshots(opened: Array<DocumentSnapshot>): Unit {
        for (expected in peers) {
            var current: Option<DocumentSnapshot> = None
            for (snapshot in opened where snapshot.uri == expected.uri) { current = Some(snapshot) }
            let actual = current.getOrDefault({ => DocumentSnapshot(expected.uri, 0,
                String.fromUtf8(File.readFrom(expected.uri))) })
            if (actual.version != expected.version || actual.text != expected.text) {
                throw IllegalArgumentException("Completion snapshot changed")
            }
        }
    }
    func result(): JsonValue {
        let probeText = changed(marker)
        let probe = compile(probeText)
        if (!database.isEmpty()) {
            let context = probe.CompletionImportPath(marker, span.first)
            if (let Some((prefix, organization)) <- context) {
                let candidates = HashSet<String>()
                for (packageName in projectPackages) {
                    if (prefix.isEmpty()) {
                        // A configured module is emitted whole, including its
                        // organization. Children are selected after its dot.
                        let parts = packageName.split(".")
                        candidates.add(parts[0])
                    } else {
                        let path = prefix + if (organization) { "::" } else { "." }
                        if (packageName.startsWith(path)) { candidates.add(packageName[path.size..].split(".")[0]) }
                    }
                }
                if (prefix.isEmpty() || !candidates.isEmpty()) {
                    probe.compiler.DestroyASTResources()
                    probe.compiler.JoinDestroyASTResources()
                    let items = ArrayList<JsonValue>()
                    let sorted = candidates.toArray(); sort(sorted)
                    for (name in sorted where name.startsWith(span.prefix)) {
                        items.add(object([("label", JsonString(name)), ("detail", JsonString("project package")),
                            ("textEdit", object([("range", rangeJson(ProtocolPositionAt(original.text, span.first), ProtocolPositionAt(original.text, span.last))),
                                ("newText", JsonString(name))]))]))
                    }
                    if (String.fromUtf8(File.readFrom(database)) != databaseBytes) {
                        throw IllegalArgumentException("Project configuration changed during completion")
                    }
                    return object([("isIncomplete", JsonBool(false)), ("items", JsonArray(items.toArray()))])
                }
            }
        }
        let outsideError = probe.CompletionExternalError(marker, span.first)
        let discovered = try { probe.CompletionNames(marker, span.first, "") }
            finally { probe.compiler.DestroyASTResources(); probe.compiler.JoinDestroyASTResources() }
        // Try actual prefix candidates first. A successful normal SEMA repairs
        // propagated hole errors as well. Only seek a nonmatching empty-result
        // witness when the probe has no diagnostic outside the request token.
        let names = ArrayList<CompletionName>()
        for (name in discovered where name.name.startsWith(span.prefix)) { names.add(name) }
        for (name in discovered where !name.name.startsWith(span.prefix)) { names.add(name) }
        var witnessed = false
        let emitted = HashSet<String>(); let items = ArrayList<JsonValue>()
        for (name in names) {
            if (!witnessed && !name.name.startsWith(span.prefix) && !outsideError.isEmpty()) {
                throw IllegalArgumentException(outsideError)
            }
            if (emitted.contains(name.name) || (witnessed && !name.name.startsWith(span.prefix))) { continue }
            let text = changed(name.name)
            let semantic = compile(text)
            try {
                if (!semantic.succeeded) { continue }
                let point = ProtocolPositionAt(text.text, span.first)
                var matched = false
                for (binding in semantic.Bindings()) {
                    if (!binding.isDeclaration && binding.location.path == original.uri &&
                        binding.location.start.line == point.line && binding.location.start.character == point.character &&
                        sameDeclaration(name, binding, probeText, text)) { matched = true }
                }
                if (!matched) { continue }
                let hover = semantic.Hover(point)
                if (hover.isNone()) { continue }
                witnessed = true
                if (!name.name.startsWith(span.prefix)) { continue }
                emitted.add(name.name)
                items.add(object([("label", JsonString(name.name)), ("detail", JsonString(hover.getOrThrow().text)),
                    ("textEdit", object([("range", rangeJson(ProtocolPositionAt(original.text, span.first), ProtocolPositionAt(original.text, span.last))),
                        ("newText", JsonString(name.name))]))]))
            } finally { semantic.compiler.DestroyASTResources(); semantic.compiler.JoinDestroyASTResources() }
        }
        // No successful repair is distinguishable from a valid empty name set
        // only after a semantic witness. Never hide unrelated compilation errors.
        if (!witnessed) { throw IllegalArgumentException("No semantically validated completion for this snapshot") }
        if (!database.isEmpty() && String.fromUtf8(File.readFrom(database)) != databaseBytes) {
            throw IllegalArgumentException("Project configuration changed during completion")
        }
        return object([("isIncomplete", JsonBool(false)), ("items", JsonArray(items.toArray()))])
    }
}
