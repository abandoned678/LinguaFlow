# 构建与安装

## 开发版安装

日常开发在仓库根目录运行：

```bash
./scripts/install-local.sh
./scripts/check-installed-input-sources.swift --local
```

脚本将「随键译」安装到 `~/Library/Input Methods/SentenceAlong.app`。系统域测试包安装到 `/Library/Input Methods/SentenceAlong.app`，并尝试为当前桌面用户注册和启用。随键译使用新的输入源 ID 和独立的 Rime 用户数据目录 `~/Library/Application Support/SentenceAlong/Rime/`。原「LinguaFlow Dev 中文」及其词频数据可在原输入源继续使用，安装随键译时不会迁移。

若菜单栏未显示该输入源，可在「系统设置 → 键盘 → 文本输入 → 编辑」中添加。第一次使用翻译前，从输入法菜单选择「准备本地翻译模型…」，在「翻译」页主动准备模型，并按系统提示确认下载。

构建面向 Apple 芯片 Mac。源码目标从 macOS 26 编译，构建脚本读取实际 app、设置助手和全部内嵌动态库的 Mach-O 最低系统版本，并将其中的最高值写入两个 app 与安装包。本机 Homebrew librime 生成的产物要求 macOS 27.0。当前实测环境为 macOS 27.0.1。

## 开发者构建

构建机器仍需要 Swift 工具链和 Homebrew `librime`，因为它是链接输入；生成的安装包自身不依赖 Homebrew：

```bash
brew install librime
./scripts/build-installer.sh release
```

产物写入 `.build/dist/`。应用的 `Contents/Resources/BuildInfo.plist` 记录版本、构建号、最低系统、源码提交、工作区改动标记、内嵌动态库版本、构建依赖和词库提交。安装包附有 SHA-256 校验文件。

安装后可用以下独立检查确认开发版中文输入源已启用、可选择，并且 LaunchServices 指向系统目录中的副本：

```bash
./scripts/check-installed-input-sources.swift
```

无证书时会生成适合本机测试的未签名 `.pkg`，应用包采用 ad-hoc 签名。用于 GitHub Release 等公开下载时，需要 Apple Developer Program 的 `Developer ID Application` 与 `Developer ID Installer` 证书，并完成公证：

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Example (TEAMID)' \
INSTALLER_SIGN_IDENTITY='Developer ID Installer: Example (TEAMID)' \
NOTARYTOOL_PROFILE='macos-notary' \
./scripts/build-installer.sh release
```

`NOTARYTOOL_PROFILE` 应提前使用 `xcrun notarytool store-credentials` 写入钥匙串。脚本会等待公证完成，然后 staple 并验证票据。

未签名、未公证的安装包从互联网下载后会触发 Gatekeeper 警告，不应作为面向公众的正式发行版本。
