# Cangjie stdio LSP server

The executable is built from `server/main.cj`, `cangjie_lsp_core`, and
`cangjie_lsp_protocol`. It links the selected Cangjie frontend packages and
normal stdx JSON targets. It does not launch or link the former C++ LSP backend.

`build.mjs --server stdio` builds the core and executable through CJPM. Supply
`--sdk`, `--cjpm`, `--frontend-packages`, `--runtime-config`, `--json-build`,
`--llvm-shim`, `--llvm-library`, `--build`, and `--install` explicitly. The JSON
build directory must be the normal stdx CMake output for the same development
host compiler, including targets `cangjieCJNATIVEJson`, `stdx.encoding.json`, and
`stdx.serialization.serialization`. Host runtime dependencies are installed in
`lib`; the binary uses an origin-relative linker RPATH. The analyzed target SDK
is selected separately at runtime:

```
bin/cangjie-lsp --sdk /absolute/target/sdk
```

The current implemented protocol surface is initialize/initialized,
shutdown/exit, incremental UTF-16 didOpen/didChange/didClose, definition,
references, document highlights, hover, prepareRename/rename, completion, and published frontend diagnostics. Same-directory open documents
are analyzed together using cached source buffers and declaration identity.
Local absolute file URIs are decoded at the protocol boundary. The server
advertises only its implemented semantic request capabilities; it does not
claim the entire old server protocol. The supported
same-directory and explicit CJPM project modes are described below.

`tests/server-client.mjs EXE TARGET_SDK EVIDENCE_DIRECTORY` is a real framed
stdio client. It checks fragmented initialization, fragmented non-BMP UTF-8,
member definition, cross-file definition/references, type diagnostics, repair,
close, unknown-method/JSON errors, orderly shutdown, early exit, and truncated
frames. Run the same client against the independent installation and the fresh
unpacked installation. The explicit target SDK remains an input; it is not
silently replaced by the compiler's host SDK.

This is a development-host nonmacro scope. Shared frontend 523a macro execution
has a separately preserved failing producer/host combination and is not granted
by nonmacro server results. These tests neither delete that obligation nor grant
full target SDK, managed, or cross-platform LSP qualification.

Workspace successor: explicit initialize.workspaceFolders/rootUri enables the normal same-directory source-package graph, including unopened .cj siblings (excluding _test.cj). Open snapshots override disk. didClose restores disk and workspace/didChangeWatchedFiles refreshes unopened sources. Use the explicit compilation database mode below for CJPM import/build graphs. tests/server-client.mjs mode workspace covers this directory mode; completion remains unimplemented. Historical a3e results keep their original scope.

`textDocument/documentHighlight` uses the selected snapshot's resolved declaration
identity and returns declaration/reference ranges only in the requested file.
Highlights use kind Text (1); read/write classification is not claimed. An
invalid SEMA snapshot returns null, a valid position without a symbol returns
an empty array, and unknown documents keep the invalid-params response.
`server-client.mjs ... highlight` exercises shadowing, UTF-16 after a non-BMP
character, unopened siblings, buffer/disk changes and error snapshot recovery
through stdio. Mode `highlight-control` makes an independent definition query.
The project modes and the remaining protocol/macro obligations above continue
to apply. New source is not dynamic qualification by itself.

## Explicit CJPM projects

Use the matching CJPM candidate's normal build to publish a standard arguments-based compilation database:

```text
cjpm build -i --target-dir <selected-target> --export-compile-commands /absolute/project/compile_commands.json
```

This selects normal workspace members, source directories, path/binary dependencies and target configuration. The same CompileTask argument expansion serves executed and cached tasks. The database includes every selected source compile task; scheduler-only job admission is not a semantic input. Publication happens after successful build/post-build processing. Starting a new export removes the old database, so a failed build cannot leave the previous graph available as current. The database describes the selected compilation; it is not compiler execution history.

Start the server with its explicit analysis prefix, then initialize with `initializationOptions: {compilationDatabase: "/absolute/project/compile_commands.json"}`. `workspace/didChangeConfiguration` uses the same field in `settings`; watched-file notifications reread the selected database and disk sources. Empty compilationDatabase returns to the existing standalone-document mode.

Project mode indexes only files listed in the selected database. Open buffers override their disk files; close restores disk contents. Paths are resolved relative to each command's directory without changing the server process working directory or host environment. Target/cfg/import arguments pass to CompilerInvocation, while explicit --sdk remains the analysis modules selection. Ambiguous multiple commands for one source are rejected: select a single target/build configuration. Shell command-only databases and source response files are not supported.

Cross-package source queries use the frontend's CJO export identities and actual source declarations, not pointer equality across CompilerInstances or name matching. Binary-only dependencies return no fabricated definition location. Imported type information still comes from the selected CJO: rebuild the normal project after changing a dependency's exported API and notify the server/configuration refresh. A source overlay does not silently manufacture a new CJO. Local declarations retain their own instance identity.

This is Linux host development analysis with the fixed shared frontend and matching major1 analysis prefix. It does not establish macro, complete SDK, other-platform or all-protocol qualification. P/core/leaf fixtures are deliberately not a full SDK.

## Semantic hover

`textDocument/hover` returns plaintext resolved identifier/type with the request occurrence UTF-16 range. Declaration identifiers, resolved expression references and member names use the same snapshot as definition/references. Reference and member types come from the resolved AST occurrence, including instantiated generics and selected overloads; declarations use their own semantic type. Display uses the selected frontend's type renderer (for example its uninstantiated generic is `Generics-T`, while `same<Int64>` has the instantiated `(Int64) -> Int64` type). It does not expose declaration bodies or initializers as hover text.

Failed snapshots, missing/invalid types and positions without a collected resolved identifier return null. Unknown nonproject documents keep the existing invalid-params response. The snapshot owns all AST types; no cross-instance pointer or name matching is used. Source documentation extraction is not advertised.

`node tests/hover-client.mjs EXE ANALYSIS_SDK EVIDENCE_DIRECTORY PROJECT [all|target|control|project]` uses real framed stdio. The project argument is an existing normal CJPM-generated database with direct/transitive/binary dependencies; it is not generated by this client. The default checks declared/inferred types, parameter/member references, generic instantiation, overload selection, shadowing, UTF-16 ranges, buffer changes, invalid snapshots, project refresh and natural shutdown. Target isolates hover's type pipeline and control makes an independent definition query. Run against the normal installation and the fresh unpacked installation with the original install hidden. Linux host finite evidence is recorded separately; other platforms, macros and full SDK qualification remain separate.

## Semantic rename

The client must advertise workspace.workspaceEdit.documentChanges. prepareRename returns the current UTF-16 identifier range and placeholder. rename returns versioned documentChanges (null version for unopened disk files); the server never applies them. Source declarations and uses are selected by frontend binding identity, including parameter labels, type names and source import tokens. An import alias retains its own spelling; invoking rename on the alias rather than its source declaration is rejected. Open, abstract, override/interface member sets and inherited same-name member associations are rejected at prepare when the complete relationship is not supported. Fields and ordinary unrelated methods are not rejected merely because the frontend inserted Object as a base.

The candidate is compiled through normal SEMA. In a selected source project, each successfully analyzed candidate package is exported through the existing AST writer to a request-local CJO directory before its dependents are analyzed. Those files are removed after validation and never replace the project's build artifacts. Every collected reference and declaration is compared before and after, using source anchors and export identities across instances; successful compilation alone does not establish absence of capture. Failed semantics, ambiguous or unavailable source bindings, illegal identifiers, changed source/version/database, or changed reference relationships reject the whole edit. Binary-only definitions, macros and unknown external dependents are outside the editable source graph.

After applying a cross-package edit, the client must rebuild through the same normal CJPM graph and refresh the server's project inputs. The request's temporary semantic CJO is not an installed library or a replacement for the normal build. The explicit analysis prefix and execution host remain separate.

The real stdio test is tests/rename-client.mjs EXE ANALYSIS_SDK EVIDENCE_DIRECTORY PROJECT MODE. Modes local, target, control, members, workspace, capability, and project isolate their respective contracts. Project mode consumes a normal compilation database and a recorded normal CJPM build recipe, applies edits, rebuilds and runs the resulting program. Cut mode is supplied by the external isolated product-source experiment, not a server switch. Tests record original wire and process status; a failed client may terminate its server for cleanup, which is recorded separately from natural shutdown. Source support does not grant unexecuted platform, macro, full LSP or SDK qualification.

## Semantic completion

Completion accepts a UTF-16 identifier position, including a partially spelled identifier or a member-access hole, in the current standalone or explicitly selected project snapshot. A request-local marker locates the actual frontend AST scope or receiver. Candidate names come from that scope, loaded import declarations, receiver/superclass members and visible extension members; the list is not returned directly. Each proposed replacement is compiled through normal SEMA and must bind to the discovered declaration with the resulting resolved type. This preserves the frontend's actual package relation, access, declaration-order, overload and generic-constraint rules. Same-package protected access is legal; unrelated-package refusal is established by the selected frontend, not Java access rules.

Each item contains a label, resolved type detail, and a replacement textEdit for the current identifier range. The method does not invent call arguments or perform additional imports. A valid semantic repair is required even to establish an empty result; unknown syntax, unavailable dependencies and unrelated semantic errors are rejected. Requests preserve document and compilation-database identity, and return isIncomplete=false only after the selected candidates finish. Completion edits do not carry a protocol version; clients must apply them to the matching request snapshot.

The real consumer is tests/completion-client.mjs EXE ANALYSIS_SDK EVIDENCE_DIRECTORY PROJECT MODE. Named modes isolate actual member, shadowing, generic, import, package-access and error cases; project mode applies edits and invokes the normal CJPM build/loader/program recipe. Wire and natural/cleanup exit statuses are retained. Linux host evidence is recorded per product and test revision: already completed subsets are not represented as one final-ELF full matrix. Exact product cuts and final unpacked consumption remain required before this feature's complete finite handoff; macro, other-platform, full LSP and full SDK qualifications remain separate.
