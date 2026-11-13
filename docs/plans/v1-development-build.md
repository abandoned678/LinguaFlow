# 首版开发基线与中文分发 Plan

依据 [Spec](../specs/v1-development-build.md)。任务状态见 [Master Checklist](../MASTER_CHECKLIST.md)。构建命令和安装边界见 [项目构建技能](../../.agents/skills/linguaflow-build-debug/SKILL.md)。

## A1 建立基线

记录当前 `main` 和子模块版本，以该版本创建开发分支。核对 librime 与 OpenCC 的头文件、动态库、数据和工具。准备依赖后构建 `LinguaFlowIME`、`LinguaFlowSetup`，执行核心、真实 Rime 和翻译自检。记录首个失败及诊断。模型未安装的退出码 2 单独记录。此任务产出基线记录。

<a id="a1-baseline"></a>

### A1 执行记录 · 2026-11-13

源码基线为 `b966fe6`，开发分支为 `codex/linguaflow-v1`。基线构建与自检使用原有源码和脚本。

- 环境为 Apple Silicon（arm64）、macOS 27.0.1（26A434）、Xcode 27.2（27B52）、Swift 6.4.2。
- 通过 Homebrew 安装 librime `1.17.0_2` 和 OpenCC `1.4.2`，确认 librime 头文件及动态库、OpenCC 工具及数据可访问。
- 词库固定版本为 `rime-essay@e9b1a374a6ea015fca5bdd04318924b4483ac35a`、`rime-luna-pinyin@56b934b099dfbeab842320f13aa8b461a6ab3e42`、`rime-prelude@082425ea0684bca36474415d4a0e8db9b016487e`。

| 验证 | 结果 |
| --- | --- |
| `./scripts/build-app.sh release` | IME 和设置助手均构建成功。生成 `.build/LinguaFlow.app` 和 `.build/LinguaFlowEnglish.app`，通过脚本内的 plist 和签名检查。 |
| `swift run linguaflow-core-checks` | 通过。 |
| `swift run linguaflow-rime-checks "$rime_shared" "$rime_user"` | 通过。共享资源由 `./scripts/prepare-rime-data.sh` 生成，用户目录用 `mktemp -d "$PWD/.build/rime-user-check.XXXXXX"` 创建。`nihao` 输出「你好」，`ceshi` 输出「测试」。 |
| `swift run linguaflow-translation-checks` | 首次运行抛出 `TranslationError.notInstalled`，顶层未捕获错误使进程退出 133。随后用临时探针分别确认两个方向均为 `installed` 且 `isReady` 为真，固定句子均可翻译。原命令重跑通过。首次错误的原因尚未确认。 |

链接器报告目标为 macOS 26.0，而当前 Homebrew 的 librime 动态库按 macOS 27.0 构建。`xcrun vtool -show-build .build/LinguaFlow.app/Contents/Frameworks/librime.1.dylib` 确认其最低版本为 27.0。本次通过结果适用于上述本机环境。要验证 macOS 26 支持，需使用符合目标版本的依赖产物并在 macOS 26 上实测。

安装注册和真实宿主验收分别由后续任务记录。

## A2 隔离身份

在同一提交更新 `Resources/`、`AppEnvironment.swift`、`LinguaFlowApplication.swift` 以及受影响的构建、安装和检查脚本。先确定一致的开发身份值和预期安装路径，再核对 IMK、TIS、助手、Rime 数据目录及安装注册目标。保留现有输出行为直到 A3。验收时构建开发版并检查 plist、签名、路径和注册入口。实际共存由 E1 核验。

### A2 执行记录

开发身份采用 `LinguaFlow Dev`，中文 Bundle 和输入源 ID 均为 `com.abandoned678.inputmethod.LinguaFlowDev`，Rime 数据位于 `~/Library/Application Support/LinguaFlowDev/Rime`。开发包拥有独立的连接名、助手标识和可执行文件名。开发安装器只注册开发身份，移除了面向旧上游副本的迁移流程。

Release 构建、plist、签名和两套开发产物的身份检查通过。Core 和真实 Rime 自检通过。安装与共存验证见 E1。

## A3 仅提供中文

核对 `build-app.sh`、`build-installer.sh`、`install-local.sh`、`installer/` 和 `check-installed-input-sources.swift`，在同一提交收敛组装、负载、注册及检查目标。可以保留英文相关源码。构建两项产品并检查安装包清单、中文资源、内嵌依赖及许可。用残留英文产物的构建目录再核对负载，确认注册脚本只针对开发版中文身份。

### A3 执行记录

Release 构建、Core 和 Rime 自检通过。展开 arm64 安装包验证固定安装路径和中文身份，检查负载含设置助手、librime、OpenCC 和许可证。构建目录仍有英文开发产物，安装包只包含中文开发输入源。当前 Xcode 的组件清单可能缺少 `BundleIsRelocatable`，脚本在该情况下添加该键，再检查生成包的不可重定位元数据。
