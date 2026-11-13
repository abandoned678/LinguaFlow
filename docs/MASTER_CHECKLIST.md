# LinguaFlow 首版 Master Checklist

整理于 2026-11-13。编制依据为 `b966fe6` 的源码、[首版需求](需求与待办.md)和[架构说明](../ARCHITECTURE.md)。构建基线、功能和宿主结果待执行时记录。

| 部分 | Spec | Plan |
| --- | --- | --- |
| A 开发基线与中文分发 | [Spec](specs/v1-development-build.md) | [Plan](plans/v1-development-build.md) |
| B 当前句与英文预览 | [Spec](specs/v1-sentence-preview.md) | [Plan](plans/v1-sentence-preview.md) |
| C 光标浮层与会话清理 | [Spec](specs/v1-caret-lifecycle.md) | [Plan](plans/v1-caret-lifecycle.md) |
| D 主动整句替换 | [Spec](specs/v1-sentence-replacement.md) | [Plan](plans/v1-sentence-replacement.md) |
| E 宿主验证与验收 | [Spec](specs/v1-host-validation.md) | [Plan](plans/v1-host-validation.md) |

## 开发顺序

| 状态 | ID | 任务 | 前置 | 完成依据 |
| --- | --- | --- | --- | --- |
| ☑ | A1 | 确认开发分支并建立未改动行为的构建基线 | — | [本机构建与自检通过](plans/v1-development-build.md#a1-baseline)，macOS 26 兼容性待验证 |
| ☑ | A2 | 隔离开发版身份及 Rime 数据目录 | A1 | 独立构建产物和安装目标核对 |
| ☑ | A3 | 构建、安装与注册路径只提供中文输入源 | A2 | 中文产物和注册目标检查 |
| ☑ | E1 | 提前探测文本编辑和 Codex 的宿主能力 | A3 | [初次探测已记录](plans/v1-host-validation.md)，真实组词与替换待验证 |
| ☑ | B1 | 按标点、换行和退格规则追踪当前句 | A1。宿主换行以 E1 结果为依据 | 句子边界与宿主事件检查 |
| ☑ | B2 | 高亮候选参与临时预览 | B1 | 组词、候选切换和提交检查 |
| ☑ | B3 | 超长句暂停预览和替换 | B2 | 280 字边界与下一句恢复检查 |
| ☑ | C1 | 修正光标锚点优先级和失效处理 | A1 | 几何与锚点检查 |
| ☑ | C2 | 验证会话清理、快捷键和旧译文失效 | A1 | 对应回归结果，发现问题时附修复提交 |
| ☑ | C3 | 接入宿主可观察的位置变化 | C1、E1 | 移动窗口与滚动的定位记录 |
| ☑ | D1 | 原位替换当前句，停用原追加逻辑 | B3、C2、E1 的宿主探测结果 | 替换与拒绝分支检查 |
| ☐ | E2 | 文本编辑最终验收 | A3、B3、C2、C3、D1 | [已激活输入源，自动化按键未进入 IMK](plans/v1-host-validation.md#e2-执行记录--2026-11-13) |
| ☐ | E3 | Codex 最终验收 | A3、B3、C2、C3、D1 | 最终构建的 Codex 结果 |

A3 完成后即可安排 E1。B1、C1、C2 可在等待实际宿主验证期间推进。E2 和 E3 可用同一构建分别执行。宿主验证缺失时继续记录缺口，依据需求处理不可用路径。

## 提交与完成记录

- 每个代码任务对应一个可构建、可审查的提交单元。状态行为先跑出有意义的失败检查，再把修复和检查一起提交。按 [AGENTS.md](../AGENTS.md#development) 执行相关检查。
- A1、E1、E2、E3 是验证任务，记录结果即可。C2 如现有行为通过，同样只记录结果。环境操作本身无需创建 Git 提交。
- 在对应 Plan 记录任务状态、提交或构建标识、执行命令、结果与遗留项，再勾选本表。代码验证通过后可勾选代码任务，实际宿主状态由 E2、E3 跟踪。
- 首版整体验收按 [需求验收表](需求与待办.md#v1-host-acceptance) 执行。两个宿主的结果都要有记录。若某宿主无法验证安全替换，记录保留原文的结果与兼容性缺口，由用户决定是否接受首版范围调整。
- P1、P2 继续由需求文档维护，进入该阶段时再拆 Spec 和 Plan。
