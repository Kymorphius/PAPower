# PAPower

PAPower 是一个原生 macOS 菜单栏功耗监控原型。它会把当前功耗直接显示成
`12.4W` 这样的菜单栏文字，点击后可以查看短期趋势、高活跃应用、CPU／GPU／SSD／电池温度，
以及电池功率、电压和电流。

## 数据含义

- 菜单栏优先读取 AppleSMC 的 `PSTR`，表示 Mac 的总板级功耗（Total Board Power）。
- 电池详情来自 IOKit / AppleSmartBattery，电池功率按 `电压 × 电流` 计算。
- CPU、GPU 和 SSD 温度优先从 IOKit/HID 温区读取，并显示当前可识别温区中的最高有效值；
  AppleSMC 传感器键作为兼容回退。不同芯片和 macOS 版本提供的温区可能不同，缺失时会显示 `—`。
- 如果 `PSTR` 不可用且 Mac 正在使用电池，PAPower 会明确切换为“电池端估算值”。
- `PSTR` 不是插座侧功率，不包含电源适配器的转换损耗。需要精确测量墙上取电时，应使用 USB-C 或插座功率计。
- macOS 不提供可靠的逐应用瓦数。弹窗中的“高活跃应用”会合并同一应用的 Helper 进程，并按近期 CPU 活跃度提供排查线索；它不是功率分摊结果。

所有功耗采样均在本机完成，不需要管理员权限，也不会上传数据。只有用户主动点击
“检查 GitHub 更新”时，应用才会访问 GitHub Releases 查询最新版本。

## Spotlight 索引开关

面板中的“Spotlight 索引”开关用 `mdutil -a -i on|off` 打开或关闭所有卷的 Spotlight 索引，
用来减少 `mds_stores` 在后台建索引的耗电。状态读取自 `mdutil -s /System/Volumes/Data`，
不需要权限；切换时会弹出系统管理员密码框。关闭后 ⌘空格、Finder 和邮件搜索
都无法再按内容找到新文件，重新打开后 macOS 会重建索引，期间会有一段较高的后台占用。

## 独立网络流量菜单栏

应用同时提供一个独立的流量菜单栏项，两行分别显示代理与直连的下载／上传速度。
点击可查看分类累计量、活动连接数、未归类流量，并清零本次监测累计。

面板中的“高流量来源”按当前下载与上传速度的合计列出前五项，分别显示上下行速度、
连接数和代理／直连类型。同一应用的 Helper 合并为一个来源；无法识别应用或进程时，
显示目标域名或 IP。排名仅反映两次采样之间能归属的活动连接，服务恢复后的首帧不显示旧排名。

流量数据只读接入 local-manager 管理的 sing-box Clash API（默认回环地址），
优先读取 `/Applications/local-manager/var/state/network/sing-box/runtime.json` 的控制器配置，
不存在时使用 `10.network/20.sing-box/sing-box.json`。其他安装位置可通过
`PAPOWER_LOCAL_MANAGER_ROOT` 环境变量指定。可选 API secret 只在内存中用于认证，
不会写入用户设置或探针输出；应用不会修改或重启 local-manager。

代理／直连根据活动连接实际出口的类型判断。全局字节增量作为总量，能归属的连接增量
分入代理与直连，其余保留为“未归类”：采样间隔内关闭的连接、DNS 等数据不一定能完整归属。
因此分类速度与累计量是采样统计，仅覆盖 local-manager 管理的连接，不能当作全机网卡流量
或今日账单。累计从本次监测开始计算；服务失联期间不累计，重连／核心重启后重新建立基线。

控制器的接口与认证方式见 [sing-box Clash API 文档](https://sing-box.sagernet.org/configuration/experimental/clash-api/)。

## 从 GitHub 更新

在菜单栏弹窗中点击“检查 GitHub 更新”，PAPower 会读取
[`Kymorphius/PAPower` 的最新 Release](https://github.com/Kymorphius/PAPower/releases/latest)
并与当前版本比较。发现新版本后，点击“前往下载”即可打开对应的 Release 页面。

应用不会在后台自动检查或自动安装更新。

## 构建和运行

要求 macOS 13 或更高版本，以及完整安装的 Xcode。

```bash
./Scripts/build-app.sh
open dist/PAPower.app
```

构建产物位于 `dist/PAPower.app`。要长期使用，可以把它拖到“应用程序”文件夹，再在弹出面板里开启“登录时自动启动”。

读取一次数据并输出 JSON（便于调试）：

```bash
dist/PAPower.app/Contents/MacOS/PAPower --probe
```

读取一次高活跃应用列表：

```bash
dist/PAPower.app/Contents/MacOS/PAPower --activity-probe
```

读取两次真实流量采样，输出代理／直连／未归类速度与本次累计；连接失败返回非零退出码：

```bash
dist/PAPower.app/Contents/MacOS/PAPower --traffic-probe
```

读取原始温度传感器，便于核对新机型：

```bash
dist/PAPower.app/Contents/MacOS/PAPower --temperature-probe
```

## 技术与分发边界

菜单栏和电池状态使用 Apple 的公开 macOS 框架。`PSTR` 功耗键以及 CPU／GPU／SSD 温区读取
依赖未公开承诺稳定性的 AppleSMC 或 IOKit 接口；它们在 Apple Silicon Mac 上很实用，
但未来系统或不同机型可能改变。
因此当前版本更适合 Developer ID 直签分发，不应在未验证 App Sandbox 与审核政策前直接按
Mac App Store 方案发布。

本项目只参考 AlDente 的公开产品行为，没有使用或逆向其私有源码。
