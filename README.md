Rom Opti
A clean, one-click Windows optimizer and Rust FPS tuner.
Made by @rrromuluss (YouTube / Discord).
Rom Opti is a lightweight, single-file utility for gamers. It applies well-known, documented Windows tweaks — the same kind used by popular open-source optimizers — wrapped in a clean multi-page interface with a plain-English explanation on every single option. Tailored for Rust players who want maximum FPS and smoother gameplay.
> Everything Rom Opti changes is reversible through Windows System Restore. The **Create Restore Point** option is on by default and always runs first.
---
✨ Features
Rom Opti is split into four sections. Hover the `(?)` next to any option in the app to see exactly what it does before you apply it.
🎨 Preferences
Appearance and quality-of-life toggles: one-click Dark / Light mode, show file extensions, show hidden files, left-align the taskbar, hide Widgets, disable Bing web-search in Start, classic Win11 right-click menu, disable transparency, open Explorer to "This PC", and more.
🛠️ Tweaks
Privacy and system cleanups: disable Telemetry, Consumer Features, Activity History, Game DVR, Hibernation, Location Tracking, Storage Sense, Wi-Fi Sense, Advertising ID, tips & ads; delete temp files; enable "End Task" on right-click; set non-essential services to Manual.
⚡ Rust FPS
The performance core — built for maximum frames and minimum latency:
Ultimate Performance power plan + disable CPU core parking & power throttling
GPU Hardware-Accelerated Scheduling
Windows Game Mode on, Xbox Game Bar overlay off
MMCSS game priority + disable network throttling
Disable Nagle's algorithm for lower ping
Disable mouse acceleration for 1:1 raw aim
Best-performance visual effects + exclusive fullscreen
One-click copy of tuned Steam launch options for Rust
🧹 Debloat
Remove unused preinstalled apps, optionally remove Xbox apps (safe for Steam), disable Windows Copilot, kill telemetry scheduled tasks, and optionally uninstall OneDrive.
---
📋 Requirements
Windows 10 or Windows 11
Administrator rights (the tool asks for them automatically)
---
🚀 How to Run
Option 1 — Download and run (easiest)
Go to the latest files and download both `Rom-Opti.ps1` and `Run-RomOpti.bat` into the same folder.
Double-click `Run-RomOpti.bat`.
Click Yes on the admin (UAC) prompt.
If Windows SmartScreen shows a blue "Windows protected your PC" box, click More info → Run anyway. This appears because the tool isn't signed by a large company yet — not because anything is wrong with it. The full source is right here for you to read.
Option 2 — Run straight from source (no download)
Open PowerShell as Administrator (right-click Start → Terminal (Admin)) and paste:
```powershell
irm https://raw.githubusercontent.com/RomOpti/RomOpti/main/Rom-Opti.ps1 | iex
```
This runs the exact code in this repo, nothing hidden.
---
🛡️ Safety & Transparency
Reversible: leave Create Restore Point ticked (it's on by default). If anything feels off, roll back from Windows System Restore.
Reboot: restart your PC after applying for all changes to take full effect.
Open source: read every line before you run it. That's the whole point.
Antivirus note: optimizers that edit the registry and disable services sometimes get flagged as a false positive by Windows Defender or other AV, because they touch the same system areas malware does. The source is fully public here so you can verify it's clean. Do not disable your antivirus to run it.
A couple of options are situational, and the in-app `(?)` tooltips flag them:
Skip Disable SysMain if you're on a mechanical hard drive (HDD), not an SSD.
Skip Remove Xbox Apps if you play Xbox Game Pass or Microsoft Store games. (Steam, including Rust, is unaffected.)
---
⚠️ Disclaimer
Rom Opti is provided as-is. System tweaks always carry some risk. By using it you accept responsibility for changes made to your system. Always use the restore point. The author is not liable for any issues that may arise.
---
🙌 Credits
Made by @rrromuluss — find me on YouTube and Discord.
If Rom Opti helped your FPS, a ⭐ on the repo is appreciated.
📄 License
Released under the MIT License — free to use, modify, and share.
