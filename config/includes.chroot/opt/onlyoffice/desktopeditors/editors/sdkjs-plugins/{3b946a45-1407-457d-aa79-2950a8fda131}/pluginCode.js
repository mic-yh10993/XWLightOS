/*
 * XWLightOS PPT 放映桥接插件 (background)
 *
 * 职责：
 *  1. 在演示文稿打开时获取总页数；
 *  2. 轮询本机工具栏服务 (http://127.0.0.1:18923/cmd) 获取翻页/结束等指令，
 *     通过官方放映 API 执行；
 *  3. 把 {presenting, current, total} 状态 POST 到 /state，供工具栏显示页码。
 *
 * 使用的放映 API（ONLYOFFICE 8.0+ 官方插件方法，已核验）：
 *  StartSlideShow / EndSlideShow / GoToNextSlideInSlideShow /
 *  GoToPreviousSlideInSlideShow / GoToSlideInSlideShow / PauseSlideShow / ResumeSlideShow
 *
 * 页码跟踪说明（诚实标注）：
 *  官方 API 未提供“获取放映当前页”的方法，因此 current 采用计数器跟踪：
 *  工具栏发起的翻页会精确计数；若用户在放映中直接用键盘/鼠标翻页，
 *  计数器可能偏离，工具栏提供“回到首页”可一键重同步。
 */
(function () {
    'use strict';

    var BRIDGE = 'http://127.0.0.1:18923';
    var CMD_URL = BRIDGE + '/cmd';
    var STATE_URL = BRIDGE + '/state';

    var state = {
        presenting: false,
        current: 1,
        total: 0,
        seq: 0            // 已处理的指令序号
    };

    var lastSelectedSlide = 1;  // 编辑态最后选中的页（放映起点估计）

    function postState() {
        try {
            fetch(STATE_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(state)
            }).catch(function () { /* 工具栏未运行则静默 */ });
        } catch (e) { /* 忽略 */ }
    }

    function clamp() {
        if (state.total > 0) {
            if (state.current < 1) state.current = 1;
            if (state.current > state.total) state.current = state.total;
        } else if (state.current < 1) {
            state.current = 1;
        }
    }

    // 通过 Builder API 获取总页数。callCommand 无法直接返回值，
    // 因此把结果写进一个隐藏的文档变量再读回；若失败则 total 保持 0。
    function refreshTotal() {
        try {
            window.Asc.plugin.callCommand(function () {
                var pres = Api.GetPresentation();
                var n = pres.GetSlidesCount();
                // 把页数暂存到插件可读的位置：写进当前文档的 core 属性无副作用，
                // 这里采用更稳妥的方式——通过全局变量经由 executeMethod 回调带出。
                window.__xw_ppt_total = n;
            }, false, false, function () {
                try {
                    var n = window.__xw_ppt_total | 0;
                    if (n > 0) {
                        state.total = n;
                        clamp();
                        postState();
                    }
                } catch (e) { /* 忽略 */ }
            });
        } catch (e) { /* 忽略 */ }
    }

    // 尝试读取编辑态当前选中的幻灯片索引（1-based），用于估计放映起点。
    function refreshSelectedSlide() {
        try {
            window.Asc.plugin.callCommand(function () {
                try {
                    var pres = Api.GetPresentation();
                    var cur = pres.GetCurrentSlide && pres.GetCurrentSlide();
                    if (cur && cur.GetSlideIndex) {
                        window.__xw_ppt_cur = cur.GetSlideIndex() + 1;
                    }
                } catch (e) { /* API 不存在则忽略 */ }
            }, false, false, function () {
                try {
                    var n = window.__xw_ppt_cur | 0;
                    if (n > 0) lastSelectedSlide = n;
                } catch (e) { /* 忽略 */ }
            });
        } catch (e) { /* 忽略 */ }
    }

    function execSlideShow(method, args) {
        try {
            window.Asc.plugin.executeMethod(method, args || []);
            return true;
        } catch (e) {
            return false;
        }
    }

    function handleCommand(cmd) {
        if (!cmd || typeof cmd.seq !== 'number' || cmd.seq <= state.seq) return;
        state.seq = cmd.seq;
        var action = cmd.action;

        if (action === 'sync') {
            // 工具栏检测到放映窗口出现：以编辑态选中页为起点
            state.presenting = true;
            state.current = lastSelectedSlide || 1;
            refreshTotal();
            clamp();
            postState();
        } else if (action === 'hide') {
            state.presenting = false;
            postState();
        } else if (action === 'next') {
            if (execSlideShow('GoToNextSlideInSlideShow')) {
                state.presenting = true;
                state.current += 1;
                clamp();
                postState();
            }
        } else if (action === 'prev') {
            if (execSlideShow('GoToPreviousSlideInSlideShow')) {
                state.presenting = true;
                state.current -= 1;
                clamp();
                postState();
            }
        } else if (action === 'goto') {
            var idx = (cmd.index | 0);
            if (execSlideShow('GoToSlideInSlideShow', [idx])) {
                state.presenting = true;
                state.current = idx + 1;  // API 索引为 0-based
                clamp();
                postState();
            }
        } else if (action === 'first') {
            if (execSlideShow('GoToSlideInSlideShow', [0])) {
                state.presenting = true;
                state.current = 1;
                postState();
            }
        } else if (action === 'end') {
            if (execSlideShow('EndSlideShow')) {
                state.presenting = false;
                postState();
            }
        } else if (action === 'pause') {
            execSlideShow('PauseSlideShow');
        } else if (action === 'resume') {
            execSlideShow('ResumeSlideShow');
        }
        // 未知 action：忽略
    }

    function pollCmd() {
        try {
            fetch(CMD_URL, { method: 'GET' })
                .then(function (resp) { return resp.json(); })
                .then(function (cmd) { handleCommand(cmd); })
                .catch(function () { /* 工具栏未运行则静默 */ });
        } catch (e) { /* 忽略 */ }
    }

    window.Asc.plugin.init = function () {
        // 后台插件：初始化后即开始工作
        refreshTotal();
        postState();
        setInterval(pollCmd, 300);
        // 编辑态定期记录选中页，供放映起点估计
        setInterval(function () {
            if (!state.presenting) refreshSelectedSlide();
        }, 1000);
    };

    window.Asc.plugin.onDocumentContentReady = function () {
        refreshTotal();
    };

    // 文档切换/关闭时复位
    window.Asc.plugin.onDetachEvent = function () {};
})();
