package lsp_semantic_contract
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*

func check(value: Bool, name: String): Unit {
    if (!value) { throw Exception("LSP_SEMANTIC_TARGET_FAIL " + name) }
    println("LSP_SEMANTIC_TARGET_PASS " + name)
}
main(args: Array<String>): Int64 {
    try {
        if (args.size != 2) { return 2 }
        let text = "package lsp_semantic_fixture\npublic func pick(value: Int64): Int64 { return value }\npublic func pick(value: Bool): Bool { return value }\npublic func use(): Int64 {\n    let value: Int64 = 40\n    let text = \"😀\"\n    let result = /*😀*/ pick(value)\n    return result\n}\n"
        let snapshot = DocumentSnapshot(args[1], 1, text)
        let doc = SemanticDocument(snapshot, args[0], importPaths: [args[0]+"/modules/linux_x86_64_cjnative"])
        check(doc.succeeded, "real-sema-cache")
        let pick = ProtocolPosition(6, 24)
        check(ProtocolPositionAt(text, ProtocolOffset(text, pick)).character == 24, "utf16-after-supplementary")
        let found = doc.Definition(pick).getOrThrow()
        check(found.path == args[1] && found.start.line == 1 && found.start.character == 12, "resolved-int-overload")
        let local = doc.Definition(ProtocolPosition(6, 29)).getOrThrow()
        check(local.start.line == 4 && local.start.character == 8, "local-binding-not-same-named-parameter")
        let localRefs = doc.References(ProtocolPosition(6, 29), includeDeclaration: true)
        check(localRefs.size == 2, "local-reference-set")
        check(doc.References(ProtocolPosition(1, 17), includeDeclaration: true).size == 2, "parameter-reference-set")
        check(doc.References(ProtocolPosition(2, 12)).isEmpty(), "unused-overload-control")
        check(doc.Definition(ProtocolPosition(5, 16)).isNone(), "string-is-not-reference")
        let next = SemanticDocument(DocumentSnapshot(args[1], 2, text.replace("pick(value)", "pick(true)")), args[0], importPaths: [args[0]+"/modules/linux_x86_64_cjnative"])
        check(!next.succeeded && next.Definition(pick).isNone(), "type-error-does-not-publish-stale-index")
        check(doc.Definition(pick).getOrThrow().start.line == 1 && doc.snapshot.version == 1, "old-snapshot-retains-binding")
        return 0
    } catch (e: Exception) { eprintln(e.message); return 41 }
}
