#!/bin/bash
# XWLightOS 实体键盘在场守候（2026-11-01 第五轮，用户要求：
# “检测有没有连接实体键盘，连接了就不弹出虚拟键盘，没有就弹”）。
#
# 开关落点（gnome-shell 43.9 源码取证，js/ui/keyboard.js，与
# Bookworm 43.9-0+deb12u2 同版）：KeyboardManager 构造时把
# org.gnome.desktop.a11y.applications 的 'changed' 信号连到
# _syncEnabled()，screen-keyboard-enabled 一变即重建/销毁 OSK
# 对象，运行时动态生效、不需重启会话。本守候据此写这个键：
# dconf 播种默认 true 不动，本守候只在在场判定与当前键值不符
# 时才写（有键盘=false、无键盘=true）；判定没变绝不重写，用
# 户在两次插拔事件之间手动改设置不会被无故改回去。
# 注：_syncEnabled() 里还有一条 Shell 自带的触屏自动启用通道
# （enabled = 设置值 || (touch-mode && 最后设备是触屏)），其在
# Xorg 会话下的实际触发情况静态不可判，列入设备验收观察项；
# 本守候只负责简报指定的设置开关，不 patch Shell。
#
# 在场判定只认“真键盘”：遍历 /sys/class/input/event*/device/
# capabilities/key 位图，bits 0-63（位图逐词最高位在前打印、
# 最后一个词即 bits 0-63）同时含 KEY_Q(16)、KEY_ENTER(28)、
# KEY_SPACE(57) 的设备才算。按构造排除：触摸屏（键位在 256
# 以上，如 BTN_TOUCH=330）、电源键（KEY_POWER=116 在第二个
# 词）、视频总线（亮度键 224+）、鼠标（按钮 272+），以及
# XTest/IBus 这类根本不建 evdev 节点的纯虚拟源。希沃（只有
# 触屏）判无键盘→OSK 允许弹；VMware（虚拟 PS/2 键盘位图有
# 完整字母键）判有键盘→不弹，属用户知情的预期行为。
#
# 形态：systemd user unit 常驻（1720 钩子启用）。登录评估
# 一次，之后阻塞在 udevadm monitor 的 input 子系统事件流上
# ——netlink 事件驱动、零轮询、无任何周期扫描；每来一条
# add/remove 就重评一次。判定与写键全部打到 stdout，进
# user journal（journalctl --user -u xwlightos-keyboard-watch）
# 供真机对账。udevadm 流断开则退出，由 unit 的
# Restart=on-failure 拉起重评。本脚本故意不用 set -e：常驻
# 守候不能因一次 gsettings 失败就死。
#
# --check 模式（校验脚本离线自检用）：只跑判定、打印
# keyboard/no-keyboard 后退出，不写设置、不碰 udev；判定根
# 目录可用 XW_KBD_WATCH_SYSFS 覆盖指向合成设备树。

SYSFS_INPUT="${XW_KBD_WATCH_SYSFS:-/sys/class/input}"
SETTING_SCHEMA="org.gnome.desktop.a11y.applications"
SETTING_KEY="screen-keyboard-enabled"

log() {
    echo "xwlightos-keyboard-watch: $*"
}

keymap_is_real_keyboard() {
    local words=($1)
    local n=${#words[@]}
    [ "$n" -ge 1 ] || return 1
    local last="${words[$((n - 1))]}"
    case "$last" in
        ''|*[!0-9a-fA-F]*) return 1 ;;
    esac
    local v=$((16#$last))
    (( (v & (1 << 16)) != 0 && (v & (1 << 28)) != 0 && (v & (1 << 57)) != 0 ))
}

has_real_keyboard() {
    local f dev name
    for f in "$SYSFS_INPUT"/event*/device/capabilities/key; do
        [ -r "$f" ] || continue
        if keymap_is_real_keyboard "$(cat "$f" 2>/dev/null)"; then
            dev="$(dirname "$(dirname "$f")")"
            name="$(cat "$dev/name" 2>/dev/null || true)"
            log "real keyboard detected: ${name:-unknown} ($dev)"
            return 0
        fi
    done
    return 1
}

if [ "${1:-}" = "--check" ]; then
    if has_real_keyboard; then
        echo "keyboard"
        exit 0
    fi
    echo "no-keyboard"
    exit 1
fi

apply_state() {
    local reason="$1" want current
    if has_real_keyboard; then
        want="false"
    else
        want="true"
        log "no real keyboard found under $SYSFS_INPUT"
    fi
    current="$(gsettings get "$SETTING_SCHEMA" "$SETTING_KEY" 2>/dev/null || echo 'unknown')"
    if [ "$current" != "$want" ]; then
        if gsettings set "$SETTING_SCHEMA" "$SETTING_KEY" "$want" 2>/dev/null; then
            log "[$reason] $SETTING_KEY: $current -> $want"
        else
            log "[$reason] WARNING: failed to set $SETTING_KEY to $want (current read: $current)"
        fi
    else
        log "[$reason] $SETTING_KEY already $want, no write"
    fi
}

log "starting (sysfs: $SYSFS_INPUT); writes happen only when the presence verdict differs from the setting"
apply_state "login evaluation"

udevadm monitor --udev --subsystem-match=input 2>/dev/null | while IFS= read -r line; do
    case "$line" in
        *" add "*|*" remove "*)
            log "udev event: $line"
            apply_state "udev event"
            ;;
    esac
done

log "udev event stream ended, exiting so systemd restarts and re-evaluates"
exit 1
