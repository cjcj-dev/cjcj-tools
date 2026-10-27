import cjfmt_core.*
import cjcj::ast.{Walker, VisitAction, Node, ASTKind}
import cjcj::basic.Position

func require(value: Bool, name: String): Unit {
    if (!value) { throw Exception("CJFMT_TARGET_FAIL " + name) }
    println("CJFMT_TARGET_PASS " + name)
}

main(): Int64 {
    let source = "// retained comment\npublic func identity<T>(value: T): T {\n    return value\n}\nmain() {\n    let value = identity(7)\n    println(value)\n}\n"
    let input = FormattingInput("formatter-input.cj", source)
    require(!input.HasErrors(), "real-parser-generics")
    require(input.file.decls.size == 2, "real-parser-declarations")
    let first = input.file.decls[0]
    require(FormattingBegin(first) == Position(2, 1), "modifier-begin")
    let region = RegionFormattingTracker(6, 6)
    var selected: Option<Node> = None
    Walker(input.file, visitPre: {node: Node =>
        if (node.astKind == ASTKind.VAR_DECL && node.begin.line == 6) { selected = node }
        return VisitAction.WALK_CHILDREN
    }).Walk()
    require(selected.isSome(), "real-parser-variable")
    let variable = selected.getOrThrow()
    require(region.ShouldFormat(variable), "selected-variable")
    require(!region.ShouldFormat(first), "outside-region-control")
    region.ProcessNodeFormatted(variable)
    let bounds = region.GetPreciseFragmentBounds(input.sourceManager).getOrThrow()
    require(input.sourceManager.GetContentBetween(bounds[0], bounds[1]) == "let value = identity(7)", "precise-source-fragment")
    require(region.IsInsideFormattedNode(variable), "inside-selected-node")
    require(!region.IsInsideFormattedNode(first), "outside-selected-node")
    let broken = FormattingInput("broken.cj", "func missing( { }")
    require(broken.HasErrors(), "real-parser-diagnostic")
    let noSelection = RegionFormattingTracker(30, 31)
    require(noSelection.GetPreciseFragmentBounds(input.sourceManager).isNone(), "empty-selection")
    return 0
}
