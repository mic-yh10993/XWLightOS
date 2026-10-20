# XWLightOS 硬件兼容性核查（2026-10-20）

依据用户 2026-10-20 邮件「再改一点」所附 Windows 驱动备份列表（29 个驱动目录），
逐项核查在 XWLightOS（Debian Bookworm，kernel 6.1）下的驱动覆盖情况。

## 结论总览

| 状态 | 数量 | 说明 |
|------|------|------|
| ✅ 已覆盖 | 26 | 内核自带驱动 / 已在包列表 / 固件已包含 |
| ➕ 本次补齐 | 1 | modemmanager（4G 蜂窝管理） |
| ⚠️ 需真机验证 | 2 | Realtek USB WiFi（固件已含，稳定性待实测） |

## 逐项核查

### Intel 平台（Tiger Lake）
| Windows 驱动 | 硬件 | Linux 覆盖 | 状态 |
|---|---|---|---|
| tigerlakepch-hsystem.inf | Tiger Lake PCH 芯片组 | 内核原生 | ✅ |
| cometlakesystem.inf | 芯片组（备用条目） | 内核原生 | ✅ |
| iigd_dch.inf / iigd_ext.inf | Intel 核显 | i915 + firmware-misc-nonfree（GuC/HuC） | ✅ |
| intcdaud.inf ×3 | Intel 显示音频（HDMI/DP） | snd_hda_intel | ✅ |
| iaahcic.inf | Intel AHCI SATA | ahci | ✅ |
| heci.inf / dal.inf / iclsclient.inf / lms.inf | Intel ME | mei_me（非关键功能） | ✅ |
| hdbusext.inf | Intel HDBus | 内核原生 | ✅ |
| Tiger Lake 音频 | SOF 音频 | firmware-sof-signed | ✅ |
| cui_dch.inf / igcc_dch.inf | Intel 显卡控制面板（Windows 应用） | Linux 不需要 | ✅ |

### 网络
| Windows 驱动 | 硬件 | Linux 覆盖 | 状态 |
|---|---|---|---|
| rt640x64.inf | Realtek PCIe 千兆有线（RTL8168/8111） | r8169 + firmware-realtek | ✅ |
| netrtwlanu.inf / rtux64w10.inf | Realtek USB WiFi | rtl8xxxu/rtw88 + firmware-realtek | ⚠️ 固件已含，稳定性需真机实测 |
| qcmdm.inf / qcnet.inf / qcser.inf | 高通 4G 模块 | qcserial/qmi_wwan（内核）+ modemmanager（本次补齐） | ➕ |
| sc08_rndis.inf | RNDIS（USB 网络共享） | rndis_host | ✅ |

### 输入/多媒体
| Windows 驱动 | 硬件 | Linux 覆盖 | 状态 |
|---|---|---|---|
| ambarella_evaluation_board | Ambarella 摄像头 SoC | uvcvideo（UVC）+ cheese/v4l-utils | ✅ |
| vmultia.inf | 虚拟多点触控（Windows 层） | Linux 不需要；真实触屏由 hid-multitouch 接管（Build 64 已修） | ✅ |
| android_winusb.inf | Android USB（ADB） | 标准 USB（非关键） | ✅ |
| prnms001.inf / prnms009.inf | 打印机 | cups/cups-filters（已在包列表） | ✅ |
| rtkfilter.inf | Realtek 音频滤镜 | snd_hda_intel 直接处理（不需要） | ✅ |

## 本次修改
- `config/package-lists/xwlightos-compat.list.chroot`: 新增 `modemmanager`
- `config/hooks/normal/1555-fix-easinote5-launcher.hook.chroot`: 白板改回走厂商 sh（已审计无硬件校验）

## 诚实说明
以上为静态配置核查（包列表 + 内核驱动映射 + 固件覆盖）。Realtek USB WiFi
在 Linux 下偶有稳定性差异，4G 模块的数据连接，均需真机实测确认。
