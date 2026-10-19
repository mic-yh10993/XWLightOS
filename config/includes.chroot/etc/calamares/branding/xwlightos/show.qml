import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation {
    id: presentation
    textColor: "#EAF6FF"
    titleColor: "#75D6FF"
    fontFamily: "Noto Sans CJK SC"

    Rectangle {
        anchors.fill: parent
        color: "#07162F"
        z: -1
    }

    function nextSlide() {
        presentation.goToNextSlide();
    }

    Timer {
        id: advanceTimer
        interval: 4200
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: nextSlide()
    }

    Slide {
        centeredText: qsTr("欢迎安装 XWLightOS 1.0\nAI Agent 操作系统：GNOME 桌面 + macOS 风格主题，基于 Debian 构建")
    }

    Slide {
        centeredText: qsTr("XWLightOS\n基于 Debian Bookworm 构建\n由 SYSTEM-Intel-MIC 维护")
    }

    Slide {
        centeredText: qsTr("安装提示\n请先确认目标磁盘和分区方案，再开始安装。")
    }

    function onActivate() {
        presentation.currentSlide = 0;
    }

    function onLeave() {
        advanceTimer.stop();
    }
}
