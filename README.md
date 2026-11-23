# 随键译 / SentenceAlong

随键译是 macOS 原生输入法。一个输入源即可用 Rime 输入简体中文，或直接输入英文，并用 Apple Translation 在本机预览当前句的译文。

## 日常使用

- 「输入法设置 → 翻译」可切换全局翻译预览，并选择快速、均衡、节能。均衡档的普通输入停顿为 200 ms，高亮候选变化为 120 ms，已上屏的句末标点可立即触发。关闭预览后仍可使用中文组词、候选和上屏。
- 组词时按空格确认候选并上屏，可以继续输入同一句。上屏后再按一次空格，宿主会插入空格，后续输入从新的翻译上下文开始。没有标点时也可以这样分段。
- 在「输入与候选」选择每页 5～10 项，默认 5 项。数字 1～9 或鼠标点击选择对应候选，第十项按 0。组词中按 Return 原样提交拉丁输入串；没有组词时，Return 交给宿主。
- 从输入法菜单或「输入法设置 → 翻译」选择中译英或英译中。切换时取消未确认拼音，保留已经上屏的正文。英译中模式保留词间空格和大小写；想在中文中临时输入英文，可在设置开启单按 Shift 切换。
- 全拼、小鹤双拼、分组模糊音和学习由「输入与候选」管理，个人输入码在「词典与短语」维护。按应用设置预览开关后，其他应用仍跟随全局选择。完整操作见设置中的「使用说明」。
- 使用句末标点和宿主确认的换行区分句子。无标点当前句超过 280 字时暂停预览与替换。
- 当前句已经上屏、译文就绪且光标仍在句尾时，可用默认的 `Control + Shift + T` 或菜单「用译文替换当前句」原位替换。替换键可在「外观与操作」修改。
- 浮层优先使用当前光标位置。失焦、切换应用或安全输入时清理预览与上下文。
- 文本编辑和 Codex 的真实输入及原位替换已通过验收，结果见 [首版任务清单](docs/V1_REQUIREMENTS.md)。

### 导入短语或词频

在「输入法设置 → 词典与短语 → 从文件导入」选择文件类型，再选择文件。核对条数并点击「导入」后，词表会在组词空闲时重新加载。Debug 和正式版各用各自的数据目录。

| 来源 | 准备文件 |
| --- | --- |
| 通用个人短语 | UTF-8 文本，每行两列，用 Tab 分隔，例如 `sjy⇥随键译`。此处 ⇥ 表示一个真正的 Tab 字符。导入保留已有输入码。 |
| 苹果文本替换 | 在 macOS「系统设置 → 键盘 → 自定义短语（文本替换）」选中条目并拖到桌面，直接选生成的 plist。输入码需要 1～64 个小写英文字母；不兼容的条目计入跳过数。[Apple 导出说明](https://support.apple.com/zh-cn/guide/mac-help/mchl2a7bd795/mac) |
| 搜狗自定义短语 | 搜狗 Mac 的「自定义短语设置」提供导出。随键译可读形如 `sjy,1=随键译` 的单行文本；同码取文件中的第一条可用短语。支持 UTF-8 和带 BOM 的 UTF-16。[搜狗短语格式](https://pinyin.sogou.com/help.php?list=1&q=9) |
| 带词频的词表 | UTF-8 TSV，每行三列，例如 `多模态⇥duomotai⇥200`，依次为词条、实际输入码、正整数权重。同词同码重复导入会更新权重。导入词频可单独清除。 |

搜狗 Mac 也提供中文用户词库导出。专用词库文件（如细胞词库 `.scel`）目前没有直接解析入口。苹果的 plist 包含替换规则；系统拼音的自动学习记录不在 plist 中。本机已将搜狗用户词库一次性转换为带权词表并完成导入；设置页接受转换后的 TSV，后续新增词频需重新导入。[搜狗 Mac 更新记录](https://pinyin.sogou.com/mac/update_log.php)

## 从源码构建和安装

需要 Apple 芯片 Mac、Swift 工具链、Homebrew、librime 和 OpenCC。Swift Package 的源码目标为 macOS 26。安装包最低版本根据实打包的依赖生成，本机链接的 Homebrew librime 要求 macOS 27.0。

```bash
git submodule update --init --recursive
brew install librime opencc
./scripts/install-local.sh
./scripts/check-installed-input-sources.swift --local
```

开发版安装在当前用户的 `~/Library/Input Methods/SentenceAlong.app`。从菜单栏选择「随键译」，若未启用，可在「系统设置 → 键盘 → 文本输入」中添加。第一次使用翻译时，从输入法菜单打开「准备本地翻译模型…」，在「翻译」页主动准备模型，并按系统提示确认下载。

系统域打包方式见 [安装说明](docs/INSTALL.md)。旧版双输入源及其升级记录见 [0.2.2 版本说明](docs/releases/0.2.2.md)。

## 开发验证

```bash
swift test
swift run input-core-checks

shared_dir=$(./scripts/prepare-rime-data.sh)
user_data_dir=$(mktemp -d .build/rime-user-check.XXXXXX)
swift run rime-checks "$shared_dir" "$user_data_dir"

swift run translation-checks
./scripts/build-app.sh release
./scripts/build-installer.sh release
# 安装刚生成的 .pkg 后再运行：
./scripts/check-installed-input-sources.swift
```

`translation-checks` 在模型尚未下载时会以退出码 2 返回；这是环境状态，不是构建失败。

Debug 输入法的构建、独立安装和真实宿主用例见 [Debug 测试指南](docs/IME_DEBUG_TESTING_SPEC.md#开发机运行)。

XCTest 和自检程序可分别运行。真实宿主的操作步骤见 [首版验收表](docs/V1_REQUIREMENTS.md#v1-host-acceptance)。

## 隐私边界

- 输入和翻译热路径不调用第三方网络 API。
- 只记录当前 InputMethodKit 会话中由随键译自己提交的文本，不读取任意宿主文档前文。
- 翻译缓冲上限为 280 个字符。
- 失焦、切换输入源、出现选区、光标离开已追踪文尾、Forward Delete、宿主编辑快捷键或 Secure Event Input 会取消翻译并丢弃无法验证的上下文。
- 当前版本不保存翻译历史和原始句子。

## 已知限制

- 当前发布包仅支持 Apple 芯片 Mac；尚未提供 Intel 或 Universal 版本。
- 当前测试安装包没有 Developer ID 签名和 Apple 公证，从 GitHub 下载后会出现 Gatekeeper 提示。
- 通过鼠标或上下文菜单直接修改宿主文本时，InputMethodKit 不一定立即发送按键事件；随键译会在浮层刷新或下一次可观察的输入事件中对账，并在发现光标或选区与已记录位置不一致时清空旧上下文。
- 尚未完成 Notes、Safari、Chrome、VS Code 等宿主的人工兼容性矩阵。
- Apple 翻译模型需要用户首次明确授权下载。

## 目录

系统结构、资源所有权和主要数据流见 [ARCHITECTURE.md](ARCHITECTURE.md)。

- `Sources/InputCore`：句子缓冲、请求修订号和异步结果验旧。
- `Sources/RimeBridge`：极窄的 C/librime 边界。
- `Sources/RimeInput`：Swift 拼音引擎封装。
- `Sources/InputMethod`：InputMethodKit、候选/英文预览浮层。
- `Sources/TranslationSetup`：Apple 本地翻译模型准备助手。
- `Vendor/`：以 Git submodule 引用的 Rime 配置和词典数据。

项目代码采用 MIT License。Rime 组件和输入方案保留各自许可证，详见 `THIRD_PARTY_NOTICES.md`。
