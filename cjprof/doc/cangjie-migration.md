# Cangjie migration

Behavior reference: `271b2f4c20be309205eca5e58bb09ffa24727a64`. The only producer is normal CMake → `build/build.mjs` → Cangjie executable/shared library, minimal C runtime startup, Java API jar → independent install. See [build and consumer commands](../README.md). The old C++ implementation and Python producers are removed; their fixed Git objects remain the behavior reference. No legacy executable or C++ profiling algorithm is linked or invoked. `libstdc++` supplies the system demangler only.

The implementation and exercised host scope cover heap, report, HTTP, Java/JNI, live dump and CPU recording. Target-runtime rebuild and repository-wide CI integration remain separate, unfinished obligations. Host development results confer no target SDK, other platform or release qualification.

## Surfaces derived from the fixed implementation

All reference paths below are relative to `cjprof/` at the fixed behavior reference. Candidate paths are current Cangjie implementation files. Assertions are in the named installed-consumer test, rather than internal-only calls.

| Surface / reference | Implementation | Installed consumer and branches |
|---|---|---|
| CLI `src/main.cpp`, `src/Commands/Heap.cpp` | `cangjie/main.cj` | `cangjie-functional.mjs`: default/explicit input, version/help, threads, outgoing/incoming references, depth, missing/bad input |
| Format `src/Data/Hprof.cpp`, `HprofParser.cpp` | `hprof.cj` | functional: V1/V2, 4/8-byte IDs, all 13 heap object tags, primitive widths, roots, original thread/frame/local records, high UInt64 IDs, malformed bounds |
| Sizes/graph `src/Analyzer/HeapAnalyzer.cpp` | `analysis.cj` | functional: alignment, duplicate/null references, diamond and 24 seeded graphs; retained oracle removes each object and counts lost reachability independently |
| Dominators `src/Cjprof.cpp`, `HeapAnalyzer.cpp` | `analysis.cj` | functional oracle, JNI diamond retained assertion, `cangjie-retained-probe.mjs` independent controls and exact retained target |
| Registry/API `src/Cjprof.cpp` | `snapshot.cj`, `jni.cj` | Java test: all 21 native methods, registry/dedup/cleanup, constructor and instance expansion, incoming/outgoing detail, root filters/paths, threads/locals, filtering/pagination, three diff presence branches, first/repeat cache paths, invalid snapshots |
| HTTP `src/Analyzer/HttpServer.cpp`, `HttpHandlers.cpp` | `http.cj` | `cangjie-http.mjs`: all 11 API routes, static page, automatic port increment, response framing, malformed queries, unsupported transfer encoding and traversal rejection |
| Cache `src/Analyzer/DatabaseCache.cpp` | `cache.cj` | HTTP cold first run writes same-directory packed v2 cache; second server reads it and repeats graph/route assertions. Root kind 255 is preserved on disk. HTTP cache has graph/object metadata, not the full JNI registry. |
| Dump `src/Commands/Heap.cpp` | `dump.cj` | `cangjie-dump.mjs`: actual runtime SIGUSR1 dump, obsolete file replacement, explicit/default destination, real dump parsed by installed CLI, invalid/missing PID |
| Record `src/Recorder/LinuxRecorder.cpp`, `src/Commands/Record.cpp` | `record.cj`, `sample_writer.cj` | `cangjie-record.mjs`: actual positive CPU samples from concurrent Cangjie workers, launch/attach, ELF demangling, flat/SVG consumers, SIGINT detach/preserve attached target and terminate exact launched target |
| Symbols `src/Symbol/Elf.cpp` | `elf.cj` | actual recording resolves Cangjie worker names; ELF parsing, map relocation and symbol lookup are Cangjie, runtime/system demanglers are infrastructure |
| Reports `src/Reporter/*.cpp` | `report.cj`, `static/flamegraph.svg` | functional format matrix and real record output: flat percentages and interactive SVG |
| JNI startup `bridge/jni/cpp` | `build/jni-bootstrap.c` | real JVM load/business/exit with `-Xcheck:jni`; C only starts public runtime before managed exports, contains no model conversion or profiling algorithm |
| Build/install `CMakeLists.txt`, `build/build.py` | `CMakeLists.txt`, `build/build.mjs` | explicit SDK/JDK/header/Lombok selection, environment defaults, fresh/warm build, independent install, eight registered CTests; package/fresh-unpack repeats affected installed consumers |

Linux x86-64 is the current producer/platform scope. Perf permissions are required and failures are errors. Kernel clone/exit tracing, per-thread perf rings and sample serialization are implemented in Cangjie. The test's real positive samples distinguish working sampling from an empty profile control. A full perf overflow/load campaign is not claimed. The fixed reference's Windows build path is not implemented by this Linux recorder.

## Existing 20 API test obligations

The old C++ API is intentionally removed. Its three test files are migrated to the real public Java API consumer `tests/CangjieJniFunctional.java`; they are not kept as unbuilt tests counted as passing. Their originals remain at the fixed Git reference. The table names the old cases and the new assertion labels/calls. The Java test requires the positive branches to execute and has no `GTEST_SKIP` equivalent.

| Original case | Java consumer assertions/calls |
|---|---|
| ParseSingleHeapSnapshot | single original heap registered; snapshot file size/path |
| QuerySnapshotByFilePath | opaque path IDs distinct; repeat parse deduplicates |
| GetConstructorNodes | constructor query real objects |
| CleanHeapSnapshotFiles | cleanup clears registry and comparison cache; reload after cleanup |
| GetConstructorNodesThenExpand | constructor complete expansion; stable UI handle |
| GetRootNodesBySnapshotID | empty root filter; root filter positive |
| ExpandInstanceNode | outgoing and incoming expansion executed |
| ExpandDetailNodeByReference | detail retainers only |
| ExpandDetailNodeChildren | detail children only |
| QuerySnapshotCountOfResults | keyword positive/negative |
| QuerySnapshotNodeByIndex | zero result index; snapshot result pagination |
| GetThreadInfos | thread frames real fixture; thread locals consumed |
| GetNodeRootpaths | multiple root paths executed; root paths truncate |
| QuerySnapshotComparisonSameInput | comparison positive; same snapshot comparison negative |
| GetRootDiffNodes | root diff positive |
| QueryComparisonPaged | comparison keyword positive/negative; comparison zero index; comparison result pagination |
| ExpandConstructorDiffNodeBranches | all three constructor diff presence branches; diff states align instances; diff signed count delta |
| ExpandDiffNodeCacheHit | diff first/repeat cache |
| ExpandDiffNodeCacheMissNotFound | unchanged class diff cache miss; target-only constructor presence and its instance expansion |
| ExpandInstanceAndDetailDiffNode | diff instance loop; diff reference branch; diff children branch |

Added consumers are `cangjie-functional.mjs`, `cangjie-http.mjs`, `cangjie-jni.mjs`/Java, `cangjie-dump.mjs`/target, `cangjie-record.mjs`/target, the three regression consumers below, and `cangjie-retained-probe.mjs`. Normal CTest registers eight consumers and uses an independent install. The retained probe is run separately with a production-source cut and restoration. Repository-level `tests/cjprof-coverage.mjs` and `tests/cjprof-http-headers.mjs` are outside this writer's ownership; the CI owner must migrate their producer assumptions. Their old producer commands have not been claimed as executed against this implementation.

## Migration regression contracts

`include/Data/Hprof.h` defines wire tags 0x23 (primitive array) and 0x24
(struct array); `include/Data/ObjectCategory.h` defines public categories
PRIMITIVE_ARRAY=3 and STRUCT_ARRAY=2. These two namespaces do not share numeric
order. The parser maps them explicitly. `cangjie-categories.mjs` independently
declares all 13 wire records with literal expected categories and sizes, then
consumes them through CLI JSON, HTTP layout/summary/address distribution, packed
cache bytes and a second HTTP server. That second server receives a deliberately
invalid original heap, so success requires the cache reader to supply the data.

The Linux `getopt_long` tables in fixed `src/Commands/{Heap,Report,Record}.cpp`
give the following option arities. `cangjie/cli.cj` implements their shared
parsing rules; command handlers retain validation and behavior.

| Command | Required values | Optional attached values | Flags |
|---|---|---|---|
| heap | depth/D, dump/d, input/i, output/o | dump-report, show-reference | help/h, incoming-reference, show-thread/t, verbose/V |
| report | input/i, output/o | none | flame-graph/F, help/h |
| record | freq/f, output/o, pid/p | none | help/h |

Required values accept `--input FILE`, `--input=FILE`, `-i FILE`, `-iFILE`;
short flag clusters can end in an option with a value. Optional values accept
only `--name=value`; the next word remains an operand. Exact long names win;
unique prefixes are accepted and ambiguous prefixes are errors. A flag with
`=value`, unknown options and missing required values return 1. `--` terminates
option parsing, but can itself be consumed as a required value. GNU permutation
is preserved; `POSIXLY_CORRECT` stops at the first operand. Heap/report reject
remaining operands; record passes them to the launched command. Repeated options
are processed in order. Positive numeric values use the original base-10 strtol
rules (leading ASCII whitespace and `+`, signed-long range, no trailing junk),
with each handler's prior fallback/range policy. The old short string declares
`r::` without a switch handler: it remains an error, rather than an invented
show-reference alias. Subcommand `-h`/`--help` print usage and return 1 in the
fixed implementation; top-level help/version return 0. The Cangjie-only JSON
inspection flag remains available. `cangjie-cli-compat.mjs` exercises these rules
through real heap/report/HTTP, live dump and positive CPU record consumers,
including attach/launch, output destinations and error controls.

The Java API retains int fields. Fixed `src/Cjprof.cpp:397–400` saturates the
snapshot total at UINT32_MAX; instance/constructor and diff totals inherit it.
Other byte accumulations in the old raw snapshot use uint32 arithmetic, and
percentages use those public values divided by the saturated total. The
snapshot layer preserves this behavior before JNI conversion, while CLI/HTTP
Analysis keeps UInt64 accounting. `cangjie-boundaries.mjs` and
`CangjieJniBoundaries.java` use tiny files declaring large class sizes to test
INT32/UINT32 boundaries, same-class shallow/retained accumulation, a retained
chain and diff totals/deltas. They also verify that CLI/HTTP still report the
actual 4 GiB sum. No 4 GiB allocation or test-side clamp repairs a product result.

## Runtime startup boundary

A pure managed `JNI_OnLoad` cannot initialize the runtime needed by its own N2C entry stub; real Java loading exposed SIGABRT before its function body. The separately authorized minimal C entry uses the selected runtime's public `Cangjie.h` and real JDK `jni.h`, checks `GetEnv`, calls `InitCJRuntime` then `LoadCJLibraryWithInit` for the same-directory Cangjie library, and returns `JNI_ERR` on startup failure. All 21 native method implementations and model conversion remain Cangjie. It does not call `FiniCJRuntime` or unload the process runtime on JVM library unload, because that runtime can be shared. Repeated Java initialization and normal JVM exit are exercised. Target ABI startup must be rebuilt and verified with the eventual matching target dependency set.

The JVM consumer requires the selected JDK `lib/libjsig.so` preloaded for signal chaining. A load-only control without it exposed modified JVM SIGSEGV/SIGILL/SIGFPE/SIGBUS handlers despite a successful process exit. The same installed library with libjsig passes load and Java business tests without those diagnostics. The normal JNI harness selects that dependency, rejects handler warnings, and exercises Java exceptions after runtime startup. This is a JDK runtime dependency, with no additional C code.

The Java 20,000-exception control passes, but the selected host runtime still
prints E-level SIGFPE/native-frame messages. Those logs remain evidence; absence
of JVM handler warnings does not establish full signal-chain safety. The target
runtime/SDK path remains unexecuted until its matching dependency closure exists.
