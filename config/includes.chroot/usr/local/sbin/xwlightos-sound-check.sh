#!/bin/sh
# XWLightOS: boot-time sound configuration check.
#
# 第 13 轮（2026-11-12，用户 2026-11-11 邮件第 8 项“声音一定要搞定，
# 查清楚为什么不行、配置是否真的生效”）：开机后把声音配置的实际生效值
# 写进 journal 与 /var/lib/xwlightos/sound-check.log，用户只用
# `cat /var/lib/xwlightos/sound-check.log` 就能看到配置生没生效，
# 不用再跑诊断。一次性服务（xwlightos-sound-check.service），开机跑
# 一次；也可随时手动跑本脚本刷新。
#
# 只记录、不改任何配置。尽力而为：查不到的项如实记“未就绪/不可用”，
# 绝不编数；任何一步失败都不拖垮开机（脚本恒返回 0）。
#
# 可测性：sysfs 根目录可用环境变量 XW_SOUND_CHECK_SYSFS 覆盖（默认
# /sys），日志路径可用 XW_SOUND_CHECK_LOG 覆盖（默认
# /var/lib/xwlightos/sound-check.log），本地先验用 mock sysfs 跑。
set -u

SYSFS_ROOT=${XW_SOUND_CHECK_SYSFS:-/sys}
LOG=${XW_SOUND_CHECK_LOG:-/var/lib/xwlightos/sound-check.log}

# 日志目录建不出来时退到 /dev/null（只写 journal，不拖垮开机）。
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=/dev/null

read_sysfs() {
    # 读一个 sysfs 参数文件，读不到返回 "（不可用）"。
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null || echo "（不可用）"
    else
        echo "（不可用）"
    fi
}

{
echo "=== XWLightOS sound check $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
echo "--- snd_hda_intel 电源管理（sysfs 实测值；Build 72/73 镜像已写 power_save=0）---"
echo "power_save: $(read_sysfs "$SYSFS_ROOT/module/snd_hda_intel/parameters/power_save")"
echo "power_save_controller: $(read_sysfs "$SYSFS_ROOT/module/snd_hda_intel/parameters/power_save_controller")"
echo "--- CPU 调速器（sysfs 实测值；powersave 下频率爬升滞后是卡顿嫌疑之一）---"
echo "cpu0 governor: $(read_sysfs "$SYSFS_ROOT/devices/system/cpu/cpu0/cpufreq/scaling_governor")"
echo "--- PipeWire/WirePlumber 用户服务状态 ---"
if command -v systemctl >/dev/null 2>&1; then
    _PWU=$(systemctl --user is-active pipewire wireplumber 2>/dev/null | tr '\n' ' ' || true)
    if [ -n "$_PWU" ]; then echo "pipewire wireplumber: $_PWU"; else echo "（读不到用户服务状态：本脚本以 root 跑时无用户会话）"; fi
else
    echo "（systemctl 不可用）"
fi
echo "--- PipeWire 实时线程（ps 实测调度类与优先级；RR 20 为预期）---"
if command -v ps >/dev/null 2>&1; then
    ps -eo pid,cls,rtprio,comm 2>/dev/null | grep -i -E 'pipewire|wireplumber' | sed 's/^/  /' || echo "  （未找到 pipewire/wireplumber 进程）"
else
    echo "（ps 不可用）"
fi
echo "--- 会话内实际值（以会话用户身份查；会话未就绪时如实记未就绪）---"
USER_NAME=$(cat /etc/xwlightos/session-user 2>/dev/null || echo user)
USER_UID=$(id -u "$USER_NAME" 2>/dev/null || echo 1000)
BUS_PATH=/run/user/$USER_UID/bus
if [ -S "$BUS_PATH" ] && command -v runuser >/dev/null 2>&1; then
    _DS=$(runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR=/run/user/$USER_UID DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_PATH" pactl info 2>/dev/null | grep 'Default Sink' || true)
    if [ -n "$_DS" ]; then echo "  $_DS"; else echo "  （pactl 读不到默认输出）"; fi
    _DV=$(runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR=/run/user/$USER_UID DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_PATH" pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null || true)
    if [ -n "$_DV" ]; then echo "  默认输出音量：$_DV"; else echo "  （读不到默认输出音量）"; fi
    if command -v pw-metadata >/dev/null 2>&1; then
        _QM=$(runuser -u "$USER_NAME" -- env XDG_RUNTIME_DIR=/run/user/$USER_UID DBUS_SESSION_BUS_ADDRESS="unix:path=$BUS_PATH" pw-metadata -n settings 2>/dev/null | grep -i 'quantum' || true)
        if [ -n "$_QM" ]; then echo "$_QM" | sed 's/^/  运行中量子：/'; else echo "  （pw-metadata 未报告运行中量子）"; fi
    else
        echo "  （pw-metadata 不可用，运行中量子查不到）"
    fi
else
    echo "  （会话总线未就绪：PipeWire 实际值本次未采到，可手动重跑本脚本）"
fi
echo "--- 镜像静态配置值（对照用；上面是实测值）---"
if [ -f /etc/pipewire/pipewire.conf.d/51-xwlightos-quantum.conf ]; then
    grep -h 'min-quantum' /etc/pipewire/pipewire.conf.d/51-xwlightos-quantum.conf 2>/dev/null | head -1 | sed 's/^/  /'
else
    echo "  （量子配置文件缺失）"
fi
if [ -f /etc/wireplumber/wireplumber.conf.d/52-xwlightos-alsa-buffering.conf ]; then
    grep -h 'api.alsa.period-size\|api.alsa.headroom' /etc/wireplumber/wireplumber.conf.d/52-xwlightos-alsa-buffering.conf 2>/dev/null | head -2 | sed 's/^/  /'
else
    echo "  （ALSA 缓冲配置文件缺失）"
fi
echo "=== end sound check ==="
} | tee "$LOG" 2>/dev/null || true
exit 0
