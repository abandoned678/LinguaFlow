---
name: linguaflow-build-debug
description: "构建或打包 LinguaFlow 的 macOS IME 和设置助手，排查 librime/OpenCC、签名资源、输入源注册、旧进程及内存增长；使用仓库 Swift Package 和脚本，不套用 iOS 模拟器流程。"
---

# LinguaFlow 构建与运行排查

## 确认实际构建与运行身份

从本技能目录向上三级定位仓库根目录。先读 [项目规则](../../../AGENTS.md)、[README](../../../README.md)，安装／打包任务再读 [安装说明](../../../docs/INSTALL.md) 和实际会运行的脚本。

- `Package.swift` 定义 macOS 26、Swift 工具版本与语言模式；构建依赖包括 Homebrew librime，准备词库还依赖子模块和 OpenCC。核对实际文件，不把某台旧机器的缺依赖或 Xcode 许可状态当作当前事实。
- 本项目通过 Swift Package 构建，再由脚本组装应用、嵌入依赖和签名。Xcode MCP 是可选诊断工具，不是前置依赖；使用当前可用工具的实际接口，不硬编码旧 Playbook 工具名或强制启动 IDE。
- 首版目标只提供中文输入源，但当前脚本、plist 和安装检查仍可能保留上游双输入源。阅读 [首版需求](../../../docs/需求与待办.md) 区分目标与实现，不能因文档已确认就报告代码完成。

按任务读取以下入口：

| 入口 | 用途／影响 |
| --- | --- |
| `scripts/build-app.sh` | 构建两项产品、组装 `.build/` 下应用、复制词库／许可、嵌入 dylib 并签名；会重建现有应用产物 |
| `scripts/prepare-rime-data.sh` | 准备子模块词库及 OpenCC 数据，支持 `LINGUAFLOW_OPENCC_DATA_DIR`、`LINGUAFLOW_OPENCC_BINARY` |
| `scripts/embed-rime-runtime.sh` | 嵌入和改写运行库引用，检查依赖装载路径 |
| `scripts/build-installer.sh` | 生成 `.build/dist/` 安装包；指定签名／公证环境变量时可能执行外部签名服务操作 |
| `scripts/install-local.sh` | 终止输入法／助手进程、写入用户 Input Methods、注册上游两套输入源；不是普通构建 |
| `installer/scripts/preinstall`、`postinstall` | 系统安装及旧版本迁移；执行前审查身份与精确目标 |
| `scripts/check-installed-input-sources.swift` | 当前检查上游两套输入源及 `/Library/Input Methods` 路径，不能直接作为隔离中文开发版的通过标准 |

## 选择最小验证层

命令从仓库根目录运行，按依赖顺序执行，不并发写同一 `.build`：

```sh
swift build --product LinguaFlowIME
swift build --product LinguaFlowSetup
```

UI 或翻译变更必须构建这两个产品。需要完整本地产物时用 `./scripts/build-app.sh release`；明确要求安装包时用 `./scripts/build-installer.sh release`。纯 Swift 编译通过不证明资源、内嵌动态库、签名或安装包完整，完整应用构建也不证明宿主兼容性。

输入变更还需按 [状态测试技能](../linguaflow-state-testing/SKILL.md) 运行核心与真实 Rime 检查。翻译 provider／模型相关任务按需运行：

```sh
swift run linguaflow-translation-checks
```

退出码 2 表示支持该语言对但模型未安装，不是通过也不是编译失败；其他异常读取实际诊断。该自检目前会打印固定合成句子的中英双向译文；它只是本地模型冒烟，不代表首版保留英文输入源，也不证明任意句子的质量。

## 先诊断，再恢复环境

- 依赖或头文件错误：核对 `xcode-select -p`、`swift --version`、`git submodule status`、`brew list --versions librime opencc` 与 `Package.swift` 的 include／link 路径。当前配置含 `/opt/homebrew` 路径，不宣称 Intel 或 Universal 构建已支持。
- 构建成功但行为没变：对照 `.build` 产物、实际安装路径、运行进程的可执行文件、Bundle ID、TISInputSourceID、InputMethodConnectionName 和版本。记录路径与版本匹配证据，不因“已安装”便认为运行了最新代码。
- 装载或签名问题：对实际目标使用 `otool -L`、`plutil -lint`、`codesign --verify --deep --strict`。复用打包脚本对动态库和许可证的校验；ad-hoc 签名不等于 Developer ID 签名或公证。
- 卡住或疑似缓存问题：先看诊断和进程进展，保留现有 `.build`／DerivedData；只有项目证据指向损坏时再清理对应产物。只停止已确认与本任务有关的进程，不清空其他项目缓存或广泛杀进程。
- 内存增长：围绕合成输入重复“激活 → 组词／翻译 → 失焦”周期，用 Instruments Allocations／Leaks 或 Memory Graph 区分增长与稳定缓存；检查 controller、panel、翻译 Task、session、timer 和 observer 的所有权。遵守应用持有全局 Rime runtime、controller 持有 session、C 分配释放留在桥内的约束；不套用 iOS 内存阈值。

## 安装和数据边界

构建不包含安装、注册、修改系统设置或主动下载模型的授权。沿用当前会话已有授权，不重复确认；缺少相关授权时先完成构建和精确目标检查，再说明待执行操作。

安装开发版前核对独立名称、Bundle／输入源 ID、连接名、用户数据目录，以及源码和安装脚本中的固定路径／ID 白名单；只改 plist 不能证明隔离完成。不得覆盖上游或其他输入法的数据，不手动删除系统共享翻译模型，不扫描宿主历史或记录用户原句／译文来排查问题。

交付时分别说明：构建产品、应用打包、安装包、签名／公证、安装注册、真实宿主运行中哪些已执行。附失败命令与关键诊断；不要把预览版未签名或旧宿主验证记录当作本次结果。
