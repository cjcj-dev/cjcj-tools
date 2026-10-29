# 外部依赖边界

本仓工具业务为仓颉实现。历史 C++ LSP 使用过 FlatBuffers、nlohmann JSON 和 SQLite；历史源码与许可证保留在 Git 对象，当前构建不下载或恢复该后端。

- LSP、cjhead、cjlint、cjcompat 通过各包 build/build.mjs 接受同源仓颉 frontend 的 CJO/archive、runtime_config 和 LLVM shim。LLVM/系统底层仍是合法依赖，不能用旧 libcangjie-lsp 替代。
- LSP 的 JSON 是显式选择的仓颉 stdx JSON 产物。
- cjtrace-recover 消费固定仓颉 mangle 源；其 CMake 只组织正常仓颉编译依赖。
- cjprof 使用显式 JDK/Lombok/runtime 头。native/jni-bootstrap.c 仅启动 runtime；Java API 和仓颉 JNI 业务在包内。
- HLE 的现成 Node/npm/cjbind 为独立外部输入。安装从明确依赖记录取值，不隐式下载，也不把 cjbind 冒作本仓已完成仓颉重写。

配置与安装命令见根 README 和各包 build/build.mjs。不同 host/analysis/target 输入必须按实际生产者分别选择。
