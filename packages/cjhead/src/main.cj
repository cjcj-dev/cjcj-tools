package cjhead

import std.collection.*
import std.env.*
import std.fs.{FileInfo, Directory}
import std.sort.*
import cjcj::ast.*
import cjcj::frontend.{CompilerInvocation, CompilerInstance, CompileStage, DiagnosticEngine, ReadFileContent}
import cjcj::utils.FileUtil
import cjcj::option.OutputMode

func readText(path: String): (Bool, String, String) { return ReadFileContent(path) }

class HeadPackage {
    let compiler: CompilerInstance
    let pkg: Package
    init(compiler: CompilerInstance, pkg: Package) {
        this.compiler = compiler
        this.pkg = pkg
    }
}

// SEMA is the production boundary: parser, conditional compilation, imports,
// macro expansion and type checking must all succeed before any output is written.
func compilePackage(path: String, options: HeadOptions): HeadPackage {
    let home = FileUtil.GetAbsPath(getVariable("CANGJIE_HOME") ?? "") ??
        throw Exception("Can not find realpath of CANGJIE_HOME, please setup CANGJIE_HOME")
    let invocation = CompilerInvocation()
    let opts = invocation.globalOptions
    opts.cangjieHome = home
    @When[os == "Windows"]
    let compilerName = "bin/cjc.exe"
    @When[os != "Windows"]
    let compilerName = "bin/cjc"
    opts.executablePath = FileUtil.JoinPath(home, compilerName)
    opts.compilePackage = true
    opts.outputMode = OutputMode.STATIC_LIB
    opts.enableOutputType = true
    opts.packagePaths.add(path)
    opts.enableAddCommentToAst = true
    // Use the Cangjie frontend's normal in-process evaluator. LSP mode
    // dispatches to a separate LSPMacroServer and its private wire protocol.
    opts.enableMacroDebug = false
    opts.enableMacroInLSP = false
    for (dependency in options.importPaths) { opts.importPaths.add(dependency) }
    for (dependency in options.macroPaths) { opts.importPaths.add(dependency) }
    let diag = DiagnosticEngine()
    let compiler = CompilerInstance(invocation, diag)
    if (!compiler.Compile(stage: CompileStage.SEMA) || diag.GetErrorCount() != 0) {
        throw Exception("Semantic analysis failed: " + path)
    }
    let packages = compiler.GetSourcePackages()
    if (packages.size != 1) { throw Exception("Expected one source package: " + path) }
    return HeadPackage(compiler, packages[0])
}

func writeHeader(path: String, content: String): Unit {
    let parent = FileUtil.GetDirPath(path)
    if (!parent.isEmpty() && FileUtil.CreateDirs(parent) != 0) {
        throw Exception("Cannot create output directory: " + parent)
    }
    if (!FileUtil.WriteToFile(path, installedCopyright() + content)) { throw Exception("Cannot write header: " + path) }
}

func runHead(options: HeadOptions): Unit {
    let inputFile = !FileUtil.IsDir(options.input)
    let root = if (inputFile) { FileUtil.GetDirPath(options.input) } else { options.input }
    let dirs = ArrayList<String>()
    dirs.add(root)
    if (!inputFile) {
        Directory.walk(root) { info =>
            if (info.isDirectory()) { dirs.add(info.path.toString()) }
            return true
        }
    }
    sort(dirs)
    let packages = ArrayList<HeadPackage>()
    let seenDirs = HashSet<String>()
    for (dir in dirs) {
        if (!seenDirs.add(dir)) { continue }
        let files = FileUtil.GetAllFilesUnderCurrentPath(dir, "cj", shouldSkipTestFiles: false)
        if (!files.isEmpty()) { packages.add(compilePackage(dir, options)) }
    }
    let visibility = PackageVisibility(packages)
    let outputs = HashMap<String, String>()
    for (unit in packages) {
        let emitter = HeaderEmitter(unit.compiler.GetSourceManager(), visibility,
            unit.compiler.typeManager.getOrThrow().AsFaithfulSemaTypeManager())
        let files = ArrayList<File>()
        for (file in unit.pkg.files) {
            if (inputFile && file.filePath != options.input) { continue }
            if (options.excluded(file.fileName)) { continue }
            files.add(file)
        }
        if (files.isEmpty()) { continue }
        if (options.packageMode) {
            let path = FileUtil.JoinPath(options.output, unit.pkg.fullPackageName + ".cj.d")
            outputs[path] = emitter.emitFiles(files, true)
        } else {
            for (file in files) {
                let path = if (FileUtil.IsDir(options.output) || !inputFile) {
                    FileUtil.JoinPath(options.output, file.filePath[root.size + 1..] + ".d")
                } else { options.output }
                if (outputs.contains(path)) { throw Exception("Duplicate output path: " + path) }
                outputs[path] = emitter.emitFiles(ArrayList<File>([file]), false)
            }
        }
    }
    // Semantic failure in any input package leaves existing output untouched.
    for ((path, content) in outputs) { writeHeader(path, content) }
}

main(args: Array<String>): Int64 {
    try {
        let options = HeadOptions()
        options.parse(args)
        if (options.help) { print(helpText); return 0 }
        runHead(options)
        println("execute successfully")
        return 0
    } catch (e: Exception) {
        println("cjhead: " + e.message)
        return 1
    }
}

func installedCopyright(): String {
    let command = getCommand()
    var executable = FileUtil.GetAbsPath(command)
    if (executable.isNone()) {
        executable = FileUtil.GetAbsPath(FileUtil.FindProgramByName(command,
            FileUtil.SplitEnvironmentPaths(getVariable("PATH") ?? "")))
    }
    if (let Some(path) <- executable) {
        let resource = FileUtil.JoinPath(FileUtil.GetDirPath(path), "resources/COPYRIGHT.txt")
        if (FileUtil.FileExist(resource)) {
            let (ok, content, _) = readText(resource)
            if (ok && !content.trimAscii().isEmpty()) { return content + "\n" }
        }
    }
    return ""
}
