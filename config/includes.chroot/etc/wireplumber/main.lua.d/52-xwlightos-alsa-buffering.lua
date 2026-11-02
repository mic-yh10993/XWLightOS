-- XWLightOS: ALSA 播放缓冲加大——治虚拟机里看视频声音断断续续。
--
-- 定案（用户 2026-10-31 实测，Build 57 VMware 虚拟机）：看视频时
-- 音频持续断续、“根本用不了”；而 speaker-test 用巨大 ALSA 缓冲播
-- 放干净。同链路在缓冲宽裕时没问题、在 PipeWire 常规小 quantum
-- 实时投递时欠载——这是 VMware/VirtualBox 模拟 HDA 的经典爆音
-- 形态，与音量缺陷（见 51 号 drop-in）是两个独立子缺陷。
--
-- 杠杆（属性名与结构均以随包文件 50-alsa-config.lua 为准，不猜）：
-- WirePlumber 的 vm.node.defaults 对虚拟机给的是 period-size=256
-- （48kHz 下约 5.3ms 一段，模拟声卡根本喂不及）、headroom=8192。
-- 这里把 VM 默认的 period 提到 2048（约 42ms），并给全部 ALSA
-- 输出节点追加同一组规则——真机（希沃 HDA）也适用：period 加大
-- 只增加约几十毫秒延迟、换欠载余量，对课堂播放无副作用。
-- 配套：图级 quantum 下限已在 pipewire 的 drop-in
-- （51-xwlightos-quantum.conf）同步钉到 2048、rtkit 已进包清单
-- （数据线程实时优先级）；2026-11-02 第七轮（用户令“调高缓存”，
-- 推翻 10-31 不加档决定）：真机本地视频嘟嘟卡顿、选错设备已排
-- 除，故 period 1024→2048、headroom 8192→16384；若本档仍断，
-- 下一杠杆是查链路本身（USB 音频 gadget 路径），不是继续加档。
alsa_monitor.properties["vm.node.defaults"] = {
  ["api.alsa.period-size"] = 2048,
  ["api.alsa.headroom"] = 16384,
}

table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.*" },
    },
  },
  apply_properties = {
    ["api.alsa.period-size"] = 2048,
    ["api.alsa.headroom"] = 16384,
  },
})
