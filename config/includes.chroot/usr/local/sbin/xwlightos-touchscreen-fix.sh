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
#
# 第九轮（2026-11-06，用户令“先改再测、尽可能一次搞定”）：
# 对齐 Windows 打包，一次做完五件（接受归因变粗，第八轮取证
# 全保留使失败仍可分岔）：
#   1. 阶段三 WIN_8 类保持，不回退。
#   2. 阶段四 MI_01 隔离：Windows 诊断原文里 0F26 的 MI_01
#      接口状态是 Error、未启动成功（其下无任何已启动集合，
#      配置集合与触摸集合都在 MI_00），即 Windows 根本不对
#      该接口发起会话；Linux 却完整绑定它。本阶段在阶段三
#      后把 :1.1 接口下的 HID 子设备解绑并保持无驱动，复刻
#      这个“不启动”状态。双重校验防误伤 MI_00（接口目录名
#      以 :1.1 结尾且 bInterfaceNumber=01 才动手）。
#   3. usbhid 少提问：出货 /etc/modprobe.d/xwlightos-touch-
#      quirks.conf 给 usbhid 加 HID_QUIRK_NOGET（BIT(3)=
#      0x8）与 HID_QUIRK_NO_INIT_REPORTS（BIT(29)=
#      0x20000000），合并掩码 0x20000008——位值按出货内核
#      6.1 同世代源码 include/linux/hid.h 核实；语义是
#      usbhid_start 不再调 usbhid_init_reports 在枚举期批量
#      GET_REPORT、内核据 NOGET 跳过对该设备的 GET。
#   4. 阶段六 Input Mode 的 SET 重试送达：见 stage6 函数头。
#   5. 阶段五关名单设备的 USB autosuspend（power/control
#      钉 on 并回读）。
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
# 第九轮新增路径常量（阶段四/五/六与 quirks 回读用）。
USB_SYS="/sys/bus/usb/devices"
HID_DRIVERS="/sys/bus/hid/drivers"
HIDRAW_SYS="/sys/class/hidraw"
HIDRAW_DEVDIR="/dev"
DEBUG_HID_DIR="/sys/kernel/debug/hid"
USBHID_QUIRKS_PARAM="/sys/module/usbhid/parameters/quirks"

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
# 所在报告，其后 "@IMLEN@ <字节数|none>" 给出该报告的
# Feature 数据总字节长（不含报告 ID 字节；第九轮阶段六构造
# SET 载荷补零长度用，位长按 Report Size×Count 逐 Feature
# 条目累计）。只认短条目；Usage Min/Max 区间覆盖 0x52 时也算。
ev_parse_rdesc() {
    awk '
        function hv(c) { return index("0123456789ABCDEF", c) - 1 }
        function hx(v, w,   s, i, d) { s = ""; for (i = 0; i < w; i++) { d = v % 16; s = substr("0123456789ABCDEF", d + 1, 1) s; v = int(v / 16) } return s }
        BEGIN {
            line = ""; getline line; n = length(line) / 2
            for (i = 0; i < n; i++) B[i] = hv(substr(line, 2 * i + 1, 1)) * 16 + hv(substr(line, 2 * i + 2, 1))
            page = 0; rid = 0; npend = 0; umin = -1; umax = -1
            rsz = 0; rcnt = 0
            ncoll = 0; nfeat = 0; imrid = -1
            i = 0
            while (i < n) {
                b = B[i]; bs = b % 4; if (bs == 3) bs = 4
                bt = int(b / 4) % 4; tg = int(b / 16)
                val = 0; m = 1
                for (k = 0; k < bs; k++) { val += B[i + 1 + k] * m; m *= 256 }
                if (bt == 1) {
                    if (tg == 0) page = val
                    else if (tg == 7) rsz = val
                    else if (tg == 8) rid = val
                    else if (tg == 9) rcnt = val
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
                            fbits[rid] += rsz * rcnt
                            feat[nfeat] = "Feature 报告ID=" rid " 位长=" (rsz * rcnt) " usages:" (u == "" ? " (无显式 usage)" : u)
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
            if (imrid >= 0) print "@IMLEN@ " int((fbits[imrid] + 7) / 8); else print "@IMLEN@ none"
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
        _rd="$DEBUG_HID_DIR/$_dev/rdesc"
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

# ---------- 第九轮对齐包（阶段四/五/六，只在 root 下执行） ----------
# 阶段四/五/六的结论行经 align_note 汇成 ALIGN_NOTES，收尾时
# 由 ev_write_align_status 与 quirks 回读一起落 align-status.txt。
ALIGN_NOTES=""
align_note() { ALIGN_NOTES="${ALIGN_NOTES}$1
"; }

# USB 设备目录是否命中已知 ID 名单：idVendor/idProduct 与名单
# 逐项比对（十六进制、忽略前导零与大小写）。接口目录没有
# idVendor 文件，天然被排除，不会把接口误当设备。
usbdev_is_known() { # $1=USB 设备 sysfs 目录
    [ -f "$KNOWN_IDS_CONF" ] || return 1
    [ -f "$1/idVendor" ] && [ -f "$1/idProduct" ] || return 1
    _uv="$(printf '%x' "0x$(cat "$1/idVendor" 2>/dev/null)" 2>/dev/null)"
    _up="$(printf '%x' "0x$(cat "$1/idProduct" 2>/dev/null)" 2>/dev/null)"
    [ -n "$_uv" ] && [ -n "$_up" ] || return 1
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line="$(echo "$_line" | sed 's/#.*//; s/[[:space:]]//g')"
        [ -n "$_line" ] || continue
        _wvid="$(printf '%x' "0x$(echo "$_line" | cut -d: -f1 | tr 'A-F' 'a-f')" 2>/dev/null)"
        _wpid="$(printf '%x' "0x$(echo "$_line" | cut -d: -f2 | tr 'A-F' 'a-f')" 2>/dev/null)"
        if [ "$_uv" = "$_wvid" ] && [ "$_up" = "$_wpid" ]; then
            return 0
        fi
    done < "$KNOWN_IDS_CONF"
    return 1
}

# 阶段四（第九轮）：MI_01 隔离。识别以 sysfs 实物结构为准：
# 名单命中的 USB 设备 → 其 :1.1 接口（目录名以 :1.1 结尾且
# bInterfaceNumber=01，双重校验防误伤触控集合所在的 MI_00）
# → 接口之下的 HID 子设备（0003:*），从其当前驱动解绑且不
# 重绑。解绑后本脚本后续流程不会再认领它：阶段一/二只动
# hid-generic 已绑设备、阶段三只动 hid-multitouch 已绑设
# 备，无驱动设备两者都不碰。已无驱动 = 已隔离（幂等跳过）。
stage4_isolate_mi01() {
    [ "$(id -u)" = "0" ] || return 0
    _found=0
    for _usbdev in "$USB_SYS"/*; do
        usbdev_is_known "$_usbdev" || continue
        for _iface in "$_usbdev":*; do
            [ -f "$_iface/bInterfaceNumber" ] || continue
            [ "$(cat "$_iface/bInterfaceNumber" 2>/dev/null)" = "01" ] || continue
            case "$(basename "$_iface")" in
                *:1.1) ;;
                *) continue ;;
            esac
            _found=1
            _any=0
            for _hiddev in "$_iface"/0003:*; do
                [ -e "$_hiddev/uevent" ] || continue
                _any=1
                _hname="$(basename "$_hiddev")"
                if [ -L "$_hiddev/driver" ]; then
                    _dtarget="$(readlink -f "$_hiddev/driver" 2>/dev/null || true)"
                    _drv=""
                    if [ -n "$_dtarget" ]; then
                        _drv="$(basename "$_dtarget")"
                    fi
                    if [ -n "$_drv" ] && echo "$_hname" > "$HID_DRIVERS/$_drv/unbind" 2>/dev/null; then
                        log "stage4: isolated MI_01 device $_hname (unbound from $_drv, left driverless, matching the Windows unstarted state)"
                        align_note "MI_01隔离：$_hname 已从 $_drv 解绑并保持无驱动"
                    else
                        log "stage4: unbind $_hname from ${_drv:-unknown} FAILED"
                        align_note "MI_01隔离：$_hname 解绑失败（原驱动 ${_drv:-未知}）"
                    fi
                else
                    log "stage4: MI_01 device $_hname already driverless, isolation already in effect"
                    align_note "MI_01隔离：$_hname 已无驱动（隔离已生效，跳过）"
                fi
            done
            if [ "$_any" = 0 ]; then
                align_note "MI_01隔离：接口 $(basename "$_iface") 在位但其下无 HID 子设备"
            fi
        done
    done
    if [ "$_found" = 0 ]; then
        align_note "MI_01隔离：未找到名单设备的 :1.1 接口（设备不在位或结构不同）"
    fi
}

# 阶段五（第九轮）：关名单设备的 USB autosuspend——把该 USB
# 设备的 power/control 钉在 on 并回读记录，避免 gadget 在
# 会话期间被自动挂起打断（桌面电源管理若其后改写，诊断回
# 读会如实呈现）。
stage5_autosuspend_off() {
    [ "$(id -u)" = "0" ] || return 0
    _any=0
    for _usbdev in "$USB_SYS"/*; do
        usbdev_is_known "$_usbdev" || continue
        _pc="$_usbdev/power/control"
        [ -f "$_pc" ] || continue
        _any=1
        echo on > "$_pc" 2>/dev/null || true
        _rb="$(cat "$_pc" 2>/dev/null)"
        log "stage5: autosuspend off for $(basename "$_usbdev"), power/control readback=${_rb:-unknown}"
        align_note "autosuspend：$(basename "$_usbdev") power/control 回读=${_rb:-读不到}（on=已关自动挂起）"
    done
    if [ "$_any" = 0 ]; then
        align_note "autosuspend：未定位到名单设备的 power/control（设备不在位）"
    fi
}

# 在名单设备的 rdesc 里定位 Input Mode 特征：stdout 输出
# "<HID设备名> <报告ID> <Feature数据字节长>"，找不到输出空。
# 多个功能都带 Input Mode 时优先 USB interface 0（:1.0，
# Windows 证据里配置集合 COL05 所在的接口）。
find_input_mode_target() {
    _fb_dev=""; _fb_rid=""; _fb_len=""
    for _devpath in "$HID_SYS"/*; do
        _dev="$(basename "$_devpath")"
        ev_is_known_dev "$_devpath/uevent" || continue
        _rd="$DEBUG_HID_DIR/$_dev/rdesc"
        [ -r "$_rd" ] || continue
        _hex="$(tr -d '[:space:]' < "$_rd" 2>/dev/null | tr 'a-f' 'A-F')"
        [ -n "$_hex" ] || continue
        _parsed="$(printf '%s' "$_hex" | ev_parse_rdesc)"
        _rid="$(printf '%s\n' "$_parsed" | sed -n 's/^@IM@ //p' | head -1)"
        [ -n "$_rid" ] && [ "$_rid" != "none" ] || continue
        _rlen="$(printf '%s\n' "$_parsed" | sed -n 's/^@IMLEN@ //p' | head -1)"
        [ -n "$_rlen" ] && [ "$_rlen" != "none" ] || _rlen=0
        _full="$(readlink -f "$_devpath" 2>/dev/null || true)"
        case "$_full" in
            *:1.0/*) echo "$_dev $_rid $_rlen"; return 0 ;;
        esac
        if [ -z "$_fb_dev" ]; then
            _fb_dev="$_dev"; _fb_rid="$_rid"; _fb_len="$_rlen"
        fi
    done
    if [ -n "$_fb_dev" ]; then
        echo "$_fb_dev $_fb_rid $_fb_len"
    fi
    return 0
}

# 某 HID 功能的 hidraw 节点路径：阶段三改绑后 hidraw 节点会
# 消失再重建，最多等 10 秒（1 秒一轮）；stdout 输出节点路
# 径，超时输出空。
wait_hidraw_node() { # $1=HID 设备名
    _i=0
    while [ "$_i" -lt 10 ]; do
        for _hd in "$HIDRAW_SYS"/hidraw*; do
            [ -e "$_hd/device" ] || continue
            _tgt="$(readlink -f "$_hd/device" 2>/dev/null || true)"
            if [ "$(basename "$_tgt")" = "$1" ]; then
                echo "$HIDRAW_DEVDIR/$(basename "$_hd")"
                return 0
            fi
        done
        sleep 1
        _i=$((_i + 1))
    done
    return 0
}

# 阶段六（第九轮）：Input Mode 的 SET 按 Windows 式重试送达。
# 内核 mt_set_modes 在 probe 期本应发出同一帧 SET_REPORT，
# 但前八轮证据始终无法证明它真到了设备；MTConfig.sys 的静
# 态核查显示 Windows 为这一帧专门做了“拦截留存+重投、失败
# 重试至共 3 次”的保证送达。本阶段在用户态复刻这个行为：
# 载荷完全由设备自身报告描述符派生（报告 ID 与报告长来自
# 本脚本的 rdesc 解析；值 0x02 是内核 HID_DG_INPUTMODE 的
# 触摸屏模式值，与 mt_set_modes 填的值相同；其余字节补
# 零），经 hidraw 的 HIDIOCSFEATURE 发往含 Input Mode 特征
# 的那个 HID 功能，最多 3 次、间隔 300ms，逐次结果与终局
# 判行记 ev_setfeature.txt。不使用 MTConfig 的任何内部控
# 制码。python3 为镜像内现成解释器（Build 68 构建日志与桌
# 面包单 python3-gi 依赖可证），ioctl 请求值按 uapi
# include/uapi/linux/hidraw.h 的 HIDIOCSFEATURE(len) 定义
# 在 Python 内构造。安排在 usbmon 抓取窗口内执行（收尾的
# ev_usbmon_stop 之前），与内核 probe 期的传输可同窗对照。
stage6_set_input_mode() {
    _evf="$EVDIR/ev_setfeature.txt"
    _target="$(find_input_mode_target)"
    if [ -z "$_target" ]; then
        {
            echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
            echo "SET重试结果：未执行（rdesc 里定位不到 Input Mode 特征，见 rdesc-summary.txt）"
        } | ev_write "$_evf"
        align_note "SET重试：未执行（定位不到 Input Mode 特征）"
        return 0
    fi
    _dev="$(printf '%s' "$_target" | cut -d' ' -f1)"
    _rid="$(printf '%s' "$_target" | cut -d' ' -f2)"
    _rlen="$(printf '%s' "$_target" | cut -d' ' -f3)"
    _lenfix=""
    if [ "$_rlen" -lt 1 ] 2>/dev/null; then
        _rlen=1
        _lenfix="（报告长解析为 0，按 Input Mode 单字节字段的最小长 1 处理）"
    fi
    _buflen="$_rlen"
    if [ "$_rid" -gt 0 ] 2>/dev/null; then
        _buflen=$((_rlen + 1))
    fi
    _node="$(wait_hidraw_node "$_dev")"
    if [ -z "$_node" ]; then
        {
            echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
            echo "目标：$_dev 的 Input Mode 报告ID=$_rid"
            echo "SET重试结果：未执行（等 $_dev 的 hidraw 节点 10 秒未出现）"
        } | ev_write "$_evf"
        align_note "SET重试：未执行（$_dev 的 hidraw 节点未出现）"
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        {
            echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
            echo "目标：$_node（$_dev），Input Mode 报告ID=$_rid"
            echo "SET重试结果：未执行（镜像内无 python3，HIDIOCSFEATURE 通道不可用）"
        } | ev_write "$_evf"
        align_note "SET重试：未执行（无 python3）"
        return 0
    fi
    _pytmp="/tmp/.xw-setfeature.$$"
    python3 - "$_node" "$_rid" "$_buflen" > "$_pytmp" 2>&1 <<'PYEOF' || true
import fcntl, os, sys, time
path = sys.argv[1]
rid = int(sys.argv[2])
buflen = int(sys.argv[3])
buf = bytearray(buflen)
if rid > 0:
    buf[0] = rid
    if buflen > 1:
        buf[1] = 0x02
else:
    buf[0] = 0x02
# HIDIOCSFEATURE(len) = _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)
# 出处：include/uapi/linux/hidraw.h（出货内核 6.1 同世代）。
req = (3 << 30) | (buflen << 16) | (0x48 << 8) | 0x06
print("PAYLOAD " + bytes(buf).hex())
if os.environ.get("XW_TOUCH_SETFEATURE_DRYRUN") == "1":
    print("ATTEMPT 1: DRYRUN ret=%d" % buflen)
    print("RESULT DELIVERED attempt=1 (dryrun)")
    sys.exit(0)
try:
    fd = os.open(path, os.O_RDWR)
except OSError as e:
    print("OPEN_FAIL errno=%d %s" % (e.errno, e.strerror))
    print("RESULT FAILED open")
    sys.exit(0)
delivered = 0
for att in range(1, 4):
    try:
        ret = fcntl.ioctl(fd, req, bytes(buf), False)
        if ret == buflen:
            print("ATTEMPT %d: OK ret=%d" % (att, ret))
            delivered = att
            break
        print("ATTEMPT %d: PARTIAL ret=%s expected=%d" % (att, ret, buflen))
    except OSError as e:
        print("ATTEMPT %d: FAIL errno=%d %s" % (att, e.errno, e.strerror))
    if att < 3:
        time.sleep(0.3)
os.close(fd)
if delivered:
    print("RESULT DELIVERED attempt=%d" % delivered)
else:
    print("RESULT FAILED attempts=3")
PYEOF
    _pyout="$(cat "$_pytmp" 2>/dev/null || true)"
    rm -f "$_pytmp"
    _verdict="$(printf '%s\n' "$_pyout" | sed -n 's/^RESULT //p' | head -1)"
    case "$_verdict" in
        DELIVERED*) _vline="SET重试结果：已送达（$_verdict）" ;;
        FAILED*) _vline="SET重试结果：失败（$_verdict）" ;;
        *) _vline="SET重试结果：失败（python 无 RESULT 行，详见下方原始输出）" ;;
    esac
    {
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "目标：$_dev 的 hidraw 节点 $_node，Input Mode 报告ID=$_rid，Feature 数据长=$_rlen 字节，缓冲长=$_buflen 字节$_lenfix"
        printf '%s\n' "$_pyout"
        echo "$_vline"
    } | ev_write "$_evf"
    log "stage6: Input Mode SET on $_node (device $_dev, report id $_rid): $_vline"
    align_note "$_vline"
}

# 对齐包状态汇总（root 收尾）：阶段三类值 + 阶段四/五/六结
# 论行 + usbhid quirks 的开机回读，一份文件供诊断第 17 节
# 与结论区第 3 项引用。quirks 回读是出货 modprobe.d 是否真
# 生效的第一手判据（文件写了不等于模块参数里有）。
ev_write_align_status() {
    # 注意：cat 读不到时必须 || true 兜底——赋值语句的退出码取
    # 命令替换的退出码，set -e 下裸失败会把整个脚本在这里杀
    # 掉（干跑实测：收尾的 usbmon 汇总与 done 日志会被连带吃
    # 掉）。readlink 的几处命令替换同理。
    _qk="$(cat "$USBHID_QUIRKS_PARAM" 2>/dev/null || true)"
    [ -n "$_qk" ] || _qk="读不到（usbhid 未加载或参数文件不存在）"
    {
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S')（root 在开机修复后汇总）"
        echo "对齐包（第九轮）：阶段三类值 $QUIRK_CLASS_LABEL，本轮改绑台数=$_quirked（为 0 时可能已由 marker 跳过，详见诊断第 15 节）"
        printf '%s' "$ALIGN_NOTES"
        echo "usbhid quirks 开机回读：$_qk"
    } | ev_write "$EVDIR/align-status.txt"
    log "evidence: align status written"
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

# ---- 阶段四/五（第九轮对齐包）：MI_01 隔离 + 关 autosuspend ----
# 都在阶段三改绑完成后跑；函数内自检 root，普通用户重跑自
# 动跳过（不重复动设备、不产生权限噪声）。
stage4_isolate_mi01
stage5_autosuspend_off

# 第八轮取证收尾 + 第九轮 SET 送达（root）：阶段三重绑已完
# 成，此刻的 rdesc 是改绑后的描述符；阶段六的 SET 安排在
# usbmon 停抓之前发出（仍在抓取窗口内，与内核 probe 期的
# 传输同窗对照）；对齐包状态最后汇总。
if [ "$(id -u)" = "0" ]; then
    ev_collect_rdesc
    stage6_set_input_mode
    ev_write_align_status
    ev_usbmon_stop
fi

log "done, moved $_moved device(s) to hid-multitouch, quirked $_quirked device(s)"
exit 0
