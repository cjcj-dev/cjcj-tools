package cangjie_lsp

import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import cjcj::option.{CreateOptionTable, ArgList, ArgInstanceType, Group, ID, Kind}

// A standard arguments-based compilation database is the selected project.
// No workspace scan, build history, or package-name heuristic participates.
class ProjectCommand {
    let directory: String
    let arguments: Array<String>
    let files = HashSet<String>()
    init(directory: String, arguments: Array<String>) {
        this.directory = directory; this.arguments = arguments
    }
    func absolute(value: String): String {
        return if (Path(value).isAbsolute()) { value } else { Path(directory).join(value).toString() }
    }
    func semanticArguments(): Array<String> {
        let result = ArrayList<String>([arguments[0]])
        var i: Int64 = 1
        while (i < arguments.size) {
            let arg = arguments[i]
            // Expand the exact selected source list, including in-memory overlays.
            if (arg == "-p") { i += 2; continue }
            if (arg.startsWith("--package=")) { i++; continue }
            if (arg.startsWith("@")) { throw IllegalArgumentException("Project response-file arguments are not supported") }
            if (arg == "--import-path" || arg == "--output-dir" || arg == "-o" || arg == "-L" || arg == "--sysroot") {
                if (i + 1 >= arguments.size) { throw IllegalArgumentException("Missing project path argument") }
                result.add(arg); result.add(absolute(arguments[i + 1])); i += 2; continue
            }
            var handled = false
            for (prefix in ["--import-path=", "--output-dir=", "--sysroot="]) {
                if (arg.startsWith(prefix)) { result.add(prefix + absolute(arg[prefix.size..])); handled = true; break }
            }
            if (!handled) {
                if (!arg.startsWith("-") && arg.endsWith(".cj")) { i++; continue }
                if (!arg.startsWith("-") && (arg.endsWith(".a") || arg.endsWith(".o"))) { result.add(absolute(arg)) }
                else { result.add(arg) }
            }
            i++
        }
        for (file in files) { result.add(file) }
        // The database is a driver command. Use its real option metadata for
        // the same DRIVER/GLOBAL split as GenerateFrontendOptions; do not send
        // library/linker options to frontend-only CompilerInvocation.ParseArgs.
        let parsed = ArgList()
        if (!CreateOptionTable().ParseArgs(result.toArray(), parsed)) {
            throw IllegalArgumentException("Invalid project driver arguments")
        }
        let frontend = ArrayList<String>([result[0]])
        for (entry in parsed.entries) {
            if (entry.argInstanceType == ArgInstanceType.Input) {
                let value = parsed.inputArgs[entry.index].value
                if (!value.endsWith(".a") && !value.endsWith(".o")) { frontend.add(value) }
            } else {
                let option = parsed.optionArgs[entry.index]
                if (option.info.GetID() == ID.OUTPUT_FILE || option.info.BelongsGroup(Group.DRIVER)) { continue }
                frontend.add(option.name)
                if (option.info.GetKind() == Kind.SEPARATED) { frontend.add(option.value) }
            }
        }
        return frontend.toArray()
    }
}

class ProjectGraph {
    let commands = HashMap<String, ProjectCommand>()
    let files = HashMap<String, ProjectCommand>()
    init(database: String) {
        if (!Path(database).isAbsolute()) { throw IllegalArgumentException("compilationDatabase must be an absolute path") }
        let rows = JsonValue.fromStr(String.fromUtf8(File.readFrom(database))).asArray().getItems()
        if (rows.isEmpty()) { throw IllegalArgumentException("Empty compilation database") }
        for (row in rows) {
            let directory = canonicalize(string(row, "directory")).toString()
            let arguments = field(row, "arguments").asArray().getItems().map { value => value.asString().getValue() }
            if (arguments.isEmpty()) { throw IllegalArgumentException("Empty compiler arguments") }
            let rawFile = string(row, "file")
            let file = canonicalize(if (Path(rawFile).isAbsolute()) { rawFile } else { Path(directory).join(rawFile).toString() }).toString()
            let key = directory + "\u{0}" + field(row, "arguments").toString()
            if (!commands.contains(key)) { commands[key] = ProjectCommand(directory, arguments.toArray()) }
            let command = commands[key]
            if (files.contains(file)) { throw IllegalArgumentException("Ambiguous compilation database entry: " + file) }
            command.files.add(file); files[file] = command
        }
        // Validate all argument paths before publishing any semantic index.
        for (command in commands.values()) { let _ = command.semanticArguments() }
    }
}
