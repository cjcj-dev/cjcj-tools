package cjlint

import cjcj::frontend.{CompilerInvocation, CompilerInstance, DiagnosticEngine}
import cjcj::utils.FileUtil
import std.collection.*
import std.fs.File as SourceFile
import std.fs.{FileInfo, exists}

func requireFrontendStage(ok: Bool, name: String, diagnostics: DiagnosticEngine): Unit {
    if (!ok || diagnostics.GetErrorCount() != 0) {
        diagnostics.EmitCategoryGroup()
        diagnostics.ReportErrorAndWarningCount()
        fail("Frontend ${name} failed")
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
    configuration.cangjieHome = options.applicationRoot
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
    let moduleRoot = if (options.modules.isEmpty()) { options.applicationRoot } else { options.modules }
    let modules = FileUtil.JoinPath(FileUtil.JoinPath(moduleRoot, "modules"), configuration.GetCangjieLibTargetPathName())
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
    compiler.cangjieHome = options.applicationRoot
    compiler.cangjieModules = modules
    compiler.isCJLint = true
    compiler.buildTrie = false
    let collected = ArrayList<Finding>()
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
            finally { diagnostics.close() }
        }
    }
}
