# PAPower

PAPower 是一个原生 macOS 菜单栏功耗监控原型。它会把当前功耗直接显示成
`12.4W` 这样的菜单栏文字，点击后可以查看短期趋势、高活跃应用、电池功率、电压、电流和温度。

## 数据含义

- 菜单栏优先读取 AppleSMC 的 `PSTR`，表示 Mac 的总板级功耗（Total Board Power）。
- 电池详情来自 IOKit / AppleSmartBattery，电池功率按 `电压 × 电流` 计算。
- 如果 `PSTR` 不可用且 Mac 正在使用电池，PAPower 会明确切换为“电池端估算值”。
- `PSTR` 不是插座侧功率，不包含电源适配器的转换损耗。需要精确测量墙上取电时，应使用 USB-C 或插座功率计。
- macOS 不提供可靠的逐应用瓦数。弹窗中的“高活跃应用”会合并同一应用的 Helper 进程，并按近期 CPU 活跃度提供排查线索；它不是功率分摊结果。

所有采样均在本机完成，不需要管理员权限，也不会联网。

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

## 技术与分发边界

菜单栏和电池状态使用 Apple 的公开 macOS 框架。`PSTR` 则来自未公开承诺稳定性的
AppleSMC 传感器键；它在 Apple Silicon Mac 上很实用，但未来系统或不同机型可能改变。
因此当前版本更适合 Developer ID 直签分发，不应在未验证 App Sandbox 与审核政策前直接按
Mac App Store 方案发布。

本项目只参考 AlDente 的公开产品行为，没有使用或逆向其私有源码。
