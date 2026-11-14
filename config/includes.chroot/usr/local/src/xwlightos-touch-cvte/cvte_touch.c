// XWLightOS: CVTE 触屏（1FF7:0F26）hidraw -> uinput 绕过服务。
//
// reuse-check: 复用来源是用户在真机上验证跑通的 DeepSeek C 程序
// （~/workspace/seewo-touch-sound-20261110/触屏/第二次触摸修复/持久化/cvte_touch.c，
// Build 70 + 该程序触屏已跑通）。照搬的部分：sysfs uevent 扫描找 1FF7:0F26 的
// hidraw 节点；只解报告 2（62 字节，6 指 x 10 字节）；Tip 位（bit0）判按下，
// InRange 不算按下；INPUT_PROP_DIRECT；逐指抬起发 TRACKING_ID=-1；断开重连；
// 设备名 "CVTE Touch Emulator"、VID:PID 1FF7:0F26、X/Y 0-32767。
//
// reuse-check: 改动一处（原程序隐患）：原程序拿设备接触编号直接当数组下标
// （active_slots[contact_id]，表只有 6 格），编号 >= 6 会越界写内存。
// 本版改为“编号映射到空槽 0-5”：tracking ID 仍用设备编号原值，槽位由本
// 程序本地分配；编号 255（空位标记）跳过；6 槽全满时多余手指丢弃，绝不越界。
//
// 叠加、不是取代（用户 2026-11-10 10:29 硬约束）：本程序只补触摸报告（报告
// 号 2）这一条路；鼠标/笔/键盘/系统控制仍由内核 hid-multitouch 驱动负责。
// 本镜像不装任何 blacklist hid_multitouch，内核驱动原样绑定。
// 构建期由 1620 钩子用 gcc 编译成本文件，产物 /usr/local/bin/cvte_touch。
//
// 本地测试：编译时定义 CVTE_TOUCH_TEST，则 main() 与 emit() 不编入，
// 测试文件提供自己的 emit()（记录事件）与 main()，再 #include 本文件，
// 直接调 process_report2() / flush_pending_releases() /
// bypass_decision() 验解码、槽位映射、防抖与首次启动观测（见 round16 测试）。
//
// 第 12 轮（Build 73）：防抖（Tip 闪烁不再变两次点击，见 CVTE_DEBOUNCE_MS
// 与 flush_pending_releases）；首次创建 uinput 后调通知脚本一次
// （/usr/local/bin/xwlightos-touch-bypass-notify，尽力而为）。
//
// 第 16 轮（用户 2026-11-14 三次拍板）：
// （1）内核守卫已删除（用户 18:25 裁决：持续监视浪费性能；内核驱动即使
// 能出事件也可能触摸偏移，让路给偏移的驱动更糟）。兜底一旦开启就一直
// 开着，不再监视内核节点、不再自动让路。找内核 MT 节点与读事件的函数
// 保留，但只在首次启动观测里调用，主循环里不再有任何内核节点读取。
// 权衡：某台硬件内核驱动真出事件时可能双份输入；目标硬件（希沃 T86EA /
// CVTE 1FF7:0F26）实测内核事件字节=0，此风险在目标硬件上不存在。
// （2）30 秒首次启动观测（用户 18:22/18:27）：开机后 30 秒内没有任何
// 触屏输入（内核 MT 节点的触摸事件）才自动开启兜底；只做 LiveCD 每次
// 开机 + 装好系统的首次启动，之后开机只尊重服务本身的启用/禁用状态。
// 靠 stamp 文件区分：/var/lib/xwlightos/touch-bypass-first-boot，内容
// 为 bypass 或 kernel；LiveCD 的 /var 不持久，每次开机都没有 stamp，
// 所以每次都跑观测；装好的系统首次启动跑完就建 stamp，之后开机跳过。
// 无论观测结果是开启还是不开启，都建 stamp（决策已做过，不重复判断）。
// 手动在设置里打开时 stamp 必已存在，立即开启、无 30 秒延迟；若 stamp
// 是 kernel，手动开启的助手脚本先把它改写成 bypass（用户显式选择压过
// 自动决策）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <linux/uinput.h>
#include <linux/input.h>

#define CVTE_MAX_SLOTS 6
#define CVTE_REPORT_ID_TOUCH 2
#define CVTE_REPORT_LEN 62
#define CVTE_CONTACT_NONE 0xFF
/* 第 12 轮（Build 73）防抖：Tip 位由 1 变 0 时不立刻发抬起，先挂起一个
   宽限期。依据（见 round12 评估卡 §2.3）：设备报告率约 60Hz，一次闪烁
   通常 1–2 帧（17–34ms），60ms 盖住 3 帧有余量；人类有意双击间隔通常
   ≥150ms，60ms 不会合并两次有意点击；抬起延迟 60ms 低于约 100ms 的
   可察觉阈值。按下本身不延迟，响应零影响。 */
#define CVTE_DEBOUNCE_MS 60
/* 第 16 轮：首次启动观测窗口（毫秒）。开机后 30 秒内没有任何内核触摸
   事件，才自动开启兜底。出货值 30 秒；测试时 bypass_decision() 的
   observe_ms 参数可传短值。 */
#define CVTE_OBSERVE_WINDOW_MS 30000
/* 第 16 轮：首次启动决策 stamp。内容 bypass = 兜底已判需要（之后开机
   直接开启，不再观测）；kernel = 内核驱动已判能用（之后开机直接退出，
   不开启）。LiveCD 的 /var 不持久，每次开机都没有 stamp，所以每次都
   跑观测；装好的系统首次启动跑完就建 stamp，之后开机跳过。 */
#define CVTE_FIRST_BOOT_STAMP "/var/lib/xwlightos/touch-bypass-first-boot"
/* 观测轮询间隔（毫秒）：200ms 足够密（触摸事件不会 200ms 内来又走），
   又不会让观测期的 CPU 空转有存在感。 */
#define CVTE_OBSERVE_POLL_MS 200

struct touch_state {
    /* 每槽当前占用的设备接触编号，-1 = 空槽。tracking ID 用设备编号原值。 */
    int slot_contact[CVTE_MAX_SLOTS];
    /* 挂起抬起的到期时刻（单调时钟毫秒），0 = 未挂起。挂起期间槽仍被占用，
       宽限期内同一编号重新按下视为同一次触摸（不发抬起、不重发按下）。 */
    long slot_release_at_ms[CVTE_MAX_SLOTS];
};

static void touch_state_init(struct touch_state *st)
{
    int i;
    for (i = 0; i < CVTE_MAX_SLOTS; i++) {
        st->slot_contact[i] = -1;
        st->slot_release_at_ms[i] = 0;
    }
}

/* 单调时钟毫秒（防抖与首次启动观测用；不受系统时间调整影响）。
   第 16 轮起测试构建也用它（观测函数直接调 now_ms 判截止时间，
   测试传短窗口即可），故不再包进 #ifndef；两个构建里都有调用方，
   -Werror 下不会 unused-function。解码/防抖测试仍用测试注入的
   假时钟（process_report2/flush_pending_releases 的 now 参数）。 */
static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

#ifndef CVTE_TOUCH_TEST
void emit(int fd, int type, int code, int val) {
    struct input_event ie;
    memset(&ie, 0, sizeof(ie));
    ie.type = type;
    ie.code = code;
    ie.value = val;
    if (write(fd, &ie, sizeof(ie)) < 0) {
        /* uinput 写失败（如设备已销毁）不致命：主循环会在下次重连。 */
    }
}
#else
/* 测试构建：emit() 由测试文件提供（记录事件，不写真实 fd）。 */
void emit(int fd, int type, int code, int val);
#endif

/* 处理一帧触摸报告（报告号 2，62 字节）。now_ms 为调用方传入的单调时钟
   毫秒（测试时可注入假时钟）。返回 1 = 已处理并同步一帧，
   0 = 不是触摸报告或长度不足（调用方跳过）。 */
static int process_report2(const unsigned char *buf, int n, int uinput_fd,
                           struct touch_state *st, long now)
{
    int i, s;
    int touching_contact[CVTE_MAX_SLOTS];
    int touching_x[CVTE_MAX_SLOTS];
    int touching_y[CVTE_MAX_SLOTS];
    int n_touching = 0;
    int any_touch = 0;

    if (n < CVTE_REPORT_LEN || buf[0] != CVTE_REPORT_ID_TOUCH)
        return 0;

    /* 先收集本帧所有按下中的手指（只看 Tip 位 bit0；InRange 不算按下）。 */
    for (i = 0; i < CVTE_MAX_SLOTS; i++) {
        int offset = 1 + (i * 10);
        unsigned char status;
        unsigned char contact_id;
        int x, y;

        if (offset + 10 > n)
            break;
        status = buf[offset];
        contact_id = buf[offset + 1];
        /* reuse-check: 空位标记 255 绝不进槽位表（原程序靠状态位顺带跳过，
           这里显式跳过，避免状态位异常时越界）。 */
        if (!(status & 0x01) || contact_id == CVTE_CONTACT_NONE)
            continue;
        x = (unsigned char)buf[offset + 2] | ((unsigned char)buf[offset + 3] << 8);
        y = (unsigned char)buf[offset + 4] | ((unsigned char)buf[offset + 5] << 8);
        touching_contact[n_touching] = contact_id;
        touching_x[n_touching] = x;
        touching_y[n_touching] = y;
        n_touching++;
    }

    /* 按下：编号映射到槽（已有则复用，无则取首个空槽；满了则丢弃该指）。 */
    for (i = 0; i < n_touching; i++) {
        int slot = -1;
        for (s = 0; s < CVTE_MAX_SLOTS; s++) {
            if (st->slot_contact[s] == touching_contact[i]) {
                slot = s;
                break;
            }
        }
        if (slot < 0) {
            for (s = 0; s < CVTE_MAX_SLOTS; s++) {
                if (st->slot_contact[s] == -1) {
                    slot = s;
                    break;
                }
            }
        }
        if (slot < 0)
            continue; /* 6 槽全满：丢弃该指，绝不越界。 */
        /* 第 12 轮防抖：宽限期内同一编号重新按下 = 同一次触摸的闪烁，
           取消挂起的抬起（槽从未释放，不重发 TRACKING_ID）。 */
        st->slot_release_at_ms[slot] = 0;
        emit(uinput_fd, EV_ABS, ABS_MT_SLOT, slot);
        if (st->slot_contact[slot] == -1) {
            /* 新按下的触点才分配 TRACKING_ID（用设备编号原值）。 */
            emit(uinput_fd, EV_ABS, ABS_MT_TRACKING_ID, touching_contact[i]);
            st->slot_contact[slot] = touching_contact[i];
        }
        emit(uinput_fd, EV_ABS, ABS_MT_POSITION_X, touching_x[i]);
        emit(uinput_fd, EV_ABS, ABS_MT_POSITION_Y, touching_y[i]);
        any_touch = 1;
    }

    /* 抬起：第 12 轮防抖——本帧已不在按下的槽不立刻释放，只挂起一个
       宽限期（到期由 flush_pending_releases() 真释放；宽限期内重按
       即取消挂起）。挂起期间槽仍被占用，BTN_TOUCH 保持 1。 */
    for (s = 0; s < CVTE_MAX_SLOTS; s++) {
        int still_down = 0;
        if (st->slot_contact[s] == -1 || st->slot_release_at_ms[s] != 0)
            continue;
        for (i = 0; i < n_touching; i++) {
            if (touching_contact[i] == st->slot_contact[s]) {
                still_down = 1;
                break;
            }
        }
        if (!still_down)
            st->slot_release_at_ms[s] = now + CVTE_DEBOUNCE_MS;
    }

    /* 挂起的槽仍算按下（否则一次闪烁会让 BTN_TOUCH 先 0 后 1，
       桌面照样看到两次点击）。 */
    for (s = 0; s < CVTE_MAX_SLOTS; s++) {
        if (st->slot_contact[s] != -1)
            any_touch = 1;
    }

    emit(uinput_fd, EV_KEY, BTN_TOUCH, any_touch);
    emit(uinput_fd, EV_SYN, SYN_REPORT, 0);
    return 1;
}

/* 到期的挂起抬起：发 TRACKING_ID=-1、释槽；若无槽占用则 BTN_TOUCH=0。
   返回 1 = 发了事件（含 SYN），0 = 无到期项。主循环每轮都调（有报告
   与空闲都调），避免报告流停后抬起永远发不出去。 */
static int flush_pending_releases(int uinput_fd, struct touch_state *st,
                                  long now)
{
    int s, any = 0, flushed = 0;
    for (s = 0; s < CVTE_MAX_SLOTS; s++) {
        if (st->slot_contact[s] == -1 || st->slot_release_at_ms[s] == 0)
            continue;
        if (now < st->slot_release_at_ms[s])
            continue;
        emit(uinput_fd, EV_ABS, ABS_MT_SLOT, s);
        emit(uinput_fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
        st->slot_contact[s] = -1;
        st->slot_release_at_ms[s] = 0;
        flushed = 1;
    }
    if (!flushed)
        return 0;
    for (s = 0; s < CVTE_MAX_SLOTS; s++) {
        if (st->slot_contact[s] != -1)
            any = 1;
    }
    emit(uinput_fd, EV_KEY, BTN_TOUCH, any);
    emit(uinput_fd, EV_SYN, SYN_REPORT, 0);
    return 1;
}

/* 第 12 轮由内核守卫引入，第 16 轮起只供首次启动观测用：找同一 HID
   设备下内核驱动的 MT 触摸节点。扫描 /sys/bus/hid/devices/ 找
   1FF7:0F26 设备，再进其 input/input* 找 event* 节点，用 EVIOCGBIT
   甄别带 ABS_MT_SLOT 能力的节点（只认触摸节点，避免把鼠标/笔节点
   误认）。返回已打开的 fd（O_RDONLY | O_NONBLOCK），找不到返回 -1
   （观测期内可重试；30 秒都找不到按“无内核触摸输入”处理）。
   注意：只读打开不抢事件——evdev 向所有打开的 fd 广播，GNOME/
   libinput 照常收到触摸事件。 */
int find_kernel_touch_evdev() {
    DIR *dir, *idir, *edir;
    struct dirent *ent, *ient, *eent;
    char path[512], evpath[512];
    unsigned long abs_bits[(ABS_MAX + 1 + 63) / 64];
    int fd = -1;

    if ((dir = opendir("/sys/bus/hid/devices")) == NULL)
        return -1;
    while ((ent = readdir(dir)) != NULL) {
        if (strstr(ent->d_name, "1FF7") == NULL ||
            strstr(ent->d_name, "0F26") == NULL)
            continue;
        snprintf(path, sizeof(path), "/sys/bus/hid/devices/%.64s/input",
                 ent->d_name);
        if ((idir = opendir(path)) == NULL)
            continue;
        while ((ient = readdir(idir)) != NULL) {
            char ipath[512];
            if (strncmp(ient->d_name, "input", 5) != 0)
                continue;
            snprintf(ipath, sizeof(ipath), "%.384s/%.64s", path, ient->d_name);
            if ((edir = opendir(ipath)) == NULL)
                continue;
            while ((eent = readdir(edir)) != NULL) {
                int efd;
                if (strncmp(eent->d_name, "event", 5) != 0)
                    continue;
                snprintf(evpath, sizeof(evpath), "/dev/%.32s", eent->d_name);
                efd = open(evpath, O_RDONLY | O_NONBLOCK);
                if (efd < 0)
                    continue;
                memset(abs_bits, 0, sizeof(abs_bits));
                if (ioctl(efd, EVIOCGBIT(EV_ABS, sizeof(abs_bits)),
                          abs_bits) >= 0 &&
                    (abs_bits[ABS_MT_SLOT / 64] &
                     (1UL << (ABS_MT_SLOT % 64)))) {
                    fd = efd;
                    closedir(edir);
                    closedir(idir);
                    closedir(dir);
                    return fd;
                }
                close(efd);
            }
            closedir(edir);
        }
        closedir(idir);
    }
    closedir(dir);
    return -1;
}

/* 第 12 轮由内核守卫引入，第 16 轮起只供首次启动观测用：从内核 MT
   节点 fd 非阻塞读事件。读到 MT 触摸事件（ABS_MT_* 或 BTN_TOUCH）
   返回 1 = 内核驱动能出触摸事件。笔事件（ABS_X/Y、BTN_TOOL_PEN）
   与非触摸事件不算。无事件返回 0。读到的数据全部排空，避免旧事件
   堆积。fd<0 时返回 0。读出错（errno 非 EAGAIN，如节点被 rebind
   销毁）时返回 -1（若本轮已读到事件则仍返回 1），调用方据此重找
   节点。 */
int kernel_touch_event_seen(int fd)
{
    struct input_event ev;
    int seen = 0;
    ssize_t n;

    if (fd < 0)
        return 0;
    for (;;) {
        n = read(fd, &ev, sizeof(ev));
        if (n < 0) {
            if (errno == EAGAIN)
                break;
            /* 非 EAGAIN 的读错：fd 已死。已读到事件则算见过。 */
            return seen ? 1 : -1;
        }
        if (n != (ssize_t)sizeof(ev))
            break;
        if (ev.type == EV_ABS &&
            (ev.code == ABS_MT_SLOT || ev.code == ABS_MT_TRACKING_ID ||
             ev.code == ABS_MT_POSITION_X || ev.code == ABS_MT_POSITION_Y ||
             ev.code == ABS_MT_TOUCH_MAJOR || ev.code == ABS_MT_TOUCH_MINOR ||
             ev.code == ABS_MT_WIDTH_MAJOR || ev.code == ABS_MT_WIDTH_MINOR ||
             ev.code == ABS_MT_PRESSURE))
            seen = 1;
        if (ev.type == EV_KEY && ev.code == BTN_TOUCH)
            seen = 1;
    }
    return seen;
}

/* 第 16 轮：读首次启动决策 stamp。1 = bypass（兜底已判需要），
   0 = kernel（内核驱动已判能用），-1 = 无 stamp / 读失败 / 内容非法。 */
static int read_bypass_stamp(const char *stamp_path)
{
    FILE *f = fopen(stamp_path, "r");
    char line[32];
    int r = -1;

    if (!f)
        return -1;
    if (fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = '\0';
        if (strcmp(line, "bypass") == 0)
            r = 1;
        else if (strcmp(line, "kernel") == 0)
            r = 0;
    }
    fclose(f);
    return r;
}

/* 第 16 轮：写首次启动决策 stamp（decision 为 "bypass" 或 "kernel"）。
   返回 0 = 写好，-1 = 失败（调用方按“无 stamp”继续，下次开机重判；
   失败不影响本次决策本身）。父目录不存在则逐级建（mkdir -p；只建
   一级不够——/var/lib/xwlightos 若整条不存在，一级 mkdir 会失败，
   本地先验 round16 用例 1 实测抓到过）。 */
static int write_bypass_stamp(const char *stamp_path, const char *decision)
{
    FILE *f;
    const char *slash = strrchr(stamp_path, '/');

    if (slash && slash != stamp_path) {
        char dirbuf[512];
        size_t len = (size_t)(slash - stamp_path);
        size_t i;
        if (len < sizeof(dirbuf)) {
            memcpy(dirbuf, stamp_path, len);
            dirbuf[len] = '\0';
            for (i = 1; i < len; i++) {
                if (dirbuf[i] == '/') {
                    dirbuf[i] = '\0';
                    mkdir(dirbuf, 0755); /* 已存在则忽略。 */
                    dirbuf[i] = '/';
                }
            }
            mkdir(dirbuf, 0755); /* 已存在则忽略。 */
        }
    }
    f = fopen(stamp_path, "w");
    if (!f)
        return -1;
    if (fprintf(f, "%s\n", decision) < 0) {
        fclose(f);
        return -1;
    }
    if (fclose(f) != 0)
        return -1;
    return 0;
}

/* 第 16 轮：在已打开的内核 MT 节点 fd 上观测到 deadline_ms（单调时钟
   毫秒）为止。返回 1 = 读到内核触摸事件，0 = 到时无事件，
   -1 = fd 出错（调用方应重找节点）。 */
static int observe_kernel_fd(int fd, long deadline_ms)
{
    for (;;) {
        int r = kernel_touch_event_seen(fd);
        if (r != 0)
            return r; /* 1 = 见过事件；-1 = fd 已死。 */
        if (now_ms() >= deadline_ms)
            return 0;
        usleep(CVTE_OBSERVE_POLL_MS * 1000);
    }
}

/* 第 16 轮首次启动决策。返回 1 = 开启兜底，0 = 不开启（内核驱动能用）。
   stamp_path：决策 stamp 路径；observe_ms：无 stamp 时的观测窗口毫秒
   （出货值 CVTE_OBSERVE_WINDOW_MS，测试可传短值）；inject_fd：测试注入
   （>=0 时当作内核节点 fd 用，不扫 sysfs；生产传 -1）。
   逻辑：stamp 为 bypass → 立即返回 1；为 kernel → 立即返回 0；
   无 stamp/非法 → 观测 observe_ms：读到内核触摸事件 → 写 kernel、
   返回 0；到时无事件（或节点始终未出现）→ 写 bypass、返回 1。
   节点中途被重建（fd 出错）时关闭重找，窗口继续计时。 */
int bypass_decision(const char *stamp_path, int observe_ms, int inject_fd)
{
    int r = read_bypass_stamp(stamp_path);
    long deadline;
    int kfd = -1;
    int own_fd = 0;

    if (r == 1)
        return 1;
    if (r == 0)
        return 0;
    deadline = now_ms() + observe_ms;
    if (inject_fd >= 0) {
        kfd = inject_fd;
        own_fd = 0;
    }
    for (;;) {
        int seen;
        if (kfd < 0) {
            kfd = find_kernel_touch_evdev();
            own_fd = 1;
            if (kfd < 0) {
                /* 节点尚未出现（驱动绑定晚于服务启动）：等到截止。 */
                if (now_ms() >= deadline)
                    break;
                usleep(CVTE_OBSERVE_POLL_MS * 1000);
                continue;
            }
        }
        seen = observe_kernel_fd(kfd, deadline);
        if (seen == 1) {
            if (own_fd)
                close(kfd);
            write_bypass_stamp(stamp_path, "kernel");
            return 0;
        }
        if (seen == -1) {
            /* fd 已死（节点被重建）：关闭重找，窗口继续。 */
            if (own_fd)
                close(kfd);
            kfd = -1;
            own_fd = 0;
            if (inject_fd >= 0)
                break; /* 注入的 fd 已死，测试里不再重找。 */
            if (now_ms() >= deadline)
                break;
            continue;
        }
        break; /* seen == 0：到时无事件。 */
    }
    if (kfd >= 0 && own_fd)
        close(kfd);
    write_bypass_stamp(stamp_path, "bypass");
    return 1;
}

// 自动寻找希沃触屏 (VID: 1ff7, PID: 0f26) 的 hidraw 节点
int find_hidraw_device() {
    DIR *dir;
    struct dirent *ent;
    char path[256], line[256];
    int fd = -1;

    if ((dir = opendir("/sys/class/hidraw")) != NULL) {
        while ((ent = readdir(dir)) != NULL) {
            if (strncmp(ent->d_name, "hidraw", 6) == 0) {
                /* %.32s：hidraw 名形如 hidraw0，32 足够；同时消掉
                   -Wformat-truncation（目标 256 字节装不下 255 字节名）。 */
                snprintf(path, sizeof(path), "/sys/class/hidraw/%.32s/device/uevent", ent->d_name);
                FILE *f = fopen(path, "r");
                if (f) {
                    while (fgets(line, sizeof(line), f)) {
                        // 匹配 0003:00001FF7:00000F26
                        if (strstr(line, "1FF7") && strstr(line, "0F26")) {
                            snprintf(path, sizeof(path), "/dev/%.32s", ent->d_name);
                            fd = open(path, O_RDONLY | O_NONBLOCK);
                            if (fd >= 0) {
                                printf("成功锁定设备: %s\n", path);
                                fclose(f);
                                closedir(dir);
                                return fd;
                            }
                        }
                    }
                    fclose(f);
                }
            }
        }
        closedir(dir);
    }
    return -1;
}

#ifndef CVTE_TOUCH_TEST
int main() {
    int hid_fd, uinput_fd;
    unsigned char buf[128];
    struct touch_state st;

    /* 日志行立即进 journal（否则 stdout 全缓冲，启动行要攒够 4KB 才出现，
       用户 journalctl 查启动行时会看不到）。 */
    setvbuf(stdout, NULL, _IOLBF, 0);
    touch_state_init(&st);

    // 等待设备就绪
    while ((hid_fd = find_hidraw_device()) < 0) {
        printf("等待 CVTE Touch Device 插入...\n");
        sleep(2);
    }
    /* 第 16 轮首次启动决策：stamp 已判过则直接按决策走；否则观测
       30 秒——期间有内核触摸事件说明内核驱动能用，不开启兜底，
       退出 0（Restart=on-failure 不会重启退出 0 的进程，服务保持
       未运行状态）。观测不到事件才开启。决策结果写进 stamp，下次
       开机不再重复判断（LiveCD 的 /var 不持久，每次开机重判）。 */
    if (!bypass_decision(CVTE_FIRST_BOOT_STAMP, CVTE_OBSERVE_WINDOW_MS, -1)) {
        printf("内核触摸链路已有事件，兜底不需要，退出\n");
        /* 顺带把服务禁用掉，使设置里的开关状态与实际一致（尽力而为；
           失败也不影响本次退出——下次开机 stamp 仍会让本进程直接退出）。 */
        {
            int dis_rc = system("systemctl disable xwlightos-touch-bypass.service >/dev/null 2>&1");
            (void)dis_rc;
        }
        close(hid_fd);
        return 0;
    }

    uinput_fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (uinput_fd < 0) {
        perror("无法打开 /dev/uinput");
        close(hid_fd);
        return 1;
    }

    ioctl(uinput_fd, UI_SET_EVBIT, EV_KEY);
    ioctl(uinput_fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(uinput_fd, UI_SET_EVBIT, EV_ABS);
    ioctl(uinput_fd, UI_SET_ABSBIT, ABS_MT_SLOT);
    ioctl(uinput_fd, UI_SET_ABSBIT, ABS_MT_TRACKING_ID);
    ioctl(uinput_fd, UI_SET_ABSBIT, ABS_MT_POSITION_X);
    ioctl(uinput_fd, UI_SET_ABSBIT, ABS_MT_POSITION_Y);

    // 关键属性：标识为直接触摸设备，解决桌面环境（如 GNOME）的拖拽逻辑问题
    ioctl(uinput_fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT);

    struct uinput_user_dev uidev;
    memset(&uidev, 0, sizeof(uidev));
    snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "CVTE Touch Emulator");
    uidev.id.bustype = BUS_USB;
    uidev.id.vendor  = 0x1ff7;
    uidev.id.product = 0x0f26;

    uidev.absmin[ABS_MT_POSITION_X] = 0;
    uidev.absmax[ABS_MT_POSITION_X] = 32767;
    uidev.absmin[ABS_MT_POSITION_Y] = 0;
    uidev.absmax[ABS_MT_POSITION_Y] = 32767;
    uidev.absmin[ABS_MT_SLOT] = 0;
    uidev.absmax[ABS_MT_SLOT] = 5;
    uidev.absmin[ABS_MT_TRACKING_ID] = 0;
    uidev.absmax[ABS_MT_TRACKING_ID] = 65535;

    if (write(uinput_fd, &uidev, sizeof(uidev)) < 0) {
        perror("无法写入 uinput 设备信息");
        close(uinput_fd);
        close(hid_fd);
        return 1;
    }
    ioctl(uinput_fd, UI_DEV_CREATE);
    printf("虚拟触摸屏已启动，正在转发数据...\n");
    /* 第 12 轮：自动兜底生效后弹一次桌面通知（尽力而为；脚本自带 stamp
       防重复。发失败不影响触屏服务，故忽略返回值——接进变量再丢弃，
       否则 -Werror 下 warn_unused_result 会让构建红灯）。 */
    {
        int notify_rc = system("/usr/local/bin/xwlightos-touch-bypass-notify");
        (void)notify_rc;
    }

    /* 第 16 轮：内核守卫已删除（用户 2026-11-14 裁决）。兜底一旦开启
       就一直开着，不再监视内核节点、不再自动让路；主循环只转发
       hidraw 报告。服务停止时 systemd 发 SIGTERM，本进程随之结束，
       uinput fd 关闭后内核自动销毁虚拟设备。 */
    while (1) {
        int n = read(hid_fd, buf, sizeof(buf));

        if (n < 0) {
            if (errno == EAGAIN) {
                /* 空闲也冲掉到期的挂起抬起（报告流停后抬起仍要发出）。 */
                flush_pending_releases(uinput_fd, &st, now_ms());
                usleep(5000);
                continue;
            } else {
                // 设备被拔出，重新等待
                close(hid_fd);
                while ((hid_fd = find_hidraw_device()) < 0) sleep(2);
            }
        }

        if (n > 0) {
            process_report2(buf, n, uinput_fd, &st, now_ms());
            flush_pending_releases(uinput_fd, &st, now_ms());
        }
    }

    /* 正常情况下主循环不退出；以下清理只为完整性（服务停止时进程
       被 SIGTERM 结束，uinput 设备由内核在 fd 关闭时自动销毁）。 */
    close(hid_fd);
    ioctl(uinput_fd, UI_DEV_DESTROY);
    close(uinput_fd);
    return 0;
}
#endif /* !CVTE_TOUCH_TEST */
