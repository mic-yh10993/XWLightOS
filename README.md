# XWLightOS

XWLightOS 1.0 — 专为希沃交互智能平板打造的教育 LiveCD 发行版。

基于 Debian Bookworm，GNOME 桌面 + WhiteSur macOS 风格主题，开机即用。

## 特性

- **希沃硬件深度适配**：红外触屏框通用兼容方案（开机自动识别并切换到 hid-multitouch 驱动），覆盖主流 USB HID 红外触屏
- **教育软件预装**：钉钉、希沃白板、希沃管家（需在构建时提供厂商 .deb 包）
- **中文输入法**：Fcitx5，单击左/右 Shift 切换中英文
- **办公套件**：ONLYOFFICE DesktopEditors（文档/表格/幻灯片/PDF）
- **驱动齐全**：Intel/AMD 显卡固件、Vulkan/VDPAU、声卡（PipeWire）、摄像头
- **GDM 自动登录**：Live 会话开机直达桌面

## 构建

GitHub Actions 自动构建（`Build XWLightOS Live ISO` workflow）：

1. 获取固定版本第三方包
2. 安装教育软件（1550 钩子，需预先将厂商 .deb 放入 `/opt/xwlightos/edu-packages/`）
3. live-build 构建 ISO
4. QEMU BIOS/UEFI 双烟测
5. 发布 Release（ISO 分卷 `.001/.002/.003`）

教育软件包为厂商专有，不随仓库发布。构建时如未提供，1550 钩子会跳过并继续构建基础系统。

## 下载

见 [Releases](https://github.com/mic-yh10993/XWLightOS/releases) 页面。三个分卷下载后合并：

```sh
cat XWLightOS-1.0-amd64-livecd.iso.0* > XWLightOS-1.0-amd64-livecd.iso
sha256sum -c XWLightOS-1.0-amd64-livecd.iso.sha256
```

## 许可证

见 LICENSE 文件。
