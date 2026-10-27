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
references, and published frontend diagnostics. Same-directory open documents
are analyzed together using cached source buffers and declaration identity.
Local absolute file URIs are decoded at the protocol boundary. The server
advertises only its implemented semantic request capabilities; it does not
claim completion, rename, workspace indexing, hover, or the entire old server
protocol. Further protocol and project graph work remains required.

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
