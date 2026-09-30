# ShuVPN

[![Release](https://img.shields.io/github/v/release/preca-hoshino/ShuVPN?color=1677ff&label=release)](https://github.com/preca-hoshino/ShuVPN/releases)
[![Downloads](https://img.shields.io/github/downloads/preca-hoshino/ShuVPN/total?color=1677ff&label=downloads)](https://github.com/preca-hoshino/ShuVPN/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0-1677ff)](./LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.2-02569B?logo=flutter&logoColor=white)](https://flutter.dev)

专为 SHUer 设计的一站式校园VPN服务软件！

- 校园账户 账密/企业微信登录支持
- aTrust, Easyconnect, OpenVPN 多协议支持
- 按照各平台特性设计的多种接入方式,包含 HTTP 代理，Socks5代理等

## 安装

### Android
Android 版本可以打开 [release 页面](https://github.com/preca-hoshino/ShuVPN/releases)下载。（依据设备差异，您可能需要在设置中允许「安装来自未知来源的应用」）

### MacOS/Windows/Linux
目前正在全力适配中，敬请期待。

### HarmoneyOS
> 特指 	HarmonyOS 5.0 及其未来版本的系统

目前正在全力适配中，敬请期待。

HarmonyOS 4.X 及其以前版本系统请使用 Android 版本安装包。

### iOS/iPadOS
目前暂时没有 ios/iPadOS 平台的适配计划。

如果您遇到了本应用中不符合预期的行为，欢迎先查看已有的 [Issues](https://github.com/preca-hoshino/ShuVPN/issues)，也可以[新建 Issue](https://github.com/preca-hoshino/ShuVPN/issues/new/choose) 反馈问题或提出建议。修复问题或新增功能时，欢迎提交 Pull Request。

## 编译说明

本应用使用 [Dart](https://dart.dev/) 和 [Flutter](https://flutter.dev/) 开发。

我们跟随 Flutter `stable` 渠道的最新版本，当前使用的编译版本为：

```shell
Flutter 3.47.2 • channel stable • https://github.com/flutter/flutter.git
Framework • revision d3b14c8769 (5 weeks ago) • 2026-08-26 16:07:51 -0700
Engine • hash 1cf1c4773fb941c4c74a7f8bb144a8837596c0f4 (revision a804b26164) (1 months ago) • 2026-08-26
18:46:13.000Z
Tools • Dart 3.13.2 • DevTools 2.60.0
```

为了构建本应用，您需要[下载](https://flutter.cn/docs/get-started/install)并安装 `Flutter SDK`，将 `flutter` 加入 PATH；

如果您正在为 `Android` 平台构建，需要安装 [Android Studio](https://developer.android.google.cn/studio)、配置 Android SDK 与 [Android Command Line Tools](https://developer.android.google.cn/studio)，并准备好可用的 Android 模拟器或真机设备。

<!-- 如果您正在为 `iOS/iPadOS` 平台构建，您还需要[安装并配置](https://apps.apple.com/app/id497799835) `Xcode`，并准备可用的 Simulator 或真机进行调试。 -->

确定配置正确后，在项目根目录执行：

```shell
flutter pub get
flutter devices
flutter run -d <device-id>
```

运行测试：

```shell
flutter test
```

## 许可证

[AGPL-3.0](./LICENSE)
