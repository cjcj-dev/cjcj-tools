# cjprof

`cjprof` analyzes Cangjie heap dumps and records CPU call chains. The command implementation, heap parser, graph analysis, snapshot API, HTTP service, ELF symbols, recorder and report generation are Cangjie source in `cangjie/`. The Java API retains its existing package and model classes.

This producer currently supports Linux x86-64. Select a compiler SDK containing a **matching compiler, std and runtime**. A host development build does not qualify a different target SDK or runtime.

## Build and install

Dependencies: CMake 3.16+, Node.js, `cjc`, a C compiler, Linux system libraries (`libatomic`, `libstdc++`, `libdl`), a JDK with JNI headers, and the selected Lombok annotation processor for the existing Java API. The C compiler builds only `build/jni-bootstrap.c`, which starts the Cangjie runtime before managed JNI exports can be entered. No C/C++ profiling algorithm is compiled.

```console
cmake -S cjprof -B /absolute/build -G Ninja \
  -DCJPROF_SDK=/absolute/matching-sdk \
  -DCJPROF_JNI_HOME=/absolute/jdk \
  -DCJPROF_RUNTIME_HEADER=/absolute/matching-runtime/Cangjie.h \
  -DCJPROF_LOMBOK_JAR=/absolute/lombok.jar \
  -DCMAKE_INSTALL_PREFIX=/absolute/install
cmake --build /absolute/build -j 4
cmake --install /absolute/build
```

`CANGJIE_HOME`, `JAVA_HOME` and `CJPROF_LOMBOK_JAR` provide defaults for the corresponding three CMake inputs. The public runtime header is always selected explicitly. The standalone producer is the same script CMake invokes:

```console
node cjprof/build/build.mjs build --sdk /absolute/matching-sdk \
  --jni-home /absolute/jdk --runtime-header /absolute/matching-runtime/Cangjie.h \
  --lombok-jar /absolute/lombok.jar --build-dir /absolute/build/product
node cjprof/build/build.mjs install --build-dir /absolute/build/product --prefix /absolute/install
```

An installed directory contains `bin/cjprof`, `lib/libcjprof-cangjie.so`, `lib/libcjprof-jni.so`, `share/java/cjprof.jar`, `config/static/` and `build-facts.json`. Keep these paths together when archiving or moving it. The selected SDK runtime remains an external dependency:

```console
export CANGJIE_HOME=/absolute/matching-sdk
export LD_LIBRARY_PATH="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/tools/lib"
/absolute/install/bin/cjprof --help
```

## Use

```console
cjprof heap -i heap.data
cjprof heap -i heap.data --json
cjprof heap -i heap.data --show-thread
cjprof heap -i heap.data '--show-reference=SomeClass;AnotherClass' --depth 10
cjprof heap -i heap.data --dump-report=8080
cjprof heap --dump PID --output live.data
cjprof record -f 499 -o samples.data -- program arg
cjprof record -p PID -o samples.data
cjprof report -i samples.data
cjprof report -i samples.data -F -o FlameGraph.svg
```

Heap/report input and record/dump output default to `cjprof.data`. HTTP tries the requested port and then up to 99 successors. Its first run writes `<input>.cjprof.db`; a later run consumes the compatible packed version-2 cache. Dump uses the target runtime's SIGUSR1 protocol. Record uses Linux perf events and ptrace permissions; denial is an error. SIGINT stops recording, detaches an attached target, and terminates the exact target launched by the profiler.

For Java, compile against `share/java/cjprof.jar`, supply `-Djava.library.path=/absolute/install/lib`, and set the selected SDK library environment above. Also preload the selected JDK signal chaining library before starting the JVM: `LD_PRELOAD=/absolute/jdk/lib/libjsig.so /absolute/jdk/bin/java ...`. The JVM and Cangjie runtime both install signal handlers; without this JDK support, `-Xcheck:jni` reports modified JVM handlers. Call `com.cjprof.jni.Cjprof.initialize()` before using its snapshot methods. Neither C++ headers nor a C++ API library are installed by this producer.

## Installed product tests

Configure the same build with `-DBUILD_TESTING=ON -DCJPROF_TEST_PREFIX=/absolute/install`, build and install, then run `ctest --test-dir /absolute/build --output-on-failure`. All five registered tests consume the installed prefix: CLI, HTTP, Java/JNI, real runtime heap dump, and real CPU recording. The last two compile small Cangjie targets and require permission to signal/trace those owned processes and open perf events. They fail if those operations are unavailable; they do not report skipped work as a pass. Java/JNI selects the JDK `libjsig.so`, runs with `-Xcheck:jni`, exercises Java exceptions after runtime startup, and rejects native contract or signal handler diagnostics.

The migration map and exact scope are in [doc/cangjie-migration.md](doc/cangjie-migration.md). Public repository CI/SDK integration is maintained outside this cjprof-only producer.
