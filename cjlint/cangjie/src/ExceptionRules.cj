package cjlint

import cjcj::ast.*
import std.collection.*

func checkDocumentedExceptions(engine: RuleEngine, body: FuncBody, comments: ArrayList<CommentGroup>): Unit {
    if (let Some(block) <- body.body) {
        for (item in block.body) {
            Walker(item, visitPre: { node: Node =>
                if ((node as FuncDecl).isSome()) { return VisitAction.SKIP_CHILDREN }
                if (let Some(attempt) <- (node as TryExpr)) {
                    for (handler in attempt.catchBlocks) {
                        if (handler.body.isEmpty() || handler.body[0].TestAttr(Attribute.COMPILER_ADD)) {
                            engine.findings.add(Finding(engine.path, handler.leftCurlPos, handler.rightCurlPos,
                                "G_ERR_01_exceptions_process_01", []))
                        }
                    }
                }
                if (let Some(thrown) <- (node as ThrowExpr)) {
                    if (let Some(expression) <- thrown.expr) {
                        if (let Some(call) <- (expression as CallExpr)) {
                            if (let Some(function) <- call.baseFunc) {
                                let name = function.ToString()
                                var documented = false
                                for (group in comments) {
                                    for (comment in group.cms) {
                                        if (comment.info.Value().contains(name)) { documented = true }
                                    }
                                }
                                if (!documented) { engine.emit(thrown, "G_ERR_01_exceptions_process_02", []) }
                            }
                        }
                    }
                }
                return VisitAction.WALK_CHILDREN
            }).Walk()
        }
    }
}

func checkExceptionHandling(engine: RuleEngine, root: Node): Unit {
    Walker(root, visitPre: { node: Node =>
        if (let Some(mainDecl) <- (node as MainDecl)) {
            if (let Some(function) <- mainDecl.desugarDecl) {
                if (let Some(body) <- function.funcBody) {
                    checkDocumentedExceptions(engine, body, function.comments.leadingComments)
                }
            } else if (let Some(body) <- mainDecl.funcBody) {
                checkDocumentedExceptions(engine, body, mainDecl.comments.leadingComments)
            }
            return VisitAction.SKIP_CHILDREN
        }
        if (let Some(function) <- (node as FuncDecl)) {
            if (let Some(body) <- function.funcBody) { checkDocumentedExceptions(engine, body, function.comments.leadingComments) }
        }
        return VisitAction.WALK_CHILDREN
    }).Walk()
}
