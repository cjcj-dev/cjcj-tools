package cjcompat

import cjcj::ast.*
import cjcj::ast.AnnotationKind as AstAnnotationKind

func AddedAttr(a: Decl, b: Decl, attr: Attribute): Bool { !a.TestAttr(attr) && b.TestAttr(attr) }
func RemovedAttr(a: Decl, b: Decl, attr: Attribute): Bool { a.TestAttr(attr) && !b.TestAttr(attr) }
func ReducedAccess(a: Decl, b: Decl): Bool {
    Visible(a) && !Visible(b) || a.TestAttr(Attribute.PUBLIC) && b.TestAttr(Attribute.PROTECTED)
}
func Deprecation(d: Decl): (Bool, Bool) {
    for (anno in d.annotations) {
        if (anno.kind == AstAnnotationKind.DEPRECATED) {
            let message = Box<String>(""); let since = Box<String>(""); let strict = Box<Bool>(false)
            ExtractArgumentsOfDeprecatedAnno(anno, message, since, strict)
            return (true, strict.value)
        }
    }
    return (false, false)
}

