package rename_export_contract
import std.fs.*
import cangjie_lsp_core.*
import cangjie_lsp_protocol.*

func check(value: Bool, name: String): Unit {
    if (!value) { throw Exception("RENAME_EXPORT_FAIL " + name) }
    println("RENAME_EXPORT_PASS " + name)
}
main(args: Array<String>): Int64 {
    try {
        if (args.size != 3) { return 2 }
        let sdk = args[0]
        let root = args[1]
        let mode = args[2]
        let leafPath = root + "/leaf.cj"
        let usePath = root + "/use.cj"
        let declName = if (mode == "normal" || mode == "control") { "answer" } else { "renamed" }
        let useName = if (mode == "normal" || mode == "old-name") { "answer" } else { "renamed" }
        let leafText = "package rename_leaf\npublic func " + declName + "(): Int64 { return 42 }\npublic func untouched(): Int64 { return 7 }\n"
        let useText = "package rename_use\nimport rename_leaf.*\npublic func use(): Int64 { return " + (if (mode == "control") { "untouched" } else { useName }) + "() }\n"
        File.writeTo(leafPath, leafText.toArray())
        File.writeTo(usePath, useText.toArray())
        let leaf = SemanticDocument(DocumentSnapshot(leafPath, 1, leafText), sdk)
        check(leaf.succeeded, "leaf-sema")
        let packages = leaf.compiler.GetSourcePackages()
        check(packages.size == 1, "one-source-package")
        let bytes = leaf.compiler.ExportAST(true, packages[0])
        check(!bytes.isEmpty() && leaf.diagnostics.GetErrorCount() == 0, "official-export")
        File.writeTo(root + "/rename_leaf.cjo", bytes)
        let consumer = SemanticDocument(DocumentSnapshot(usePath, 1, useText), sdk, importPaths: [root])
        if (mode == "old-name") {
            check(!consumer.succeeded && consumer.diagnostics.GetErrorCount() > 0, "old-name-rejected")
        } else {
            for (record in consumer.records) { eprintln(record.message) }
            check(consumer.succeeded, "dependent-sema-" + mode)
            check(!consumer.ExportedTarget(ProtocolPosition(2, 35)).isEmpty(), "imported-target-identity")
        }
        return 0
    } catch (e: Exception) { eprintln(e.message); return 41 }
}
