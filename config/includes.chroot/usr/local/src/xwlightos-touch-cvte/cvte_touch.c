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
// 直接调 process_report2() 验解码与槽位映射（见 round11 测试）。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <dirent.h>
#include <linux/uinput.h>
#include <linux/input.h>

#define CVTE_MAX_SLOTS 6
#define CVTE_REPORT_ID_TOUCH 2
#define CVTE_REPORT_LEN 62
#define CVTE_CONTACT_NONE 0xFF

struct touch_state {
    /* 每槽当前占用的设备接触编号，-1 = 空槽。tracking ID 用设备编号原值。 */
    int slot_contact[CVTE_MAX_SLOTS];
};

static void touch_state_init(struct touch_state *st)
{
    int i;
    for (i = 0; i < CVTE_MAX_SLOTS; i++)
        st->slot_contact[i] = -1;
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

/* 处理一帧触摸报告（报告号 2，62 字节）。返回 1 = 已处理并同步一帧，
   0 = 不是触摸报告或长度不足（调用方跳过）。 */
static int process_report2(const unsigned char *buf, int n, int uinput_fd,
                           struct touch_state *st)
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

    /* 抬起：本帧已不在按下的槽，逐指释放。 */
    for (s = 0; s < CVTE_MAX_SLOTS; s++) {
        int still_down = 0;
        if (st->slot_contact[s] == -1)
            continue;
        for (i = 0; i < n_touching; i++) {
            if (touching_contact[i] == st->slot_contact[s]) {
                still_down = 1;
                break;
            }
        }
        if (!still_down) {
            emit(uinput_fd, EV_ABS, ABS_MT_SLOT, s);
            emit(uinput_fd, EV_ABS, ABS_MT_TRACKING_ID, -1);
            st->slot_contact[s] = -1;
        }
    }

    emit(uinput_fd, EV_KEY, BTN_TOUCH, any_touch);
    emit(uinput_fd, EV_SYN, SYN_REPORT, 0);
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

    while (1) {
        int n = read(hid_fd, buf, sizeof(buf));

        if (n < 0) {
            if (errno == EAGAIN) {
                usleep(5000);
                continue;
            } else {
                // 设备被拔出，重新等待
                close(hid_fd);
                while ((hid_fd = find_hidraw_device()) < 0) sleep(2);
            }
        }

        if (n > 0)
            process_report2(buf, n, uinput_fd, &st);
    }

    close(hid_fd);
    ioctl(uinput_fd, UI_DEV_DESTROY);
    close(uinput_fd);
    return 0;
}
#endif /* !CVTE_TOUCH_TEST */
