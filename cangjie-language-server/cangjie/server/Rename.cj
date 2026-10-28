package cangjie_lsp

import std.collection.*
import std.fs.*
import std.env.*
import std.console.Console
import stdx.encoding.json.*
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*
import cjcj::utils.{FileUtil, SplitQualifiedName}

foreign func mkdtemp(pattern: CPointer<UInt8>): CPointer<UInt8>

class RenameEdit {
    let path: String
    let first: Int64
    let last: Int64
    let text: String
    init(path: String, first: Int64, last: Int64, text: String) {
        this.path = path; this.first = first; this.last = last; this.text = text
    }
}

// A request-local candidate, never applied to the live DocumentStore or disk.
class RenameTransaction {
    let sdk: String
    let sources = HashMap<String, DocumentSnapshot>()
    let oldSemantics: HashMap<String, SemanticDocument>
    let database: String
    let databaseBytes: String
    let graph: Option<ProjectGraph>
    let edits = ArrayList<RenameEdit>()
    let oldExports = HashMap<String, SemanticBinding>()
    private var selectedTarget: Option<SemanticBinding> = None
    private var selectedLocation: Option<SemanticLocation> = None
    prop target: SemanticBinding { get() { return selectedTarget.getOrThrow() } }
    prop requestLocation: SemanticLocation { get() { return selectedLocation.getOrThrow() } }
    var targetKey = ""
    let newName: String
    var temporary = ""

    init(sdk: String, semantics: HashMap<String, SemanticDocument>, database: String,
        path: String, position: ProtocolPosition, newName: String) {
        this.sdk = sdk; oldSemantics = semantics; this.database = database; this.newName = newName
        databaseBytes = if (database.isEmpty()) { "" } else { String.fromUtf8(File.readFrom(database)) }
        graph = if (database.isEmpty()) { None } else { Some(ProjectGraph(database)) }
        for ((file, semantic) in semantics) {
            if (!semantic.succeeded) { throw IllegalArgumentException("Rename requires successful current project semantics") }
            sources[file] = semantic.snapshot
            for (binding in semantic.Bindings() where binding.isDeclaration && !binding.exportKey.isEmpty()) {
                oldExports[binding.exportKey] = binding
            }
        }
        if (let Some(project) <- graph) {
            for (file in project.files.keys()) { if (!sources.contains(file)) { throw IllegalArgumentException("Incomplete project snapshot") } }
        }
        let semantic = semantics.get(path).getOrThrow()
        var hit: Option<SemanticBinding> = None
        for (binding in semantic.Bindings()) {
            let found = binding.location
            if (found.path == path && position.line == found.start.line && position.line == found.end.line &&
                position.character >= found.start.character && position.character < found.end.character) {
                if (hit.isSome() && identity(hit.getOrThrow(), oldExports, false) != identity(binding, oldExports, false)) {
                    throw IllegalArgumentException("Ambiguous rename binding")
                }
                hit = Some(binding)
            }
        }
        let selected = hit.getOrThrow()
        selectedLocation = Some(selected.location)
        selectedTarget = Some(if (!selected.exportKey.isEmpty() && oldExports.contains(selected.exportKey)) { oldExports[selected.exportKey] } else { selected })
        if (!target.canRename || target.declaration.isNone() || !sources.contains(target.declaration.getOrThrow().path)) {
            throw IllegalArgumentException("Rename target has no complete editable source binding")
        }
        targetKey = identity(target, oldExports, false)
        let selectedText = sources[path].text
        let selectedName = selectedText[ProtocolOffset(selectedText, requestLocation.start)..ProtocolOffset(selectedText, requestLocation.end)]
        if (selectedName != target.name) { throw IllegalArgumentException("Import alias or implicit token is not the declaration name") }
        if (!newName.isEmpty()) { semantic.ValidateRenameName(newName) }
        let seen = HashSet<String>()
        for (doc in semantics.values()) { for (binding in doc.Bindings()) {
            if (identity(binding, oldExports, false) != targetKey) { continue }
            if (!binding.canRename) { throw IllegalArgumentException("Incomplete associated rename declarations") }
            let loc = binding.location
            if (!sources.contains(loc.path)) { throw IllegalArgumentException("Reference outside the selected source graph") }
            let text = sources[loc.path].text
            let begin = ProtocolOffset(text, loc.start); let end = ProtocolOffset(text, loc.end)
            // An import alias keeps its own spelling; the original import token
            // is separately indexed through the frontend's imported declaration.
            if (text[begin..end] != target.name) { continue }
            let key = loc.path + ":" + begin.toString()
            if (seen.add(key)) { edits.add(RenameEdit(loc.path, begin, end, newName)) }
        } }
        if (edits.isEmpty()) { throw IllegalArgumentException("No editable rename occurrences") }
    }

    func offsetAfter(path: String, offset: Int64): Int64 {
        var result = offset
        for (edit in edits where edit.path == path && edit.last <= offset) { result += edit.text.size - (edit.last - edit.first) }
        return result
    }
    func identity(binding: SemanticBinding, exports: HashMap<String, SemanticBinding>, mapped: Bool): String {
        let resolved = if (!binding.exportKey.isEmpty() && exports.contains(binding.exportKey)) { exports[binding.exportKey] } else { binding }
        if (let Some(loc) <- resolved.declaration) {
            if (sources.contains(loc.path)) {
                let offset = ProtocolOffset(sources[loc.path].text, loc.start)
                return loc.path + ":" + (if (mapped) { offsetAfter(loc.path, offset) } else { offset }).toString() + ":" + resolved.kind
            }
        }
        if (!resolved.exportKey.isEmpty()) { return "external:" + resolved.exportKey }
        throw IllegalArgumentException("Unresolvable reference identity in rename snapshot")
    }
    func changed(snapshot: DocumentSnapshot): DocumentSnapshot {
        var text = snapshot.text
        var limit = text.size + 1
        while (true) {
            var next: Option<RenameEdit> = None
            for (edit in edits where edit.path == snapshot.uri && edit.first < limit) {
                if (next.isNone() || edit.first > next.getOrThrow().first) { next = Some(edit) }
            }
            if (let Some(edit) <- next) {
                text = text[0..edit.first] + edit.text + text[edit.last..text.size]; limit = edit.first
            } else { break }
        }
        return DocumentSnapshot(snapshot.uri, snapshot.version, text)
    }
    func validate(): Unit {
        let base = getVariable("TMPDIR").getOrDefault({ => "/tmp" })
        let pattern = (base + "/cangjie-lsp-rename-XXXXXX\u{0}").toArray()
        let handle = unsafe { acquireArrayRawData(pattern) }
        try {
            let result = unsafe { mkdtemp(handle.pointer) }
            if (result.isNull()) { throw IllegalStateException("Cannot create candidate CJO directory") }
        } finally { unsafe { releaseArrayRawData(handle) } }
        temporary = String.fromUtf8(pattern[0..pattern.size - 1])
        try { validatePackages() } finally { remove(temporary, recursive: true) }
    }
    func validatePackages(): Unit {
        let packages = HashMap<String, SemanticDocument>()
        let nextSources = HashMap<String, DocumentSnapshot>()
        for ((path, doc) in oldSemantics) { packages[doc.SourcePackageName()] = doc; nextSources[path] = changed(doc.snapshot) }
        let nextDocs = HashMap<String, SemanticDocument>(); let completed = HashSet<String>()
        while (completed.size < packages.size) {
            var progress = false
            for ((name, old) in packages) {
                if (completed.contains(name)) { continue }
                var ready = true
                for (dependency in old.ImportedPackages()) { if (dependency != name && packages.contains(dependency) && !completed.contains(dependency)) { ready = false } }
                if (!ready) { continue }
                let peers = ArrayList<DocumentSnapshot>(); let args = ArrayList<String>()
                if (let Some(project) <- graph) {
                    let command = project.files[old.snapshot.uri]
                    let original = command.semanticArguments()
                    args.add(original[0]); args.add("--import-path=" + temporary)
                    for (i in 1..original.size) { args.add(original[i]) }
                    for (path in command.files) { peers.add(nextSources[path]) }
                } else {
                    for (doc in nextSources.values() where parent(doc.uri) == parent(old.snapshot.uri)) { peers.add(doc) }
                }
                let candidate = SemanticDocument(nextSources[old.snapshot.uri], sdk, importPaths: [temporary],
                    companions: peers.toArray(), compilerArguments: args.toArray())
                if (!candidate.succeeded) {
                    for (diag in candidate.records) { Console.stdErr.writeln(if (diag.isRefactor) { diag.errorMessage } else { diag.diagMessage }) }
                    throw IllegalArgumentException("Rename candidate failed semantic analysis")
                }
                // Match FindSerializationFile: grouped paths across all roots are
                // searched before flat paths. A flat candidate would lose to an
                // existing CJPM package even with the candidate root first.
                let directory = temporary + "/" + FileUtil.ToCjoFileName(SplitQualifiedName(name)[0])
                Directory.create(directory, recursive: true)
                File.writeTo(directory + "/" + FileUtil.ToCjoFileName(name) + ".cjo", candidate.ExportCandidate())
                nextDocs[name] = candidate; completed.add(name); progress = true
            }
            if (!progress) { throw IllegalArgumentException("Rename source package dependencies cannot be ordered") }
        }
        let nextExports = HashMap<String, SemanticBinding>()
        for (doc in nextDocs.values()) { for (binding in doc.Bindings() where binding.isDeclaration && !binding.exportKey.isEmpty()) { nextExports[binding.exportKey] = binding } }
        // Compare every reference/declaration, not just renamed occurrences.
        // A successful compile can still silently capture an unrelated name.
        let after = HashMap<String, String>()
        for (doc in nextDocs.values()) { for (binding in doc.Bindings()) {
            let loc = binding.location
            if (!nextSources.contains(loc.path)) { continue }
            let at = ProtocolOffset(nextSources[loc.path].text, loc.start)
            let resolved = if (!binding.exportKey.isEmpty() && nextExports.contains(binding.exportKey)) { nextExports[binding.exportKey] } else { binding }
            var id = "external:" + resolved.exportKey
            if (let Some(decl) <- resolved.declaration) {
                if (nextSources.contains(decl.path)) { id = decl.path + ":" + ProtocolOffset(nextSources[decl.path].text, decl.start).toString() + ":" + resolved.kind }
            }
            let key = loc.path + ":" + at.toString() + ":" + binding.isDeclaration.toString()
            if (after.contains(key) && after[key] != id) { throw IllegalArgumentException("Ambiguous candidate binding") }
            after[key] = id
        } }
        let beforeKeys = HashSet<String>()
        for (doc in oldSemantics.values()) { for (binding in doc.Bindings()) {
            let loc = binding.location
            if (!sources.contains(loc.path)) { continue }
            let at = offsetAfter(loc.path, ProtocolOffset(sources[loc.path].text, loc.start))
            let key = loc.path + ":" + at.toString() + ":" + binding.isDeclaration.toString()
            beforeKeys.add(key)
            if (!after.contains(key) || after[key] != identity(binding, oldExports, true)) {
                throw IllegalArgumentException("Rename would change an existing reference binding")
            }
        } }
        if (beforeKeys.size != after.size) { throw IllegalArgumentException("Rename changed the reference graph") }
    }
    func result(opened: Array<DocumentSnapshot>): JsonValue {
        let versions = HashMap<String, Int64>()
        for (snapshot in opened) {
            versions[snapshot.uri] = snapshot.version
            if (sources.contains(snapshot.uri) && (sources[snapshot.uri].version != snapshot.version || sources[snapshot.uri].text != snapshot.text)) {
                throw IllegalArgumentException("Document changed during rename")
            }
        }
        for ((path, snapshot) in sources) {
            if (!versions.contains(path) && String.fromUtf8(File.readFrom(path)) != snapshot.text) { throw IllegalArgumentException("Disk source changed during rename") }
        }
        if (!database.isEmpty() && String.fromUtf8(File.readFrom(database)) != databaseBytes) { throw IllegalArgumentException("Project configuration changed during rename") }
        let changes = ArrayList<JsonValue>()
        for ((path, snapshot) in sources) {
            let items = ArrayList<JsonValue>()
            for (edit in edits where edit.path == path) {
                items.add(object([("range", rangeJson(ProtocolPositionAt(snapshot.text, edit.first), ProtocolPositionAt(snapshot.text, edit.last))), ("newText", JsonString(edit.text))]))
            }
            if (!items.isEmpty()) {
                let version: JsonValue = if (versions.contains(path)) { JsonInt(versions[path]) } else { JsonNull() }
                changes.add(object([("textDocument", object([("uri", JsonString(fileUri(path))), ("version", version)])), ("edits", JsonArray(items.toArray()))]))
            }
        }
        return object([("documentChanges", JsonArray(changes.toArray()))])
    }
}
