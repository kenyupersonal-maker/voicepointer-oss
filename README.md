# 咻 · VoicePointer

咻是一款 macOS 语音输入工具。用触控手势呼出语音圆盘，说完即可把文字放进当前输入框。在圆盘上可以选择发送或撤销，适合写消息、做笔记和给 AI 提问。

- 支持 Mac 触控板和 Magic Mouse。
- 可以使用豆包输入法、下载本地识别模型，或配置自己的在线识别服务。
- 可以先在输入框里检查文字，再用圆盘发送或撤销。

## 下载

[下载体验版](https://github.com/kenyupersonal-maker/voicepointer-oss/releases/latest) · Apple 芯片 Mac，macOS 14 或更新版本。解压后将咻拖进「应用程序」，按应用引导开启所需权限。体验版使用本地开发签名，首次启动可能被 macOS 拦下。[Apple 的说明](https://support.apple.com/zh-cn/102445)

## 打赏

如果咻对你有帮助，可以 [用 PayPal 支持作者](https://paypal.me/KenYu8171)，也可以用支付宝扫描下面的收款码。应用内「设置 → 打赏」还提供其他方式。

<img src="docs/alipay.png" alt="支付宝打赏二维码" width="184">

## 从源码构建

需要 Apple 芯片 Mac、macOS 14 或更新版本，以及装有 Swift 6 的 Xcode Command Line Tools。用 Git 克隆仓库后，在仓库根目录运行：

```sh
bash scripts/build-from-source.sh
```

应用生成在 `.cache/maintenance04-build/`。源码构建包含界面、手势和语音接入代码，省略预打包的 Python 环境和模型。要体验附带 Python 环境的版本，请下载 Releases 安装包。本地模型在应用里选择并下载。

源码采用 [MIT 许可证](LICENSE)。第三方组件和模型分别适用各自的许可证，见 [NOTICE](NOTICE)。
