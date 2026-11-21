package cjlint

import cjcj::frontend.{CompilerInvocation, CompilerInstance, DiagnosticEngine}
import cjcj::utils.FileUtil
import std.collection.*
import std.fs.File as SourceFile
import std.fs.{FileInfo, Directory, exists, remove}
import std.env.{getVariable, getTempDirectory}
import std.process.execute

func requireFrontendStage(ok: Bool, name: String, diagnostics: DiagnosticEngine): Unit {
    if (!ok || diagnostics.GetErrorCount() != 0) {
        diagnostics.EmitCategoryGroup()
        diagnostics.ReportErrorAndWarningCount()
        fail("Frontend ${name} failed")
    }
}

// The SDK launcher sets CANGJIE_HOME to its own root. A standalone install
// without an active SDK uses the compiler SDK selected by its installer.
// -m supplies analysis modules; it does not select an executable.
private func macroCompiler(applicationRoot: String): String {
    let sdk = getVariable("CANGJIE_HOME") ??
        readJson(FileUtil.JoinPath(applicationRoot, "cjlint-build.json")).field("analysis").field("sdk").text()
    if (!FileUtil.IsAbsolutePath(sdk)) { fail("Macro compiler SDK must be an absolute directory: " + sdk) }
    @When[os == "Windows"]
    let binary = "cjc.exe"
    @When[os != "Windows"]
    let binary = "cjc"
    let driver = FileUtil.JoinPath(FileUtil.JoinPath(sdk, "bin"), binary)
    if (!exists(driver) || !FileInfo(driver).isRegular()) { fail("Missing SDK macro compiler: " + driver) }
    return driver
}

private func compileMacroPackages(compiler: CompilerInstance, applicationRoot: String, output: String): Unit {
    let opts = compiler.invocation.globalOptions
    let driver = macroCompiler(applicationRoot)
    // Runtime binding is relative to the public compiler path (keep bin/cjc
    // even if it is a symlink), independently of cjlint's own loader/config.
    opts.executablePath = driver
    opts.importPaths.add(output, at: 0)
    var i: Int64 = 0
    while (i < compiler.srcPkgs.size) {
        let pkg = compiler.srcPkgs[i]
        if (!pkg.isMacroPackage) { i++; continue }
        let args = ArrayList<String>()
        args.add("--compile-macro")
        args.add("-o")
        args.add(output)
        for (path in opts.importPaths) {
            args.add("--import-path")
            args.add(path)
        }
        // ParseModule has already applied the input selection. Passing -p
        // here would rediscover and compile files excluded from lint.
        for (file in pkg.files) { args.add(file.filePath) }
        let rc = execute(driver, args.toArray())
        if (rc != 0) { fail("Macro package " + pkg.fullPackageName + ": " + driver + " exited with " + rc.toString()) }
        compiler.srcPkgs.remove(at: i)
    }
}

func analyzeWithFrontend(options: Options, selected: HashSet<String>, paths: ArrayList<String>,
    findings: ArrayList<Finding>, controls: DiagnosticControls): Bool {
    let invocation = CompilerInvocation()
    let arguments = ArrayList<String>()
    let executable = FileUtil.JoinPath(options.applicationRoot, "bin/cjlint")
    arguments.add(executable)
    arguments.add("--output-type=staticlib")
    for (path in paths) { arguments.add(path) }
    if (!invocation.ParseArgs(arguments)) { fail("Frontend rejected compiler arguments") }
    let configuration = invocation.globalOptions
    configuration.executablePath = executable
    // Keep the frontend's standard and third-party modules on the same SDK.
    let analysisRoot = if (options.modules.isEmpty()) { options.applicationRoot } else { options.modules }
    configuration.cangjieHome = analysisRoot
    configuration.compilePackage = true
    configuration.moduleSrcPath = options.source
    configuration.implicitPrelude = true
    configuration.parseTest = true
    configuration.enableAddCommentToAst = true
    let directories = HashSet<String>()
    for (path in paths) {
        let directory = FileUtil.GetDirPath(path)
        if (!directories.contains(directory)) { configuration.packagePaths.add(directory); directories.add(directory) }
    }
    let modules = FileUtil.JoinPath(FileUtil.JoinPath(analysisRoot, "modules"), configuration.GetCangjieLibTargetPathName())
    if (!exists(modules) || !FileInfo(modules).isDirectory()) { fail("Compiler modules directory is missing: " + modules) }
    configuration.importPaths.add(modules)
    for (directory in options.importPath.split(" ")) {
        if (!directory.isEmpty()) {
            if (!exists(directory) || !FileInfo(directory).isDirectory()) { fail("Import directory is missing: " + directory) }
            configuration.importPaths.add(FileUtil.GetAbsPath(directory) ?? directory)
        }
    }
    let diagnostics = DiagnosticEngine()
    let compiler = CompilerInstance(invocation, diagnostics)
    compiler.cangjieHome = analysisRoot
    compiler.cangjieModules = modules
    compiler.isCJLint = true
    compiler.buildTrie = false
    let collected = ArrayList<Finding>()
    var macroOutput = ""
    var frontendSucceeded = true
    try {
        // Public frontend stage APIs, in CompilerInstance.Compile's actual order.
        // Each stage runs once; parse-rule source information is consumed before
        // semantic desugaring, and resolved-type rules run only after real SEMA.
        requireFrontendStage(compiler.InitCompilerInstance(), "initialization", diagnostics)
        requireFrontendStage(compiler.PerformPluginLoad(), "plugin loading", diagnostics)
        requireFrontendStage(compiler.PerformParse(), "parse", diagnostics)
        for (pkg in compiler.GetSourcePackages()) {
            for (file in pkg.files) { RuleEngine(selected, collected, file.filePath, compiler.sm, configRoot: options.config, fileID: file.begin.fileID).runParse(file) }
        }
        var semantic = false
        for (id in selected) { if (id != "G.DCL.02" && id != "G.FMT.01") { semantic = true } }
        if (semantic) {
            requireFrontendStage(compiler.PerformConditionCompile(), "conditional compilation", diagnostics)
            for (pkg in compiler.GetSourcePackages()) {
                if (pkg.isMacroPackage) {
                    macroOutput = Directory.createTemp(getTempDirectory()).toString()
                    compileMacroPackages(compiler, options.applicationRoot, macroOutput)
                    break
                }
            }
            requireFrontendStage(compiler.PerformImportPackage(), "package import", diagnostics)
            requireFrontendStage(compiler.PerformMacroExpand(), "macro expansion", diagnostics)
            requireFrontendStage(compiler.PerformIncrementalScopeAnalysis(), "AST diff", diagnostics)
            // SEMA diagnostics are also inputs to lint rules (notably G.ITF.01).
            // Keep the real frontend result through report generation. Earlier
            // stages still fail immediately, before typed AST consumption.
            let semaSucceeded = compiler.PerformSema()
            frontendSucceeded = semaSucceeded && diagnostics.GetErrorCount() == 0
            if (!frontendSucceeded) {
                diagnostics.EmitCategoryGroup()
                diagnostics.ReportErrorAndWarningCount()
            }
            // This accessor requires RunRealSema to have created the actual
            // checker. A failed stage without a typed AST must not be treated
            // as an empty successful analysis.
            compiler.GetTypeChecker()
            let lockOrder = LockOrderCheck()
            let flowSource = FlowSourceInfo()
            for (pkg in compiler.GetSourcePackages()) {
                for (file in pkg.files) {
                    let engine = RuleEngine(selected, collected, file.filePath, compiler.sm, configRoot: options.config, fileID: file.begin.fileID)
                    engine.run(file)
                    if (selected.contains("G.VAR.01")) { flowSource.collect(file, file.filePath) }
                    if (selected.contains("P.01")) { lockOrder.collect(engine, file) }
                    runResolvedTypeRules(engine, file, compiler.typeManager.getOrThrow().AsFaithfulSemaTypeManager())
                }
            }
            if (selected.contains("P.01")) { lockOrder.finish() }
            var needsCHIR = false
            for (id in dataflowRuleIds) { if (selected.contains(id)) { needsCHIR = true } }
            if (needsCHIR && frontendSucceeded && diagnostics.GetErrorCount() == 0) {
                // Preserve the formal frontend stage order and consume actual
                // CHIR packages, never the frontend's declaration summaries.
                var chirSucceeded = compiler.PerformDesugarAfterSema()
                chirSucceeded = chirSucceeded && diagnostics.GetErrorCount() == 0 && compiler.PerformGenericInstantiation()
                chirSucceeded = chirSucceeded && diagnostics.GetErrorCount() == 0 && compiler.PerformOverflowStrategy()
                chirSucceeded = chirSucceeded && diagnostics.GetErrorCount() == 0 && compiler.PerformMangling()
                chirSucceeded = chirSucceeded && diagnostics.GetErrorCount() == 0 && compiler.PerformCHIRCompilation()
                frontendSucceeded = chirSucceeded && diagnostics.GetErrorCount() == 0
                if (frontendSucceeded) {
                    for (pkg in compiler.chirData.getOrThrow().GetAllRealCHIRPackages()) { runDataflowRules(selected, collected, pkg, options.config, compiler.chirData.getOrThrow().GetRealCHIRContext(), compiler.importManager.getOrThrow().GetDiagnosticEngine(), flowSource) }
                    frontendSucceeded = diagnostics.GetErrorCount() == 0
                } else {
                    diagnostics.EmitCategoryGroup()
                    diagnostics.ReportErrorAndWarningCount()
                }
            }
        }
        for (finding in collected) {
            let source = String.fromUtf8(SourceFile.readFrom(finding.file))
            if (controls.retain(finding, controls.directives(source))) { findings.add(finding) }
        }
        return frontendSucceeded
    } finally {
        try { compiler.FreeCHIRData() }
        finally {
            try { compiler.JoinDestroyASTResources() }
            finally {
                try { diagnostics.close() }
                finally { if (!macroOutput.isEmpty()) { remove(macroOutput, recursive: true) } }
            }
        }
    }
}
