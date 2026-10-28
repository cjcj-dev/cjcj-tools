# 仓颉兼容检查工具

`cjcompat` 比较真实编译器生产的两个 CJO，按 API、ABI 或两者报告库演进兼容性。CLI、声明对应、规则和报告均由 `cangjie/` 中的仓颉源码实现。CJO 验证和反序列化复用固定编译器的 `modules/ASTSerialization` 与 `frontend/CjoSignatureMaterializer`；类型关系复用其语义类型和 `TypeManager`。

正式入口为 `Main → ParseOptions → Library → Comparison.Run → Comparison.Print`。两侧分别持有 AST、源文件映射、类型管理器和依赖包图。未支持或损坏的格式由原编译器 reader 拒绝。

## 构建与安装

构建依赖已安装的 host 仓颉 SDK，以及固定编译器 `523a2dbec18cae73c83f1553d938f4eff0664508` 的仓颉 package 构建输出、既有原生 shim 与匹配 LLVM。SDK 和依赖库应由其各自生产入口准备；本构建不修改这些输入。

```text
zx cjcompat/build/build.mjs build --sdk <host-sdk> \
  --compiler-source <fixed-compiler-source> --compiler-libs <cjpm-target/release> \
  --runtime-config /path/to/cjc_runtime_config.o --shim <existing-cjselfhost_llvmshim.o> --llvm <libLLVM-15.so> \
  --build-dir <component-build> --jobs 4
zx cjcompat/build/build.mjs install --build-dir <component-build> --prefix <independent-install>
zx cjcompat/build/build.mjs package --build-dir <component-build> \
  --prefix <independent-install> --output <outside-install>/cjcompat.tar.gz
```

默认构建类型为 `release`；`--type debug|release` 显式选择。默认输出目录为 `cjcompat/build/cangjie-build`。每次构建直接调用 `cjc`，不通过 CMake 或旧 C++ 工具，不依赖 `libcangjie-lsp`。安装布局为 `bin/cjcompat` 和 `share/cjcompat/build-inputs.json`。`build-commands.json` 保存实际编译器 argv、rc、signal 和执行器异常；打包命令另存 `package-commands.json`，保留原编译记录。`inputs.json` 记录显式输入与构型。

当前 host 构建的运行库路径须指向该 host SDK 的 runtime/tools 与匹配 LLVM。使用最终目标 runtime 重编属于另一项验证；不能从 host 测试推得目标资格。

## 使用

```text
export CANGJIE_HOME=<sdk-directory>
<independent-install>/bin/cjcompat --old <old.cjo> --new <new.cjo>
<independent-install>/bin/cjcompat --old <old.cjo> --new <new.cjo> --api
<independent-install>/bin/cjcompat --old <old.cjo> --new <new.cjo> --abi --import-path <dependency-directory>
```

未给比较模式时检查 API 和 ABI；两个标志可同时给出。`--import-path` 可重复。依赖按 CJO 所在目录、显式搜索目录、`CANGJIE_PATH` 和 SDK modules 查找。`-h` 显示帮助，`-v` 显示版本，`--printDebugInfo` 输出声明差异。

兼容输出 `Compatible!`；不兼容输出 `Incompatible!`，随后给 `[API]`、`[ABI]` 或 `[API/ABI]` 的规则说明与 BEFORE/AFTER 源位置。两种有效比较均返回 0；参数错误、缺失依赖、格式或版本读错返回 1。

## 真实产品测试

`tests/cjcompat-producer.mjs <config.json>` 是组件完整入口：默认/显式 release/debug 构建、独立安装、真实 CJO 功能检查、从同一安装目录打包、解包并重复功能检查。配置字段为 `sdk`、`compilerSource`、`compilerLibs`、`shim`、`llvm`、`jobs`、`work`、`producerCjc`、`producerHome`、`producerPaths`、`llvmLib`、`legacySdk`、`control`。生产者和 host SDK 可分别指定；不能借 host 旧 CJO 代替目标编译器输入。`consumeOnly: true` 与 `install` 可消费已独立安装的组件。

`cjcompat-cangjie.mjs` 覆盖四种比较模式及读错，`cjcompat-rules.mjs` 从 `cjcompat-cases.mjs` 逐对生产真实库演进输入，`cjcompat-cli.mjs` 验证依赖目录、环境和 SDK 查找、CLI、调试输出及真实旧版本 CJO 拒绝，`cjcompat-imports.mjs` 验证导入的访问、别名与同包声明变化。所有脚本保留命令原件和已执行断言。输入缓存由源码内容和显式生产者身份约束；失败原件不覆盖。规则配置的可选 `only` 为用例名数组，结果记录实际所选用例，不把局部运行计作全量。

`tests/cjcompat-obligations.json` 导出固定 tools 基线 `271b2f4c20be309205eca5e58bb09ffa24727a64` 的全部 310 条规则描述、模式、309 条注册和规则源码锚；`export-cjcompat-obligations.mjs` 可从该 Git 对象重新导出。目录或注册完整不等于每条动态分支已实测。实际覆盖及未完成项以本轮执行原件和报告为准。

`--runtime-config` selects the producer-owned runtime config object explicitly; the legacy source-relative default remains available. `inputs.json` records this object and every linked Cangjie archive. Frontend cache provenance must come from its producer, not from the current source HEAD.
