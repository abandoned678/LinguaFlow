---
name: linguaflow-state-testing
description: "修改或排查 LinguaFlow 的分句、组词、光标追踪、异步翻译及当前句替换状态时，先构造失败检查再修复，并执行项目核心与真实 Rime 检查；不替代宿主兼容性验收。"
---

# LinguaFlow 输入状态测试

## 先确定行为契约

从本技能目录向上三级定位仓库根目录。先读 [AGENTS.md](../../../AGENTS.md) 和 [首版需求](../../../docs/需求与待办.md)，再定位受影响实现。目标需求和上游现状可能不同；不要把旧行为的断言当作新需求已经完成。

| 状态 | 实现入口 | 现有检查位置 |
| --- | --- | --- |
| 当前句、标点、退格、字符上限 | `Sources/LinguaFlowCore/CommittedSentenceBuffer.swift` | `Sources/LinguaFlowCoreChecks/main.swift`、`Tests/LinguaFlowCoreTests/CommittedSentenceBufferTests.swift` |
| 候选参与临时预览 | `Sources/LinguaFlowCore/LiveTranslationDraft.swift` | 核心自检 |
| 光标／选区对账、宿主替换范围 | `Sources/LinguaFlowCore/TrackedCaretReconciliation.swift`、`TrackedTextReplacement.swift` | 核心自检 |
| 防抖、取消、过期结果 | `Sources/LinguaFlowCore/TranslationCoordinator.swift` | 核心自检、`Tests/LinguaFlowCoreTests/TranslationCoordinatorTests.swift` |
| 按键、marked text、会话及浮层 | `Sources/LinguaFlowIME/LinguaFlowInputController.swift`、`PreviewPanelController.swift` | 可提取的核心检查加真实宿主验收 |
| 引擎与键盘映射 | `Sources/LinguaFlowRime/`、`Sources/LinguaFlowRimeBridge/` | `Sources/LinguaFlowRimeChecks/main.swift` |

## 先失败，再修复

1. 用合成输入写一个能揭示用户可见错误的最小检查，并在生产代码修改前运行。确认失败原因是行为不符，而不是缺少依赖或错误的调用方式。
2. 优先扩展当前无依赖核心自检；保留 XCTest 风格，只有任务需要且运行环境支持时才使用或迁移测试框架。不要为了本技能引入 FrameBase、FrameLog 或其他公司框架。
3. 修复最小范围，再运行受影响检查及项目要求的检查。输入变更后的核心和 Rime 两项检查都要执行；UI／翻译变更还要构建 IME 与设置助手。
4. 报告失败前后的行为证据。编译失败、环境受阻、检查通过和宿主实测分别记录；不通过修改断言来掩盖未满足的需求。

按变化选边界，不照抄全量测试：

- 分句：逗号保留、句末后新句独立、换行边界、标点退格与超长句恢复。上限策略按需求验证，不默认沿用旧版截尾策略。
- 字符范围：Swift `Character` 与宿主 `NSRange` 的 UTF-16 单位不同；用中文、emoji／组合字符、非零前文偏移及无效范围验证，不拿字符数直接构造宿主删除长度。
- 组词：临时候选不算已提交文本；组词中的退格属于 Rime，不误删已上屏上下文；替换不得隐式确认或取消未完成组词。
- 替换：最新原句与译文修订号一致，追踪句尾且无选区；无效范围、旧译文、失焦及重复触发不能修改宿主文本。纯范围计算通过不等于宿主接受该范围。
- 生命周期：deactivate、焦点变化和安全输入取消任务、推进失效状态并清理 marked text／浮层；只追踪本会话文本，不用读取宿主全文补上下文。

## 异步检查要控制顺序

使用实现 `TranslationProviding` 的测试替身，以可控 continuation／信号记录“请求已开始”和手动完成结果。参考现有 XCTest 中的 `ControlledTranslationProvider`，但为等待补上有限超时与失败清理；避免无限轮询和未恢复的 continuation。

构造 A 开始 → B 开始 → B 完成 → A 晚完成，以及 A 开始 → 取消／失焦 → A 晚完成，断言只有最新有效结果能发布。测试替身应能在忽略取消后仍返回，验证修订号防线，而不只检查 `Task.cancel()` 被调用。

优先注入零防抖或可控时钟来验证结果验旧；防抖时序另行窄测。固定 sleep 或固定次数 `Task.yield()` 不能证明回调完成。使用 Swift Testing 时，`confirmation` 只统计其闭包执行期间的事件，不会自动等待稍后回调；必须在闭包内等待可观察完成，并有超时。

## 必要命令

从仓库根目录顺序运行，前一步失败先定位原因，不并发创建多个全局 Rime runtime：

```sh
swift run linguaflow-core-checks
```

真实 Rime 检查使用临时用户目录，不指向已安装输入法的学习数据：

```sh
mkdir -p .build
shared_dir=$(./scripts/prepare-rime-data.sh) || exit
user_data_dir=$(mktemp -d "$PWD/.build/rime-user-check.XXXXXX") || exit
swift run linguaflow-rime-checks "$shared_dir" "$user_data_dir"
```

若任务也改到 `Tests/`，在工具链支持时运行对应 XCTest；不能只运行未包含新增断言的自检就声称新增测试通过。Apple 模型冒烟检查与构建命令按需见 [构建技能](../linguaflow-build-debug/SKILL.md)。状态检查不依赖真实翻译措辞，真实模型测试不替代状态机断言。
