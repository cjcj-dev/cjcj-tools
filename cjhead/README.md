# cjhead

Generate Cangjie declaration files (`.cj.d`) from checked Cangjie source packages.
The entry point, visibility rules and declaration emitter are written in Cangjie.
The parser, imports, conditional compilation, macro expansion and type checker
come from the same `cjcj` frontend packages used by the compiler.

The export rules and examples are in [the user guide](doc/user_guide.md).

## Build and install

Use a Cangjie compiler and matching compiled `cjcj` packages. The frontend package
input contains the compiler's `target/release` package layout, including all Sema
subpackage archives. An installed compiler may provide this under
`share/cjcj/cjo`. Supply its existing LLVM boundary object and LLVM library;
cjhead does not build or link the former C++ tool or `libcangjie-lsp`.

```console
zx build/build.mjs build --cjc /sdk/bin/cjc \
  --frontend-dir /compiler/target/release \
  --frontend-commit <compiler-source-commit> \
  --shim /compiler/runtime_shim/cjselfhost_llvmshim.o \
  --runtime-config /compiler/runtime_shim/cjc_runtime_config.o \
  --llvm-lib /sdk/third_party/llvm/lib/libLLVM-15.so \
  --runtime-dir /sdk/runtime/lib/linux_x86_64_cjnative \
  --build-dir /work/cjhead-build --jobs 4
zx build/build.mjs install --build-dir /work/cjhead-build --prefix /work/cjhead-install
```

`build` writes the executable, compiler stdout/stderr, and build source facts.
`install` copies that executable into `bin`, the supplied LLVM/runtime libraries
into `lib`, and documentation/build facts into `share/cjhead`. Repeating either
command uses the same explicit inputs and destination. The manifest records facts;
it is not an installation authority or authentication mechanism.

CMake delegates to the same builder. Configure `CJHEAD_CJC`,
`CJHEAD_FRONTEND_DIR`, `CJHEAD_FRONTEND_COMMIT`, `CJHEAD_LLVM_SHIM`,
`CJHEAD_LLVM_LIBRARY`, `CJHEAD_RUNTIME_CONFIG` and `CJHEAD_RUNTIME_DIR`, then use `cmake --build` and
`cmake --install`. No C++ tool build is available.

For runtime source resolution, set `CANGJIE_HOME` to the matching compiler SDK.
The binary loads its own installed LLVM/runtime libraries through its relative
runtime path. Imported `.cjo` packages and macro libraries still come from the
explicit paths passed to the CLI or the frontend's SDK defaults.

## Run

```console
cjhead -i source -o headers
cjhead -i source -o headers -p --import-path dependencies --macro-path macros
cjhead -i source/api.cj -o api.cj.d --exclude excludes.txt
```

`-i` accepts a directory tree or one source file. Directory mode preserves relative
source paths and appends `.d`; `-p` writes one `<full-package-name>.cj.d` per package.
A single source file can write to an output file or an existing output directory.
`-o` defaults to the current directory. A single-file request type checks its
package siblings but emits only the requested file. Exclusions apply to emitted
file names after semantic analysis, as in the original tool.

`--import-path` and `--macro-path` can be repeated. `--exclude` reads one regular
expression per line, searches file names, skips empty lines and reports invalid
expressions. These expressions select files; language syntax and semantics are
handled by the frontend. `-h` or no arguments prints help. Invalid arguments,
failed semantic analysis and output errors return a nonzero exit status. No output
is written until every selected package has passed semantic analysis.

If `bin/resources/COPYRIGHT.txt` exists and contains non-whitespace text, its
contents are prepended to each generated header. This optional resource can be
provided by the distributor without recompiling the executable.

## Validation

```console
zx tests/public.mjs --binary /work/cjhead-install/bin/cjhead --evidence /work/results
```

Tests exercise the installed CLI, inspect actual generated headers, and preserve
child exit status/stdout/stderr. The same command accepts a freshly unpacked
installation. Host development results and source-built target runtime
qualification must be recorded separately; a successful host build does not
qualify a different frontend, runtime, SDK or platform.

Supply `--runtime-config` (`CJHEAD_RUNTIME_CONFIG` in CMake) when the chosen
frontend requires its existing runtime configuration object. It remains a
compiler infrastructure input alongside the LLVM bridge. Keep its producer
identity with the frontend facts; changing frontend inputs requires a separate
build and affected validation.
