# cjcj-tools

仓颉工具源码集合，保留原 Cangjie tools 的 Git 历史、作者及 Apache-2.0 with Runtime Library Exception 许可。所有工具业务实现位于 `packages/<tool>/src`，公共构建入口为根目录 `build.mjs`。

| 包 | 正常生产图 | 额外输入 |
|---|---|---|
| cjpm | Cangjie 包按依赖序编译；正常 CJPM manifest 保留 | 匹配的 SDK/stdx；仓颉 watcher |
| cjfmt | `build/cjpm.toml.in` → CJPM | 同源六包 frontend CJO/archive/native |
| lsp | core + protocol + server，正常 CJPM 图 | 同次完整 frontend、JSON、LLVM shim；analysis SDK 单列 |
| cjlint | `cjpm.toml.in` → CJPM | frontend/LLVM；显式 analysis SDK，与执行 H 分离 |
| cjcompat、cjhead | 正常 Cangjie compiler/frontend link | 同源 CJO/archive/runtime_config/shim/LLVM |
| cjprof | 仓颉 CLI/shared/JNI 业务 | JDK/Lombok/runtime 头；`native/jni-bootstrap.c` 仅启动 runtime，`java/` 是公共 Java API |
| cjtrace-recover | Cangjie 模块和 mangle 图 | 固定 mangle 源与批准补丁；CMake 仅承载既有 CJ 依赖图 |
| cjcov、hle | 正常 Cangjie 包图 | 匹配的 SDK/stdx；HLE 另需 Node/npm/cjbind |

不建立一个跨不同 SDK 版本的虚假公共 workspace。实际 CJPM manifest/template 保留包边界；需要不同 host 的工具通过逐工具输入选择。直接 compiler 图不提供没有真实依赖的装饰性 manifest。LSP 的 `src/`、`protocol/`、`server/src/` 分别保留原 core、protocol 和 server 模块。业务测试位于各包 `tests/`，旧上游参考样例标为 `tests/reference/`。

## 命令

```console
node build.mjs list
node build.mjs build --tool cjpm --build-root /work/build -- -t release --jobs 4
node build.mjs install --tool cjpm --build-root /work/build --prefix /work/install/cjpm
node build.mjs build --inputs /work/inputs.json --build-root /work/build
node build.mjs install --inputs /work/inputs.json --build-root /work/build --prefix /work/install
node build.mjs test --tool lsp --suite tests/completion-client.mjs -- <原消费者参数>
node build.mjs package --prefix /work/install --archive /work/cjcj-tools.tar.gz
```

逐工具的 compiler/stdx/frontend/JDK 等参数沿各包 `build/build.mjs` 的真实接口传递。`inputs.json` 只把这些已有参数分配到工具，不增加另一套依赖选择：

```json
{
  "cjpm": {
    "env": {"CANGJIE_HOME": "/fixed/H", "CANGJIE_STDX_PATH": "/fixed/S/static/stdx"},
    "build": ["-t", "release", "--jobs", "4"]
  }
}
```

`all` 构建需要全部十项明确输入；单工具可使用已设定的正常环境。构建输出只进 `--build-root/<tool>`，多工具安装进 `--prefix/<tool>`；单工具安装以指定 prefix 为根。打包消费已经安装的目录，缺工具主体即失败，不在打包中隐式补建。测试必须选真实消费者，dispatcher 的 fixture 门只证明调用、布局及错误传播，不能冒工具功能验收。

HLE 的外部 cjbind 并非本仓重写，Node/npm/cjbind 依赖及 TS/OHOS 未成范围仍单列。Linux host 开发产物不自动获得 target SDK、其它平台、宏或完整语言资格。新仓远端当前未获创建权限；本地候选可用于受控固定 Git 输入，不能称远端可取或正式发行。
