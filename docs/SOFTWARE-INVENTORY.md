# XWLightOS 系统软件清单

> 基于构建 #8（xwlightos-1.0-preview-8，待构建）汇总。最后更新：2026-10-20

## 桌面环境

- **GNOME 43**（Debian bookworm）+ WhiteSur macOS 风格主题
- GDM 自动登录，X11 会话
- GNOME Shell 扩展：Apps Menu、dash-to-dock、Desktop Icons NG (ding)、Native Window Placement、Places Status Indicator、Removable Drive Menu、System Monitor、User Themes、AppIndicator
- **Dock 固定栏（7 个）**：希沃白板、希沃视频展台、班级优化大师、ONLYOFFICE、钉钉、微信、QQ（2026-10-20 用户邮件指令）

## 办公软件

| 软件 | 版本 | 来源 |
|------|------|------|
| ONLYOFFICE DesktopEditors | 9.4.0 | GitHub 官方 release（SHA256 锁定） |
| PeaZip | 11.2.0 Qt6 | GitHub 官方 release（SHA256 锁定） |

## 教育软件（来自 WinduxEdu，版本锁定）

| 软件 | 版本 |
|------|------|
| 钉钉 | 8.2.8.260818002 |
| 希沃白板 5 | 5.2.2.4.13701 | .desktop 已修正为直接启动 EasiNote5 二进制（2026-10-20，不再经厂商 .sh）；swenserver 改由自启服务保证 |
| 希沃管家 | 3.0.6.716 |
| 希沃视频展台 | 2.0.5.2580 |
| 班级优化大师 | 2.1.0.3274 |
| QQ | 3.2.34-53644 |
| 微信 | 4.1.13.23 |
| 希沃侧边栏（含桌面批注、截屏、计时器、随机点名、点名） | 6.0.0.x（用户 2026-10-25 09:01 指令暂时删除，本次构建不装，恢复时 revert 删除提交） |

## 浏览器

- Firefox ESR（Debian 官方源）

## 输入法

- fcitx5（单击左/右 Shift 切换中英文，Ctrl+Space 保留）

## 驱动/固件

- firmware-linux、firmware-iwlwifi、firmware-atheros、firmware-brcm80211、firmware-realtek、firmware-misc-nonfree、firmware-amd-graphics、firmware-intel-sound、firmware-sof-signed 等全套
- mesa 全套：mesa-utils、mesa-va-drivers、mesa-vulkan-drivers、mesa-vdpau-drivers、intel-media-va-driver、i965-va-driver、vainfo
- 触屏：通用红外触屏框两阶段修法（1620 钩子，开机自动）

## 音频/视频

- PipeWire + WirePlumber + pipewire-pulse + pipewire-alsa + pavucontrol
- 蓝牙音频：libspa-0.2-bluetooth、bluez
- 摄像头：v4l-utils + Cheese

## 系统工具

- Calamares 安装器（XWLightOS 品牌）
- fwupd（固件更新）
- openssh-server
- Python 3 开发环境（python3-pip、venv、build-essential 等）

## 已移除（相对 DclawOS）

- OpenClaw、OmniRoute 及全部 AI 组件（AI 聊天、AI 管理器、相关 systemd 服务）
- Node.js（曾为 OpenClaw 运行时）
