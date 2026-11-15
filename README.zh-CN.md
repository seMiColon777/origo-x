# 开元阅读 — 本地阅读源码版

本仓库提供可以独立构建的本地优先阅读源码版，复用最新版 TXT/EPUB 分页、排版、书签、笔记和系统听书组件。

保留功能：本地书库与文件导入、翻页、正文搜索、字体主题设置、书签笔记、本地阅读统计、系统 TTS，以及可选的自行部署同步服务（阅读位置与云端书籍文件）。

源码树和依赖中不包含账号服务、内购、探元/高级书源引擎、AI、云同步或开发者后端集成实现。内置同步模块默认关闭并需要自行部署：默认只交换阅读位置，只有在用户开启“同步书籍文件”后才存储 TXT/EPUB 文件；它是 `tool/check_public_source.py` 中唯一经过审核的例外。

## 本地构建

使用 Flutter 3.44.4（Dart 3.12 及以上）：

```sh
flutter pub get --enforce-lockfile
flutter gen-l10n
flutter run
```

平台工程使用中性的示例应用标识，不包含维护者签名身份。需要签名的平台请配置自己的开发签名。公开 CI 会验证 Android 和桌面构建。

## 可选自托管同步

应用内置可选的同步客户端，`sync_server/` 提供阅读位置同步和可选的 TXT/EPUB 云端书架。先执行 `flutter pub get`（服务端用与应用相同的 `crypto` 依赖校验上传文件），再运行 `dart run sync_server/bin/server.dart`。在书库中点击云同步图标填写服务器地址、用户 ID 和访问令牌；点击云端书架图标可以上传或下载整本书。需要先在设置中开启“同步书籍文件”，否则只交换阅读位置。通过 `SYNC_USERS` 配置每用户独立令牌，服务端会按用户执行存储配额。笔记和阅读统计始终不会上传。环境变量、存储布局与 API 说明见 [sync_server/README.md](sync_server/README.md)；若服务器可从公网访问，请使用 HTTPS。

## 官方安装包

从 [Releases](https://github.com/miloquinn/origo-x/releases) 下载官方发行版。官方安装包的功能可能多于本地源码版；这份源码快照不应被当作完整发行包的逐字节复现配方。

## 许可与范围

阅读代码使用 [AGPL-3.0-only](LICENSE)，保留原有版权归属、历史 MIT 许可和字体许可。详情见 [LICENSING.md](LICENSING.md)。

[PUBLIC_SOURCE_SCOPE.md](PUBLIC_SOURCE_SCOPE.md) 定义源码边界。公开 CI 在构建前检查当前跟踪文件中的高级实现和私有运维信息。这次整理不重写历史提交，也不改变其他仓库的可见性。

系统听书依赖操作系统语音引擎；当前 Flutter TTS 插件不支持 Linux 听书。
