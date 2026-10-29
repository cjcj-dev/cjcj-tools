package cjcompat

import std.collection.*
import cjcj::ast.*
import cjcj::basic.DiagnosticEngine as HeaderDiagnosticEngine
import cjcj::basic.SourceManager
import cjcj::frontend.{CjoSignatureMaterializer, DiagnosticEngine}
import cjcj::modules.{ASTLoader, GetPackage}
import cjcj::sema.TypeManager
import cjcj::utils.FileUtil

// Both sides own their AST, types and dependency graph. No bytes are decoded here:
// the compiler's versioned ASTSerialization and materializer own the CJO format.
class Library {
    let sources = SourceManager()
    let diag = DiagnosticEngine()
    let types = TypeManager()
    let packages = ArrayList<Package>()
    let decls = HashMap<String, PackageDecl>()
    let exports = HashMap<String, HashMap<String, Decl>>()
    let loaders = ArrayList<CjoSignatureMaterializer>()
    let loaded = HashMap<String, Package>()
    let paths: ArrayList<String>
    var root = Package()
    init(file: String, paths: ArrayList<String>) {
        diag.SetSourceManager(sources)
        this.paths = ArrayList<String>()
        this.paths.add(FileUtil.GetDirPath(file))
        this.paths.add(all: paths)
        root = Load(file)
        for (loader in loaders) { loader.LoadPackageDecls() }
        for (loader in loaders) { loader.LoadRefs() }
        if (diag.GetErrorCount() != 0u64) { throw Exception("Cannot load file " + file) }
    }

    public func Load(file: String): Package {
        let (ok, bytes, reason) = FileUtil.ReadBinaryFileToBuffer(file)
        if (!ok) { throw Exception("Cannot load file " + file + ": " + reason) }
        let headerDiag = HeaderDiagnosticEngine()
        headerDiag.SetSourceManager(sources)
        let header = ASTLoader(bytes, "", headerDiag)
        header.SetCjoPath(file)
        let _ = header.LoadPackageDepInfo()
        if (headerDiag.GetErrorCount() != 0u64 || !header.HasCjoVersion()) {
            throw Exception("Cannot load file " + file + ": invalid or unsupported CJO format/version")
        }
        let name = GetPackage(bytes).GetFullPkgName().getOrThrow().str()
        if (let Some(existing) <- loaded.get(name)) { return existing }
        let pkg = Package(name)
        let loader = CjoSignatureMaterializer(name, pkg, HashMap<UInt32, File>(),
            HashMap<UInt64, File>(), packages, decls, exports, diag, types)
        loader.SetCjoPath(file)
        if (!loader.LoadPackageDependencies(bytes)) { throw Exception("Cannot load file " + file) }
        loaded[name] = pkg
        packages.add(pkg)
        decls[name] = PackageDecl(pkg)
        for (dependency in loader.GetDependentPackageNames()) {
            if (loaded.contains(dependency)) { continue }
            let depFile = FileUtil.FindSerializationFile(dependency, ".cjo", this.paths.toArray())
            if (depFile.isEmpty()) {
                throw Exception("Cannot load dependency " + dependency + "; use --import-path or CANGJIE_PATH")
            }
            let _ = Load(depFile)
        }
        loaders.add(loader)
        return pkg
    }
}
