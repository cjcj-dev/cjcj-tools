# CJO publication watcher successor

Base: afe0b04ae0613b5353d6d8f6425737ad54abfb16, the explicitly selected SDK cjpm source. The public default pin 1a636 and tools T271 are distinct inputs.

The compiler's persistent .cjo.flag is observed by cjpm.watcher using std.fs system calls and a bounded 10ms event loop. Preparation completes before task dispatch, clears stale task flags, and rejects non-files. Expected full paths map to the existing TaskIds; each is delivered once. Exceptions notify Failed monitors and propagate through the joined worker. stop precedes join; cleanup follows join. There is no C++/libuv watcher implementation in this graph. Jobserver, MAKEFLAGS, FD/token propagation and the incremental engine are unchanged.

build/build.py is only the public process adapter to build.mjs. The normal graph compiles toml/util/config/watcher/implement/command then cjpm. The existing --native-only phase has no tool-native sources and performs no compilation. It does not claim a compiler/SDK build. The old cpp CMake producer and fswatcher.cpp are retired; historical Git objects remain.

publication.cj consumes real flag files using the production watcher module: stale removal, same basename in distinct directories, unrelated control, exactly-once, stop/join/cleanup and callback-error propagation. control mode exercises invalid input independently. A production cut removing pending.remove(path) must fail exactly-once while control remains valid; restoration is a fresh compile of original fixed source. These tests do not substitute for complete cjpm pipeline/cache/recovery tests.

STATUS: source prepared; actual new module/build/jobserver and public cjpm integration execution NOT_RUN pending small remote resource admission. Windows/Darwin/native target qualification NOT_RUN. No default pin is changed before independent review/publication.
