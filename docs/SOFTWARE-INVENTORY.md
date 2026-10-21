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

### ONLYOFFICE PPT 放映工具栏（XWLightOS 自研，2026-10-20 新增）

- **全局插件** `xwlightos-ppt-bridge`（后台插件，GUID `asc.{3b946a45-1407-457d-aa79-2950a8fda131}`）：跟踪放映页码，执行官方放映 API（Start/End/GoToNext/GoToPrevious/GoToSlide/Pause/ResumeSlideShow，ONLYOFFICE 8.0+）
- **全局软件** `xwlightos-ppt-toolbar`（Python3+GTK，常驻）：检测到全屏放映窗口后在屏幕下方置顶显示工具栏
- 功能：上一页 | 页码 X/Y | 下一页 | 批注 | 橡皮 | 首页 | 结束放映
- 批注流程（原生批注，2026-10-21）：退出放映→编辑器确认目标页→输入文本→原生 AddComment API 添加到当前幻灯片→继续放映从当前页开始；批注为幻灯片原生对象，随翻页切换，全程不依赖页码计数器；橡皮=Ctrl+Z 撤销

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
| 希沃侧边栏（含桌面批注、截屏、计时器、随机点名、点名） | 6.0.0.x |

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
