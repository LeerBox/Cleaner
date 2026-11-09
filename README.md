<div align="center">

<img src="Assets/Cleaner.png" width="96" alt="Cleaner logo">

# Cleaner

**See what goes. Keep what matters.**

A preview-first cleanup tool for Windows. Analyze, review every item, then confirm.

[![Release](https://img.shields.io/github/v/release/LeerBox/Cleaner?include_prereleases&style=flat-square&label=release)](https://github.com/LeerBox/Cleaner/releases)
[![License: MIT](https://img.shields.io/github/license/LeerBox/Cleaner?style=flat-square)](LICENSE)
![Windows 10/11 x64](https://img.shields.io/badge/Windows-10%20%2F%2011%20x64-0078D4?style=flat-square)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)

[**Download**](https://github.com/LeerBox/Cleaner/releases) · [Quick start](#quick-start) · [What it cleans](#what-it-cleans) · [Safety](#safety) · [Report an issue](https://github.com/LeerBox/Cleaner/issues)

</div>

![Cleaner cleanup review screen in dark mode](docs/images/cleanup-dark.png)

<p align="center"><sub>The cleanup review screen. Categories shown depend on the applications installed.</sub></p>

> [!WARNING]
> Cleaner is an **unsigned public preview** without an independent security audit, and cleanup **permanently deletes** the items you select. Review candidates and back up valuable work first.

## Why Cleaner

- **Nothing is deleted blind.** Analyze shows what each category would remove and how much space it uses before anything happens.
- **Scoped rules, not drive scans.** Cleaner targets specific, known cleanup locations instead of searching your whole drive.
- **Privacy cleanup is opt-in.** Browsing history is a separate category that is never preselected.
- **Running apps are respected.** Browser and app caches are cleaned only while the application is closed.
- **Reviewable.** Readable PowerShell source, sandbox tests, and local operation logs.

## Quick start

1. Download **Cleaner-Portable.zip** from [Releases](https://github.com/LeerBox/Cleaner/releases). `SHA256SUMS.txt` contains the archive checksum.
2. Extract the entire archive to a folder you control.
3. Run **Cleaner.exe**. Keep its companion scripts and `Assets` folder next to it.
4. Click **Analyze**, review the **Items** page, then confirm your selection.

**Requirements:** 64-bit Windows 10 or 11 with Windows PowerShell 5.1.

Administrator rights are optional. They unlock the system-wide categories and can be requested from Settings or by starting `Cleaner.exe /admin`.

> [!NOTE]
> Windows may show a reputation warning because the release is unsigned. `Cleaner.exe` is a compiled launcher for the PowerShell application, not a standalone rewrite, so the source you can read is the code that runs.

## What it cleans

| Group | Categories | Notes |
| --- | --- | --- |
| **System** | Temporary files · Error reports and crash dumps · Recycle Bin | Temporary files older than 7 days; reports and dumps older than 30 days |
| **Web browsers** | Chrome · Edge · Brave · Vivaldi · Opera · Opera GX · Firefox | Cache only. Passwords, cookies and history stay |
| **Browsing activity** | History for the Chromium browsers above | Opt-in, never preselected. Firefox history is not cleared |
| **Apps** | Discord · Slack · Visual Studio Code · Cursor | Cached web content. Settings, extensions and sign-in are kept |
| **Explorer privacy** | Recent files list · Recent folders · Jump Lists | Pins are checked; a safety copy of the list is saved locally |
| **Developer** | pip · npm · NuGet HTTP cache | Downloads older than 30 days |
| **Graphics** | DirectX and GPU driver shader caches | Older than 30 days |
| **Administrator** | Windows temporary files · System error reports and dumps | Requires administrator rights |

The interface offers light, dark and system themes.

## Safety

- **Deletion is permanent.** File age or a cache location cannot prove that a file is unimportant.
- **History cleanup is local.** Browser sync may restore activity, and Cleaner does not erase activity held by websites or online accounts. It is not secure erasure.
- **Close applications first.** The optional *Close app* action requests a normal close; forced closing needs a separate confirmation and may lose unsaved work.
- **Compatibility varies.** Browser storage formats change between versions, and running-app checks reduce risk without eliminating it.

Full details are in [Safety and limitations](docs/SAFETY.md).

## Build from source

Run from the repository root in Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build\Build.ps1
```

The build uses the Windows .NET Framework C# compiler and creates `dist\Cleaner\Cleaner.exe` with its companion files. No external NuGet packages are required. The execution-policy argument applies only to that process.

## Tests

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Tests\Test-CleanerEngine.ps1
```

The suite exercises deletion in disposable test folders, including locked files, links, protected files and history-file allowlists. It also reads real cleanup locations without cleaning them. Passing these checks does not establish compatibility with every browser version or Windows configuration.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). When reporting issues, include your Windows and browser versions and remove personal paths from logs and screenshots. Suggestions for accessibility, translations and better diagnostics are welcome.

## License

Released under the [MIT License](LICENSE).
