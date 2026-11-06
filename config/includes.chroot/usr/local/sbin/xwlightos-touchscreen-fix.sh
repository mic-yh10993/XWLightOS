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
# 前置（Build 40 补）：必须先主动加载 hid-multitouch。非标设备的模块
# 别名匹配不上该驱动，内核不会自动加载它；此前脚本直接检查驱动目录，
# 不存在就静默退出，修法等于没跑——这是 Build 39 上修法没起作用的
# 第一嫌疑（全仓库此前没有任何地方加载它）。
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
# 阶段三（第七轮起，用户 2026-11-02 令“开启怪癖模式”）：
#   Build 65/67 真机定案：希沃触屏框开机就原生绑在 hid-multitouch
#   上，阶段一/二在真机上是 moved 0 的 no-op，但持续触摸下
#   evdev 仍 0 字节——断点在 hid-multitouch 到 input 的映射段。
#   改绑带类值的 new_id（mt_probe 按 id->driver_data 选类，第 4
#   字段十六进制解析），再 unbind/bind 触发重 probe，类在 probe
#   期选定。注意：sysfs quirks 属性只能改 quirks 位掩码、改不了
#   类标志，故不能用它代替本阶段。
#   类值沿革：第七轮用 MT_CLS_EXPORT_ALL_INPUTS（0x13）；Build 68
#   真机裁决：改绑生效但触摸窗内六节点仍全 0——导出全部输入这
#   条路走完未打通。第八轮（2026-11-06，用户定“逻辑尽可能对
#   齐 Windows”+ MTConfig.sys 静态核查，证据报告见仓库外评估
#   卡）改用 MT_CLS_WIN_8（0x12）：该类在内核 mt_classes 表里同
#   样带 export_all_inputs=true（不丢第七轮的导出行为），并带
#   Win8 认证设备整套 quirks；mt_probe 对各类都会在 probe 期
#   经 mt_set_modes 给 Input Mode 特征（0x0D/0x52）填 0x02 发
#   SET_REPORT——与 Windows 侧 MTConfig 保证 Input Mode 的
#   SET_FEATURE 送达设备的行为对齐。new_id 写 "3 1ff7 0f26 12"。
#   范围只限已知 ID 名单（通用阶段一的设备不动，防误伤正常触
#   屏）；本启动内已处理过的设备名写 marker，诊断重跑时跳过
#   （/tmp 重启清空，开机服务每启动重做）；重绑失败时用 plain
#   new_id 再绑一次恢复怪癖前状态，绝不留设备无驱动。
#
# 第八轮 root 取证（只读、不改设备状态，与阶段一~三并存）：
#   本脚本开机以 root 运行，正好补上此前诊断的两处权限盲区：
#   (1) rdesc 摘要：debugfs 的 rdesc 普通用户读不到，root 在此
#       解析出 Input Mode 特征所在的报告 ID 与配置集合情况；
#   (2) usbmon：在阶段一~三（含重绑重新 probe）全程抓控制传
#       输，统计发往触屏 gadget 的 SET_REPORT/GET_REPORT 特征
#       请求及完成状态——分清“内核根本没发/发了被拒/发了无效”；
#   (3) hidraw 触摸窗采样：独立服务 xwlightos-touch-hidraw-
#       sampler 以 "sampler" 模式调本脚本，等诊断脚本的窗口
#       标记出现后以 root 并读 0F26 的 hidraw 节点 8 秒。
#   证据一律落 /tmp/xwlightos-touch-evidence/（0666 体例，同
#   LOG_FILE），诊断脚本（普通用户）只读展示。非 root 重跑
#   （诊断触发）时整段跳过，不覆盖开机那次证据。
set -eu

HID_SYS="/sys/bus/hid/devices"
GENERIC_DRV="/sys/bus/hid/drivers/hid-generic"
MULTITOUCH_DRV="/sys/bus/hid/drivers/hid-multitouch"
KNOWN_IDS_CONF="/etc/xwlightos/touchscreen-known-ids.conf"
# 阶段三类值：MT_CLS_WIN_8 = 0x0012（十进制 18；第八轮起，
# 替换第七轮的 MT_CLS_EXPORT_ALL_INPUTS 0x13，理由见文件头）。
QUIRK_CLASS_HEX="12"
QUIRK_CLASS_LABEL="MT_CLS_WIN_8 (0x12)"
QUIRK_MARKER="/tmp/xwlightos-touch-quirks-applied"
# 第八轮 root 取证落点（诊断脚本从这里读，普通用户可读）。
EVDIR="/tmp/xwlightos-touch-evidence"
USBMON_NODE="/sys/kernel/debug/usb/usbmon/0u"

# 日志文件落 /tmp 固定路径（2026-11-01 第五轮附带小修）：本脚本既被
# systemd 服务以 root 身份开机跑，又被触屏诊断脚本以 live 用户身份
# 在登录后重跑——原先写 /var/log/xwlightos-touchscreen-fix.log，开机
# 跑出的文件是 root 属主，live 用户重跑时追加被拒（Build 64 live
# 实测照片：cannot create /var/log/... permission denied），诊断
# 证据留不下。改落 /tmp：两个身份引用同一绝对路径，诊断脚本也从
# 这里读；追加时以 umask 000 建文件，先建者（root 或用户）留下的
# 都是 0666，后来者不会被属主挡住。
LOG_FILE="/tmp/xwlightos-touchscreen-fix.log"

log() {
    echo "xwlightos-touchscreen-fix: $*" >&2
    logger -t xwlightos-touchscreen-fix "$*" 2>/dev/null || true
    # 再写一份普通用户可读的日志：live 用户未必能读系统 journal，
    # 诊断终端靠这个文件看脚本到底跑没跑、跑到哪一步。
    ( umask 000; echo "$(date '+%Y-%m-%d %H:%M:%S') xwlightos-touchscreen-fix: $*" >> "$LOG_FILE" ) 2>/dev/null || true
}

# ---------- 第八轮 root 取证（只读，不改设备状态） ----------
# 证据文件统一经 ev_write 落盘：umask 000 建临时文件再 mv 原子
# 替换，保证诊断脚本（普通用户）读到的永远是完整文件。

ev_write() { # $1=目标文件，内容从 stdin 读
    _f="$1"
    ( umask 000; cat > "$_f.tmp.$$" ) 2>/dev/null || return 0
    mv -f "$_f.tmp.$$" "$_f" 2>/dev/null || true
}

# 设备 uevent 里的 HID_ID 是否命中已知 ID 名单。
ev_is_known_dev() { # $1=uevent 文件路径
    [ -f "$KNOWN_IDS_CONF" ] || return 1
    _hid_id="$(sed -n 's/^HID_ID=//p' "$1" 2>/dev/null | head -1)"
    [ -n "$_hid_id" ] || return 1
    _dvid="$(printf '%x' "0x$(echo "$_hid_id" | cut -d: -f2)" 2>/dev/null)"
    _dpid="$(printf '%x' "0x$(echo "$_hid_id" | cut -d: -f3)" 2>/dev/null)"
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="$(echo "$_line" | sed 's/#.*//; s/[[:space:]]//g')"
        [ -n "$_line" ] || continue
        _wvid="$(printf '%x' "0x$(echo "$_line" | cut -d: -f1 | tr 'A-F' 'a-f')" 2>/dev/null)"
        _wpid="$(printf '%x' "0x$(echo "$_line" | cut -d: -f2 | tr 'A-F' 'a-f')" 2>/dev/null)"
        if [ "$_dvid" = "$_wvid" ] && [ "$_dpid" = "$_wpid" ]; then
            return 0
        fi
    done < "$KNOWN_IDS_CONF"
    return 1
}

# HID 报告描述符解析器（POSIX awk）：stdin 一行十六进制串（无空
# 格、大写），输出应用集合清单、各 Feature 报告的 ID 与 usage
# 清单，末行 "@IM@ <报告ID|none>" 标记 Input Mode 特征
# （Digitizer 页 0x0D、usage 0x52，即内核 HID_DG_INPUTMODE）
# 所在报告。只认短条目；Usage Min/Max 区间覆盖 0x52 时也算。
ev_parse_rdesc() {
    awk '
        function hv(c) { return index("0123456789ABCDEF", c) - 1 }
        function hx(v, w,   s, i, d) { s = ""; for (i = 0; i < w; i++) { d = v % 16; s = substr("0123456789ABCDEF", d + 1, 1) s; v = int(v / 16) } return s }
        BEGIN {
            line = ""; getline line; n = length(line) / 2
            for (i = 0; i < n; i++) B[i] = hv(substr(line, 2 * i + 1, 1)) * 16 + hv(substr(line, 2 * i + 2, 1))
            page = 0; rid = 0; npend = 0; umin = -1; umax = -1
            ncoll = 0; nfeat = 0; imrid = -1
            i = 0
            while (i < n) {
                b = B[i]; bs = b % 4; if (bs == 3) bs = 4
                bt = int(b / 4) % 4; tg = int(b / 16)
                val = 0; m = 1
                for (k = 0; k < bs; k++) { val += B[i + 1 + k] * m; m *= 256 }
                if (bt == 1) {
                    if (tg == 0) page = val
                    else if (tg == 8) rid = val
                } else if (bt == 2) {
                    if (tg == 0) { npend++; pend[npend] = page "," val }
                    else if (tg == 1) umin = val
                    else if (tg == 2) umax = val
                } else if (bt == 0) {
                    if (tg == 10) {
                        if (val == 1 && npend >= 1) { ncoll++; coll[ncoll] = pend[1] }
                        npend = 0; umin = -1; umax = -1
                    } else if (tg == 11 || tg == 8 || tg == 9) {
                        if (tg == 11) {
                            nfeat++; u = ""
                            for (j = 1; j <= npend; j++) {
                                split(pend[j], pv, ",")
                                u = u " " hx(pv[1], 2) "/" hx(pv[2], 4)
                                if (pv[1] == 13 && pv[2] == 82 && imrid < 0) imrid = rid
                            }
                            if (umin >= 0 && page == 13 && umin <= 82 && umax >= 82 && imrid < 0) imrid = rid
                            feat[nfeat] = "Feature 报告ID=" rid " usages:" (u == "" ? " (无显式 usage)" : u)
                        }
                        npend = 0; umin = -1; umax = -1
                    } else if (tg == 12) {
                        npend = 0; umin = -1; umax = -1
                    }
                }
                i += 1 + bs
            }
            c = ""
            for (j = 1; j <= ncoll; j++) { split(coll[j], pv, ","); c = c (j > 1 ? ", " : "") hx(pv[1], 2) "/" hx(pv[2], 4) }
            print "应用集合: " (ncoll ? c : "(未解析到)")
            if (nfeat == 0) print "Feature 报告: (未解析到)"
            for (j = 1; j <= nfeat; j++) print feat[j]
            if (imrid >= 0) print "@IM@ " imrid; else print "@IM@ none"
        }'
}

# rdesc 摘要：对名单内每个 HID 功能读 debugfs rdesc 并解析，
# 汇总出 Input Mode 的总判行（诊断结论第 1 项直接引这一行）。
ev_collect_rdesc() {
    _body="/tmp/.xw-rdesc-body.$$"
    : > "$_body" 2>/dev/null || return 0
    _any=0
    for _devpath in "$HID_SYS"/*; do
        _dev="$(basename "$_devpath")"
        ev_is_known_dev "$_devpath/uevent" || continue
        _any=1
        _name="$(sed -n 's/^HID_NAME=//p' "$_devpath/uevent" 2>/dev/null | head -1)"
        _rd="/sys/kernel/debug/hid/$_dev/rdesc"
        {
            echo "设备 $_dev（$_name）："
            if [ -r "$_rd" ]; then
                _hex="$(tr -d '[:space:]' < "$_rd" 2>/dev/null | tr 'a-f' 'A-F')"
                if [ -n "$_hex" ]; then
                    echo "  rdesc 全长 $(( ${#_hex} / 2 )) 字节"
                    printf '%s' "$_hex" | ev_parse_rdesc | sed 's/^/  /'
                else
                    echo "  rdesc 读到空内容"
                fi
            else
                echo "  rdesc 读不到（debugfs 未挂载或文件不存在）"
            fi
        } >> "$_body" 2>/dev/null
    done
    _imrid="$(sed -n 's/.*@IM@ //p' "$_body" 2>/dev/null | grep -v '^none$' | head -1)"
    if [ -n "$_imrid" ]; then
        _imline="InputMode: 有 报告ID=$_imrid"
    elif [ "$_any" = 1 ] && grep -q 'rdesc 全长' "$_body" 2>/dev/null; then
        _imline="InputMode: 无（已解析的 rdesc 里没有 Input Mode 特征）"
    elif [ "$_any" = 1 ]; then
        _imline="InputMode: 未知（rdesc 读不到）"
    else
        _imline="InputMode: 未知（没找到名单内设备）"
    fi
    {
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S')（root 在开机修复后采集）"
        echo "$_imline"
        grep -v '@IM@' "$_body" 2>/dev/null
    } | ev_write "$EVDIR/rdesc-summary.txt"
    rm -f "$_body"
    log "evidence: rdesc summary written ($_imline)"
}

USBM_PID=""

# usbmon 抓取开始：定位触屏 gadget 的 USB 总线/地址，抓 0u 全
# 总线流（事后按 bus/addr 过滤）。只在摘要不存在时抓——保住开
# 机那次（阶段三重绑的重新 probe 就发生在这段时间里）。
ev_usbmon_start() {
    [ -f "$EVDIR/usbmon-summary.txt" ] && return 0
    _bus=""; _addr=""
    for _devpath in "$HID_SYS"/*; do
        ev_is_known_dev "$_devpath/uevent" || continue
        _full="$(readlink -f "$_devpath" 2>/dev/null)"
        [ -n "$_full" ] || continue
        _iface="${_full%/*}"
        _usbdev="${_iface%/*}"
        if [ -f "$_usbdev/busnum" ] && [ -f "$_usbdev/devnum" ]; then
            _bus="$(cat "$_usbdev/busnum" 2>/dev/null)"
            _addr="$(cat "$_usbdev/devnum" 2>/dev/null)"
        fi
        [ -n "$_bus" ] && [ -n "$_addr" ] && break
    done
    if [ -z "$_bus" ] || [ -z "$_addr" ]; then
        {
            echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
            echo "方法：不可用（定位不到触屏 gadget 的 USB 总线/地址）"
            echo "SET_REPORT_FEATURE: 未知"
            echo "GET_REPORT_FEATURE: 未知"
        } | ev_write "$EVDIR/usbmon-summary.txt"
        return 0
    fi
    echo "$_bus $_addr" | ev_write "$EVDIR/.usbmon-target"
    if [ ! -e "$USBMON_NODE" ]; then
        modprobe usbmon 2>/dev/null || true
        if [ ! -e "$USBMON_NODE" ] && [ ! -d /sys/kernel/debug/usb ]; then
            mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
        fi
    fi
    if [ -e "$USBMON_NODE" ]; then
        ( timeout 45 cat "$USBMON_NODE" 2>/dev/null | head -c 16777216 > "$EVDIR/usbmon.raw" 2>/dev/null ) &
        USBM_PID=$!
        log "evidence: usbmon capture started (bus $_bus addr $_addr)"
    else
        {
            echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
            echo "方法：不可用（usbmon 节点缺失，modprobe 与 debugfs 挂载均未奏效）"
            echo "SET_REPORT_FEATURE: 未知"
            echo "GET_REPORT_FEATURE: 未知"
        } | ev_write "$EVDIR/usbmon-summary.txt"
    fi
}

# usbmon 抓取结束并汇总：统计发往 gadget 的 HID 类请求——
# SET_REPORT（bmRequestType 21、bRequest 09，wValue 高字节
# 03=Feature）与 GET_REPORT（a1/01），以及控制输出传输的完成
# 状态集合（0=成功，负数=被拒，如 -32=STALL）。
ev_usbmon_stop() {
    [ -n "$USBM_PID" ] || return 0
    kill "$USBM_PID" 2>/dev/null || true
    wait "$USBM_PID" 2>/dev/null || true
    USBM_PID=""
    sleep 1
    _raw="$EVDIR/usbmon.raw"
    _tgt="$EVDIR/.usbmon-target"
    [ -f "$_raw" ] && [ -f "$_tgt" ] || return 0
    _bus="$(cut -d' ' -f1 "$_tgt" 2>/dev/null)"
    _addr="$(cut -d' ' -f2 "$_tgt" 2>/dev/null)"
    _addr3="$(printf '%03d' "$_addr" 2>/dev/null)"
    _pat=":${_bus}:${_addr3}:"
    _stats="$(awk -v pat="$_pat" '
        index($4, pat) > 0 && $3 == "S" && $5 == "s" && $6 == "21" && $7 == "09" { setall++; if (substr($8, 1, 2) == "03") { setfeat++; ids = ids " " $8 } }
        index($4, pat) > 0 && $3 == "S" && $5 == "s" && $6 == "a1" && $7 == "01" { getall++; if (substr($8, 1, 2) == "03") getfeat++ }
        index($4, pat) > 0 && $3 == "C" && $4 ~ /^Co:/ { st[$5] = 1 }
        END {
            ss = ""; for (s in st) ss = ss " " s
            print "SET_REPORT_FEATURE: 提交=" (setfeat + 0) " wValue列表:" (ids == "" ? " 无" : ids)
            print "SET_REPORT_ALL: 提交=" (setall + 0)
            print "GET_REPORT_FEATURE: 提交=" (getfeat + 0)
            print "CONTROL_OUT_STATUS:" (ss == "" ? " 无完成记录" : ss)
        }' "$_raw" 2>/dev/null)"
    {
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "方法：usbmon（$USBMON_NODE，开机修复全程含阶段三重绑重 probe；目标 bus $_bus addr $_addr）"
        echo "$_stats"
        echo "SET_REPORT 样本行（原始 usbmon，最多 4 条）："
        grep -F "$_pat" "$_raw" 2>/dev/null | grep ' s 21 09 ' | head -4 | sed 's/^/  /'
    } | ev_write "$EVDIR/usbmon-summary.txt"
    log "evidence: usbmon summary written"
}

# hidraw 触摸窗采样（sampler 模式，由 xwlightos-touch-hidraw-
# sampler.service 以 root 调用）：等诊断脚本在采样窗开始时创
# 建的窗口标记，出现就对名单内设备的全部 hidraw 节点并读
# 8 秒（与诊断第 7/8 节同一个窗口），结果原子写入
# hidraw-root.txt。每启动只采一次（锁目录防重复）。
run_hidraw_sampler() {
    ( umask 000; mkdir -p "$EVDIR" ) 2>/dev/null || true
    mkdir "$EVDIR/.sampler-lock" 2>/dev/null || return 0
    _marker="$EVDIR/diag-window-open"
    _result="$EVDIR/hidraw-root.txt"
    _i=0
    while [ "$_i" -lt 1500 ]; do
        [ -e "$_marker" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    if [ ! -e "$_marker" ]; then
        {
            echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
            echo "状态：等待诊断窗口超时（25 分钟未见窗口标记），未采样"
        } | ev_write "$_result"
        return 0
    fi
    _nodes=""
    for _hd in /sys/class/hidraw/hidraw*; do
        [ -e "$_hd/device/uevent" ] || continue
        if ev_is_known_dev "$_hd/device/uevent" || grep -qiE 'HID_NAME=.*(CVTE|Touch)' "$_hd/device/uevent" 2>/dev/null; then
            _nodes="$_nodes $(basename "$_hd")"
        fi
    done
    _td="/tmp/.xw-hidraw-sample.$$"
    mkdir -p "$_td" 2>/dev/null || return 0
    for _n in $_nodes; do
        if [ -r "/dev/$_n" ]; then
            timeout 8 cat "/dev/$_n" > "$_td/$_n" 2>/dev/null &
        fi
    done
    wait
    {
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S')（与诊断第 7/8 节同一个触摸窗口，root 采样）"
        if [ -z "$_nodes" ]; then
            echo "状态：没有找到名单内设备的 hidraw 节点"
        else
            for _n in $_nodes; do
                if [ -f "$_td/$_n" ]; then
                    echo "$_n=$(wc -c < "$_td/$_n" | tr -d ' ') 字节"
                else
                    echo "$_n=不可读（root 采样亦未读到）"
                fi
            done
        fi
    } | ev_write "$_result"
    rm -rf "$_td"
}

# sampler 模式分发：只跑 hidraw 采样，不动修复主流程。
if [ "${1:-}" = "sampler" ]; then
    run_hidraw_sampler
    exit 0
fi

# 先主动加载 hid-multitouch（见文件头注释），再检查驱动目录。
modprobe hid-multitouch 2>/dev/null || true
[ -d "$MULTITOUCH_DRV" ] || {
    log "hid-multitouch driver not present after modprobe, nothing to do"
    exit 0
}
[ -d "$HID_SYS" ] || {
    log "$HID_SYS missing, nothing to do"
    exit 0
}

# 第八轮取证（仅 root 开机运行；诊断以普通用户重跑时跳过整
# 段，不覆盖开机证据）：usbmon 先开，盖住后面全部阶段——阶
# 段三重绑触发的重新 probe 里 mt_set_modes 若发 SET_REPORT，
# 就发生在这段时间。rdesc 与 usbmon 汇总在收尾处做。
if [ "$(id -u)" = "0" ]; then
    ( umask 000; mkdir -p "$EVDIR" ) 2>/dev/null || true
    ev_usbmon_start
fi

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

# 设备是否正被 hid-multitouch 驱动。
is_multitouch_bound() {
    _dev="$1"
    _drvlink="$HID_SYS/$_dev/driver"
    [ -L "$_drvlink" ] || return 1
    [ "$(readlink "$_drvlink")" = "../../drivers/hid-multitouch" ] || \
    [ "$(basename "$(readlink -f "$_drvlink" 2>/dev/null)")" = "hid-multitouch" ]
}

# 阶段三单设备：把已绑 hid-multitouch 的已知 ID 设备改绑
# QUIRK_CLASS_HEX 指定的类（第八轮为 MT_CLS_WIN_8）。
# 参数：sysfs 设备名。
# 调用者保证：设备当前绑 hid-multitouch、ID 在名单里。
apply_mt_class_quirk() {
    _dev="$1"
    _uevent="$HID_SYS/$_dev/uevent"
    [ -f "$_uevent" ] || return 0

    _hid_id="$(sed -n 's/^HID_ID=//p' "$_uevent" | head -1)"
    [ -n "$_hid_id" ] || return 0
    _bus="$(echo "$_hid_id" | cut -d: -f1)"
    _vid="$(echo "$_hid_id" | cut -d: -f2)"
    _pid="$(echo "$_hid_id" | cut -d: -f3)"
    _bus_h="$(printf '%x' "0x$_bus" 2>/dev/null || echo "$_bus")"
    _vid_h="$(printf '%x' "0x$_vid" 2>/dev/null || echo "$_vid")"
    _pid_h="$(printf '%x' "0x$_pid" 2>/dev/null || echo "$_pid")"
    _name="$(sed -n 's/^HID_NAME=//p' "$_uevent" | head -1)"

    # 重绑前该名字在输入设备里的节点数（保留作类切换前后的
    # 中性对照；WIN_8 与 EXPORT_ALL 都带 export_all_inputs，
    # 节点数不作本轮成败判据）。
    _before="$(grep -cF "Name=\"$_name\"" /proc/bus/input/devices 2>/dev/null || true)"
    [ -n "$_before" ] || _before=0

    # 1. 注册带类值的 id（已注册过会报 exists，忽略）。
    echo "$_bus_h $_vid_h $_pid_h $QUIRK_CLASS_HEX" > "$MULTITOUCH_DRV/new_id" 2>/dev/null || true
    # 2. 解绑。
    if ! echo "$_dev" > "$MULTITOUCH_DRV/unbind" 2>/dev/null; then
        log "quirks: unbind $_dev ($_name) from hid-multitouch failed, skip"
        return 0
    fi
    # 3. 重绑：probe 按 new_id 的 driver_data 选类。
    if echo "$_dev" > "$MULTITOUCH_DRV/bind" 2>/dev/null; then
        _after="$(grep -cF "Name=\"$_name\"" /proc/bus/input/devices 2>/dev/null || true)"
        [ -n "$_after" ] || _after=0
        log "quirks: $_dev ($_name) rebound to hid-multitouch with $QUIRK_CLASS_LABEL, input nodes ${_before}->${_after}"
        ( umask 000; echo "$_dev" >> "$QUIRK_MARKER" ) 2>/dev/null || true
        _quirked=$((_quirked + 1))
    else
        log "quirks: bind $_dev ($_name) with class failed, restoring plain binding"
        echo "$_bus_h $_vid_h $_pid_h" > "$MULTITOUCH_DRV/new_id" 2>/dev/null || true
        if echo "$_dev" > "$MULTITOUCH_DRV/bind" 2>/dev/null; then
            log "quirks: $_dev ($_name) restored to hid-multitouch without class"
        else
            log "quirks: RESTORE FAILED for $_dev ($_name), device left unbound (needs replug/reboot)"
        fi
    fi
    return 0
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

# ---- 阶段三：已知 ID 怪癖类（第七轮）----
# 只对名单里的设备、且当前已绑 hid-multitouch 的做。本启动内
# 已处理过的设备名在 marker 里，诊断重跑时跳过（/tmp 重启清空，
# 开机服务每启动重做）。阶段一/二先跑完：hid-generic 上的名单
# 设备被挪过来后，本循环正好接住它。
_quirked=0
if [ -f "$KNOWN_IDS_CONF" ]; then
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="$(echo "$_line" | sed 's/#.*//; s/[[:space:]]//g')"
        [ -n "$_line" ] || continue
        _wvid="$(echo "$_line" | cut -d: -f1 | tr 'A-F' 'a-f')"
        _wpid="$(echo "$_line" | cut -d: -f2 | tr 'A-F' 'a-f')"
        [ -n "$_wvid" ] && [ -n "$_wpid" ] || continue
        _wvid_n="$(printf '%x' "0x$_wvid" 2>/dev/null || echo "$_wvid")"
        _wpid_n="$(printf '%x' "0x$_wpid" 2>/dev/null || echo "$_wpid")"
        for _devpath in "$HID_SYS"/*; do
            _dev="$(basename "$_devpath")"
            is_multitouch_bound "$_dev" || continue
            _hid_id="$(sed -n 's/^HID_ID=//p' "$_devpath/uevent" 2>/dev/null | head -1)"
            [ -n "$_hid_id" ] || continue
            _dvid="$(printf '%x' "0x$(echo "$_hid_id" | cut -d: -f2)" 2>/dev/null)"
            _dpid="$(printf '%x' "0x$(echo "$_hid_id" | cut -d: -f3)" 2>/dev/null)"
            if [ "$_dvid" = "$_wvid_n" ] && [ "$_dpid" = "$_wpid_n" ]; then
                if [ -f "$QUIRK_MARKER" ] && grep -qxF "$_dev" "$QUIRK_MARKER" 2>/dev/null; then
                    log "quirks: $_dev already quirked this boot, skip"
                    continue
                fi
                apply_mt_class_quirk "$_dev"
            fi
        done
    done < "$KNOWN_IDS_CONF"
fi

# 第八轮取证收尾（root）：阶段三重绑已完成，此刻的 rdesc 是
# 改绑后的描述符；usbmon 停抓并汇总。
if [ "$(id -u)" = "0" ]; then
    ev_collect_rdesc
    ev_usbmon_stop
fi

log "done, moved $_moved device(s) to hid-multitouch, quirked $_quirked device(s)"
exit 0
