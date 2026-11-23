# NamiRead

NamiRead 是一款 Android 本地阅读器。你可以把 TXT、EPUB 放进书架，也可以从自定义书源找书。阅读进度和书签保存在手机或平板上。

[产品主页](https://yo1128.github.io/NamiRead/) · [下载 Android 版](https://github.com/Yo1128/NamiRead/releases/download/v0.7.0/NamiRead-0.7.0-universal.apk)

## 阅读

- 从系统文件选择器导入电子书，或从书源搜索作品、浏览目录。
- 左右滑动翻页，调整字体、字号、行距和页边距。平板横屏支持双页阅读。
- 整书下载可暂停和续传。下载完成后可离线阅读，也可另存为 UTF-8 TXT。
- 通过本地备份迁移藏书、阅读位置、书签和设置。

适用于 Android 7.0 及以上。0.7.0 启用新的分发签名。从 0.5.5 升级前，请先在旧版导出备份到应用目录之外，再卸载旧版、安装新版并导入备份。应用使用 [MiSans 字体](https://hyperos.mi.com/font/download)。

## 从 NamiHub 打开电脑上的书

NamiRead 0.7.0 支持从局域网书库分段读 TXT、按章节读 EPUB，也可下载整本离线阅读。

使用 0.7.0 时，先在 Windows 上用 NamiHub 共享存书的文件夹，让手机和电脑连到同一局域网。在书架点「＋ → 浏览 NamiHub 书库」，输入电脑显示的八位配对码。点书名即可在线阅读。要在电脑关机后继续读，可从书名旁的菜单选择「下载到本机」。

[获取 NamiHub Windows 版和连接指南](https://yo1128.github.io/NamiHub/)

## 从源码构建

从[小米 MiSans 官网](https://hyperos.mi.com/font/download)下载可变字体，将 `MiSans-VF.ttf` 放入 `assets/fonts/`。安装 Flutter 后，在仓库根目录运行 `flutter pub get` 和 `flutter build apk --release`。官方签名安装包可从本页顶部下载。
