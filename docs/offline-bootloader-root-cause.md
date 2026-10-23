# bootloader-config exit 127 根因实证（2026-10-23）

用户真机安装时 Calamares 报错：`命令 </usr/sbin/bootloader-config/> 以退出代码 127 完成`，
输出显示 apt 尝试从 deb.debian.org 下载 grub-efi-amd64/grub2-common 失败。

## 证据链

1. 触发点不是上游 `bootloader` 模块，而是 Debian 打包加的 process 模块。
   `calamares-settings-debian_12.0.9-1+deb12u2_all.deb` 内：
   - `/usr/lib/calamares/modules/bootloader-config/module.desc`：
     `command: "/usr/sbin/bootloader-config"`（type job，interface process）
   - `/etc/calamares/settings.conf` exec 序列含 `- bootloader-config`（在 `bootloader` 之前）

2. `/usr/sbin/bootloader-config` 全文（该 deb 内原样提取）：

```bash
#!/bin/bash

CHROOT=$(mount | grep proc | grep calamares | awk '{print $3}' | sed -e "s#/proc##g")

# Install luks utilities if needed.
# Also, set secure permissions for the initramfs if we're configuring
# full-disk-encryption. The initramfs is re-generated later in the
# installation process so we only set the permissions snippet without
# regenerating the initramfs right now:
if [ "$(mount | grep $CHROOT" " | cut -c -16)" = "/dev/mapper/luks" ]; then
    echo "UMASK=0077" > $CHROOT/etc/initramfs-tools/conf.d/initramfs-permissions
    chroot $CHROOT apt-get -y install cryptsetup-initramfs cryptsetup keyutils
fi

echo "Running bootloader-config..."

if [ -d /sys/firmware/efi/efivars ]; then
    echo " * Installing grub-efi (uefi)..."
    DEBIAN_FRONTEND=noninteractive chroot $CHROOT apt-get -y install grub-efi-amd64
else
    echo " * install grub... (bios)"
    DEBIAN_FRONTEND=noninteractive chroot $CHROOT apt-get -y install grub-pc
fi

# Re-enable os-prober:
sed -i "s/#GRUB_DISABLE_OS_PROBER=false/# OS_PROBER re-enabled by Debian Calamares installation:\nGRUB_DISABLE_OS_PROBER=false/g" $CHROOT/etc/default/grub
chroot $CHROOT /usr/sbin/update-grub
```

3. exit 127 的完整链条：
   - 用户机器是 UEFI → 走 `chroot $CHROOT apt-get -y install grub-efi-amd64`。
   - 目标里只有 `grub-efi-amd64-bin`，没有元包 `grub-efi-amd64` 和 `grub2-common`
     → apt 去 deb.debian.org 下载 → 断网失败（apt-get exit 100）。
   - **脚本没有 `set -e`**，继续往下执行。
   - `chroot $CHROOT /usr/sbin/update-grub`：grub2-common 没装上，
     `/usr/sbin/update-grub` 不存在 → bash 报 command not found → **exit 127**。
   - 与截图输出逐行吻合（"Installing grub-efi-amd64 (uefi)..."、
     "The following NEW packages will be installed: grub-efi-amd64 grub2-common"、
     随后 Ign:1 http://deb.debian.org …）。

4. 1600 钩子旧注释"bootloader 只跑本地工具、不调 apt"是错的：
   它核查的是上游 calamares 3.2.61 的 `bootloader` 模块源码，
   漏掉了 Debian 在它前面插入的 `bootloader-config` process 模块。已修正。

## 修法（对应提交见 git log）

- package list 预装 `grub2-common` + `shim-signed`
  （`grub-common`/`grub-pc-bin`/`grub-efi-amd64-bin` 本来就有；
  `grub-efi-amd64` 与 `grub-pc` 互斥 Conflicts，不能同时预装，故不加）。
- 1565 钩子把 `/usr/sbin/bootloader-config` 换成离线友好版：
  目标里已有 grub2-common + 对应平台模块目录时跳过 apt；
  缺失时回退原 apt 行为（有网机器不变）。
- 1600 钩子构建期断言扩展到 grub2-common（update-grub/grub-install 必须存在）。
- postinst 构建安全性已核查：grub-pc/grub-efi-amd64/shim-signed 的 postinst
  只在已存在 core.img（升级场景）或 EFI 已挂载时才 grub-install，
  live-build 全新 chroot 里全部跳过，不会写构建机磁盘。

## 仍需真机验证

- 拔网线在 UEFI 机器上完整安装一次，确认 bootloader 步骤通过。
- BIOS（Legacy）机器同样测一次（走 grub-pc 分支）。
- Secure Boot 开启的机器确认能进系统（shim 链）。
