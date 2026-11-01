#!/bin/sh
# XWLightOS 触屏诊断（诊断版专用，正式版确认根因后删除自动弹窗）。
#
# 用途：开机后由桌面自启动终端运行，把触屏检测结果显示在屏幕上。
# 用户无需鼠标键盘、不用按任何键，只需把屏幕拍照发给助手。
# 检测本身只读；开头重跑一次修复脚本（该脚本幂等），既覆盖设备
# 晚枚举的情况，也让诊断屏直接显示重跑后的状态。
# 全部输出同时存到 ~/xwlightos-touch-diag.txt，供后续有键盘时查看。
# 2026-11-01 第六轮起：包清单已补 libinput-tools 与 xinput，诊断正
# 面取 libinput 的分类判定与 xinput 挂载（第 11、12 节）；第 8 至
# 10 节用 /sys、udevadm 与 Xorg 日志取 evdev 之上的分类与认领证
# 据，末尾结论区汇总五项，真机只需开机拍照即可落层（H1/H2）。
# 注意：本文件刻意不用方括号测试（用 test 命令），避免写盘时被改写。
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
echo "7. 触摸事件测试："
_EV=$(grep -i -A6 'touch\|cjtouch' /proc/bus/input/devices 2>/dev/null | grep -o 'event[0-9]*' | head -1)
if test -z "$_EV"; then
echo "  找不到触屏事件节点，无法做事件测试（这本身就是一条诊断结论）"
elif test ! -r "/dev/input/$_EV"; then
echo "  触屏节点 /dev/input/$_EV 不可读（权限），无法做事件测试"
else
echo "  触屏设备节点：/dev/input/$_EV"
echo "  请现在触摸屏幕几下，8 秒后显示结果……"
_B=$(timeout 8 cat "/dev/input/$_EV" 2>/dev/null | wc -c)
echo "  8 秒内收到事件字节数：$_B（大于 0 说明触摸事件已到达系统；等于 0 说明触摸没有产生任何事件）"
fi
echo "8. 触屏节点 ABS 能力位图（MT 多点定位位缺失→H1：描述符没把触点映射出来）："
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
echo "9. udev 分类标签（无 ID_INPUT_TOUCHSCREEN=1→udev 没把节点认作触屏）："
_UT=""
if test -n "$_EV"; then
_UT=$(udevadm info "/dev/input/$_EV" 2>/dev/null | grep 'ID_INPUT' | tr '\n' ' ')
fi
if test -n "$_UT"; then echo "  $_EV: $_UT"; else echo "  （udevadm 没给出 ID_INPUT 标签）"; fi
if echo "$_UT" | grep -q 'ID_INPUT_TOUCHSCREEN=1'; then _UDEVTS="有 ID_INPUT_TOUCHSCREEN=1"; else _UDEVTS="无 ID_INPUT_TOUCHSCREEN=1"; fi
echo "10. Xorg 认领（tagged 行是 libinput 驱动收下设备的证据）："
_XLOG=""
if test -f "$HOME/.local/share/xorg/Xorg.0.log"; then _XLOG="$HOME/.local/share/xorg/Xorg.0.log";
elif test -f /var/log/Xorg.0.log; then _XLOG=/var/log/Xorg.0.log; fi
_XG=""
if test -n "$_XLOG"; then
_XG=$(grep -i 'CVTE' "$_XLOG" 2>/dev/null | grep -E 'tagged by udev|Adding|failed|Failed|removed' | head -5)
if test -n "$_XG"; then echo "$_XG" | sed 's/^/  /'; else echo "  （Xorg 日志里没有任何 CVTE 行：Xorg 没认领→H2）"; fi
else echo "  （找不到 Xorg 日志文件）"; fi
if echo "$_XG" | grep -q 'Touchscreen'; then _XTAG="tagged as Touchscreen（已被认领）"; else _XTAG="未见 Touchscreen tag"; fi
echo "11. libinput 眼里的触屏（分类判定原件）："
_LI=$(libinput list-devices 2>/dev/null | grep -i -A8 'CVTE' | grep -E 'Device:|Kernel:|Capabilities:' | head -8)
if test -n "$_LI"; then echo "$_LI" | sed 's/^/  /'; else echo "  （libinput list-devices 里没有 CVTE：libinput 没收下→H2）"; fi
echo "12. xinput 挂载（挂在 Virtual core pointer 下才算核心指针从设备）："
_XI=$(xinput list 2>/dev/null | grep -i 'CVTE' | head -4)
if test -n "$_XI"; then echo "$_XI" | sed 's/^/  /'; else echo "  （xinput 名单里没有 CVTE：Xorg 未认领→H2）"; fi
if echo "$_XI" | grep -q 'floating'; then _XIN="在名单但浮动（未挂核心指针）";
elif echo "$_XI" | grep -q 'slave'; then _XIN="已挂 Virtual core pointer";
else _XIN="不在 xinput 名单"; fi
echo "--------------------------------------------------"
echo "===== 结论区（拍这一屏即可，五项落层） ====="
echo "1) 事件字节（第7节）：${_B:-未测}（等于 0→H1：节点不产事件）"
echo "2) ABS 的 MT 位（第8节）：${_MT:-未读到}（全无→H1：描述符未映射触点）"
echo "3) udev 标签（第9节）：${_UDEVTS:-未知}"
echo "4) Xorg tag（第10节）：${_XTAG:-未知}"
echo "5) xinput 挂载（第12节）：${_XIN:-未知}"
echo "判读：1)或2)异常→H1 在内核/描述符层；1)2)正常而 4)5)异常→H2 上层未认领。"
echo "诊断结束。请把本屏拍照发给助手。"
} 2>&1 | tee "$OUT"
