# 随键译 · Debug 自动化测试规格

**状态：首期已结项（2026-11-23）。** Debug 与 Release 共用构建入口。专用 AppKit 宿主九项用例和 TextEdit 替换撤销已通过自动验收。Codex 草稿的上屏、替换、撤销及清空后重新输入已由用户实机确认。Codex 中单按 Shift 直输英文已通过实体键盘验收。无人值守运行仍需能确认草稿焦点及空白状态。下文保留各次验收对应的构建和运行记录。

## 开发机运行

在已登录的 macOS 图形会话中使用独立开发输入源。首次构建会组装并签名 Debug IME、内嵌设置助手和专用宿主。每次重新构建 IME 都会产生新构建标识，需安装对应构建。只改测试宿主或运行器时可运行 `./scripts/build-ime-test-tools.sh`。

```sh
./scripts/build-debug-ime.sh
./scripts/install-local.sh --test-build
./scripts/test-ime.sh --case pinyin-commit
```

安装目标为当前用户的 `~/Library/Input Methods/SentenceAlongDebug.app`。正常安装会验证可选择状态；若系统仅注册而未启用，事务会回滚。此时可用 `./scripts/install-local.sh --register-test-build` 保留已注册的开发包，在「系统设置 → 键盘 → 文字输入 → 编辑 → ＋」中添加「随键译 Debug」，然后重跑用例。正式输入源可继续使用。两个产物共用输入法和设置助手源码。`./scripts/build-app.sh debug` 编译带测试探针的开发包，`./scripts/build-app.sh release` 编译正式包；`build-debug-ime.sh` 会额外组装测试宿主和运行器。正式发布使用 `./scripts/build-installer.sh release`。两者的输入源身份和数据目录独立，开发机可仅启用 Debug。

Debug 日常输入与 Release 使用同一套简体拼音和词频学习规则。仅专用测试宿主使用额外部署的 `sentencealong_fixture` 方案，以固定候选顺序，并排除个人词频与自定义短语。该方案不加入日常方案列表。

| 用例 | 核验内容 |
| --- | --- |
| `pinyin-commit` | 软件逐键发送 nihao 和空格；IME 收到六次按键，高亮「你好」，宿主经历标记文本并只提交一次 |
| `candidate-tenth`、`candidate-tenth-click` | 临时设为每页 10 项，分别用 0 和鼠标上屏专用词库中 shi 的第十项，结束后恢复页大小 |
| `english-undo` | 切至英译中，实际输入英文，等待中文预览，主动替换并撤销恢复，结束后恢复方向 |
| `direction-selection` | 同一编辑器自行结束组词并选中已上屏前文时切方向，保留正文和选区 |
| `direction-switch` | 在已上屏中文后开始新组词，切到英译中，检查只取消未确认拼音，并核对大写、空格及数字；运行结束恢复方向 |
| `ascii-comma-context` | 中译英开启英文标点，前后两次拼音上屏，中间输入英文逗号。宿主核对完整正文，Debug 探针在内存中比对包含逗号的整句预览来源 |
| `mixed-period-replace` | 临时英文输入句点和空格，切回拼音并确认下一句。显式替换后核对上一句及分隔空格，再用宿主撤销恢复全文 |
| `shift-toggle`、`shift-toggle-live`、`shift-toggle-idle` | 分别从已有组词、组词后开启设置、空输入框开始，单按 Shift 后直输英文，再按 Shift 回到拼音，核对宿主全文和标记结束。运行后恢复设置 |
| `codex-shift` | 确认新建未发送草稿为空及 Debug 输入源已选，单按 Shift 输入英文，再按 Shift 输入拼音和空格，核对 Debug 候选窗及最终混合文本 |
| `raw-return` | 已显示拼音候选时按 Return，宿主只提交一次原始拉丁拼音，无标记和换行 |
| `composition-caret` | 输入 nihaonihao，左移三次，按宿主实际选区预测插入 g 后的字母序列，再核对退格恢复原拼音 |
| `candidate-click` | 在专用用例中读取已绘制的高亮候选中心，确认坐标处最前方窗口属于 Debug IME，再投递系统鼠标按下和抬起事件；核对实际选词回调和宿主提交 |
| `punctuation-preview` | 中文模式单独输入句号；核对正文与当前句预览提交事件 |
| `translation-undo` | 实际本机模型就绪后，输入「你好」，用默认替换键换成英文，再用 ⌘Z 恢复中文。使用 Debug 默认键位和已开启的翻译设置 |
| `panel-editor-cleared` | 候选和译文已出现时，前台编辑器自行结束标记并清空内容 |
| `panel-mark-ended` | 宿主通过 NSTextInputContext 结束组词，保留当前窗口 |
| `panel-app-switch` | 组词中切换到 Finder，原宿主保持运行 |
| `panel-host-exit` | 组词中强制退出本次启动的专用宿主 |

四项浮层用例均检查 WindowServer 的屏幕窗口列表。确认 Debug 输入法候选窗已出现后触发相应操作，要求窗口在两秒内消失，随后连续 750 ms 保持隐藏。

外部宿主可用同一运行器验证：

```sh
./scripts/test-ime.sh --case textedit-undo
./scripts/test-ime.sh --case codex-draft
./scripts/test-ime.sh --case codex-draft --manual
```

外部验收需要已解锁的桌面、辅助功能和发键权限。TextEdit 使用单独启动的实例和临时文稿。Codex 用例在请求新草稿前记录窗口和编辑器身份，确认切换到新目标后，再检查可编辑字符数为零且选区位于开头。焦点、字符数或新草稿身份无法确认时，运行器报告受阻。验收期间持续核对前台进程、窗口、编辑器和 Debug 输入源。

用例使用固定前文和「你好」，并读取 Debug 设置中的翻译开关和替换快捷键。运行器观察已安装 Debug 输入法进程的预览，得到译文后才触发替换。替换后的整份文稿须与固定前文加预览译文完全一致，一次 ⌘Z 后须恢复固定前文加「你好」。额外换行、空格和丢失前文都会导致断言失败。手工校准时由开发者输入 nihao 并按空格，后续替换与撤销仍由运行器执行。结果文件记录构建号、安装路径、耗时、最后完成的断言及观测到的候选窗所属进程号 `observedIMEPID`。

专用宿主中的两项选词用例（`pinyin-commit`、`candidate-click`）也可追加 `--manual`，由开发者按屏幕提示输入，沿用同一套双端断言。报告会标明驱动。请保持测试窗口在前台；安全输入、焦点丢失和输入源变化会中止用例。

退出码 0 表示断言通过，1 表示可观察行为不符，2 表示环境受阻或证据不完整。终端给出运行 ID 与目录，启动宿主后产生的 `summary.report` 为 JSON，包含用例、构建标识、驱动、状态、最后通过步骤和原因。两端分别写事件文件；仅鼠标用例附测试面板的目标坐标。结束时清理有效运行描述并恢复输入源。测试轨迹仅位于独立 Debug 数据目录。

```sh
./scripts/prepare-rime-data.sh
swift test
swift run input-core-checks
swift run rime-checks .build/rime-shared "$(mktemp -d)"
swift run translation-checks
zsh scripts/test-local-install.sh
./scripts/build-app.sh release
./scripts/check-debug-isolation.sh
```

发版前可在同一干净提交先运行 `./scripts/build-app.sh debug`，再运行 `./scripts/build-installer.sh release --strict`。后者会构建 Release 并核对两版源码提交、工作区状态、签名和探针隔离。已有两个包时可运行 `./scripts/check-debug-isolation.sh --strict`，或在其后指定预期提交。只检查正式产物时用 `--release-only`。

### 本机验收记录

| 层次 | 结果 |
| --- | --- |
| 无桌面回放 | 真实 Rime 在独立临时词库处理合成拼音，通过生产组词提交逻辑写入内存宿主；正文保留前缀且只提交一次。已有 XCTest 覆盖失焦后迟到译文等竞态 |
| 真实 AppKit 测试宿主 | 2026-11-21 在创建宿主前选择 Debug 输入源，启动后由 NSTextView 再核对输入上下文。相同构建连续两次无人值守完成 nihao、空格、单次上屏与标记清空。运行 ID：D2C948CD-386F-49D8-86E0-464DABB78E8B、CA599164-B464-4432-B920-8E7BF3EE59EE |
| 本次专用宿主 | macOS 27.0.1，已安装 Debug 构建 `54773795-36F3-4520-AB6B-2B547C18A33A`。拼音上屏、光标中途插字及退格、点击高亮候选、单句号预览、快捷键替换后撤销均通过。测试宿主给范围替换划分独立撤销组，使用 AppKit UndoManager 处理 ⌘Z |
| TextEdit 1.21 | 在构建 `190C008F-94E9-48B2-AFB8-9550D690C4DC` 的独立临时文稿中，候选窗属于用户安装目录的 Debug IME 进程。空格上屏「你好」、快捷键替换为全英文、一次 ⌘Z 恢复完整中文均通过。旧构建曾在一次撤销后清空文稿。自动运行 `0DA80508-F00A-4FB8-9C4E-18B8D2DA0293` 通过 |
| TextEdit 回归（2026-11-23） | 运行 `529E1667-11B0-4905-8881-5A27E3D510C2` 使用新版运行器和已安装 Debug 输入法。带固定前文上屏「你好」，读取浮层实际译文后触发替换，全文精确匹配，按一次 ⌘Z 恢复含前文的中文文稿 |
| Codex | 2026-11-23，用户确认选中「随键译 Debug」后，在草稿中用实体键盘输入 nihao 并上屏「你好」，按 Control + Shift + T 替换为英文，再按一次 ⌘Z 恢复「你好」。三步均通过。软件发键与焦点检查结果见下方记录 |
| 后续产品能力 | 第十候选及运行时切换翻译方向按产品交付接入；本次仅实现当前输入行为的测试工具 |

本次五份 `summary.report` 位于 `~/Library/Application Support/SentenceAlongDebug/Tests/<运行 ID>/`。

| 用例 | 运行 ID |
| --- | --- |
| 拼音上屏 | `04DBD887-D13A-49FB-9290-6A80A100C383` |
| 长拼音中途插字及退格 | `FA1FD246-F52E-4BCC-A3C6-EEE0B16F98A7` |
| 鼠标选词 | `129DE615-5E5E-4461-A6F7-0E7C453C464A` |
| 单句号预览 | `8526007B-0D5C-4396-8FB0-F5032BD7539F` |
| 译文替换与撤销 | `AA8B7C23-FD33-49DA-999F-23BFB62EDA13` |

### 日常体验新增用例（2026-11-23）

已安装 Debug 构建 `BA60E0D9-B42B-411E-B052-A8A0CEB268F4`，安装包内的输入法可执行文件与构建产物逐字节一致。下列六项均由专用 AppKit 宿主通过 CGEvent 执行。运行器核对系统和测试输入框的输入源，结合输入法回调和宿主正文断言判定通过。设置助手的「使用说明」和「输入与候选」均在该安装包上打开并核对。鼠标用例首次因专用窗口失焦中止，重新取得焦点后原样重跑通过。返回 Codex 后核实当前输入源为 `com.abandoned678.inputmethod.SentenceAlongDebug`。外部输入法的词库测量见[质量记录](PINYIN_QUALITY.md)。

| 通过用例 | 运行 ID |
| --- | --- |
| `candidate-tenth` | `76D4B7BB-F972-42A6-B57D-EA313C64E13F` |
| `candidate-tenth-click` | `E2ED8B9C-782B-49B2-B124-D75ED97F4047` |
| `direction-selection` | `6B815C62-AE78-4700-BA19-B72A647D8CB2` |
| `direction-switch` | `FF60DAC3-FC0F-47EA-897E-C17287707CFF` |
| `english-undo` | `2FFEF8D0-C5B2-4747-9A1F-5FF4B12177E9` |
| `raw-return` | `EE1FF1E5-78FA-4EF1-9660-6F6FEBC9909E` |

### 单按 Shift 切换临时英文（2026-11-23）

安装构建 `8AA19092-9FE1-4131-A201-DD1571E0A621`，使用 CGEvent。专用宿主确认所选 Debug 源并核对最终未标记的混合文本。Codex 用例在草稿焦点检查阶段停止。

| 用例 | 结果 | 运行 ID |
| --- | --- | --- |
| shift-toggle | 专用 AppKit，组词中切换通过 | 9890C8EF-50A4-4612-B030-B9E84A753B6F |
| shift-toggle-live | 专用 AppKit，组词期间打开开关后切换通过 | 40F67AA9-795D-4A77-AC21-696EDDB4987A |
| shift-toggle-idle | 专用 AppKit，空输入框首键切换通过 | 9523AFA5-6BD6-404F-9D48-C6190E72C991 |
| codex-shift | 专用空草稿焦点未确认，未投递测试字符 | 6FF345A8-2F9C-4CF3-9B79-454DAF57D919 |

### 计划复核后的集成构建（2026-11-23）

已安装 Debug `77F9345E-E2AE-49AF-B36E-FF72CAA6F11A`，产物与安装目录的输入法可执行文件 SHA-256 均为 `08b1e4aa7efafc067f956312ba800ad543f50ed7fb51bd13dd894247974e006d`。独立临时词库通过 `rime-checks` 和 `--profiles`，核心检查及 52 项 XCTest 通过，Debug/Release 隔离脚本通过。Shift 回归包含同一活跃客户端在按下与松开之间重复激活、切换后重复激活，以及真正切换客户端时清理手势和模式。重复激活时，取消组词需要核对宿主标记、选区、字面内容和明确的替换范围，宿主已变更的选区应保留。

该构建的三个 AppKit Shift 用例、Codex Shift 用例及两个标点用例均在锁屏预检退出（2），未生成运行 ID。后续构建的 Shift 结果见下节。两个标点用例的输入框端到端验收仍待执行。

### 实体 Shift 重复事件（2026-11-23）

17:06 的 Debug 阶段日志在同一控制器上多次出现两次按下、两次松开，两次松开都被拒绝。原状态机将同键重复按下误判为左右 Shift 重叠。回放相同键码的事件序列后，新用例在旧代码下左右 Shift 均失败。修复后，相同按键的重复通知只切换一次，不同 Shift 重叠仍然取消手势。

Debug 安装构建 `6C51AE84-BF5D-483C-B188-CEBD9144D941`。53 项 XCTest、核心与真实 Rime 检查通过。专用 AppKit 宿主的空闲首键、组词中切换、动态开启三项通过，运行 ID 分别为 `0468A8D9-52BD-4CF5-BC78-10DEF53F6308`、`876E3190-8024-4AA7-B794-1E74E16155C5`、`878F0F04-482A-4A11-B015-A2FA2F951ECF`。Codex 自动运行 `CE164781-3F9F-4878-AD08-F533BB36013A` 在确认草稿为空时受阻，未投递测试字符。随后 17:09 的新版日志在实际重复通知下记录到首次松键切进临时英文，下次单按切回拼音，额外松键均被忽略。用户随后在原先出现故障的 Codex 输入框用实体键盘确认：单按 Shift 出现「临时英文」，再按 x 即直接上屏。

### Codex 输入路由定位（2026-11-23）

在 Debug 构建 `D07D14A0-0ADA-482E-B29E-783704636C04`，控制器对未激活状态下收到的普通 keyDown 增加了独立计时标记，标记不包含键值或正文。TextEdit 对照运行 `901A4DC4-027E-43D1-81D3-1DCA56E4C7A6` 通过，统计到 18 条正常输入计时记录、0 条未激活记录。Codex 草稿运行 `D7F0C727-3106-408B-A9EE-67A4A351486A` 已确认空编辑器，两类计时记录均为 0，未观察到 Debug 候选窗。该证据限于本次软件发键。测得的 Codex 主进程于 11 月 20 日启动，重启后的运行 `2D267A33-7A5E-4BF1-B51B-CD2E009445AF` 在输入前因无法确认草稿焦点而停止。随后用户在真实草稿完成上述三项验收。Codex 无人值守验收仍受焦点识别限制。

### 浮层残留回归（2026-11-21）

在 macOS 27.0.1，前台测试编辑器清空后，IMK 仍可返回上一次的标记范围。旧的定位刷新继续用这个范围显示候选。运行 `797FC755-854D-4CC5-ABEC-11916A804234` 在编辑器已经清空后仍检测到浮层。修复后，输入法在光标与本次组词位置分离时仅核实自己写入的组词范围，并处理前台应用变更、IMK 隐藏浮层和关闭会话的回调。

Debug 构建 `ED7C3E12-AA09-4865-9540-2AC174AB8B1D` 的九个用例全部通过。四种浮层场景的报告如下。

| 场景 | 运行 ID |
| --- | --- |
| 编辑器清空 | `B38176CC-B041-4C35-B545-E51D39E8372A` |
| 宿主通知输入上下文结束组词 | `6161A925-3AB8-486E-BD76-EF6093A75F9B` |
| 切换前台应用 | `AD48DCED-5945-48A9-92B9-AED1BC0FA323` |
| 宿主退出 | `5AE204FB-5920-45AC-8E1A-8FA01C98CB7E` |

仍有一个观测边界。若宿主只在文本视图调用 `unmarkText()`，保留相同的文字、选区、焦点，又没有通知输入上下文，实测 IMK 仍返回原标记、原光标和原文字。这种情况下浮层可能延续到下一个可观测的生命周期变化。截图本身无法确定触发路径。

## 1. 目标与现状

开发者应能用一条命令选定合成用例，得到通过、失败或环境受阻，以及最后一个完成的步骤。建议先交付“拼音组词 → 候选 → 中文上屏”这条最短链，再覆盖候选、光标、翻译与宿主编辑场景。此前 TextEdit 的两次合成按键尝试均得到拉丁字母，实体键盘在同一候选构建可以组词；具体分流位置尚待测定。[现场记录](DAILY_USE_PLAN.md)

## 2. 测试层次与证据

| 层次 | 驱动与观测 | 通过能证明什么 |
| --- | --- | --- |
| 控制器回放 | 在测试进程把预定义的按键、修饰键、激活与失焦序列送入生产事件处理逻辑。复用真实 Rime、独立临时词库、内存宿主及可控翻译 provider。内存宿主实现标记文本、选择范围、提交与指定范围替换，记录调用顺序 | 每次改代码后可确定性检验组词、翻页、内部光标、一次提交、替换范围、过期译文及取消。报告注明事件在测试进程直接交付 |
| 系统输入法集成 | 在已登录的 macOS 图形会话启动专用 AppKit 测试宿主，用标准 NSTextView 和正常文本输入系统连接独立安装的 Debug 输入源。以逐键 XCUITest typeKey 或虚拟键码 CGEvent 做小规模验证。宿主在转交正常 AppKit 行为的同时观测 marked range、选区、正文与撤销 | 同一用例须同时看到预期构建的 IMK 控制器收到事件、引擎产生候选、宿主收到标记文本并最终提交。通过后才把这条驱动用于更多系统集成用例 |
| 外部宿主兼容性 | 在 TextEdit 临时文稿、Codex 未发送草稿等环境重复关键路径；分宿主核实事件是否进入 IMK。辅助功能可检查焦点、菜单和可访问的正文，屏幕操作可检查点击、遮挡和边缘定位 | 得到指定宿主、系统与构建组合的结果。合成事件路由无法确认时单列受阻，保留少量实体键盘复核 |

## 3. 工程结构与进程边界

首期使用仓库内的 SwiftPM target 和现有脚本组装流程。宿主应用通过 macOS 文本输入系统使用随键译，TextEdit、Codex 等应用无需集成 SDK。

| 组件 | 部署位置 | 职责 |
| --- | --- | --- |
| Debug 输入法 | 独立输入源 App，系统启动的 IME 进程 | 运行原有 IMK 控制器、真实 Rime 和浮层；在激活、处理按键、生成候选、请求提交处加入条件编译的只读观测点。App 持有一个 Rime runtime，每个 controller 持有自己的 session |
| 测试宿主 | 测试专用 AppKit App，独立进程 | 放置标准 NSTextView，保留系统事件分发和 AppKit 编辑行为。在文本输入回调转交给 AppKit 后，检查标记范围、选区和文稿结果。只在本进程内比较固定合成文本 |
| 测试运行器 | 开发机命令行可执行文件 | 管理用例、构建校验、宿主启动、聚焦、输入源选择与还原；串行提交预定义动作、等待双端证据、输出结果和退出码。首选虚拟键码逐键发送，驱动能否经过 IMK 由集成用例验证 |
| 回放测试 | SwiftPM 内部 target 与 XCTest | 当某段交互需要回放时，从可执行 target 逐段抽取生产使用的会话逻辑，注入窄宿主接口及已有翻译 provider。宿主接口仅覆盖实际用到的读取选区、读取标记范围、设置标记文本、提交及验证替换范围。用内存宿主运行同一段逻辑 |

### 3.1 Package、目录与测试文件归属

建议继续使用根目录的单一 [Package.swift](../Package.swift)。输入法、探针与测试工具需要随同一提交验证，内部 target 足以表达依赖和构建入口。等到第二个独立仓库需要复用工具，或工具确实需要单独发布版本时，再评估拆出 package。

| 位置 | 内容与接入时机 |
| --- | --- |
| 现有 `Sources/` 和 `Tests/InputCoreTests/` | 保留当前生产代码、核心 XCTest，以及独立运行的 Core、Rime、翻译自检。已有用例继续从原入口运行 |
| `Tools/IMETesting/Host/` | AppKit 宿主 executable target；包含测试窗口和宿主 Info.plist。由开发脚本组装为可启动的 App |
| `Tools/IMETesting/Runner/` | 命令行 executable target；按用例组织合成动作与断言，首个用例位于 `Cases/PinyinCommit.swift`。真实系统用例由专用脚本显式执行，普通 `swift test` 可在无桌面会话运行 |
| `Tools/IMETesting/Trace/` | 建立仓库内部的测试事件 target，由宿主和运行器共享事件定义；Debug 输入法的观测代码复用同一格式。SwiftPM 通过显式 target 路径管理这些目录 |
| `Tests/IMETraceTests/` | 验证运行 ID、步骤与超时判定，覆盖旧会话事件、缺少一端证据和丢事件，防止运行器误报通过 |
| `Tests/InputSessionTests/` | 随首个需要回放的交互新增。只有可测试的生产会话逻辑超出现有 InputCore 职责时，才提取对应的内部 session target。内存宿主和固定翻译替身随测试放置 |
| `scripts/test-ime.sh` | 日常测试入口，调用已构建的运行器。产品组装继续使用[现有脚本](../scripts/build-app.sh)，单独验收 Release App 的内容 |

### 3.2 开发日志与测试事件

开发者查问题时继续使用已有的系统统一日志和 Instruments signpost。仓库已按 Rime 启动、翻译调度、输入与浮层耗时记录诊断信息，可沿用现有 subsystem 与分类。[引擎日志](../Sources/InputMethod/AppEnvironment.swift) · [翻译日志](../Sources/InputCore/TranslationCoordinator.swift) · [输入计时](../Sources/InputMethod/InputMethodController.swift)

排查“浮层消失并丢失拼音”时，安装带该诊断的 Debug 构建，记下复现时间，在终端查询最近十分钟的组词和清理记录。此查询只读系统统一日志，可以在 Codex 草稿保持原状时执行。

```sh
/usr/bin/log show --last 10m --style compact --predicate 'subsystem == "com.abandoned678.inputmethod.SentenceAlongDebug" AND category == "CompositionReset"'
```

对照同一进程和 `controller` 的事件时间。2026-11-23 的旧构建在 Codex 问题复现期间多次出现 `composition edge=began`，随后在 `composing=true` 时以 `markTextUnavailable` 或 `markLengthMismatch` 清理组词。这两个原因分别表示宿主标记文本不可读、标记范围长度与当前拼音不符。判读时留意事件发生在哪一轮组词。`lastCharacterRemoved` 且 `composing=false` 可发生在正常删除最后一个已上屏字时。控制器标识只在该实例内有效。

修复后，位置刷新只使用范围和长度，不读取拼音正文。对于输入法已经核实的当前标记，连续两次观察到标记消失可触发 `hostMarkEnded`。若宿主清空后仍返回旧标记，则需同时看到光标归零，并确认此前能返回非零长度的宿主连续两次报告文档为空，才触发 `hostDocumentCleared`。中途重新写入标记会使待确认的清理失效。

2026-11-23 安装构建 `1D914F6A-86A1-48EF-9BCA-4CEC67F78936` 后，专用 AppKit 宿主的上屏、组词中途编辑、编辑器清空和标记结束四项通过。编辑器清空运行 ID 为 `CDDE7874-7C4C-4CEF-B7A5-E70C3B9FB663`。Codex 独立草稿测试在确认输入框焦点时停止（`FF7B5638-6F61-4D62-9A69-803797B3C781`），随后用户在 Codex 中手动复测，确认清空后重新输入拼音正常。

重新打字后，沿同一控制器查找 `composition edge=began`。若随后收到 `reset`，查看清理原因；若收到 `composition edge=ended`，用 `hasCommit` 判断该 Rime 快照是否包含上屏内容。`commitComposition` 表示进入提交方法，其中 `source=imkCallback` 来自 IMK 回调，`hostShortcut` 和 `forwardDelete` 分别来自输入法放行快捷键和向前删除的分支。`hidePalettes` 表示有组词或面板内容时收到隐藏请求，单凭这条记录无法断定组词被清空。

单按 Shift 的日志与组词诊断共用同一类别。筛选 `shift stage=` 可依次核对按下、松开、切换到英文或拼音，以及重复激活是否保留模式。失焦、组合键或无法核实标记范围会记录固定的原因代码。

系统决定日志保留时间。诊断跳过安全输入，普通按键不会逐键记录。宿主自行改字可能没有对应事件；报告复现时间即可关联，无需粘贴原文。

自动断言使用内部 target `IMETrace`，只提供固定阶段、运行 ID、事件序号、计数、耗时和断言结果。文本比较在测试宿主或引擎侧就地完成，只输出是否匹配。运行器根据双端事件作判定；开发者可用运行 ID 查看对应测试报告。缓冲区溢出、文件写入失败或关键事件缺失时，将证据不完整写入报告。首期无需给所有 target 引入通用 DebugLog 门面，也无需靠解析 Console 日志来维持用例。

输入法侧的采集与写出实现采用专用测试构建标志并结合 Debug 配置编译；日常 Debug 会话只产生上述运行诊断，测试事件流仅在显式测试会话写出。验收时分别检查 Release 产物、未启动用例的 Debug 进程，以及显式测试会话，确认只有最后一种会生成测试事件。

## 4. 首个里程碑：无人值守完成一次中文上屏

入口为 `./scripts/test-ime.sh --case pinyin-commit`。

记录原输入源，核对 Debug 构建身份，聚焦测试文本框并选择 Debug 输入源，逐键发送 n、i、h、a、o；等待出现 marked text 和含「你好」的候选；在受控词库中确认该项，断言正文恰为「你好」、提交一次、marked range 清空。每步以事件或条件驱动，设有界超时。结束及失败清理均恢复原输入源。直接赋值、粘贴或直接调用控制器不得计作系统路由通过。

验收要求软件逐键驱动全程完成，并在同一运行中取得输入法与宿主两端的证据。若需要实体键盘，报告标注「人工击键，自动断言」，无人值守里程碑仍待验证。

## 5. 跨进程观测与失败报告

每次运行在当前用户的 Debug 数据目录内创建私有子目录。运行器生成一次性运行 ID，启动测试宿主时传入该 ID；在 Debug 专属配置目录发布带有效期的运行描述，供系统启动的 Debug IME 读取。IME 仅在构建身份、测试宿主身份和活跃会话均匹配时观测。宿主与 IME 各写自己的事件流，运行器以运行 ID、会话和步骤配对。输入热路径只在内存中产生有界元数据，文件写入在热路径外完成。用例结束清理运行描述，异常退出由过期时间兜底。首期支持单机单用例串行运行，无需常驻服务或通用命令接口。

在专用测试会话中关联用例编号、构建、会话、事件序号和阶段：宿主获焦 → IMK 激活 → handle 收到按键 → Rime 返回候选 → 宿主收到标记／提交 → 翻译状态更新 → 浮层提交显示。检查浮层实际可见性需另取窗口或 UI 证据。驱动无法送达且环境原因未明时报告受阻及最后可观测阶段；回调已到而候选、正文或撤销断言不符时报告失败。翻译先以固定替身验竞态，再单列真实 Apple 模型冒烟及模型缺失状态。

## 6. 构建与数据隔离

Debug 输入源单独使用 bundle ID、TIS ID、IMK 连接名、安装路径、设置域及 Rime 数据目录，并在开发构建的注册白名单中精确匹配。对照当前[输入源注册入口](../Sources/InputMethod/InputMethodApplication.swift)。测试探针限 Debug 构建、显式启动的合成用例与对应宿主；宿主失焦或进入安全输入即停止记录。报告保留步骤、范围长度、计数、耗时和断言状态，不记录日常键流、原句或译文。生产输入法不提供远程发键或改写任意宿主的测试端口。

## 7. 交付顺序

先给现有 controller 加观测点并打通标准宿主的 nihao 用例，验证两个进程确实能取到证据。保留可人工击键的同一用例用于校准。然后逐段提取需要自动回放的逻辑，沿用现有 InputCore、RimeInput、LocalTranslation。构建和注册时同时核对固定安装白名单、Rime 用户目录和共享设置域。验收包含 Release 产物中不携带测试宿主、运行器和测试探针。

优先扩展第十候选、长拼音左移、单标点预览、切方向后旧结果失效、替换与撤销。对于系统层受阻的场景，可先由开发者只负责按键，由程序自动判定阶段和结果。若专用测试机确需无人值守且软件发键持续受阻，可验证外置可编程 USB 键盘；是否可用以相同的双端断言判定。

第十候选和翻译方向切换的产品行为由独立的日常输入体验规格定义。
