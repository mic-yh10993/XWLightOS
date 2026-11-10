#!/usr/bin/env python3
# xwlightos-touch-bypass.py -- CVTE 触屏 hidraw -> uinput 绕过服务（第十轮，Build 71）
#
# 背景：希沃 T86EA 的 CVTE 触屏（1FF7:0F26）在 Linux 下 hid-multitouch
# 收到报告却一个 evdev 事件都不出（Build 65/68/70 三轮真机全 0）。
# 但 /dev/hidraw0 在触摸时确实吐出标准多点触控报告（用户 2026-11-09
# 深度诊断 + 2026-11-10 补充数据，主对话已解出格式）。本服务绕开
# 内核驱动：直接读 hidraw，按已解格式解码报告 2，再经 uinput 注入
# 给系统。设备不用改、驱动不用动、不发 Input Mode SET（设备默认
# 就在发报告）。
#
# 叠加、不是取代（用户 2026-11-10 10:29 邮件，最高优先级）：
#   本服务只补触摸报告（报告号 2）这一条路。鼠标（报告 1）、笔
#   （报告 0x10/0x11）、键盘（报告 7）、系统控制（报告 8）等仍由
#   内核 hid-multitouch 驱动负责——脚本做不到完全替代系统驱动，
#   所以按用户规则就不允许取代：绝对不要全局黑名单 hid_multitouch，
#   内核驱动保持原样绑定；udev 规则只匹配 1FF7:0F26，其他设备一律
#   不动；服务只打开该设备的 hidraw 节点。hidraw 读数不抢占内核
#   驱动的报告流（同一报告同时走 hid core 与 hidraw 两路）。
#
# 报告格式（已核实，见 round10 评估卡）：
#   报告 2，每帧 62 字节：6 手指 x 10 字节（状态 1 + 编号 1 +
#   X/Y/宽/高各 2，小端）+ 末尾 1 字节接触数；X/Y 逻辑范围 0-32767。
#   状态字节 bit0=Tip（按下）、bit1=InRange、bit2=Confidence；
#   空位 = 状态 0、编号 0xFF、全零；过渡帧有状态 0x04（仅
#   Confidence）的手指，接触数把它也算在内——判按下只看 Tip 位。
#
# reuse-check: hidraw 节点发现复用诊断/修复脚本的模式（扫
#   /sys/class/hidraw/hidraw*，读 device/uevent 匹配 HID_ID
#   00001FF7:00000F26）；解码格式与主对话样本解析同一来源
#   （supplement 2026-11-10，18 帧零失同步）；uinput 常量按
#   linux/uinput.h，ioctl 号现场算出并在单测里与已知值核对。
#   无第三方依赖，纯标准库。

import ctypes
import fcntl
import os
import struct
import sys
import time

VID = 0x1FF7
PID = 0x0F26
REPORT_ID_TOUCH = 0x02
REPORT_TOUCH_LEN = 62          # 1（报告号）+ 6*10（手指）+ 1（接触数）
FINGERS = 6
FINGER_BYTES = 10
EMPTY_CONTACT_ID = 0xFF
X_MAX = 32767
Y_MAX = 32767

HIDRAW_SYS = "/sys/class/hidraw"
UINPUT_DEV = "/dev/uinput"
DEVICE_NAME = b"CVTE Touch Device"

# ---- uinput ioctl（linux/uinput.h；_IOW('U', nr, type) 现场算出）----
# UI_SET_EVBIT  = _IOW('U', 100, int) = 0x40045564
# UI_SET_KEYBIT = _IOW('U', 101, int) = 0x40045565
# UI_SET_ABSBIT = _IOW('U', 103, int) = 0x40045567
# UI_SET_PROPBIT= _IOW('U', 109, int) = 0x4004556D
# UI_DEV_SETUP  = _IOW('U', 3, struct uinput_setup) = 0x405C5503
# UI_ABS_SETUP  = _IOW('U', 4, struct uinput_abs_setup) = 0x401C5504
# UI_DEV_CREATE = _IO('U', 1) = 0x5501 ; UI_DEV_DESTROY = _IO('U', 2) = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_SET_PROPBIT = 0x4004556D
UI_DEV_SETUP = 0x405C5503
UI_ABS_SETUP = 0x401C5504
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN = 0x00
EV_KEY = 0x01
EV_ABS = 0x03
SYN_REPORT = 0
BTN_TOUCH = 0x14A
ABS_MT_SLOT = 0x2F
ABS_MT_TOUCH_MAJOR = 0x30
ABS_MT_TOUCH_MINOR = 0x31
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
ABS_MT_PRESSURE = 0x3A
INPUT_PROP_DIRECT = 0x01
BUS_USB = 0x03

# struct uinput_setup: input_id{bustype,vendor,product,version}(8) +
# name[80] + ff_effects_max(u32) = 92 字节
UINPUT_SETUP_FMT = "<HHHH80sI"
# struct uinput_abs_setup: code(u16) + pad(u16) + input_absinfo{6*s32} = 28 字节
UINPUT_ABS_SETUP_FMT = "<HH6i"
# struct input_event: timeval{sec,usec}(16) + type(u16) + code(u16) + value(s32) = 24 字节
INPUT_EVENT_FMT = "<QQHHi"


def log(msg):
    print("[xwlightos-touch-bypass] %s %s" % (
        time.strftime("%Y-%m-%d %H:%M:%S"), msg), flush=True)


def u16le(buf, off):
    return buf[off] | (buf[off + 1] << 8)


def decode_report2(frame):
    """解一帧报告 2（62 字节）。返回 [(flags, contact_id, x, y, w, h), ...]（6 指）
    或 None（报告号/长度不对）。纯函数，可单测。"""
    if len(frame) != REPORT_TOUCH_LEN or frame[0] != REPORT_ID_TOUCH:
        return None
    fingers = []
    for i in range(FINGERS):
        o = 1 + i * FINGER_BYTES
        fingers.append((frame[o], frame[o + 1],
                        u16le(frame, o + 2), u16le(frame, o + 4),
                        u16le(frame, o + 6), u16le(frame, o + 8)))
    return fingers


def parse_descriptor_input_lengths(desc):
    """迷你 HID 描述符解析器：只算各报告号的 Input 位数。
    返回 {report_id: input_bits}。用于从候选 hidraw 节点里挑出
    含 61 字节触摸报告 2 的那个（MI_00 与 MI_01 共用 VID:PID）。"""
    out = {}
    i = 0
    report_id = 0
    report_size = 0
    report_count = 0
    n = len(desc)
    while i < n:
        b = desc[i]
        i += 1
        if b == 0xFE:  # 长项目
            if i >= n:
                break
            ln = desc[i]
            i += 1 + ln
            continue
        size = b & 0x03
        size = 4 if size == 3 else size
        typ = (b >> 2) & 0x03
        tag = (b >> 4) & 0x0F
        val = int.from_bytes(desc[i:i + size], "little") if size else 0
        i += size
        if typ == 0:  # 主项目
            if tag == 0x08:  # Input
                out[report_id] = out.get(report_id, 0) + report_size * report_count
        elif typ == 1:  # 全局项目
            if tag == 0x07:
                report_size = val
            elif tag == 0x08:
                report_id = val
            elif tag == 0x09:
                report_count = val
    return out


def find_touch_hidraw():
    """找触屏的 hidraw 节点（/dev/hidrawN）。返回节点名或 None。
    先按 VID:PID 筛候选，再读各候选的 report_descriptor，挑含
    61 字节输入报告 2 的；无匹配则退回第一个 VID:PID 候选。"""
    candidates = []
    try:
        nodes = sorted(os.listdir(HIDRAW_SYS))
    except OSError:
        return None
    for node in nodes:
        uevent = os.path.join(HIDRAW_SYS, node, "device", "uevent")
        try:
            with open(uevent, "r", errors="ignore") as f:
                text = f.read()
        except OSError:
            continue
        if "00001FF7:00000F26" not in text.upper():
            continue
        candidates.append(node)
    if not candidates:
        return None
    for node in candidates:
        rdesc = os.path.join(HIDRAW_SYS, node, "device", "report_descriptor")
        try:
            with open(rdesc, "rb") as f:
                desc = f.read()
        except OSError:
            continue
        try:
            lengths = parse_descriptor_input_lengths(desc)
        except Exception:
            continue
        if lengths.get(REPORT_ID_TOUCH, 0) == (REPORT_TOUCH_LEN - 1) * 8:
            return node
    log("警告：%d 个 1FF7:0F26 hidraw 节点都没有 61 字节报告 2，用第一个候选 %s"
        % (len(candidates), candidates[0]))
    return candidates[0]


class UInputTouch:
    """uinput 多点触控设备。write_event 可被单测替换（注入假接收端）。"""

    def __init__(self, path=UINPUT_DEV):
        self.fd = os.open(path, os.O_RDWR)
        self._setup()

    def _ioctl(self, req, arg):
        fcntl.ioctl(self.fd, req, arg)

    def _setup(self):
        self._ioctl(UI_SET_EVBIT, struct.pack("i", EV_SYN))
        self._ioctl(UI_SET_EVBIT, struct.pack("i", EV_KEY))
        self._ioctl(UI_SET_EVBIT, struct.pack("i", EV_ABS))
        self._ioctl(UI_SET_KEYBIT, struct.pack("i", BTN_TOUCH))
        for code in (ABS_MT_SLOT, ABS_MT_TOUCH_MAJOR, ABS_MT_TOUCH_MINOR,
                     ABS_MT_POSITION_X, ABS_MT_POSITION_Y,
                     ABS_MT_TRACKING_ID, ABS_MT_PRESSURE):
            self._ioctl(UI_SET_ABSBIT, struct.pack("i", code))
        self._ioctl(UI_SET_PROPBIT, struct.pack("i", INPUT_PROP_DIRECT))
        setup = struct.pack(UINPUT_SETUP_FMT, BUS_USB, VID, PID, 0x0100,
                            DEVICE_NAME, 0)
        assert len(setup) == 92, "uinput_setup 长度应为 92，实为 %d" % len(setup)
        self._ioctl(UI_DEV_SETUP, setup)
        for code, lo, hi in (
                (ABS_MT_SLOT, 0, FINGERS - 1),
                (ABS_MT_TRACKING_ID, -1, 65535),
                (ABS_MT_POSITION_X, 0, X_MAX),
                (ABS_MT_POSITION_Y, 0, Y_MAX),
                (ABS_MT_TOUCH_MAJOR, 0, 32767),
                (ABS_MT_TOUCH_MINOR, 0, 32767),
                (ABS_MT_PRESSURE, 0, 2047)):
            abs_setup = struct.pack(UINPUT_ABS_SETUP_FMT, code, 0,
                                    0, lo, hi, 0, 0, 0)
            assert len(abs_setup) == 28, "uinput_abs_setup 长度应为 28"
            self._ioctl(UI_ABS_SETUP, abs_setup)
        self._ioctl(UI_DEV_CREATE, 0)

    def write_event(self, etype, code, value):
        now = time.time()
        sec = int(now)
        usec = int((now - sec) * 1000000)
        data = struct.pack(INPUT_EVENT_FMT, sec, usec, etype, code, value)
        os.write(self.fd, data)

    def close(self):
        try:
            self._ioctl(UI_DEV_DESTROY, 0)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


class TouchBypass:
    """状态机：维护 6 个 MT 槽，把解出的手指映射为 uinput 事件。"""

    def __init__(self, uinput):
        self.uinput = uinput
        self.slot_contact = [None] * FINGERS  # slot -> contact id
        self.frames = 0
        self.ignored_reports = 0
        self.bad_frames = 0
        self.count_mismatch = 0
        self.count_mismatch_logged = False
        self.first_frame_logged = False

    def handle_frame(self, frame):
        fingers = decode_report2(frame)
        if fingers is None:
            self.bad_frames += 1
            return False
        self.frames += 1
        # 本帧按下的接触：{contact_id: (x, y, w, h)}，只看 Tip 位，跳过 0xFF
        active = {}
        for flags, cid, x, y, w, h in fingers:
            if (flags & 0x01) and cid != EMPTY_CONTACT_ID:
                active[cid] = (x, y, w, h)
        # 接触数字节只做校验：与 Tip 手指数不一致时记一次（设备把
        # 状态 0x04 的过渡指也算在内，属已知行为，不影响状态机）
        contact_count = frame[REPORT_TOUCH_LEN - 1]
        if contact_count != len(active):
            self.count_mismatch += 1
            if not self.count_mismatch_logged:
                log("注意：接触数字节=%d，Tip 手指数=%d（设备把 0x04 过渡指也算在内，"
                    "状态机只认 Tip 位）" % (contact_count, len(active)))
                self.count_mismatch_logged = True
        if not self.first_frame_logged:
            log("首帧已解：接触数=%d，手指=%s" % (contact_count, sorted(active.items())))
            self.first_frame_logged = True
        # 释放消失的接触（只发一次 TRACKING_ID=-1）
        for slot in range(FINGERS):
            cid = self.slot_contact[slot]
            if cid is not None and cid not in active:
                self._emit_slot_release(slot)
                self.slot_contact[slot] = None
        # 给新出现的接触分空槽（按报告内出现顺序）
        for cid, (x, y, w, h) in active.items():
            if cid not in self.slot_contact:
                free = next((s for s in range(FINGERS)
                             if self.slot_contact[s] is None), None)
                if free is None:
                    continue  # 6 槽已满，丢弃多余接触
                self.slot_contact[free] = cid
        # 每帧发全部活动槽的状态 + BTN_TOUCH + SYN
        any_active = False
        for slot in range(FINGERS):
            cid = self.slot_contact[slot]
            if cid is None:
                continue
            x, y, w, h = active[cid]
            any_active = True
            u = self.uinput
            u.write_event(EV_ABS, ABS_MT_SLOT, slot)
            u.write_event(EV_ABS, ABS_MT_TRACKING_ID, cid)
            u.write_event(EV_ABS, ABS_MT_POSITION_X, x)
            u.write_event(EV_ABS, ABS_MT_POSITION_Y, y)
            u.write_event(EV_ABS, ABS_MT_TOUCH_MAJOR, max(w, h))
            u.write_event(EV_ABS, ABS_MT_TOUCH_MINOR, min(w, h))
            u.write_event(EV_ABS, ABS_MT_PRESSURE, 1)
        self.uinput.write_event(EV_KEY, BTN_TOUCH, 1 if any_active else 0)
        self.uinput.write_event(EV_SYN, SYN_REPORT, 0)
        return True

    def _emit_slot_release(self, slot):
        u = self.uinput
        u.write_event(EV_ABS, ABS_MT_SLOT, slot)
        u.write_event(EV_ABS, ABS_MT_TRACKING_ID, -1)

    def release_all(self):
        for slot in range(FINGERS):
            if self.slot_contact[slot] is not None:
                self._emit_slot_release(slot)
                self.slot_contact[slot] = None
        self.uinput.write_event(EV_KEY, BTN_TOUCH, 0)
        self.uinput.write_event(EV_SYN, SYN_REPORT, 0)


def wait_for_uinput(timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(UINPUT_DEV):
            return True
        time.sleep(0.5)
    return os.path.exists(UINPUT_DEV)


def main():
    log("启动：CVTE 触屏 hidraw->uinput 绕过服务（报告 2，62 字节/帧）")
    if not wait_for_uinput():
        log("错误：%s 在 30 秒内未出现（uinput 模块未加载？），退出" % UINPUT_DEV)
        return 1
    try:
        uinput = UInputTouch()
    except OSError as e:
        log("错误：打开 %s 失败：%s" % (UINPUT_DEV, e))
        return 1
    log("uinput 设备已创建：%s" % DEVICE_NAME.decode())
    bypass = TouchBypass(uinput)
    last_stats = time.time()
    try:
        while True:
            node = find_touch_hidraw()
            if node is None:
                time.sleep(2)
                continue
            log("找到触屏 hidraw 节点：/dev/%s" % node)
            try:
                fd = os.open("/dev/" + node, os.O_RDONLY)
            except OSError as e:
                log("打开 /dev/%s 失败：%s，2 秒后重试" % (node, e))
                time.sleep(2)
                continue
            try:
                while True:
                    try:
                        data = os.read(fd, 4096)
                    except OSError as e:
                        log("读 /dev/%s 出错：%s，重新发现设备" % (node, e))
                        break
                    if not data:
                        log("/dev/%s 读到空，重新发现设备" % node)
                        break
                    if data[0] == REPORT_ID_TOUCH:
                        bypass.handle_frame(data)
                    else:
                        bypass.ignored_reports += 1
                        if bypass.ignored_reports <= 3:
                            log("忽略非触摸报告：号=0x%02X，长=%d" % (data[0], len(data)))
                    now = time.time()
                    if now - last_stats >= 300:
                        log("统计：帧=%d，忽略报告=%d，坏帧=%d，接触数不一致=%d"
                            % (bypass.frames, bypass.ignored_reports,
                               bypass.bad_frames, bypass.count_mismatch))
                        last_stats = now
            finally:
                bypass.release_all()
                os.close(fd)
    except KeyboardInterrupt:
        log("收到中断，退出")
    finally:
        try:
            bypass.release_all()
        except Exception:
            pass
        uinput.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
