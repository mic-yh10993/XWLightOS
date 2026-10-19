#!/bin/sh
# XWLightOS 触屏通用兼容修复（用户 2026-10-19 邮件批准两阶段方案）。
#
# 背景：国产红外触屏框（如希沃 T86EA 的 CJTouch 系，VID 1FF7）在 Linux 下
# 常被 hid-generic 兜底认领——内核创建了 input 设备但触摸事件未正确映射
# （光标浮中央不动）。hid-multitouch 驱动本来就支持这类设备（kernel 6.1
# Kconfig 明确列出 "CJTouch panels" 和 "IrTouch Infrared USB panels"），
# 只是设备的 HID report descriptor 不标准、未被分入 HID_GROUP_MULTITOUCH。
#
# 修法：用内核 new_id 机制把设备注册给 hid-multitouch，再 unbind/bind
# 转交驱动。这是 Linux 社区对付非标红外框的标准做法。
#
# 两阶段（通用兼容优先，用户 2026-10-19 明确要求不只针对他这台机）：
#   阶段一（通用兜底）：扫描被 hid-generic 占用的、名字含 touch 的设备，
#     任何牌子红外框都管用，不依赖 VID:PID。
#   阶段二（已知 ID 名单）：/etc/xwlightos/touchscreen-known-ids.conf 里
#     实测过的 ID（首批 1FF7:0F26），名字对不上也转，后续可追加。
#
# 安全边界：
#   - 只动 hid-generic 兜底的设备（已有专属驱动的一个不动）。
#   - 无触屏机器：扫描不到设备，直接 no-op 退出，零影响。
#   - 幂等：已转到 hid-multitouch 的设备不会再被扫描到，可重复跑。
#   - ops 机型：触屏正常则无事可做，天然跳过，无需专门检测。
set -eu

HID_SYS="/sys/bus/hid/devices"
GENERIC_DRV="/sys/bus/hid/drivers/hid-generic"
MULTITOUCH_DRV="/sys/bus/hid/drivers/hid-multitouch"
KNOWN_IDS_CONF="/etc/xwlightos/touchscreen-known-ids.conf"

log() {
    echo "xwlightos-touchscreen-fix: $*" >&2
    logger -t xwlightos-touchscreen-fix "$*" 2>/dev/null || true
}

# hid-multitouch 驱动不存在（极小概率）则直接退出，不报错。
[ -d "$MULTITOUCH_DRV" ] || {
    log "hid-multitouch driver not present, nothing to do"
    exit 0
}
[ -d "$HID_SYS" ] || {
    log "$HID_SYS missing, nothing to do"
    exit 0
}

# 把一个 hid-generic 设备转给 hid-multitouch。
# 参数：sysfs 设备名（如 0003:1FF7:0F26.0001）
move_to_multitouch() {
    _dev="$1"
    _uevent="$HID_SYS/$_dev/uevent"
    [ -f "$_uevent" ] || return 0

    # HID_ID 格式：bus:vendor:product（如 0003:00001FF7:00000F26）。
    _hid_id="$(sed -n 's/^HID_ID=//p' "$_uevent" | head -1)"
    [ -n "$_hid_id" ] || return 0
    _bus="$(echo "$_hid_id" | cut -d: -f1)"
    _vid="$(echo "$_hid_id" | cut -d: -f2)"
    _pid="$(echo "$_hid_id" | cut -d: -f3)"
    # 去掉前导零，转成 new_id 要的十六进制（sscanf %x 可读）。
    _bus_h="$(printf '%x' "0x$_bus" 2>/dev/null || echo "$_bus")"
    _vid_h="$(printf '%x' "0x$_vid" 2>/dev/null || echo "$_vid")"
    _pid_h="$(printf '%x' "0x$_pid" 2>/dev/null || echo "$_pid")"
    _name="$(sed -n 's/^HID_NAME=//p' "$_uevent" | head -1)"

    # 1. 注册到 hid-multitouch（已注册过会报 exists，忽略）。
    echo "$_bus_h $_vid_h $_pid_h" > "$MULTITOUCH_DRV/new_id" 2>/dev/null || true
    # 2. 从 hid-generic 解绑。
    echo "$_dev" > "$GENERIC_DRV/unbind" 2>/dev/null || {
        log "unbind $_dev ($_name) from hid-generic failed, skip"
        return 0
    }
    # 3. 绑定到 hid-multitouch。
    if echo "$_dev" > "$MULTITOUCH_DRV/bind" 2>/dev/null; then
        log "moved $_dev ($_name, ${_vid}:${_pid}) hid-generic -> hid-multitouch"
    else
        log "bind $_dev ($_name) to hid-multitouch failed"
        return 0
    fi
}

# 设备是否正被 hid-generic 驱动。
is_generic_bound() {
    _dev="$1"
    _drvlink="$HID_SYS/$_dev/driver"
    [ -L "$_drvlink" ] || return 1
    [ "$(readlink "$_drvlink")" = "../../drivers/hid-generic" ] || \
    [ "$(basename "$(readlink -f "$_drvlink" 2>/dev/null)")" = "hid-generic" ]
}

_moved=0

# ---- 阶段一：通用兜底 ----
# 名字含 touch（不分大小写）、排除 touchpad（触摸板已有 synaptics/libinput
# 专属驱动，绝不能动）。
for _devpath in "$HID_SYS"/*; do
    _dev="$(basename "$_devpath")"
    is_generic_bound "$_dev" || continue
    _name="$(sed -n 's/^HID_NAME=//p' "$_devpath/uevent" 2>/dev/null | head -1)"
    [ -n "$_name" ] || continue
    _lname="$(echo "$_name" | tr 'A-Z' 'a-z')"
    case "$_lname" in
        *touchpad*) continue ;;  # 触摸板：不动
        *touch*) ;;
        *) continue ;;
    esac
    move_to_multitouch "$_dev" && _moved=$((_moved + 1))
done

# ---- 阶段二：已知 ID 名单 ----
# 配置文件每行一个 "VID:PID"（十六进制，不分大小写，# 开头为注释），
# 例如：1FF7:0F26。名字对不上也转——名单里的都是实测过的。
if [ -f "$KNOWN_IDS_CONF" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        # 去注释、去空白。
        _line="$(echo "$_line" | sed 's/#.*//; s/[[:space:]]//g')"
        [ -n "$_line" ] || continue
        _wvid="$(echo "$_line" | cut -d: -f1 | tr 'A-F' 'a-f')"
        _wpid="$(echo "$_line" | cut -d: -f2 | tr 'A-F' 'a-f')"
        [ -n "$_wvid" ] && [ -n "$_wpid" ] || continue
        # 规范化：去掉前导零后比较（sysfs 里是 00001FF7 这种格式）。
        _wvid_n="$(printf '%x' "0x$_wvid" 2>/dev/null || echo "$_wvid")"
        _wpid_n="$(printf '%x' "0x$_wpid" 2>/dev/null || echo "$_wpid")"
        for _devpath in "$HID_SYS"/*; do
            _dev="$(basename "$_devpath")"
            is_generic_bound "$_dev" || continue
            _hid_id="$(sed -n 's/^HID_ID=//p' "$_devpath/uevent" 2>/dev/null | head -1)"
            [ -n "$_hid_id" ] || continue
            _dvid="$(printf '%x' "0x$(echo "$_hid_id" | cut -d: -f2)" 2>/dev/null)"
            _dpid="$(printf '%x' "0x$(echo "$_hid_id" | cut -d: -f3)" 2>/dev/null)"
            if [ "$_dvid" = "$_wvid_n" ] && [ "$_dpid" = "$_wpid_n" ]; then
                move_to_multitouch "$_dev" && _moved=$((_moved + 1))
            fi
        done
    done < "$KNOWN_IDS_CONF"
fi

log "done, moved $_moved device(s) to hid-multitouch"
exit 0
