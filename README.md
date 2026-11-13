# LinguaFlow

LinguaFlow 是 macOS 原生中文输入法。首版开发分支提供「LinguaFlow Dev 中文」，使用 Rime 输入简体中文，并通过 Apple Translation 在本机预览当前句英文。

## 首版开发行为

- 输入停顿 400ms 后请求英文预览。组词时将高亮候选纳入当前句预览，候选可继续调整。
- 组词时按空格确认候选并上屏，可以继续输入同一句。上屏后再按一次空格，宿主会插入空格，后续输入从新的翻译上下文开始。没有标点时也可以这样分段。
- 使用句末标点和宿主确认的换行区分句子。无标点当前句超过 280 字时暂停预览与替换。
- `Control + Shift + T` 在中文已上屏、译文已就绪且宿主可核对范围时，用英文原位替换当前句。
- 浮层优先使用当前光标位置。失焦、切换应用或安全输入时清理预览与上下文。
- 文本编辑和 Codex 的真实输入及原位替换已通过验收，结果见 [首版任务清单](docs/V1.md)。

## 从源码构建和安装

需要 Apple 芯片 Mac、Swift 工具链、Homebrew、librime 和 OpenCC。Swift Package 声明最低 macOS 26。本机使用的 Homebrew librime 要求 macOS 27，macOS 26 兼容性待验证。

```bash
git submodule update --init --recursive
brew install librime opencc
./scripts/install-local.sh
./scripts/check-installed-input-sources.swift --local
```

开发版安装在当前用户的 `~/Library/Input Methods/LinguaFlowDev.app`。从菜单栏选择「LinguaFlow Dev 中文」，若未启用，可在「系统设置 → 键盘 → 文本输入」中添加。第一次使用翻译时，从输入法菜单打开「准备本地中英翻译…」，并按提示允许 Apple 下载设备端模型。

系统域打包方式见 [安装说明](docs/INSTALL.md)。旧版双输入源及其升级记录见 [0.2.2 版本说明](docs/RELEASE_0.2.2.md)。

## 开发验证

```bash
swift test
swift run linguaflow-core-checks

shared_dir=$(./scripts/prepare-rime-data.sh)
user_data_dir=$(mktemp -d .build/rime-user-check.XXXXXX)
swift run linguaflow-rime-checks "$shared_dir" "$user_data_dir"

swift run linguaflow-translation-checks
./scripts/build-app.sh release
./scripts/build-installer.sh release
# 安装刚生成的 .pkg 后再运行：
./scripts/check-installed-input-sources.swift
```

`linguaflow-translation-checks` 在模型尚未下载时会以退出码 2 返回；这是环境状态，不是构建失败。

XCTest 和自检程序可分别运行。真实宿主的操作步骤见 [首版验收表](docs/V1.md#v1-host-acceptance)。

## 隐私边界

- 输入和翻译热路径不调用第三方网络 API。
- 只记录当前 InputMethodKit 会话中由 LinguaFlow 自己提交的文本，不读取任意宿主文档前文。
- 翻译缓冲上限为 280 个字符。
- 失焦、切换输入源、出现选区、光标离开已追踪文尾、Forward Delete、宿主编辑快捷键或 Secure Event Input 会取消翻译并丢弃无法验证的上下文。
- 当前版本不保存翻译历史和原始句子。

## 已知限制

- 当前发布包仅支持 Apple 芯片 Mac；尚未提供 Intel 或 Universal 版本。
- 当前测试安装包没有 Developer ID 签名和 Apple 公证，从 GitHub 下载后会出现 Gatekeeper 提示。
- 候选暂时只支持键盘选择，尚未实现鼠标点击和翻页按钮。
- 通过鼠标或上下文菜单直接修改宿主文本时，InputMethodKit 不一定立即发送按键事件；LinguaFlow 会在浮层刷新或下一次可观察的输入事件中对账，并在发现光标或选区与已记录位置不一致时清空旧上下文。
- 尚未完成 Notes、Safari、Chrome、VS Code 等宿主的人工兼容性矩阵。
- Apple 翻译模型需要用户首次明确授权下载。

## 目录

系统结构、资源所有权和主要数据流见 [ARCHITECTURE.md](ARCHITECTURE.md)。

- `Sources/LinguaFlowCore`：句子缓冲、请求修订号和异步结果验旧。
- `Sources/LinguaFlowRimeBridge`：极窄的 C/librime 边界。
- `Sources/LinguaFlowRime`：Swift 拼音引擎封装。
- `Sources/LinguaFlowIME`：InputMethodKit、候选/英文预览浮层。
- `Sources/LinguaFlowSetup`：Apple 本地翻译模型准备助手。
- `Vendor/`：以 Git submodule 引用的 Rime 配置和词典数据。

项目代码采用 MIT License。Rime 组件和输入方案保留各自许可证，详见 `THIRD_PARTY_NOTICES.md`。
