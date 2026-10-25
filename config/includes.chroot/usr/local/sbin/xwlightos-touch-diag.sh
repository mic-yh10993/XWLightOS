#!/bin/sh
# XWLightOS 触屏诊断（诊断版专用，正式版确认根因后删除自动弹窗）。
#
# 用途：开机后由桌面自启动终端运行，把触屏检测结果显示在屏幕上。
# 用户无需鼠标键盘、不用按任何键，只需把屏幕拍照发给助手。
# 检测本身只读；开头重跑一次修复脚本（该脚本幂等），既覆盖设备
# 晚枚举的情况，也让诊断屏直接显示重跑后的状态。
# 全部输出同时存到 ~/xwlightos-touch-diag.txt，供后续有键盘时查看。
# 刻意不用 libinput-tools（包清单里没有），只用核心工具链。
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
ls -l /var/log/xwlightos-touchscreen-fix.log 2>&1 | head -1
tail -4 /var/log/xwlightos-touchscreen-fix.log 2>/dev/null || echo "  （日志文件不存在：脚本从未跑到写日志这一步）"
echo "  重跑修复脚本……"
/usr/local/sbin/xwlightos-touchscreen-fix.sh 2>&1 | tail -2
tail -3 /var/log/xwlightos-touchscreen-fix.log 2>/dev/null
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
echo "--------------------------------------------------"
echo "诊断结束。请把本屏拍照发给助手。"
} 2>&1 | tee "$OUT"
