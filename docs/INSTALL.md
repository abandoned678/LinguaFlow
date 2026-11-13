# LinguaFlow 安装包

## 开发版安装

日常开发在仓库根目录运行：

```bash
./scripts/install-local.sh
./scripts/check-installed-input-sources.swift --local
```

脚本将「LinguaFlow Dev 中文」安装到 `~/Library/Input Methods/LinguaFlowDev.app`。系统域测试包安装到 `/Library/Input Methods/LinguaFlowDev.app`，并尝试为当前桌面用户注册和启用。开发版使用独立的 Bundle ID 与 Rime 用户数据目录。旧版安装和迁移细节见 [0.2.2 版本说明](RELEASE_0.2.2.md)。

若菜单栏未显示该输入源，可在「系统设置 → 键盘 → 文本输入 → 编辑」中添加。第一次使用翻译前，从输入法菜单选择「准备本地中英翻译…」，按提示允许 Apple 下载设备端中英翻译模型。

构建面向 Apple 芯片 Mac。源码声明最低 macOS 26，本机 Homebrew librime 产物要求 macOS 27。宿主和系统兼容性记录见 [首版任务清单](V1.md)。

## 开发者构建

构建机器仍需要 Swift 工具链和 Homebrew `librime`，因为它是链接输入；生成的安装包自身不依赖 Homebrew：

```bash
brew install librime
./scripts/build-installer.sh release
```

产物写入 `.build/dist/`。

安装后可用以下独立检查确认开发版中文输入源已启用、可选择，并且 LaunchServices 指向系统目录中的副本：

```bash
./scripts/check-installed-input-sources.swift
```

无证书时会生成适合本机测试的未签名 `.pkg`，应用包采用 ad-hoc 签名。用于 GitHub Release 等公开下载时，需要 Apple Developer Program 的 `Developer ID Application` 与 `Developer ID Installer` 证书，并完成公证：

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
INSTALLER_SIGN_IDENTITY='Developer ID Installer: Example (TEAMID)' \
NOTARYTOOL_PROFILE='linguaflow-notary' \
./scripts/build-installer.sh release
```

`NOTARYTOOL_PROFILE` 应提前使用 `xcrun notarytool store-credentials` 写入钥匙串。脚本会等待公证完成，然后 staple 并验证票据。

未签名、未公证的安装包从互联网下载后会触发 Gatekeeper 警告，不应作为面向公众的正式发行版本。
