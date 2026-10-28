仓颉 cjlint 直接消费固定 cjcj 前端的 lexer/parser/AST、SEMA 和 CHIR。
规则注册、60 个规则 ID、56 条默认规则及 111 种诊断从固定参考
271b2f4c20be309205eca5e58bb09ffa24727a64 导出，见 `reference-surface.json`。
旧 C++ 文件仅作为行为参考。

使用正常 CMake 入口构建、安装和打包。HOST_SDK 提供运行工具所需的编译器和
运行库；ANALYSIS_SDK 提供待分析程序使用的模块，两者分别指定。
FRONTEND_ARTIFACTS 必须来自 FRONTEND_REF 对应的完整前端生产结果。

```
cmake -S cjlint -B BUILD \
  -DCANGJIE_HOME=HOST_SDK \
  -DCJLINT_FRONTEND_SOURCE=FRONTEND_SOURCE \
  -DCJLINT_FRONTEND_REF=FULL_COMMIT \
  -DCJLINT_FRONTEND_ARTIFACTS=FRONTEND_ARTIFACTS \
  -DCJLINT_FRONTEND_RUNTIME_OBJECT=RUNTIME_OBJECT \
  -DCJLINT_LLVM_SHIM=LLVM_SHIM \
  -DCJLINT_LLVM_LIBRARY=LLVM_LIBRARY \
  -DCJLINT_ANALYSIS_SDK=ANALYSIS_SDK
cmake --build BUILD --parallel 4
cmake --install BUILD --prefix INSTALL
cmake --build BUILD --target package
INSTALL/bin/cjlint -f SOURCE_DIRECTORY -o REPORT -r json
```

默认使用安装目录中的完整规则配置。`-c DIRECTORY` 选择含 `config/` 的配置目录，
`--import-path DIRECTORY` 添加与分析前端版本兼容的 CJO 依赖。
报告支持 JSON、CSV、规则抑制与路径排除。SEMA 报错后若存在真实 typed AST，
仍执行适用规则并写报告，最后退出 1；parse/import 等早期失败直接退出 1。
有前端错误的程序不会进入 CHIR。

`product-test.mjs` 使用独立安装的真实 CLI，支持 `--rules`、`--case`、`--cli-only`。
含 stdx 的测试须通过 `--import-path` 提供正常编译、版本兼容的 stdx.log 和
stdx.serialization.serialization。`cmake-test.mjs` 验证默认构建、缓存、安装、
DESTDIR、CPack 及解包后的 CLI。宿主测试和目标 SDK/runtime 资格分别记录；
宿主产物不自动授予目标平台或发布资格。
