# Wallpaper Engine RDP Fix

**修复远程桌面连接后，切换窗口焦点又冒出动态壁纸的问题。**

[English](README.md) · [下载](https://github.com/sleepyquq/wallpaper-engine-rdp-fix/releases/latest) · [报告问题](https://github.com/sleepyquq/wallpaper-engine-rdp-fix/issues/new/choose)

## 适合什么情况

用 iPad Windows App 或其他 RDP 客户端连 Windows 电脑时，刚连接正常；一旦切换窗口、最小化应用或回到桌面，Wallpaper Engine 又恢复渲染。远程分辨率变化后，动态壁纸可能只占左上角一小块，后面同时露出原来的静态壁纸。

本工具在远程接入时调用官方 **Stop**，回到电脑本机时调用 **Play**。**Stop 是卸载壁纸内容，不是 Pause 暂停定格。** 托盘控制进程保留，不强杀，因此不会因本工具强制退出而在恢复时弹出“安全启动”确认框。

该症状在 Windows 11、Wallpaper Engine **2.8.42**、iPad Windows App 的组合上复现。只在你确实遇到该问题时安装；其他环境的原生 RDP 处理可能已经正常。

## 安装

需要：已能正常连接的 Windows 10/11 远程桌面、[PowerShell 7](https://learn.microsoft.com/zh-cn/powershell/scripting/install/installing-powershell-on-windows)、Wallpaper Engine、Windows 任务计划程序，以及 Windows 自带的 .NET Framework C# 编译器。编译器只用于在本机编译附带的无窗口启动器源码，不下载二进制、不要求安装开发 SDK。缺少编译器时，安装会在创建任务前停止。

1. 从 [Releases](https://github.com/sleepyquq/wallpaper-engine-rdp-fix/releases/latest) 下载 ZIP 并解压，检查脚本。
2. 先正常启动 Wallpaper Engine，安装器会识别当前会话中的实际安装目录。
3. 在解压目录运行：

```powershell
pwsh.exe -NoProfile -File .\Install.ps1
```

没有运行软件或需要指定 Steam 库时：

```powershell
pwsh.exe -NoProfile -File .\Install.ps1 -EngineDirectory "D:\SteamLibrary\steamapps\common\wallpaper_engine"
```

任务以当前用户的普通权限运行，不保存密码，不以 SYSTEM 运行；企业策略可能限制用户创建任务。本工具不会绕过策略或索取凭据。

运行文件保存在 `%LOCALAPPDATA%\WallpaperEngineRdpFix`，解压包之后可以移走，但**不要删除已安装目录**。安装后重新连接 RDP 即可，无需重启。保留 Wallpaper Engine 自己原有的开机启动。

如果系统阻止运行下载的脚本，先检查源码并遵守设备的签名／下载策略；安装器不绕过执行策略，也不关闭安全保护。

## 验证不要只看刚连接的瞬间

1. 本机确认动态壁纸正在播放。
2. 用 iPad 或其他 RDP 客户端连接，确认显示原来的 Windows 静态壁纸。
3. **切换几个窗口、最小化应用、点回桌面**，确认动态覆盖层不会重新出现。
4. 断开远程连接，不要注销。回电脑本机解锁同一账户，确认动态壁纸自动恢复，且没有终端闪窗或确认框。

只读检查安装与会话状态：

```powershell
pwsh.exe -NoProfile -File .\Status.ps1
```

动作日志在 `%LOCALAPPDATA%\WallpaperEngineRdpFix\events.jsonl`，不会上传。分享诊断前先去掉个人路径和用户名。

## 实现方式

- 两个按用户隔离的持久计划任务：远程连接调用 Stop，本机连接／解锁调用 Play；登录五秒后也会检查当前会话类型。
- 每次执行都再次判断实际会话类型，**远程解锁不会被当成本机恢复**。
- 仅恢复有本工具标记的壁纸；用户本来没有启动引擎时，不会替用户打开。
- 只识别配置目录、当前会话中的 `wallpaper32.exe` 和 `wallpaper64.exe`，恢复时可以跟随运行架构的变化。
- 无常驻轮询。安装器用 Windows 自带的编译器构建 GUI 启动器，通过 `CreateNoWindow` 启动 PowerShell，避免先出现控制台再隐藏；不依赖 VBScript。
- 不修改 RDP 服务、防火墙、分辨率、静态壁纸、安全启动保护；不结束 Steam、编辑器或其他会话的程序。

## 卸载、对照测试与更新

```powershell
pwsh.exe -NoProfile -File .\Uninstall.ps1
```

卸载会移除两个任务；在本机会话中恢复本工具停止的内容。文件和日志保留，便于检查或重新安装。若在远程会话卸载，回本机后手动恢复 Wallpaper Engine 播放。不要在任务尚未移除时直接删除安装目录。

要测试软件原生行为，可在任务计划程序中临时禁用两个 `WallpaperEngineRdpFix-` 任务，按上面的完整流程检查，再按结果恢复启用。仅“刚连上没问题”不能证明焦点切换的问题已解决。

更新时先卸载旧任务，解压新版本并运行新安装器；同一用户移除旧任务后可复用原安装目录。

## 验证范围与限制

- 原始补充方案已在 Windows 11、Wallpaper Engine 2.8.36／2.8.42 的 **32 位主程序**与 iPad Windows App 上实测：远程静态、本机恢复、切换焦点及隐藏执行。
- 公开通用包有会话状态、恢复标记、32／64 位目录筛选和切换、错误恢复、GUI 启动器、隔离安装／卸载测试。
- 通用公开包尚未另外进行一次 iPad 端到端实测；**真实 RDP 下的 64 位主程序**及其他系统／驱动／客户端组合仍需更多使用反馈。
- 已处于远程会话时，手动启动引擎或点 Play 可能覆盖停止状态；重新连接可再次应用规则。本工具不会一直监视并强制停止。
- 同一会话同时运行多个主程序会报错，不随意选择。移动 Steam 库后需按新目录重新安装。
- 真正的程序崩溃仍可能触发 Wallpaper Engine 原有的安全启动保护，本工具不会屏蔽它。
- 不要与其他 RDP 壁纸自动化工具重复运行。

## 开发与依据

```powershell
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1 -Integration
```

隔离测试创建独立命名的临时任务和假的引擎目录，然后移除任务，不控制真实壁纸进程。Windows CI 执行同样的检查。

- [官方命令行接口](https://help.wallpaperengine.io/en/functionality/cli.html)
- [开发者解释 Stop 与 Pause 的区别](https://steamcommunity.com/app/431960/discussions/2/1636418037481746366/)
- [Windows 会话变化触发器](https://learn.microsoft.com/en-us/windows/win32/taskschd/sessionstatechangetrigger)

MIT 许可证。仓库不附带 Wallpaper Engine 程序、壁纸、个人配置或机器日志。
