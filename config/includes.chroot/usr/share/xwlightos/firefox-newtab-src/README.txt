XWLightOS 新标签页扩展（源码）：
- Firefox 官方策略不支持把新标签页设为自定义网址（Mozilla 文档明言 Homepage 策略
  不改变新标签页；新标签页设置只有“Firefox 主页”和“空白页”两档），因此必须用扩展实现。
- 本扩展只做一件事：新标签页立即重定向到本地主页 file:///usr/share/xwlightos/homepage.html
  （该文件用户以后可能自己改，扩展每次都读现成的文件，不内置副本）。
- 打包：cd 本目录 && zip -r ../firefox-newtab.xpi manifest.json redirect.html
- 安装：policies.json 里 ExtensionSettings force_installed（见同级 policies.json 注释）。
