// XWLightOS 屏幕键盘助手扩展（第 17 轮，用户 2026-11-15：安装器里点输入框
// 屏幕键盘不弹；装好的系统上开了开关就能弹，说明弹出机制本身没问题，问题
// 在 Qt 应用触发不了弹出）。
//
// 根因（GNOME Shell 48.7 + Mutter 48.7 + Qt 6.8.2 源码核查）：Wayland 下
// 屏幕键盘弹出的唯一路径是 mutter 的 text-input 协议把 input-panel-state
// 设为 ON，而 mutter 只在客户端对已聚焦的输入框重复 enable+commit 时才设
// ON（meta-wayland-text-input.c 的 text_input_commit_state() 是全文件唯一
// 设 ON 的地方）；Qt 的 QWaylandTextInputV3 每个 surface 只发一次 enable
// （enableSurface() 的 m_surface == surface 守卫），且 Qt 6.8 的
// QInputMethod::show() 在 v3 实现里是空操作——Qt 应用（Calamares）永远
// 触发不了弹出。GTK 应用因主动调 gtk_im_context_activate_osk() 能弹。
// screen-keyboard-enabled=true 只决定键盘对象存在与否，不管每次聚焦。
// 鼠标/触摸无区别（用户在装好的系统上用虚拟机鼠标开了开关就能弹，实证；
// mutter 与 Shell 的弹出路径里没有任何触摸/鼠标区分）。
//
// 本扩展提供两条路（自写，不复用 Improved OSK——它只支持 Shell 43/44，
// 且其 force-touch-input 只影响第 1 层自动路径，对 Qt 聚焦不弹毫无作用）：
// 1. 顶栏键盘按钮（主路，可靠）：点一下弹键盘，再点收起。照抄 Improved OSK
//    的 toggleOSK() 模式（Main.keyboard.open()/close()，48.7 keyboard.js
//    第 1133/1140 行已核实），鼠标/触摸通用。
// 2. 聚焦自动弹（辅路，尽力而为）：包装 InputMethod.prototype.vfunc_focus_in
//    （48.7 inputMethod.js 第 195 行，只设 _currentFocus、不弹 panel），
//    原函数跑完后补 Main.keyboard.open()。48.7 下原型补丁是否生效需用户实
//    测；包装失败（try/catch）不影响按钮，扩展照常加载；disable() 时恢复
//    原函数。若设置本身是关的，Main.keyboard._keyboard 为空，open() 是空
//    操作——本扩展不绕过用户的开关。
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {InputMethod} from 'resource:///org/gnome/shell/misc/inputMethod.js';

export default class XWLightOSOskExtension extends Extension {
    enable() {
        // 顶栏键盘按钮（主路）：无菜单，点一下切换键盘开/关。
        this._button = new PanelMenu.Button(0.0, 'XWLightOS OSK', true);
        this._button.add_child(new St.Icon({
            icon_name: 'input-keyboard-symbolic',
            style_class: 'system-status-icon',
        }));
        this._button.connect('button-press-event', () => this._toggleKeyboard());
        Main.panel.addToStatusArea(this.uuid, this._button);

        // 聚焦自动弹（辅路，尽力而为）：包装 vfunc_focus_in，原函数跑完后
        // 补开键盘。任何一步失败都不影响按钮，只记日志。
        this._origFocusIn = null;
        try {
            const proto = InputMethod.prototype;
            if (proto && typeof proto.vfunc_focus_in === 'function') {
                this._origFocusIn = proto.vfunc_focus_in;
                const orig = this._origFocusIn;
                proto.vfunc_focus_in = function (focus) {
                    orig.call(this, focus);
                    try {
                        if (Main.keyboard)
                            Main.keyboard.open(Main.layoutManager.bottomIndex);
                    } catch (e) {
                        log(`[xwlightos-osk] auto-open failed: ${e}`);
                    }
                };
            }
        } catch (e) {
            log(`[xwlightos-osk] focus hook failed, button only: ${e}`);
        }
    }

    disable() {
        if (this._origFocusIn) {
            try {
                InputMethod.prototype.vfunc_focus_in = this._origFocusIn;
            } catch (e) {
                log(`[xwlightos-osk] restore focus hook failed: ${e}`);
            }
            this._origFocusIn = null;
        }
        if (this._button) {
            this._button.destroy();
            this._button = null;
        }
    }

    _toggleKeyboard() {
        if (!Main.keyboard)
            return;
        if (Main.keyboard.visible)
            Main.keyboard.close();
        else
            Main.keyboard.open(Main.layoutManager.bottomIndex);
    }
}
