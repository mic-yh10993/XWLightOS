# plymouth-script-check — Plymouth 自家脚本解析器的离线校验工具

## 为什么需要它

2026-10-31 用户在 VMware 里带 `plymouth.debug` 启动 Build 58，日志实证：
开机动画缺失的根因是主题脚本 `xwlightos.script` 第 116 行
`while (local.d >= total and local.guard < 8)` —— Plymouth 脚本语法只有
`&&`/`||`，没有 `and` 关键字，解析器在该行连环报错后放弃整个脚本，
动画从未执行。该行自主题诞生（2026-10-23）起就存在，历次静态门禁
（查文件在不在、查配置写没写对）全都看不见语法错误。

本工具把 plymouthd 运行时用的**同一个解析器**搬到构建期来跑：
解析失败即拦下构建，不再靠设备实测才发现。

## 组成与来源

- `script*.c/h`、`ply-*.c/h`：逐字取自 Plymouth **22.02.122** 源码
  （Debian bookworm 里 plymouth 包的版本，也是镜像内 plymouthd 的版本）：
  - 上游压缩包：`plymouth_22.02.122.orig.tar.xz`
    （deb.debian.org/debian/pool/main/p/plymouth/）
  - SHA256：`100551442221033ce868c447ad6c74d831d209c18ae232b98ae0207e34eadaeb`
  - 取用文件：`src/plugins/splash/script/` 的解析器/扫描器/对象/执行器
    源码（解析入口 `script_parse_file()` 在 script-parse.c），加上
    `src/libply/` 中它们依赖的 list/hashtable/bitarray/logger/utils/
    array/buffer。
  - 许可证：GPL-2.0-or-later（随各文件头声明，与上游一致）。
- `main.c`：本地薄封装——对参数文件调用 `script_parse_file()`，
  返回 NULL（解析失败）时退出码 1 并打印 `PARSE FAILED`，
  成功打印 `PARSE OK`。解析器自身的报错（`Parser error ... L:x C:y`）
  经 ply-logger 原样输出到 stderr，与 plymouthd 调试日志同格式。
- `config.h`：仅含包名/版本宏的占位（解析器源码 `#include "config.h"`）。
- `build.sh`：一条 cc 命令完成构建，无外部依赖（只需 libc 与 libm）。

## 用法

```sh
scripts/plymouth-script-check/build.sh /tmp/ply-script-check
/tmp/ply-script-check /path/to/xwlightos.script   # 退出码 0=可解析
```

`scripts/validate-xwlightos-live-image.sh` 的 Plymouth 小节会自动构建
本工具，并对 squashfs 与 initrd 内的两份 `xwlightos.script` 各跑一次。

## 本地实证记录（2026-10-31）

- 对 Build 58 的脚本（`and` 版）：输出与用户 plymouth.debug 照片逐字
  一致的 5 条 Parser error（L:116 C:28/C:32/C:47），退出码 1。
- 对修复后的脚本（`&&` 版）：PARSE OK，退出码 0。
- 对上游自带的 5 个 script-lib-*.script：全部 PARSE OK（正对照，
  证明工具不会误杀合法脚本）。
