// XWLightOS “此电脑” GNOME Shell 扩展（第 15 轮，用户 2026-11-14 明确指令：
// 自己写一个 GNOME Shell 扩展，打开文件时出现“此电脑”，里面包括所有的
// 硬盘驱动器，和 Windows 一样；不要用以前那个开源项目，非常不好用）。
//
// 从零自写：不复用以前那个第三方 Nautilus“此电脑”扩展的一行代码
// （2026-10-23 已移除，见评估卡 round15 §9）。挂载/弹出调用只遵循 GNOME
// 官方 drive-menu 扩展的平台模式（ShellMountOperation + VolumeMonitor），
// 属于平台 API 用法，不是复用第三方“此电脑”项目。
//
// 行为：顶栏“此电脑”按钮，下拉菜单列出 Gio.VolumeMonitor 的全部卷
// （内置分区、U 盘等，含未挂载的）；点驱动器：已挂载直接用文件管理器打开，
// 未挂载先经 UDisks2 挂载再打开——配合 Build 74 的“无需授权访问硬盘驱动器”
// polkit 规则，免授权时不弹密码；未开免授权时走系统密码框（与 Nautilus 同款）。
// 另设“打开此电脑”直开 computer:///（驱动器列表视图）。
// Shell 扩展无法往 Nautilus 窗口内注入 UI，“打开文件出现此电脑”由
// nautilus-python 扩展（默认打开 computer:///）实现，两项配合。
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as ShellMountOperation from 'resource:///org/gnome/shell/ui/shellMountOperation.js';

Gio._promisify(Gio.File.prototype, 'query_filesystem_info_async');
Gio._promisify(Gio.Volume.prototype, 'mount');
Gio._promisify(Gio.Mount.prototype, 'eject_with_operation', 'eject_with_operation_finish');
Gio._promisify(Gio.Mount.prototype, 'unmount_with_operation', 'unmount_with_operation_finish');

function openUri(uri) {
    const context = global.create_app_launch_context(0, -1);
    Gio.AppInfo.launch_default_for_uri(uri, context);
}

function formatCapacity(size, free) {
    // Windows“此电脑”同款：可用 X · 共 Y。
    return _('可用 %s · 共 %s').format(GLib.format_size(free), GLib.format_size(size));
}

class VolumeMenuItem extends PopupMenu.PopupBaseMenuItem {
    static {
        GObject.registerClass(this);
    }

    constructor(volume, generation, requestRebuild) {
        super({style_class: 'xwlightos-my-computer-item'});
        this._volume = volume;
        this._generation = generation;
        this._requestRebuild = requestRebuild;
        this._busy = false;

        const icon = volume.get_icon();
        if (icon) {
            this.add_child(new St.Icon({
                gicon: icon,
                style_class: 'popup-menu-icon',
            }));
        }

        this._nameLabel = new St.Label({
            text: volume.get_name() || _('未命名驱动器'),
            x_expand: true,
        });
        this.add_child(this._nameLabel);

        this._infoLabel = new St.Label({style_class: 'xwlightos-my-computer-info'});
        this.add_child(this._infoLabel);

        this._refreshInfo();

        // 可移动设备且已挂载：右侧弹出按钮（GNOME 官方 drive-menu 同款）。
        const mount = volume.get_mount();
        const drive = volume.get_drive();
        if (mount && drive && drive.is_removable() &&
            (mount.can_eject() || mount.can_unmount())) {
            const ejectButton = new St.Button({
                style_class: 'system-menu-action',
                child: new St.Icon({
                    icon_name: 'media-eject-symbolic',
                    style_class: 'popup-menu-icon',
                }),
            });
            ejectButton.connect('clicked', () => {
                this._eject(mount);
                return true;
            });
            this.add_child(ejectButton);
        }

        // 已挂载：异步取容量，回来后刷新右侧信息（菜单已重建则丢弃）。
        if (mount) {
            const root = mount.get_root();
            root.query_filesystem_info_async(
                'filesystem::size,filesystem::free',
                Gio.FileQueryInfoFlags.NONE, GLib.PRIORITY_DEFAULT, null
            ).then(info => {
                if (this._generation !== generation)
                    return;
                const size = info.get_attribute_uint64('filesystem::size');
                const free = info.get_attribute_uint64('filesystem::free');
                if (size > 0)
                    this._setInfo(formatCapacity(size, free));
            }).catch(() => {
                // 容量取不到（如特殊文件系统）不报错，只是不显示容量。
            });
        }
    }

    _deviceText() {
        try {
            return this._volume.get_identifier('unix-device') || '';
        } catch {
            return '';
        }
    }

    _setInfo(text) {
        const device = this._deviceText();
        this._infoLabel.text = device ? `${device} · ${text}` : text;
    }

    _refreshInfo() {
        const mount = this._volume.get_mount();
        this._setInfo(mount ? _('已挂载') : _('未挂载，点按挂载并打开'));
    }

    activate(event) {
        if (this._busy)
            return;
        const mount = this._volume.get_mount();
        if (mount) {
            openUri(mount.get_root().get_uri());
            super.activate(event);
            return;
        }
        // 未挂载：先挂载再打开。ShellMountOperation 负责在需要时弹出
        // 系统密码框；免授权规则开着时直接挂上，不弹密码。
        this._busy = true;
        this._setInfo(_('正在挂载…'));
        const mountOp = new ShellMountOperation.ShellMountOperation(this._volume).mountOp;
        this._volume.mount(Gio.MountMountFlags.NONE, mountOp, null).then(() => {
            const newMount = this._volume.get_mount();
            if (newMount)
                openUri(newMount.get_root().get_uri());
            this._busy = false;
            this._refreshInfo();
            this._requestRebuild();
        }).catch(e => {
            this._busy = false;
            log(`[xwlightos-my-computer] mount failed for ${this._volume.get_name()}: ${e.message}`);
            Main.notify(
                _('挂载驱动器失败'),
                _('“%s”挂载失败：%s').format(this._volume.get_name(), e.message));
            this._setInfo(_('挂载失败'));
        });
        super.activate(event);
    }

    _eject(mount) {
        const mountOp = new ShellMountOperation.ShellMountOperation(mount).mountOp;
        const op = mount.can_eject()
            ? mount.eject_with_operation(Gio.MountUnmountFlags.NONE, mountOp, null)
            : mount.unmount_with_operation(Gio.MountUnmountFlags.NONE, mountOp, null);
        op.then(() => {
            this._requestRebuild();
        }).catch(e => {
            log(`[xwlightos-my-computer] eject failed for ${mount.get_name()}: ${e.message}`);
            Main.notify(
                _('弹出驱动器失败'),
                _('“%s”弹出失败：%s').format(mount.get_name(), e.message));
        });
    }
}

class MyComputerMenu extends PanelMenu.Button {
    static {
        GObject.registerClass(this);
    }

    constructor() {
        super(0.5, _('此电脑'));

        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        box.add_child(new St.Icon({
            icon_name: 'drive-harddisk-symbolic',
            style_class: 'system-status-icon',
        }));
        box.add_child(new St.Label({
            text: _('此电脑'),
            y_align: St.Align.MIDDLE,
            style_class: 'xwlightos-my-computer-label',
        }));
        this.add_child(box);

        this._monitor = Gio.VolumeMonitor.get();
        this._generation = 0;

        // 卷/驱动器/挂载点任一变化都重建菜单；connectObject 绑到本按钮，
        // 按钮销毁时自动断开（GNOME 官方 drive-menu 同款）。
        this._monitor.connectObject(
            'volume-added', () => this._rebuild(),
            'volume-removed', () => this._rebuild(),
            'volume-changed', () => this._rebuild(),
            'drive-connected', () => this._rebuild(),
            'drive-disconnected', () => this._rebuild(),
            'drive-changed', () => this._rebuild(),
            'mount-added', () => this._rebuild(),
            'mount-removed', () => this._rebuild(),
            'mount-changed', () => this._rebuild(),
            this);

        // 每次打开菜单都重建一次，保证点开时就是最新状态。
        this.menu.connectObject(
            'open-state-changed', (menu, open) => {
                if (open)
                    this._rebuild();
            }, this);

        this._rebuild();
    }

    _rebuild() {
        this._generation += 1;
        const generation = this._generation;
        this.menu.removeAll();

        let volumes = [];
        try {
            volumes = this._monitor.get_volumes();
        } catch (e) {
            log(`[xwlightos-my-computer] get_volumes failed: ${e.message}`);
        }
        volumes.sort((a, b) =>
            (a.get_name() || '').localeCompare(b.get_name() || ''));

        if (volumes.length === 0) {
            const empty = new PopupMenu.PopupMenuItem(_('没有检测到硬盘驱动器'));
            empty.setSensitive(false);
            this.menu.addMenuItem(empty);
        } else {
            for (const volume of volumes) {
                try {
                    this.menu.addMenuItem(new VolumeMenuItem(
                        volume, generation, () => this._rebuild()));
                } catch (e) {
                    log(`[xwlightos-my-computer] menu item failed: ${e.message}`);
                }
            }
        }

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this.menu.addAction(_('打开此电脑'), () => {
            openUri('computer:///');
        });
        this.menu.addAction(_('打开文件'), () => {
            openUri('file:///home/' + GLib.get_user_name());
        });
    }
}

export default class XWLightOSMyComputerExtension extends Extension {
    enable() {
        this._indicator = new MyComputerMenu();
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator.destroy();
        delete this._indicator;
    }
}
