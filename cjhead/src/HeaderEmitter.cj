package cjhead

import std.collection.*
import std.sort.*
import cjcj::ast.*
import cjcj::basic.{Position, SourceManager}
import cjcj::sema.TypeManager as SemanticTypeManager

func hasModifier(decl: Decl, name: String): Bool {
    for (modifier in decl.modifiers) {
        if (modifier.ToString() == name) { return true }
    }
    return false
}

func publicDecl(decl: Decl): Bool {
    return hasModifier(decl, "public") || hasModifier(decl, "sealed")
}

func openClass(decl: Decl): Bool {
    return !hasModifier(decl, "sealed") && (hasModifier(decl, "open") || hasModifier(decl, "abstract"))
}

func filePackageName(file: File): String {
    if (let Some(pkg) <- file.curPackage) { return pkg.fullPackageName }
    if (let Some(spec) <- file.packageSpec) { return spec.GetPackageName() }
    return "default"
}

func packageModifier(file: File): String {
    if (let Some(spec) <- file.packageSpec) {
        if (let Some(modifier) <- spec.modifier) { return modifier.ToString() }
    }
    return "public"
}

// Public imports of protected packages are resolved as package/symbol edges,
// using the frontend's ImportContent rather than text matching the source.
class PackageVisibility {
    let visible = HashSet<String>()
    let packageNames = HashSet<String>()
    let files = ArrayList<File>()

    init(packages: ArrayList<HeadPackage>) {
        for (unit in packages) {
            packageNames.add(unit.pkg.fullPackageName)
            for (file in unit.pkg.files) {
                files.add(file)
                if (packageModifier(file) == "public") { visible.add(filePackageName(file) + ".*") }
            }
        }
        var changed = true
        while (changed) {
            changed = false
            for (file in files) {
                if (!visible.contains(filePackageName(file) + ".*")) { continue }
                for (spec in file.imports) {
                    if (let Some(mod) <- spec.modifier) {
                        if (mod.ToString() == "public" && addImport(spec.content)) { changed = true }
                    }
                }
            }
        }
    }

    func addImport(content: ImportContent): Bool {
        var changed = false
        if (content.kind == ImportKind.IMPORT_MULTI) {
            for (item in content.items) {
                if (addImport(item)) { changed = true }
            }
            return changed
        }
        let prefix = content.GetPrefixPath()
        if (packageNames.contains(prefix)) {
            return visible.add(prefix + "." + if (content.kind == ImportKind.IMPORT_ALL) { "*" } else { content.identifier.Val() })
        }
        let name = content.GetImportedPackageName()
        if (packageNames.contains(name)) { return visible.add(name + ".*") }
        return false
    }

    func allows(file: File, decl: Decl): Bool {
        if (packageModifier(file) == "private" || packageModifier(file) == "internal") { return false }
        let pkg = filePackageName(file)
        return visible.contains(pkg + ".*") || visible.contains(pkg + "." + decl.identifier.Val())
    }
}

class HeaderEmitter {
    let sm: SourceManager
    let visibility: PackageVisibility
    let types: SemanticTypeManager

    init(sm: SourceManager, visibility: PackageVisibility, types: SemanticTypeManager) {
        this.sm = sm
        this.visibility = visibility
        this.types = types
    }

    func source(begin: Position, end: Position): String {
        if (begin.fileID != end.fileID || begin.fileID == 0) {
            throw Exception("Declaration source is unavailable: begin=" + begin.fileID.toString() + ":" + begin.toString() + ", end=" + end.fileID.toString() + ":" + end.toString())
        }
        return sm.GetContentBetween(begin, end).trimAscii()
    }

    func start(decl: Decl): Position {
        var begin = decl.begin
        for (anno in decl.annotations) {
            if (anno.begin.fileID == begin.fileID && anno.begin < begin) { begin = anno.begin }
        }
        for (mod in decl.modifiers) {
            if (mod.begin.fileID == begin.fileID && mod.begin < begin) { begin = mod.begin }
        }
        return begin
    }

    func appendComments(node: Node, out: StringBuilder, seen: HashSet<String>): Unit {
        for (group in node.comments.leadingComments) {
            for (comment in group.cms) {
                let text = comment.info.Value()
                if (seen.add(text)) { out.append(text); out.append("\n") }
            }
        }
    }

    func comments(node: Node): String {
        let out = StringBuilder()
        let seen = HashSet<String>()
        appendComments(node, out, seen)
        if (let Some(decl) <- (node as Decl)) {
            var owner = decl
            var macroCall = owner.curMacroCall
            while (macroCall.isNone()) {
                if (let Some(parent) <- owner.outerDecl) {
                    owner = parent
                    macroCall = owner.curMacroCall
                } else { break }
            }
            if (let Some(call) <- macroCall) {
                // The original declaration under the invocation retains comments
                // after macro replacement. Match frontend identities/positions.
                let _ = Walker(call, visitPre: { candidate: Node =>
                    if (let Some(original) <- (candidate as Decl)) {
                        if (original.identifier.Val() == decl.identifier.Val() &&
                            original.GetBegin() == decl.GetBegin() && original.GetEnd() == decl.GetEnd()) {
                            appendComments(original, out, seen)
                        }
                    }
                    return VisitAction.WALK_CHILDREN
                }).Walk()
                if (decl.outerDecl.isNone()) { appendComments(call, out, seen) }
            }
        }
        return out.toString()
    }

    func declaration(decl: Decl, depth: Int64): String {
        if (decl.TestAttr(Attribute.COMPILER_ADD)) { return "" }
        if (let Some(expansion) <- (decl as MacroExpandDecl)) {
            let out = StringBuilder()
            for (node in expansion.invocation.nodes) {
                if (let Some(generated) <- (node as Decl)) {
                    if (publicDecl(generated)) { out.append(declaration(generated, depth)) }
                }
            }
            if (expansion.invocation.nodes.isEmpty()) {
                if (let Some(generated) <- expansion.invocation.decl) {
                    if (publicDecl(generated)) { out.append(declaration(generated, depth)) }
                }
            }
            return out.toString()
        }
        let begin = start(decl)
        var text = ""
        if (let Some(value) <- (decl as ClassDecl)) {
            let body = value.body ?? throw Exception("Missing class body")
            text = container(value, body.leftCurlPos)
        } else if (let Some(value) <- (decl as StructDecl)) {
            let body = value.body ?? throw Exception("Missing struct body")
            text = container(value, body.leftCurlPos)
        } else if (let Some(value) <- (decl as InterfaceDecl)) {
            let body = value.body ?? throw Exception("Missing interface body")
            text = container(value, body.leftCurlPos)
        } else if (let Some(value) <- (decl as EnumDecl)) {
            text = container(value, value.leftCurlPos)
        } else if (let Some(value) <- (decl as ExtendDecl)) {
            if (!exportedExtension(value)) { return "" }
            text = container(value, value.leftCurlPos)
        } else if (let Some(value) <- (decl as PropDecl)) {
            text = source(begin, if (value.leftCurlPos.IsZero()) { value.end } else { value.leftCurlPos })
        } else if (let Some(value) <- (decl as FuncDecl)) {
            text = functionSignature(value, value.funcBody)
        } else if (let Some(value) <- (decl as MacroDecl)) {
            // SEMA moves the macro body to the compiler-generated function.
            let body = if (let Some(desugared) <- value.desugarDecl) {
                desugared.funcBody
            } else { value.funcBody }
            text = functionSignature(value, body)
        } else if (let Some(value) <- (decl as PrimaryCtorDecl)) {
            text = functionSignature(value, value.funcBody)
        } else if (decl is VarDeclAbstract || decl is TypeAliasDecl) {
            text = source(begin, decl.end)
        } else {
            throw Exception("Unsupported exported declaration: " + decl.identifier.Val())
        }
        return indent(comments(decl) + text, depth) + "\n"
    }

    func functionSignature(decl: Decl, body: Option<FuncBody>): String {
        if (let Some(value) <- body) {
            if (let Some(block) <- value.body) { return source(start(decl), block.leftCurlPos) }
        }
        return source(start(decl), decl.end)
    }

    func typePublic(typeNode: Type): Bool {
        if (let Some(ty) <- typeNode.GetTy()) {
            if (let Some(decl) <- Ty.GetInheritableDeclPtrOfTy(ty)) {
                // CJO restores semantic attributes, not source modifier tokens.
                // IsExportedDecl also allows internal declarations, so use the
                // explicit public/sealed attributes required by the head rules.
                return decl.TestAnyAttr(Attribute.PUBLIC, Attribute.SEALED) || publicDecl(decl)
            }
        }
        // Primitive types and generic parameters have no inheritable declaration.
        return true
    }

    func exportedExtension(decl: ExtendDecl): Bool {
        if (!decl.IsExportedDecl()) { return false }
        if (let Some(typeNode) <- decl.extendedType) {
            if (!typePublic(typeNode)) { return false }
        }
        if (let Some(generic) <- decl.generic) {
            for (constraint in generic.genericConstraints) {
                for (bound in constraint.upperBounds) { if (!typePublic(bound)) { return false } }
            }
        }
        if (!samePackageExtension(decl)) {
            var publicInterface = false
            for (inherited in decl.inheritedTypes) {
                if (typePublic(inherited)) { publicInterface = true }
            }
            if (!publicInterface) { return false }
        }
        return true
    }

    func samePackageExtension(decl: ExtendDecl): Bool {
        if (let Some(extended) <- decl.extendedType) {
            if (let Some(ty) <- extended.GetTy()) {
                if (let Some(owner) <- Ty.GetInheritableDeclPtrOfTy(ty)) {
                    return owner.fullPackageName == decl.fullPackageName
                }
            }
        }
        return false
    }

    func extensionMember(decl: ExtendDecl, member: Decl): Bool {
        if (!member.IsExportedDecl()) { return false }
        if (samePackageExtension(decl)) { return true }
        for (inherited in decl.inheritedTypes) {
            if (!typePublic(inherited)) { continue }
            if (let Some(ty) <- inherited.GetTy()) {
                if (let Some(contract) <- Ty.GetInheritableDeclPtrOfTy(ty)) {
                    let contracts = ArrayList<InheritableDecl>()
                    contracts.add(contract)
                    for (parent in contract.GetAllSuperDecls()) { contracts.add(parent) }
                    for (parent in contracts) {
                        for (requirement in parent.GetMemberDecls()) {
                            if (types.PairIsOverrideOrImpl(member, requirement,
                                baseTy: decl.GetTy(), parentTy: inherited.GetTy())) { return true }
                        }
                    }
                }
            }
        }
        return false
    }

    func extensionSignature(decl: ExtendDecl, left: Position): String {
        let extended = decl.extendedType ?? throw Exception("Missing extended type")
        let out = StringBuilder(source(start(decl), extended.end))
        var first = true
        for (inherited in decl.inheritedTypes) {
            if (!typePublic(inherited)) { continue }
            out.append(if (first) { " <: " } else { " & " })
            out.append(source(inherited.begin, inherited.end))
            first = false
        }
        var whereBegin = decl.wherePos
        if (let Some(generic) <- decl.generic) {
            for (constraint in generic.genericConstraints) {
                // ParseConstraints records the explicit WHERE on its first
                // GenericConstraint; ExtendDecl.wherePos may remain unset.
                if (!constraint.isImplicitlyIntroduced && !constraint.wherePos.IsZero() &&
                    (whereBegin.IsZero() || constraint.wherePos < whereBegin)) {
                    whereBegin = constraint.wherePos
                }
            }
        }
        if (!whereBegin.IsZero()) { out.append(" " + source(whereBegin, left)) }
        return out.toString()
    }

    func container(decl: InheritableDecl, left: Position): String {
        let signature = if (let Some(extension) <- (decl as ExtendDecl)) {
            extensionSignature(extension, left)
        } else { source(start(decl), left) }
        let out = StringBuilder(signature + " {\n")
        if (let Some(value) <- (decl as EnumDecl)) {
            var first = true
            for (constructor in value.constructors) {
                out.append(indent(comments(constructor) + if (first) { "" } else { "| " } +
                    source(start(constructor), constructor.end), 1))
                out.append("\n")
                first = false
            }
        }
        for (member in decl.GetMemberDecls()) {
            let fromInterface = decl is InterfaceDecl
            var protectedAllowed = decl is ClassDecl && openClass(decl)
            if (let Some(extension) <- (decl as ExtendDecl)) {
                if (let Some(extended) <- extension.extendedType) {
                    if (let Some(ty) <- extended.GetTy()) {
                        if (let Some(owner) <- Ty.GetInheritableDeclPtrOfTy(ty)) {
                            protectedAllowed = openClass(owner)
                        }
                    }
                }
            }
            if (publicDecl(member) || (fromInterface && !hasModifier(member, "private") &&
                !hasModifier(member, "internal") && !hasModifier(member, "protected")) ||
                (protectedAllowed && hasModifier(member, "protected"))) {
                if (let Some(extension) <- (decl as ExtendDecl)) {
                    if (!extensionMember(extension, member)) { continue }
                }
                out.append(declaration(member, 1))
            }
        }
        out.append("}")
        return out.toString()
    }

    func emitFiles(files: ArrayList<File>, merge: Bool): String {
        let out = StringBuilder()
        let first = files[0]
        if (let Some(spec) <- first.packageSpec) {
            out.append(comments(spec))
            if (spec.hasMacro) { out.append("macro ") }
            if (let Some(mod) <- spec.modifier) { out.append(mod.ToString() + " ") }
            out.append("package " + spec.GetPackageName() + "\n\n")
        } else {
            out.append("package " + filePackageName(first) + "\n\n")
        }
        let imports = ArrayList<String>()
        let seen = HashSet<String>()
        for (file in files) {
            for (spec in file.imports) {
                if (spec.TestAnyAttr(Attribute.IMPLICIT_ADD, Attribute.COMPILER_ADD)) { continue }
                // Multi-import's end can be the closing token's beginning.
                // Its AST delimiter gives an unambiguous inclusive boundary.
                let end = if (spec.content.rightCurlPos.IsZero()) {
                    spec.end
                } else { spec.content.rightCurlPos + 1 }
                let text = source(spec.begin, end)
                if (seen.add(text)) { imports.add(comments(spec) + text) }
            }
        }
        if (merge) { sort(imports) }
        for (text in imports) { out.append(text + "\n") }
        if (!imports.isEmpty()) { out.append("\n") }
        for (file in files) {
            for (decl in file.decls) {
                if (!visibility.allows(file, decl)) { continue }
                if (publicDecl(decl) || decl is ExtendDecl || decl is MacroExpandDecl) {
                    let text = declaration(decl, 0)
                    if (!text.isEmpty()) { out.append(text + "\n") }
                }
            }
        }
        return out.toString()
    }
}

func indent(text: String, depth: Int64): String {
    let prefix = String.fromUtf8(Array<UInt8>(depth * 4, repeat: 32u8))
    let lines = text.split("\n")
    let out = StringBuilder()
    var first = true
    for (line in lines) {
        if (!first) { out.append("\n") }
        if (!line.isEmpty()) { out.append(prefix + line) }
        first = false
    }
    return out.toString()
}
