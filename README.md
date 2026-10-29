# Wallpaper Engine RDP Fix

**Live wallpaper comes back when you switch windows over Remote Desktop? Keep it unloaded until you return to the local PC.**

[简体中文](README.zh-CN.md) · [Download](https://github.com/sleepyquq/wallpaper-engine-rdp-fix/releases/latest) · [Report a bug](https://github.com/sleepyquq/wallpaper-engine-rdp-fix/issues/new/choose)

## The problem this fixes

On an affected Windows PC, connecting through RDP initially hides the Wallpaper Engine wallpaper. Switching window focus, minimizing an app, or returning to the desktop then brings it back. After the remote resolution changes, the live wallpaper may occupy only a small corner, with the normal Windows wallpaper visible behind it.

This workaround sends Wallpaper Engine's official **Stop** command on RDP connection and **Play** when you return to the physical console. **Stop unloads the wallpaper; Pause would leave the frozen wallpaper layer in place.** The controller/tray process stays running, so there is no forced termination or resulting “Safe start” confirmation.

This behavior was reproduced with Wallpaper Engine **2.8.42** on Windows 11 using Windows App on an iPad. Install this only if you see the symptom; native RDP handling may already work correctly on other systems.

## Install

Requirements:

- Windows 10/11 with an already working RDP host. This tool does not enable RDP or change its firewall rules.
- [PowerShell 7](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows), Wallpaper Engine, and Windows Task Scheduler.
- The Windows .NET Framework C# compiler. The installer uses the compiler shipped with Windows to build the small GUI launcher locally. No SDK or downloaded executable is required; if the compiler is missing, installation stops before creating tasks.
- Permission to register tasks for your own Windows account. Tasks run with normal user privileges and do not store your password. Managed devices may restrict task creation.

1. Download the ZIP from [Releases](https://github.com/sleepyquq/wallpaper-engine-rdp-fix/releases/latest), extract it, and review the scripts.
2. Start Wallpaper Engine normally so the installer can find its actual installation directory.
3. In the extracted folder, run:

```powershell
pwsh.exe -NoProfile -File .\Install.ps1
```

For a custom Steam library, or if Wallpaper Engine is not running:

```powershell
pwsh.exe -NoProfile -File .\Install.ps1 -EngineDirectory "D:\SteamLibrary\steamapps\common\wallpaper_engine"
```

Installation files are copied to `%LOCALAPPDATA%\WallpaperEngineRdpFix`. You can move or delete the downloaded ZIP/folder afterward. **Keep the installed directory.** Reconnect RDP to apply; no reboot is required. Leave Wallpaper Engine's normal auto-start enabled.

If Windows blocks downloaded scripts, review them and follow your organization's script-signing/download policy. The installer does not bypass execution policy, disable protection, or request credentials.

## Check the actual behavior

1. On the physical PC, confirm the live wallpaper is playing.
2. Connect from the iPad/another RDP client. The original Windows static wallpaper should be visible.
3. **Switch focus between windows, minimize one, and click the desktop.** The live wallpaper must stay unloaded, not just disappear at initial connection.
4. Disconnect RDP without signing out. Unlock the same account on the physical PC. The live wallpaper should return without a terminal flash or confirmation dialog.

Read-only status:

```powershell
pwsh.exe -NoProfile -File .\Status.ps1
```

Local actions are recorded in `%LOCALAPPDATA%\WallpaperEngineRdpFix\events.jsonl`. Nothing is uploaded. Remove personal paths/usernames before sharing diagnostics.

## How it works

| Event | Action |
| --- | --- |
| RDP connects | Official `-control stop`, only if the engine is already running in that user session |
| Physical console reconnects/unlocks | Official `-control play`, only with this tool's restore marker |
| Remote session unlocks | No local restore: the live session type is checked again |
| User signs in | Check after five seconds, applying only the matching session action |

Two user-scoped scheduled tasks are registered: `WallpaperEngineRdpFix-Remote-<user SID>` and `WallpaperEngineRdpFix-Local-<user SID>`. There is no resident monitoring loop. A small C# **Windows GUI** launcher starts PowerShell with `CreateNoWindow`, rather than opening a console and hiding it afterward. The installer builds this launcher from the included source.

Both `wallpaper32.exe` and `wallpaper64.exe` are recognized **only in the configured installation directory and current session**. A pending restore follows the currently running architecture. Editors, Steam, services, and other users' sessions are not terminated or controlled.

## Uninstall or test native behavior

```powershell
pwsh.exe -NoProfile -File .\Uninstall.ps1
```

This removes the two tasks and, on the physical console, resumes content this tool stopped. Files/logs are retained for inspection or reinstall. If uninstalling over RDP, return to the physical PC and resume Wallpaper Engine manually. Do not delete the installation directory while tasks are still registered.

To temporarily compare native behavior, disable **both** tasks in Task Scheduler, test the complete focus-change sequence above, and re-enable them afterward if the issue remains. Native behavior looking correct immediately after connection is not sufficient.

For an update, uninstall the tasks, download/extract the new release, and run its installer. The same installation directory can be reused for the same account after its tasks have been removed.

## Validation and limits

| Evidence | Scope |
| --- | --- |
| Original workaround field test | Windows 11, Wallpaper Engine 2.8.36 / 2.8.42, 32-bit controller, iPad Windows App; remote/static → local/dynamic, focus switching, hidden execution |
| Public package tests | Session guards, recovery markers, 32/64-bit path filtering and architecture switches, command errors, GUI launcher/exit-code behavior, isolated installation and uninstall |
| Still needs broader field testing | 64-bit controller over real RDP, other Windows/driver/client combinations; the generalized public package has not yet had a separate iPad end-to-end field run |

- This is an **unofficial workaround**, not a Wallpaper Engine patch. It does not change display resolution, wallpaper files, RDP security, or crash protection.
- Keep Wallpaper Engine running before connecting. Manually starting it or pressing Play during an existing RDP session can override the stopped state; reconnect to apply the rule again. It does not continuously police playback.
- Multiple engine instances in one session are rejected rather than guessed. An engine moved to another Steam library requires reinstalling with the new directory.
- A real engine crash may still invoke Wallpaper Engine's own safe-start protection. This tool does not suppress it.
- Do not run another RDP wallpaper automation tool alongside this one.

## Sources and development

- [Official Wallpaper Engine command-line interface](https://help.wallpaperengine.io/en/functionality/cli.html)
- [Developer explanation: Stop unloads wallpapers; Pause does not](https://steamcommunity.com/app/431960/discussions/2/1636418037481746366/)
- [Windows session-change task triggers](https://learn.microsoft.com/en-us/windows/win32/taskschd/sessionstatechangetrigger)

Run tests in PowerShell 7 on Windows:

```powershell
pwsh.exe -NoProfile -File .\tests\Run-Tests.ps1 -Integration
```

Integration tests create uniquely named temporary tasks and a fake engine directory, then remove the tasks. They do not control a real Wallpaper Engine process. CI runs the same checks on Windows.

MIT licensed. No Wallpaper Engine binaries, wallpapers, personal configuration, or machine logs are included.
