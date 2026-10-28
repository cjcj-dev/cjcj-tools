# 异常堆栈信息还原工具开发指南

`cjtrace-recover` 从符号映射文件恢复异常堆栈中的函数名和源文件路径。命令行解析、映射文件读取、重复符号检查、堆栈恢复及 demangle 全部用仓颉执行。

## 源码与依赖

- `src/cjtrace-recover.cj`：正式命令入口及恢复算法。
- 编译器仓库 `packages/mangle/src`：直接复用其 `CangjieDemangle.cj`、`Demangler.cj`、`DeCompression.cj` 和 `DemangleUtils.cj`。
- `build/prepare-demangler.mjs`：在构建目录复制上述同源文件，从 `MangleUtils.cj` 提取常量和无 AST 依赖的字符串/字符辅助函数，从 `Compression.cj` 提取 `StringRef` 和 `IntRef` 两个引用容器。这里没有第二份 demangle 语法实现。
- `CMakeLists.txt`：将上述源码编译为仓颉静态模块并链接工具，不构建或链接旧 C++ demangler。

同源模块由编译器仓库维护。当前固定输入为 `cjcj-dev/cjcj@d0eea54f75d1bf3975a7721ea9907d2c897b8b4b`。专属构建向生成目录应用 `build/mangle-bare-D.diff`：拒绝孤立 `D`，保留合法 `Dh`，与工具固定原生基线一致。补丁获本轮主控明确授权，公共模块后续归并；不修改输入原件。更换同源输入时须重新核对这个显式补丁。

构建输入应固定到具体编译器提交，保存来源坐标；工具仓库不维护该模块的长期副本。共享 `third_party/demangler` 仍服务其它原生消费者，cjtrace 构建不使用它。测试中的 `native-oracle.cpp` 只适配固定原生参考，用于差分比较，不是产品依赖，不安装或打包。

## 构建、安装和归档

需要 Cangjie SDK、CMake 3.16.3+、Ninja、patch、Node.js 20+ 和 zx 8。构建机安装这些依赖；目标机器只需相应平台的系统库。

```console
zx build/build.mjs build -t release --cangjie-sdk /path/to/sdk \
  --mangle-source /path/to/compiler/packages/mangle/src \
  --build-dir /path/to/build --prefix /path/to/install
zx build/build.mjs install --build-dir /path/to/build --prefix /path/to/install
/path/to/install/bin/cjtrace-recover -m symbols.map -f trace.txt
tar -czf cjtrace-recover.tar.gz -C /path/to/install .
```

`CANGJIE_HOME` 和 `CANGJIE_MANGLE_SOURCE_DIR` 也可提供默认输入。已有 `build/build.py` 入口保留兼容，使用同一个 CMake 构建图，新增同源依赖通过上述环境变量传入。公共 SDK/CI 调用方应传固定编译器输入，具体组合由其所有者接线。

可直接使用 CMake：

```console
cmake -S . -B /path/to/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCANGJIE_HOME=/path/to/sdk \
  -DCANGJIE_MANGLE_SOURCE_DIR=/path/to/compiler/packages/mangle/src
cmake --build /path/to/build
cmake --install /path/to/build --prefix /path/to/install
```

安装目录包含 `bin/cjtrace-recover`、`lib` 中的目标 SDK runtime/标准库依赖以及许可证。Windows runtime DLL 安装在 `bin`。不安装构建静态模块、旧 C++ 工具或旧 demangler 库。Linux 默认 rpath 为 `$ORIGIN/../lib`，macOS 为 `@loader_path/../lib`；可用 `--set-rpath` 或 CMake `RUNTIME_RPATH` 覆盖。SDK 内部统一提供依赖时可设 `-DCJTRACE_BUNDLE_RUNTIME=OFF`。

构建类型支持 `debug`、`release`、`minsizerel`、`relwithdebinfo`、`minsizerelwithdebinfo`。`build` 不隐式执行安装；`install --prefix` 可以覆盖配置时的安装目录。重复 `build` 复用实际依赖图，源码或 CJO 缺失会重新生成。`clean` 调用原生构建器清理产物。

Windows 交叉构建保留 `--target windows-x86_64 --target-sysroot /path/to/mingw`；必须提供目标 SDK 库。Linux 宿主运行测试不授予 Windows、macOS、OHOS 或重编目标 runtime 后的 SDK 资格。

## 功能和测试

正式用法见 `cjtrace-recover -h` 和用户指南。映射行含“原符号 混淆符号 [路径]”，支持多个逗号分隔的映射文件。重复映射可补全缺失路径；原符号冲突或两个非空路径冲突返回 1。未映射帧及非帧文本保留，指定 runtime 帧过滤；`SOURCE` 路径和零行号按原规则恢复。非法 mangled name 保留原符号，不让解析异常终止整份堆栈恢复。CLI、文件读取及映射格式错误保留非零退出。

专属测试：

- `tests/public/concurrent-symbols.mjs`：真实 cjc 编译/运行/nm 产生压缩并发符号和普通控制，再消费公开恢复入口。
- `tests/public/compiler-reference.mjs`：实际对象未定义引用与已链接定义同名，验证两端及文件行消费者。
- `tests/public/recovery-contract.mjs`：CLI、错误退出、重复映射、CRLF、Windows 路径、过滤、文件行及完整语法分支矩阵；可传旧工具做有限差分。
- `tests/public/symbol-corpus.mjs`：真实 cjc ELF 的全部适用符号，经公开 map/trace 入口，与固定原生语法参考逐符号比较。
- `tests/public/demangler-probe.cj`：直接测试产品所用同一模块的类型 API，用既有 primitive-types 测试验证裸 D 拒绝及 Dh/i 独立控制。此装置不安装。

构建、测试和安装的实际资格以当前固定输入的执行记录为准，不能以帮助输出或单个函数样例代替完整验收。
