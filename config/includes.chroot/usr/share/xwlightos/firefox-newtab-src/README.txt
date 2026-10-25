XWLightOS 新标签页扩展（源码）：
- Firefox 官方策略不支持把新标签页设为自定义网址（Mozilla 文档明言 Homepage 策略
  不改变新标签页；新标签页设置只有“Firefox 主页”和“空白页”两档），因此必须用扩展实现。
- 本扩展只做一件事：新标签页立即重定向到本地主页 file:///usr/share/xwlightos/homepage.html
  （该文件用户以后可能自己改，扩展每次都读现成的文件，不内置副本）。
- 打包：cd 本目录 && zip -r ../firefox-newtab.xpi manifest.json redirect.html
- 安装：policies.json 里 ExtensionSettings force_installed（见同级 policies.json 注释）。
- Build 33 真机仍是默认新标签页的根因（2026-10-25 08:29 用户反馈第 2 项）：
  策略、落盘、manifest 三环当时都已对——policies.json 在 Debian firefox-esr
  的标准路径 /usr/lib/firefox-esr/distribution/policies.json，install_url 的
  file:/// 本地路径是 Mozilla 官方文档明确认可的写法，manifest 的
  chrome_url_overrides.newtab 也指向 redirect.html；纯策略项（主页/搜索/
  收藏栏）真机正常，唯独依赖扩展运行的新标签页失效，说明策略已被 Firefox
  读到、失效点在扩展运行这一环。失效的那一环是签名：本 XPI 是本地 zip
  打包、无 META-INF 签名，而 Build 33 的 policies.json 里没有任何
  Preferences 项，Firefox ESR 默认要求扩展签名，于是强制安装的扩展被
  禁用、新标签页回落到默认页。修法：policies.json 增加 ESR 专用的
  Preferences 项 xpinstall.signatures.required=false（Status locked，
  Mozilla policy-templates 明确标注该首选项仅 ESR 可用、自 ESR 102.10
  起可由策略设定），不改扩展本身、不走 AMO 签名（离线构建无法提交
  AMO）。另把扩展版本从 1.0 升到 1.1：Mozilla 文档规定 XPI 内部版本
  变化时策略会重新安装/更新扩展，可确保 Build 33 那份已被标记禁用的
  旧扩展不靠“重新校验旧条目”复活，而是走一次干净的重新安装。
  真机仍需核验：about:policies 显示 Preferences 与 ExtensionSettings
  均生效、about:addons 里本扩展为已启用、新标签页打开即本地主页。
