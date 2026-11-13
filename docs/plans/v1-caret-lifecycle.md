# 首版光标浮层与会话清理 Plan

依据 [Spec](../specs/v1-caret-lifecycle.md) 和 [架构说明](../../ARCHITECTURE.md)。C1 与 C2 可各自验证。C3 依据 E1 的宿主事件证据推进。

- **C1 锚点选择。** 在 `UnifiedPanelLayout` 及控制器的 `captureCaretAnchor` 增加优先级和失效检查，再调整候选顺序和缓存清理。用同一屏幕上两个有效但不同的锚点验证首选位置，同时覆盖屏幕底部翻转及无有效矩形。提交锚点采样和相关几何检查。
- **C2 生命周期。** 用可控翻译替身验证旧成功和旧失败晚返回。核对 `deactivateServer`、`clearDocumentContext`、marked text、secure input、共享浮层归属及 Command 透传。已有行为通过则记录结果。若发现彼此独立的缺陷，每个缺陷配检查单独修复。
- **C3 位置变化。** 根据 E1 确认窗口移动与滚动时可获取的定位信号，在 `LinguaFlowInputController` 和 `PreviewPanelController` 接入刷新及失效清理。位置刷新遵守当前会话所有权，查不到可靠坐标时隐藏。用窗口移动、滚动和同时发生的焦点变化验证，无法观察的宿主事件记录为缺口。

状态修改遵循先失败后修复。输入变化运行核心与 Rime 自检，UI 或翻译变化构建两项产品。最终宿主行为由 E2、E3 记录。

### C1 执行记录

复现两个有效锚点时索引 0 行矩形抢占当前位置。修复后先用组词或选区对应的矩形，索引 0 仅用于当前位置确实从 0 开始的兜底。无效采样清除上次锚点。Core、Rime 和两项构建通过。
