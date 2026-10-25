XWLightOS 新标签页扩展（源码）：
- Firefox 官方策略不支持把新标签页设为自定义网址（Mozilla 文档明言 Homepage 策略
  不改变新标签页；新标签页设置只有“Firefox 主页”和“空白页”两档），因此必须用扩展实现。
- 本扩展只做一件事：新标签页直接显示本地主页（与启动主页、收藏栏主页同一份内容）。
- 打包：cd 本目录 && zip -r ../firefox-newtab.xpi manifest.json homepage.html
- 安装：policies.json 里 ExtensionSettings force_installed（见同级 policies.json 注释）。
- 本目录的 homepage.html 必须是 ../homepage.html 的逐字节副本（打包时从上层复制，
  不许手改本目录这一份；校验脚本逐字节比对 XPI 内嵌副本与落盘的 file:// 主页，
  两边不一致构建即红灯）。homepage.html 本身不改、只被引用和复制。
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
- Build 36/37 新症状根因（2026-10-25 11:41 用户反馈：新标签页能打开重定向页，
  但自动跳转不生效、点“点这里”链接也无反应）：
  签名修法已生效（扩展已运行、重定向页能打开），失效点换成了跳转机制本身：
  redirect.html 是 moz-extension:// 页，而 Firefox 安全策略禁止扩展页
  上下文加载或链接到 file:// 地址——页面里的 meta refresh、location 跳转、
  超链接点击都会被静默拦截，只在浏览器控制台留一条 Security Error
  （Content at moz-extension://.../redirect.html may not load or link to
  file:///...，见 Mozilla Bug 1487353、1523986 的实测记录）。后台脚本
  也救不了：扩展 tabs API 打开 file:// 地址会被拒为 Illegal URL
  （Mozilla Bug 1421102，Mozilla 结论是扩展打开 file: 地址与文件系统
  访问不可分割、故不放行）。也就是说，任何“扩展内跳转到 file:// 主页”
  的写法在 Firefox 里都不可能生效；旧 redirect.html 从原理上就是死路。
  修法：不再跳转。新标签页的覆盖页直接就是主页副本（本目录 homepage.html，
  与 file:// 主页逐字节一致、只含 https 外链与 data-URI 图标、无相对
  文件引用，内嵌后显示与原主页完全一致）。扩展版本从 1.1 升到 1.2，
  按 Build 34 的同款版本规则触发策略强制重新安装，Build 36 那份基于
  redirect 的 1.1 旧扩展不会被复用。
  真机仍需核验：about:policies 显示 Preferences 与 ExtensionSettings
  均生效、about:addons 里本扩展为已启用、新标签页打开即本地主页。
- 已知取舍（诚实说明）：内嵌副本只在构建时与 file:// 主页同步；用户在
  装好的系统里自己改了 /usr/share/xwlightos/homepage.html 之后，启动主页
  与收藏栏主页会立即读到新文件，但新标签页仍显示构建时的旧副本，直到
  下一次构建才刷新。这是 Firefox file: 拦截下的唯一可行机制（另一条路是
  本地 HTTP 服务转发实时文件，那是新子系统、不在本反馈修法范围内）。
