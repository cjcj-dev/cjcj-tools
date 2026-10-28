# cjhead

`cjhead` scans Cangjie source packages and produces public declaration files.
Its public build and CLI interfaces are documented in [README](../README.md),
and export rules are documented in [the user guide](user_guide.md).

## Production call chain

`build/build.mjs` compiles `src/*.cj` against the compiler's matching Cangjie
frontend packages. `CMakeLists.txt` delegates to that same build/install interface.
The installed `bin/cjhead` directly enters `main.cj`; there is no C++ launcher,
legacy executable fallback or FFI wrapper around `libcangjie-lsp`.

`HeadOptions.parse` validates CLI values and output exclusion expressions.
`runHead` discovers source package directories and calls `compilePackage`.
`CompilerInstance.Compile(SEMA)` performs source parsing, conditional compilation,
import resolution, macro expansion and semantic analysis. A failed stage stops
emission and propagates an error exit status.

`PackageVisibility` computes public package/re-export reachability from frontend
AST import nodes. `HeaderEmitter` traverses resolved declarations, preserves
public/sealed types and applicable public/protected members, uses resolved type
information for extensions, and emits source spans bounded by AST positions.
Function and property bodies are omitted; annotations, declaration comments,
generic constraints and default values retain their source spelling. Enum
constructors and public variable initializers remain declaration content.

The emitter consumes the compiler's source manager, including sources produced
by macro expansion. It does not tokenize Cangjie with regular expressions, guess
brace pairing or substitute a separate parser. File exclusion is the only use
of regular expressions in the tool.

`writeHeader` creates output parents and writes the generated declarations.
Package mode deduplicates imports and merges source declarations once per package.
The optional executable-relative copyright resource is applied at the write
boundary for both modes.

## Ownership and integration

The dedicated builder accepts fixed frontend archives and the existing compiler
LLVM boundary object. These dependencies must be built with the selected host or
target compiler and runtime. Native LLVM, runtime and system libraries are build
infrastructure; no former cjhead C++ algorithm is part of the target.

Common SDK/CI packaging consumes the independent installation directory. This
subproject does not edit shared SDKs or implement its own installation authority.
The installation can be archived and unpacked directly, preserving `bin`, `lib`
and `share/cjhead`. Run the same public tests against the unpacked executable.

Cross-platform validation requires matching platform frontend packages, LLVM and
runtime inputs, followed by execution on that platform. A Linux host result cannot
establish Windows, macOS, AArch64 or OpenHarmony qualification.
