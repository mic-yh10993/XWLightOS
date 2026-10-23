# XWLightOS: Nautilus 默认打开"其他位置"（other-locations:///）。
#
# 用户 2026-10-23 邮件指令：不需要"此电脑"了（1570 钩子已删除），文件管理器
# 默认打开"其他位置"这个标签页。
#
# 实现沿用被移除的 nautilus-my-computer 扩展 start-on-disks 的同款可靠机制：
# 监听 Gtk.Application "window-added"，等新窗口标题稳定后，只把"默认打开"
# （标题为本地化 "Home"，即无参数启动）的窗口原地导航到 other-locations:///；
# 带明确位置打开的窗口（标题不是主目录，如从其它应用"在文件夹中显示"）、
# 文件选择器窗口一律不动。nautilus-python 对加载失败的扩展是静默跳过，
# 因此本文件保持最小依赖、异常全部内部吞掉，宁可不跳转也不炸掉文件管理器。
import gi

gi.require_version("Nautilus", "4.0")
gi.require_version("Gtk", "4.0")

from gi.repository import GLib, GObject, Gtk, Nautilus

OTHER_LOCATIONS_URI = "other-locations:///"
_HOME_TITLE = GLib.dgettext("nautilus", "Home")
_LOADING_TITLE = GLib.dgettext("nautilus", "Loading…")
# bookworm = Nautilus 43（<= 46 走 legacy 布局）：先试 win 再试 slot。
_ACTION_NAMES = ("win.open-location", "slot.open-location")
_RETRY_MS = 60
_MAX_ATTEMPTS = 50  # 约 3 秒等标题稳定，超时则放弃（窗口停在默认位置即可）


def _is_file_chooser(win):
    return type(win).__name__ == "NautilusFileChooser"


def _is_nautilus_window(win):
    if _is_file_chooser(win):
        return False
    get_bid = getattr(win, "get_buildable_id", None)
    if callable(get_bid) and get_bid() == "NautilusWindow":
        return True
    return type(win).__name__ == "NautilusWindow"


def _navigate_to_other_locations(win):
    param = GLib.Variant("s", OTHER_LOCATIONS_URI)
    for name in _ACTION_NAMES:
        try:
            if win.activate_action(name, param):
                return True
        except Exception:
            pass
    return False


class XWLightOSDefaultLocation(GObject.Object, Nautilus.MenuProvider):
    """nautilus-python 扩展入口：子类化任一 Provider 即被加载。"""

    def __init__(self):
        super().__init__()
        self._handled = set()
        GLib.idle_add(self._late_init)

    def _late_init(self):
        # 扩展初始化时 Gtk.Application 可能还没建好，idle 里重试直到拿到。
        try:
            app = Gtk.Application.get_default()
        except Exception:
            app = None
        if app is None:
            return GLib.SOURCE_CONTINUE
        try:
            app.connect("window-added", self._on_window_added)
            for w in app.get_windows():
                self._on_window_added(app, w)
        except Exception:
            pass
        return GLib.SOURCE_REMOVE

    def _on_window_added(self, _app, win):
        if win in self._handled:
            return
        try:
            if not _is_nautilus_window(win):
                return
        except Exception:
            return
        self._handled.add(win)
        attempts = [0]

        def _try():
            attempts[0] += 1
            try:
                title = win.get_title() or ""
            except Exception:
                return GLib.SOURCE_REMOVE
            # 位置还没解析出来（"正在加载…"）时绝不动作，避免误判消耗掉
            # 这一次性的"默认打开"机会。
            if not title or title == _LOADING_TITLE:
                if attempts[0] < _MAX_ATTEMPTS:
                    return GLib.SOURCE_CONTINUE
                return GLib.SOURCE_REMOVE
            # 只有默认打开（主目录）的窗口才跳转；明确指定了位置的不动。
            if title == _HOME_TITLE:
                _navigate_to_other_locations(win)
            return GLib.SOURCE_REMOVE

        GLib.timeout_add(_RETRY_MS, _try)
