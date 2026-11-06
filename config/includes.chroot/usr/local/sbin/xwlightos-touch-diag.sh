#!/bin/sh
# XWLightOS 触屏诊断（诊断版专用，正式版确认根因后删除自动弹窗）。
#
# 用途：开机后由桌面自启动终端运行，把触屏检测结果显示在屏幕上。
# 用户无需鼠标键盘、不用按任何键，只需把屏幕拍照发给助手。
# 检测本身只读；开头重跑一次修复脚本（该脚本幂等），既覆盖设备
# 晚枚举的情况，也让诊断屏直接显示重跑后的状态。
# 全部输出同时存到 ~/xwlightos-touch-diag.txt，供后续有键盘时查看。
# 2026-11-01 第六轮起：包清单已补 libinput-tools 与 xinput。真机
# 定案（Build 65）显示 event5 在持续触摸下 8 秒字节数 =0：触屏节
# 点不产事件、上层（libinput/Xorg/GNOME）无罪，断点在
# hid-multitouch 到 input 的映射段。故采样改为四节点与 hidraw 同
# 窗口并读（第 7、8 节）+ 报告描述符触摸段（第 14 节）定下一岔
# 口；ABS/udev/Xorg/libinput/xinput 各节降为存档。开机拍照即可。
# 注意：本文件刻意不用方括号测试（用 test 命令），避免写盘时被改写。
# 2026-11-02 第七轮：修复脚本新增阶段三（已知 ID 改绑
# MT_CLS_EXPORT_ALL_INPUTS），诊断新增第 15 节怪癖状态与第 16 节
# 音频诊断，结论区加第 8、9 项；用户只开机拍照即可验收怪癖与
# 缓冲加档是否生效。
# 2026-11-06 第八轮：阶段三类值改 MT_CLS_WIN_8（B68 裁决
# EXPORT_ALL 已改绑但仍全 0；且 MTConfig.sys 静态核查证实
# Windows 侧靠 SET_FEATURE 送 Input Mode 配置）；诊断新增
# 第 17 节 root 取证（fix 服务以 root 采的 rdesc 摘要、usbmon
# 枚举期控制传输统计、sampler 以 root 在同一触摸窗口采的
# hidraw 字节、MI_00/MI_01 接口绑定），结论区重排：Input
# Mode 与 hidraw 字节排最前，旧项合并压缩。采样窗开始时本
# 脚本创建 /tmp/xwlightos-touch-evidence/diag-window-open
# 标记通知 root sampler 同窗采样，窗口结束删除。
OUT="$HOME/xwlightos-touch-diag.txt"
{
clear
echo "================ XWLightOS 触屏诊断 ================"
echo "内核：$(uname -r)  时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo "请把本屏拍照发给助手；最后还有一步触摸测试。"
echo "--------------------------------------------------"
echo "1. USB 设备（找 1FF7 触屏框）："
lsusb 2>&1 | head -12
echo "2. HID 设备与驱动（触屏框应在 hid-multitouch 下）："
for d in /sys/bus/hid/devices/*; do
test -e "$d/uevent" || continue
_n=$(sed -n 's/^HID_NAME=//p' "$d/uevent" 2>/dev/null | head -1)
if _link=$(readlink "$d/driver" 2>/dev/null); then _drv=$(basename "$_link"); else _drv="无驱动"; fi
echo "  $(basename "$d") $_drv $_n"
done | head -10
echo "3. hid 驱动与模块："
ls /sys/bus/hid/drivers/ 2>/dev/null | tr '\n' ' '; echo
lsmod 2>/dev/null | grep -E 'hid_multitouch|hid_generic' || echo "  未加载 hid_multitouch/hid_generic 模块"
echo "4. 触屏修复服务："
echo "  开机启用：$(systemctl is-enabled xwlightos-touchscreen-fix 2>&1)"
systemctl show xwlightos-touchscreen-fix -p ActiveState -p Result 2>/dev/null | tr '\n' ' '; echo
echo "  修复脚本日志："
ls -l /tmp/xwlightos-touchscreen-fix.log 2>&1 | head -1
tail -4 /tmp/xwlightos-touchscreen-fix.log 2>/dev/null || echo "  （日志文件不存在：脚本从未跑到写日志这一步）"
echo "  重跑修复脚本……"
/usr/local/sbin/xwlightos-touchscreen-fix.sh 2>&1 | tail -2
tail -3 /tmp/xwlightos-touchscreen-fix.log 2>/dev/null
echo "5. 内核消息（hid/1ff7）："
_dm=$(dmesg 2>/dev/null | grep -iE 'hid|1ff7' | tail -6)
if test -n "$_dm"; then echo "$_dm"; else echo "  （无匹配输出：可能无权限读内核日志）"; fi
echo "6. 输入设备里的触屏设备："
_inp=$(grep -i -A6 'touch\|cjtouch' /proc/bus/input/devices 2>/dev/null | grep -E 'Name|Handlers' | head -8)
if test -n "$_inp"; then echo "$_inp"; else echo "  （输入设备里没有 touch 设备）"; fi
echo "7. 触屏四节点事件字节（与第 8 节 hidraw 共用同一个 8 秒窗口，同时并读）："
# Build 65 真机定案只测过 event5（持续触摸下 8 秒字节数 =0）；CVTE
# 是多集合设备（Touch x2 + Stylus x2），其余节点可能单独有事件，
# 必须逐个分清。四节点与 hidraw 在同一窗口并读，避免先后窗口里
# 触摸动作不一致造成假 0；窗口内顺带扫 /proc/*/fd 看有没有别的
# 进程占着 hidraw（结论区第 7 项，排除诊断自己的采样读者）。
_EVS=$(awk '/^N: Name=/ { n=tolower($0) } /^H: Handlers=/ { if (n ~ /touch|cjtouch/ && match($0, /event[0-9]+/)) print substr($0, RSTART, RLENGTH) }' /proc/bus/input/devices 2>/dev/null | head -6)
_EV=$(echo "$_EVS" | head -1)
_HRDEV=""
for _hd in /sys/class/hidraw/hidraw*; do
test -e "$_hd/device/uevent" || continue
if grep -qiE ':00001FF7:00000F26|HID_NAME=.*(CVTE|Touch)' "$_hd/device/uevent" 2>/dev/null; then _HRDEV=$(basename "$_hd"); break; fi
done
if test -z "$_EVS"; then
echo "  输入设备里找不到触屏节点，无法采样（这本身就是一条诊断结论）"
_EVSUM="无触屏节点"
_HR="未采样（无触屏节点）"
_HOLDLINE="未采样（无采样窗口）"
else
_TD=/tmp/xwlightos-diag-ev.$$
rm -rf "$_TD"; mkdir -p "$_TD"
echo "  采样节点：$(echo "$_EVS" | tr '\n' ' ')"
# 第八轮：创建窗口标记，通知 root sampler（xwlightos-touch-
# hidraw-sampler 服务）在同一个 8 秒窗口以 root 并读 hidraw
# （补 Build 68 时 live 用户不可读 hidraw 的盲区）；第 17 节
# 据此等待并展示 root 采样结果。窗口结束（第 8 节后）删标记。
mkdir -p /tmp/xwlightos-touch-evidence 2>/dev/null
: > /tmp/xwlightos-touch-evidence/diag-window-open 2>/dev/null
_MARKED=1
echo "  请现在开始持续触摸屏幕（点、划都行，不要停），8 秒后出结果……"
for _e in $_EVS; do
if test -r "/dev/input/$_e"; then
timeout 8 cat "/dev/input/$_e" > "$_TD/$_e" 2>/dev/null &
fi
done
if test -n "$_HRDEV"; then
if test -r "/dev/$_HRDEV"; then
timeout 8 cat "/dev/$_HRDEV" > "$_TD/hidraw" 2>/dev/null &
fi
fi
_HOLD=""
for _fdp in /proc/[0-9]*/fd; do
for _fdl in "$_fdp"/*; do
_t=$(readlink "$_fdl" 2>/dev/null)
case "$_t" in
/dev/hidraw*)
_pid=$(echo "$_fdp" | cut -d/ -f3)
_pn=$(cat "/proc/$_pid/comm" 2>/dev/null)
case "$_pn" in
cat|timeout) ;;
*) _HOLD="$_HOLD $_pn(pid $_pid)";;
esac
;;
esac
done
done
if test -n "$_HOLD"; then _HOLDLINE="$_HOLD"; else _HOLDLINE="无（除诊断采样外）"; fi
wait
_EVSUM=""
for _e in $_EVS; do
if test -f "$_TD/$_e"; then
_c=$(wc -c < "$_TD/$_e" | tr -d ' ')
echo "  /dev/input/$_e：$_c 字节"
_EVSUM="$_EVSUM $_e=$_c"
else
echo "  /dev/input/$_e：不可读（权限），未采样"
_EVSUM="$_EVSUM $_e=不可读"
fi
done
echo "8. hidraw 原始报告字节（与第 7 节同一窗口并读；下一个定案岔口）："
if test -z "$_HRDEV"; then
echo "  没有找到 0F26 对应的 /dev/hidraw 节点（设备被 hid-multitouch 认领时通常没有 hidraw 旁路）"
_HR="无 hidraw 节点"
elif test -f "$_TD/hidraw"; then
_hc=$(wc -c < "$_TD/hidraw" | tr -d ' ')
echo "  /dev/$_HRDEV：$_hc 字节（大于 0 而 evdev 全 0→内核映射/quirks 层；同为 0→设备没发报告）"
_HR="/dev/$_HRDEV=$_hc 字节"
else
echo "  /dev/$_HRDEV 存在但 live 用户不可读（权限），原始字节未采样"
_HR="/dev/$_HRDEV 存在但不可读"
fi
rm -rf "$_TD"
fi
rm -f /tmp/xwlightos-touch-evidence/diag-window-open 2>/dev/null
echo "9. 触屏节点 ABS 能力位图（次要存档：节点在内核里的能力声明）："
_ABSOUT=$(awk '
/^N: Name=/ { name=$0; sub(/^N: Name=/, "", name); blk=tolower(name) }
/^H: Handlers=/ { hdl=$0 }
/^B: ABS=/ {
  if (blk ~ /touch|cjtouch/) {
    n=split($0, w, " "); last=w[n]; sub(/^ABS=/, "", last);
    hex=last; while (length(hex)<16) hex="0" hex;
    d=substr(hex, 3, 1);
    mt=(index("67efEF", d)>0) ? "有" : "无";
    ev=""; if (match(hdl, /event[0-9]+/)) ev=substr(hdl, RSTART, RLENGTH);
    printf "  %s %s MT位:%s（ABS末词 %s）\n", ev, name, mt, last;
    sum=sum ev "=" mt " ";
  }
}
END { if (sum != "") printf "  MT汇总：%s\n", sum }' /proc/bus/input/devices 2>/dev/null | head -7)
if test -n "$_ABSOUT"; then echo "$_ABSOUT"; else echo "  （没读到触屏节点的 ABS 行）"; fi
_MT=$(echo "$_ABSOUT" | sed -n 's/.*MT汇总：//p')
if test -n "$_EV"; then
if test -r "/sys/class/input/$_EV/device/capabilities/abs"; then
echo "  $_EV 的 capabilities/abs 原值：$(cat "/sys/class/input/$_EV/device/capabilities/abs" 2>/dev/null)"
fi
fi
echo "10. udev 分类标签（次要存档：udev 给节点的分类）："
_UT=""
if test -n "$_EV"; then
_UT=$(udevadm info "/dev/input/$_EV" 2>/dev/null | grep 'ID_INPUT' | tr '\n' ' ')
fi
if test -n "$_UT"; then echo "  $_EV: $_UT"; else echo "  （udevadm 没给出 ID_INPUT 标签）"; fi
if echo "$_UT" | grep -q 'ID_INPUT_TOUCHSCREEN=1'; then _UDEVTS="有 ID_INPUT_TOUCHSCREEN=1"; else _UDEVTS="无 ID_INPUT_TOUCHSCREEN=1"; fi
echo "11. Xorg 认领（次要存档：tagged 行是 libinput 驱动收下设备的证据）："
_XLOG=""
if test -f "$HOME/.local/share/xorg/Xorg.0.log"; then _XLOG="$HOME/.local/share/xorg/Xorg.0.log";
elif test -f /var/log/Xorg.0.log; then _XLOG=/var/log/Xorg.0.log; fi
_XG=""
if test -n "$_XLOG"; then
_XG=$(grep -i 'CVTE' "$_XLOG" 2>/dev/null | grep -E 'tagged by udev|Adding|failed|Failed|removed' | head -3)
if test -n "$_XG"; then echo "$_XG" | sed 's/^/  /'; else echo "  （Xorg 日志里没有任何 CVTE 行：上层存档项，不影响已定案的 evdev 层结论）"; fi
else echo "  （找不到 Xorg 日志文件）"; fi
if echo "$_XG" | grep -q 'Touchscreen'; then _XTAG="tagged as Touchscreen（已被认领）"; else _XTAG="未见 Touchscreen tag"; fi
echo "12. libinput 眼里的触屏（次要存档：分类判定原件）："
_LI=$(libinput list-devices 2>/dev/null | grep -i -A8 'CVTE' | grep -E 'Device:|Kernel:|Capabilities:' | head -6)
if test -n "$_LI"; then echo "$_LI" | sed 's/^/  /'; else echo "  （libinput list-devices 里没有 CVTE：上层存档项）"; fi
echo "13. xinput 挂载（次要存档：挂在 Virtual core pointer 下才算核心指针从设备）："
_XI=$(xinput list 2>/dev/null | grep -i 'CVTE' | head -4)
if test -n "$_XI"; then echo "$_XI" | sed 's/^/  /'; else echo "  （xinput 名单里没有 CVTE：上层存档项）"; fi
if echo "$_XI" | grep -q 'floating'; then _XIN="在名单但浮动（未挂核心指针）";
elif echo "$_XI" | grep -q 'slave'; then _XIN="已挂 Virtual core pointer";
else _XIN="不在 xinput 名单"; fi
echo "14. HID 报告描述符（触摸应用集合段；后续定 quirks 的源码层依据）："
_HDEV=$(ls -d /sys/bus/hid/devices/*1FF7:0F26* 2>/dev/null | head -1)
_RD=""
if test -n "$_HDEV"; then _RD="/sys/kernel/debug/hid/$(basename "$_HDEV")/rdesc"; fi
if test -z "$_RD"; then
echo "  在 /sys/bus/hid/devices 里找不到 1FF7:0F26 的设备目录"
_RDESC="无设备目录"
elif test -r "$_RD"; then
_RAW=$(tr -d '[:space:]' < "$_RD" 2>/dev/null | tr 'a-f' 'A-F')
_RBYTES=$(( $(printf '%s' "$_RAW" | wc -c) / 2 ))
_START=$(printf '%s' "$_RAW" | awk '{ print index($0, "050D0904A101") }')
_START=${_START:-0}
if test "$_START" -gt 0; then
_SEG=$(printf '%s' "$_RAW" | cut -c "${_START}-$(( _START + 383 ))")
echo "  描述符全长 $_RBYTES 字节；截取规则：自触摸屏应用集合标记 050D0904A101 起 192 字节："
printf '%s' "$_SEG" | fold -w 32 | sed 's/^/  /' | head -12
_RDESC="全长 $_RBYTES 字节，触摸集合段已截取"
else
_SEG=$(printf '%s' "$_RAW" | cut -c "1-384")
echo "  描述符全长 $_RBYTES 字节；未找到触摸屏应用集合标记，截取规则：自开头起 192 字节："
printf '%s' "$_SEG" | fold -w 32 | sed 's/^/  /' | head -12
_RDESC="全长 $_RBYTES 字节，未找到触摸集合标记"
fi
else
echo "  读不到报告描述符（debugfs 需 root，live 用户被拒属预期；此路不通则改走 root 通道回传）"
_RDESC="读不到（debugfs 权限）"
fi
echo "15. 怪癖模式状态（第七轮起：已知 ID 设备改绑的怪癖类；第八轮为 MT_CLS_WIN_8）："
_QLINE=$(grep 'quirks:' /tmp/xwlightos-touchscreen-fix.log 2>/dev/null | tail -3)
if test -n "$_QLINE"; then echo "$_QLINE" | sed 's/^/  /'; else echo "  （fix 日志里没有 quirks 行：阶段三未对任何设备动手）"; fi
_QBIND=""
for _qd in /sys/bus/hid/devices/*1FF7:0F26*; do
test -e "$_qd/uevent" || continue
if _qlink=$(readlink "$_qd/driver" 2>/dev/null); then _qdrv=$(basename "$_qlink"); else _qdrv="无驱动"; fi
_QBIND="$_QBIND $(basename "$_qd")=$_qdrv"
done
if test -n "$_QBIND"; then echo "  1FF7:0F26 当前绑定：$_QBIND"; else echo "  （找不到 1FF7:0F26 的 HID 设备目录）"; fi
if grep -q 'rebound to hid-multitouch with MT_CLS_WIN_8' /tmp/xwlightos-touchscreen-fix.log 2>/dev/null; then _QUIRK="已改绑 MT_CLS_WIN_8（0x12）";
elif grep -q 'rebound to hid-multitouch with MT_CLS_EXPORT_ALL_INPUTS' /tmp/xwlightos-touchscreen-fix.log 2>/dev/null; then _QUIRK="已改绑 EXPORT_ALL_INPUTS（0x13，旧版日志）";
elif grep -q 'already quirked' /tmp/xwlightos-touchscreen-fix.log 2>/dev/null; then _QUIRK="本启动已改绑（重跑跳过）";
else _QUIRK="未应用"; fi
echo "16. 音频诊断（第七轮新增：默认输出、音量、缓冲档位）："
_PWU=$(systemctl --user is-active pipewire wireplumber 2>/dev/null | tr '\n' ' ')
if test -n "$_PWU"; then echo "  pipewire/wireplumber 用户服务：$_PWU"; else echo "  （读不到用户服务状态）"; fi
_DS=$(pactl info 2>/dev/null | grep 'Default Sink')
if test -n "$_DS"; then echo "  $_DS"; else echo "  （pactl 读不到默认输出）"; fi
_DV=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null)
if test -n "$_DV"; then echo "  默认输出音量：$_DV"; else echo "  （读不到默认输出音量）"; fi
echo "  缓冲档位（镜像静态值）："
grep -h 'min-quantum' /etc/pipewire/pipewire.conf.d/51-xwlightos-quantum.conf 2>/dev/null | head -1 | sed 's/^/    /'
grep -h 'api.alsa.period-size\|api.alsa.headroom' /etc/wireplumber/main.lua.d/52-xwlightos-alsa-buffering.lua 2>/dev/null | head -2 | sed 's/^/    /'
echo "17. root 取证（第八轮：Input Mode、枚举期控制传输、hidraw root 采样、接口绑定）："
_EVD=/tmp/xwlightos-touch-evidence
# root sampler 与第 7/8 节同窗并读、结束时间接近；本轮开过窗
# 口标记且 sampler 还在跑时，最多等 10 秒让它落盘。
if test -n "${_MARKED:-}"; then
_SAMPLERSTATE=$(systemctl is-active xwlightos-touch-hidraw-sampler 2>/dev/null)
case "$_SAMPLERSTATE" in
active|activating)
_w=0
while test ! -f "$_EVD/hidraw-root.txt" && test "$_w" -lt 10; do sleep 1; _w=$((_w + 1)); done
;;
esac
fi
echo "  Input Mode 与报告描述符摘要（root 解析 rdesc）："
_IMLINE=""
if test -f "$_EVD/rdesc-summary.txt"; then
sed 's/^/    /' "$_EVD/rdesc-summary.txt" 2>/dev/null | head -14
_IMLINE=$(grep '^InputMode:' "$_EVD/rdesc-summary.txt" 2>/dev/null | head -1)
else
echo "    （证据文件缺失：fix 服务未以 root 采集过）"
fi
if test -z "$_IMLINE"; then _IMLINE="InputMode: 未知（证据缺失）"; fi
echo "  枚举期控制传输（root 以 usbmon 抓开机修复全程）："
_SETLINE=""; _STLINE=""
if test -f "$_EVD/usbmon-summary.txt"; then
grep -E '^(方法|SET_REPORT_FEATURE|SET_REPORT_ALL|GET_REPORT|CONTROL_OUT)' "$_EVD/usbmon-summary.txt" 2>/dev/null | sed 's/^/    /'
_SETLINE=$(grep '^SET_REPORT_FEATURE:' "$_EVD/usbmon-summary.txt" 2>/dev/null | head -1)
_STLINE=$(grep '^CONTROL_OUT_STATUS:' "$_EVD/usbmon-summary.txt" 2>/dev/null | head -1)
else
echo "    （证据文件缺失：usbmon 摘要未生成）"
fi
if test -z "$_SETLINE"; then _SETLINE="SET_REPORT_FEATURE: 未知（证据缺失）"; fi
if test -z "$_STLINE"; then _STLINE="CONTROL_OUT_STATUS: 未知"; fi
echo "  hidraw 原始字节（root 采样，与第 7/8 节同一个触摸窗口）："
_HRROOT=""
if test -f "$_EVD/hidraw-root.txt"; then
sed 's/^/    /' "$_EVD/hidraw-root.txt" 2>/dev/null | head -6
_HRROOT=$(grep -E '^hidraw[0-9]+=' "$_EVD/hidraw-root.txt" 2>/dev/null | tr '\n' ' ')
if test -z "$_HRROOT"; then _HRROOT=$(grep '^状态' "$_EVD/hidraw-root.txt" 2>/dev/null | head -1); fi
else
echo "    （sampler 结果缺失：服务未跑或未等到窗口）"
fi
if test -z "$_HRROOT"; then _HRROOT="未采样（sampler 结果缺失）"; fi
echo "  USB 接口绑定（1FF7:0F26，普通用户直读，仅记录、第八轮不动它）："
_MILINE=""
for _ud in /sys/bus/usb/devices/*; do
test -f "$_ud/idVendor" || continue
test "$(cat "$_ud/idVendor" 2>/dev/null)" = "1ff7" || continue
test "$(cat "$_ud/idProduct" 2>/dev/null)" = "0f26" || continue
for _ifd in "$_ud":*; do
test -f "$_ifd/bInterfaceNumber" || continue
_mi=$(cat "$_ifd/bInterfaceNumber" 2>/dev/null)
if _il=$(readlink "$_ifd/driver" 2>/dev/null); then _idrv=$(basename "$_il"); else _idrv="无驱动"; fi
echo "    MI_$_mi（$(basename "$_ifd")）：$_idrv"
_MILINE="$_MILINE MI_$_mi=$_idrv"
done
done
if test -z "$_MILINE"; then echo "    （没找到 1FF7:0F26 的 USB 设备目录）"; _MILINE="未找到设备"; fi
# 结论区第 8 项的取材：希沃厂商服务与 udi 条目的在跑状态（验证
# “厂商服务负责触屏初始化/映射、而它没在 Linux 这边跑”这条假设）。
_SEEWO=$(systemctl list-units --all 'com.seewo.*' --no-legend --no-pager 2>/dev/null | awk '{ gsub(/\.service$/, "", $1); printf "%s=%s ", $1, $3 }')
if test -z "$_SEEWO"; then _SEEWO="无 com.seewo 单元"; fi
_UDI=$( { systemctl list-units --all --no-legend --no-pager 2>/dev/null | grep -iE '(^|[^a-zA-Z])udi([^a-zA-Z]|$)' | awk '{ if ($1 == "●") print $2; else print $1 }' | head -3; ps -eo comm= 2>/dev/null | grep -iE '(^|[^a-zA-Z])udi([^a-zA-Z]|$)' | head -3; } | tr '\n' ' ' )
if test -z "$_UDI"; then _UDI="无"; fi
echo "--------------------------------------------------"
echo "===== 结论区（拍这一屏即可） ====="
echo "1) Input Mode（第17节）：${_IMLINE:-未知}；${_SETLINE:-SET 未知}；${_STLINE:-状态未知}"
echo "2) hidraw 原始字节（第8节）：root ${_HRROOT:-未采样}；live 用户 ${_HR:-未采样}（大于 0 而 evdev 全 0→映射层；同为 0→设备没发报告）"
echo "3) 四节点事件字节（第7节）：${_EVSUM:-未采样}"
echo "4) 怪癖模式（第15节）：${_QUIRK:-未知}"
echo "5) MI 接口绑定（第17节，仅记录）：${_MILINE:-未知}"
echo "6) ABS 的 MT 位（第9节）：${_MT:-未读到}；报告描述符（第14节）：${_RDESC:-未取}"
echo "7) 上层存档（已定无罪）：udev ${_UDEVTS:-未知}；Xorg ${_XTAG:-未知}；xinput ${_XIN:-未知}"
echo "8) 厂商服务：${_SEEWO}；udi 条目：${_UDI}；hidraw 占用：${_HOLDLINE:-未采样}"
echo "9) 音频（第16节）：${_DS:-未知默认输出}；${_DV:-未知音量}"
echo "判读：本版已按对齐 Windows 改绑 WIN_8 类。第 1 项：SET_REPORT 提交=0→内核没把 Input Mode 发出去（描述符解析差异）；提交大于 0 且完成状态有负数→gadget 拒收；提交大于 0、状态为 0 但第 2/3 项仍全 0→gadget 收到仍不报触摸（安卓板转发/固件条件方向）。"
echo "诊断结束。请把结论区拍照发给助手（可分两屏，第 1、2 项必须拍到）。"
} 2>&1 | tee "$OUT"
