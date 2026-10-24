# XWLightOS: Qt5 apps follow the GTK2 theme (WhiteSur-Light).
# Without this, Qt5 apps fall back to the built-in Fusion style and
# drift away from the system theme; with the gtk2 platform theme
# (package qt5-gtk-platformtheme) they read /etc/gtk-2.0/gtkrc and
# stay light and readable like everything else.
export QT_QPA_PLATFORMTHEME=gtk2
