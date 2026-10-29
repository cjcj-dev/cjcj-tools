macro package headmacro
import std.ast.*
/** Retained public macro. */
public macro Keep(input: Tokens): Tokens { input }
