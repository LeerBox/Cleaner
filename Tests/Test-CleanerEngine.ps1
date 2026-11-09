#requires -Version 5.1
<#
.SYNOPSIS
    Safety tests for CleanerEngine.psm1.

.DESCRIPTION
    Creates a new sandbox folder in %TEMP%, fills it with traps (locked files, links, a folder
    that is swapped for a junction after the analysis, read-only / system / model / document
    files, ...) and checks that ONLY the right files are deleted.

    Only files inside the sandbox are ever deleted. The real cleanup locations are analyzed
    (read-only) at the end, but never cleaned. The sandbox is removed afterwards.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-CleanerEngine.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$enginePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CleanerEngine.psm1'
$module = Import-Module -Name $enginePath -Force -PassThru -DisableNameChecking

$script:Passed = 0
$script:Failed = 0
function Assert([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:Passed++; Write-Host ('  PASS  ' + $Message) -ForegroundColor Green }
    else { $script:Failed++; Write-Host ('  FAIL  ' + $Message) -ForegroundColor Red }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('CleanerEngineTest-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$root = Join-Path $sandbox 'root'          # the cleanup location used by the test rules
$outside = Join-Path $sandbox 'outside'    # must never be touched
$logs = Join-Path $sandbox 'logs'
[void](New-Item -ItemType Directory -Path $root, $outside, $logs)
& $module { param($folder) $script:LogFolderOverride = $folder } $logs

$old = (Get-Date).AddDays(-40)

function New-TestFile([string]$Path, [int]$Size = 1024, [datetime]$Time = $old, [switch]$CreatedNow) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Size))
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $CreatedNow) { $item.CreationTime = $Time }
    $item.LastWriteTime = $Time
    return $Path
}

function Set-FolderTime([string]$Path, [datetime]$Time = $old) {
    $folder = Get-Item -LiteralPath $Path -Force
    $folder.CreationTime = $Time
    $folder.LastWriteTime = $Time
}

function New-TestTarget([string]$Path, [switch]$Recurse, [string[]]$Include = @('*'), [string[]]$ExcludeName = @(), [string[]]$AllowExtension = @(), [switch]$RemoveEmptyFolders) {
    & $module {
        param($p, $r, $i, $x, $a, $f)
        New-CleanerTarget -Path $p -Recurse:$r -Include $i -ExcludeName $x -AllowExtension $a -RemoveEmptyFolders:$f
    } $Path $Recurse.IsPresent $Include $ExcludeName $AllowExtension $RemoveEmptyFolders.IsPresent
}

function New-TestRule([string]$Id, [object[]]$Targets, [int]$MinAgeDays = 7, [string[]]$Processes = @()) {
    & $module {
        param($i, $t, $a, $p)
        New-CleanerRule -Id $i -Group 'System' -Name ('Test ' + $i) -Description 'Test rule' -Targets $t -MinAgeDays $a -Processes $p -AppName 'Test app'
    } $Id $Targets $MinAgeDays $Processes
}

function Test-Exists([string]$Path) { [IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path) }

$handles = New-Object System.Collections.Generic.List[IDisposable]
try {
    Write-Host ''
    Write-Host "Sandbox: $sandbox" -ForegroundColor Cyan

    # ------------------------------------------------------------------ build the sandbox
    $shouldGo = @(
        (New-TestFile (Join-Path $root 'old.tmp')),
        (New-TestFile (Join-Path $root 'hidden.tmp')),
        (New-TestFile (Join-Path $root 'olddir\nested\deep.tmp')),
        (New-TestFile (Join-Path $root 'youngdir\old-in-young-folder.tmp'))
    )
    (Get-Item -LiteralPath (Join-Path $root 'hidden.tmp') -Force).Attributes = 'Hidden'

    $mustStay = [ordered]@{
        'recent file'                  = New-TestFile (Join-Path $root 'young.tmp') -Time (Get-Date)
        'old date but created just now' = New-TestFile (Join-Path $root 'unpacked.tmp') -CreatedNow
        'date in the future'           = New-TestFile (Join-Path $root 'future.tmp') -Time (Get-Date).AddYears(3)
        'read-only file'               = New-TestFile (Join-Path $root 'readonly.tmp')
        'system file'                  = New-TestFile (Join-Path $root 'system.tmp')
        'AI model (.gguf)'             = New-TestFile (Join-Path $root 'model.gguf')
        'document (.docx)'             = New-TestFile (Join-Path $root 'report.docx')
        'file locked by a program'     = New-TestFile (Join-Path $root 'locked.tmp')
        'file open with delete sharing' = New-TestFile (Join-Path $root 'shared.tmp')
        'file changed after analysis'  = New-TestFile (Join-Path $root 'changed.tmp')
    }
    (Get-Item -LiteralPath $mustStay['read-only file'] -Force).Attributes = 'ReadOnly'
    (Get-Item -LiteralPath $mustStay['system file'] -Force).Attributes = 'System'

    $canaryJunction = New-TestFile (Join-Path $outside 'canary-junction.txt')
    $canaryHardLink = New-TestFile (Join-Path $outside 'canary-hardlink.txt')
    $junctionInside = Join-Path $root 'link-to-outside'
    [void](cmd /c mklink /J "$junctionInside" "$outside")
    $hardLink = Join-Path $root 'hardlink.tmp'
    [void](cmd /c mklink /H "$hardLink" "$canaryHardLink")

    # Swap trick: after the analysis, root\swap is replaced by a junction to outside\swap,
    # which holds a file with the same name, size and dates.
    $swapVictim = New-TestFile (Join-Path $root 'swap\victim.tmp') -Size 4096
    $swapCanary = New-TestFile (Join-Path $outside 'swap\victim.tmp') -Size 4096
    (Get-Item -LiteralPath $swapCanary).LastWriteTime = (Get-Item -LiteralPath $swapVictim).LastWriteTime
    (Get-Item -LiteralPath $swapCanary).CreationTime = (Get-Item -LiteralPath $swapVictim).CreationTime

    Set-FolderTime (Join-Path $root 'olddir\nested')
    Set-FolderTime (Join-Path $root 'olddir')
    Set-FolderTime (Join-Path $root 'swap')

    # ------------------------------------------------------------------ analysis
    Write-Host ''
    Write-Host 'Analysis' -ForegroundColor Cyan
    $rule = New-TestRule -Id 'sandbox' -Targets @((New-TestTarget -Path $root -Recurse -RemoveEmptyFolders)) -MinAgeDays 7
    $scan = @(Invoke-CleanerScan -Rule @($rule))[0]
    $found = @($scan.Files | ForEach-Object { $_.Path })

    Assert ($scan.State -eq 'Ready') "analysis state is Ready (got $($scan.State))"
    foreach ($path in $shouldGo) { Assert ($found -contains $path) ("old file is listed: " + (Split-Path -Leaf $path)) }
    foreach ($name in @('recent file', 'old date but created just now', 'date in the future', 'read-only file', 'system file', 'AI model (.gguf)', 'document (.docx)')) {
        Assert (-not ($found -contains $mustStay[$name])) "not listed: $name"
    }
    Assert (-not ($found | Where-Object { $_ -like "$junctionInside*" })) 'nothing listed through the junction'
    Assert ($scan.SkippedLinks -ge 1) 'the junction was counted as a skipped link'
    Assert ($scan.SkippedRecent -ge 3) "recent / new / future files counted as recent ($($scan.SkippedRecent))"
    Assert ($scan.SkippedProtected -ge 4) "read-only / system / model / document counted as protected ($($scan.SkippedProtected))"

    # ------------------------------------------------------------------ tamper after the analysis
    $locked = [IO.File]::Open($mustStay['file locked by a program'], 'Open', 'Read', 'None')
    $handles.Add($locked)
    $shared = [IO.File]::Open($mustStay['file open with delete sharing'], 'Open', 'Read', ([IO.FileShare]'ReadWrite, Delete'))
    $handles.Add($shared)
    [IO.File]::AppendAllText($mustStay['file changed after analysis'], 'changed')
    Rename-Item -LiteralPath (Join-Path $root 'swap') -NewName 'swap-moved'
    [void](cmd /c mklink /J "$(Join-Path $root 'swap')" "$(Join-Path $outside 'swap')")

    # ------------------------------------------------------------------ clean
    Write-Host ''
    Write-Host 'Cleaning (sandbox only)' -ForegroundColor Cyan
    $clean = @(Invoke-CleanerClean -ScanResult @($scan))[0]
    foreach ($handle in $handles) { $handle.Dispose() }
    $handles.Clear()

    foreach ($path in $shouldGo) { Assert (-not (Test-Exists $path)) ('deleted: ' + (Split-Path -Leaf $path)) }
    foreach ($name in $mustStay.Keys) { Assert (Test-Exists $mustStay[$name]) "kept: $name" }
    Assert (Test-Exists $canaryJunction) 'file behind a junction survived'
    Assert (Test-Exists $canaryHardLink) 'hard-linked file survived'
    Assert (Test-Exists $hardLink) 'hard link itself was kept'
    Assert (Test-Exists $swapCanary) 'swap trick defeated: file outside the location survived'
    Assert (Test-Exists $junctionInside) 'junction inside the location was not removed'
    Assert (Test-Exists (Join-Path $root 'swap')) 'swapped-in junction was not removed'
    Assert (-not (Test-Exists (Join-Path $root 'olddir'))) 'old empty folders were removed'
    Assert (Test-Exists (Join-Path $root 'youngdir')) 'recently created folder was kept'
    Assert (Test-Exists $root) 'the location itself was kept'
    Assert ($clean.InUse -ge 2) "files in use were skipped ($($clean.InUse))"
    Assert ($clean.Changed -ge 1) "changed file was skipped ($($clean.Changed))"
    Assert ($clean.Protected -ge 2) "hard link and swapped file were refused ($($clean.Protected))"
    Assert ($clean.Deleted -eq $shouldGo.Count) "deleted exactly $($shouldGo.Count) files (got $($clean.Deleted))"
    $logText = (Get-ChildItem -LiteralPath $logs -Filter 'Cleaner-*.log' | Get-Content -Raw)
    Assert ($logText -match 'DELETED' -and $logText -match 'OUTSIDE' -and $logText -match 'IN USE') 'log lists deleted, outside and in-use files'

    # ------------------------------------------------------------------ more rules
    Write-Host ''
    Write-Host 'Filters, links and protected folders' -ForegroundColor Cyan
    $filterRoot = Join-Path $sandbox 'filters'
    $dump = New-TestFile (Join-Path $filterRoot 'app.dmp')
    $text = New-TestFile (Join-Path $filterRoot 'notes.txt')
    $pins = New-TestFile (Join-Path $filterRoot 'f01b4d95cf55d32a.automaticDestinations-ms')
    $other = New-TestFile (Join-Path $filterRoot 'other.automaticDestinations-ms')
    $bin = New-TestFile (Join-Path $filterRoot 'cache.bin')
    $deep = New-TestFile (Join-Path $filterRoot 'sub\deep.dmp')

    $dumpScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'dumps' -Targets @((New-TestTarget -Path $filterRoot -Include '*.dmp')))))[0]
    $dumpFiles = @($dumpScan.Files | ForEach-Object { $_.Path })
    Assert (($dumpFiles -contains $dump) -and -not ($dumpFiles -contains $text)) 'include filter: only *.dmp files'
    Assert (-not ($dumpFiles -contains $deep)) 'no recursion when not asked for'

    $jumpScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'jump' -MinAgeDays 0 -Targets @((New-TestTarget -Path $filterRoot -Include '*.automaticDestinations-ms' -ExcludeName 'f01b4d95cf55d32a.automaticDestinations-ms')))))[0]
    $jumpFiles = @($jumpScan.Files | ForEach-Object { $_.Path })
    Assert (($jumpFiles -contains $other) -and -not ($jumpFiles -contains $pins)) 'Quick Access pins file is excluded'

    $binScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'bin' -Targets @((New-TestTarget -Path $filterRoot -Include '*.bin')))))[0]
    Assert ($binScan.Files.Count -eq 0) '.bin is protected by default'
    $binAllowed = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'bin2' -Targets @((New-TestTarget -Path $filterRoot -Include '*.bin' -AllowExtension '.bin')))))[0]
    Assert ($binAllowed.Files.Count -eq 1) '.bin allowed only where a rule explicitly allows it'

    $rootLink = Join-Path $sandbox 'root-link'
    [void](cmd /c mklink /J "$rootLink" "$filterRoot")
    $linkScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'linkroot' -Targets @((New-TestTarget -Path $rootLink -Recurse)))))[0]
    Assert ($linkScan.State -eq 'Unavailable' -and $linkScan.Files.Count -eq 0) 'a location that is itself a junction is refused'

    foreach ($protected in @([Environment]::GetFolderPath('UserProfile'), [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'))) {
        $protectedScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'protected' -Targets @((New-TestTarget -Path $protected -Recurse)))))[0]
        Assert ($protectedScan.State -eq 'Unavailable' -and $protectedScan.Files.Count -eq 0) "protected folder refused: $protected"
    }

    $blockedScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'blocked' -Processes @('explorer') -Targets @((New-TestTarget -Path $filterRoot)))))[0]
    Assert ($blockedScan.State -eq 'Blocked' -and $blockedScan.Files.Count -eq 0) 'cache is skipped while its app is running'

    $sync = [hashtable]::Synchronized(@{ Cancel = $true })
    $cancelScan = @(Invoke-CleanerScan -Rule @((New-TestRule -Id 'cancel' -Targets @((New-TestTarget -Path $filterRoot)))) -Sync $sync)[0]
    Assert ($cancelScan.State -eq 'Cancelled') 'cancel stops the analysis'

    # ------------------------------------------------------------------ settings
    Write-Host ''
    Write-Host 'Settings' -ForegroundColor Cyan
    $dataFolder = Join-Path $sandbox 'data'
    & $module { param($folder) $script:DataFolderOverride = $folder } $dataFolder
    $cleanedAt = (Get-Date).AddDays(-2)
    for ($n = 0; $n -lt 6; $n++) {
        Save-CleanerSettings -Settings @{
            Theme = $(if ($n % 2 -eq 0) { 'Light' } else { 'Dark' }); Rules = @{ 'temp' = $true; 'jump-lists' = ($n -eq 5) }
            LastCleanedAt = $cleanedAt; LastFreedBytes = [long]1234; TotalFreedBytes = [long](5000 + $n)
        }
    }
    $loaded = Read-CleanerSettings
    Assert ($loaded.Theme -eq 'Dark' -and $loaded.Rules['jump-lists'] -eq $true -and $loaded.Rules['temp'] -eq $true) 'settings survive six quick saves in a row'
    Assert ($loaded.LastCleanedAt -is [DateTime] -and [Math]::Abs(($loaded.LastCleanedAt - $cleanedAt).TotalSeconds) -lt 1 -and $loaded.TotalFreedBytes -eq 5005) 'cleaning statistics are saved and read back'
    Assert (-not (Test-Path -LiteralPath (Join-Path $dataFolder 'settings.json.tmp'))) 'no temporary settings file is left behind'

    # ------------------------------------------------------------------ native helper
    Write-Host ''
    Write-Host 'Native safety helper' -ForegroundColor Cyan
    $finalRoot = [CleanerNative.SafeIO]::GetFinalPath($filterRoot)
    Assert ([CleanerNative.SafeIO]::DeleteFileChecked((Join-Path $filterRoot 'missing.tmp'), $finalRoot, 1, 1, [long]::MaxValue) -eq 'Missing') 'missing file reported as Missing'
    Assert ([CleanerNative.SafeIO]::DeleteFileChecked((Join-Path $filterRoot 'sub'), $finalRoot, 0, 0, [long]::MaxValue) -ne 'Deleted') 'a folder is never deleted as a file'
    Assert ([CleanerNative.SafeIO]::DeleteEmptyFolderChecked((Join-Path $filterRoot 'sub'), $finalRoot) -eq 'NotEmpty') 'a folder with content is not removed'
    Assert ([CleanerNative.SafeIO]::DeleteEmptyFolderChecked($filterRoot, $finalRoot) -eq 'Outside') 'the location itself is never removed'
    Assert (-not [CleanerNative.SafeIO]::IsStrictlyUnder('C:\a\bc\file', 'C:\a\b')) 'prefix trick (C:\a\bc vs C:\a\b) rejected'
    Assert (-not [CleanerNative.SafeIO]::IsStrictlyUnder('C:\Windows\x', 'C:\')) 'a drive root is never a location'
    Assert ($null -ne [CleanerNative.SafeIO]::QueryRecycleBin()) 'Recycle Bin size can be read (read-only)'
    Assert ((Format-CleanerSize 1536) -eq ('{0:N1} KB' -f 1.5) -or (Format-CleanerSize 1536) -eq '2 KB') 'size formatting works'

    # ------------------------------------------------------------------ browser cache folders
    Write-Host ''
    Write-Host 'Browser cache folders' -ForegroundColor Cyan
    $fakeBrowser = Join-Path $sandbox 'FakeBrowser\User Data'
    foreach ($relative in 'Default\Cache\Cache_Data', 'Default\Code Cache', 'Profile 2\GPUCache', 'component_crx_cache',
                          'Default\Local Storage', 'Default\Service Worker', 'Default\Extensions', 'Default\component_crx_cache') {
        [void](New-Item -ItemType Directory -Path (Join-Path $fakeBrowser $relative) -Force)
    }
    $browserTargets = @(& (Get-Module CleanerEngine) { param($p) Get-ChromiumCacheTarget -DataPath $p } $fakeBrowser | ForEach-Object { $_.Path.Substring($fakeBrowser.Length + 1) })
    Assert (('Default\Cache\Cache_Data', 'Default\Code Cache', 'Profile 2\GPUCache', 'component_crx_cache' | Where-Object { $browserTargets -notcontains $_ }).Count -eq 0) 'browser caches and downloaded components are found'
    Assert (('Default\Local Storage', 'Default\Service Worker', 'Default\Extensions', 'Default\component_crx_cache' | Where-Object { $browserTargets -contains $_ }).Count -eq 0) 'site data, extensions and service workers are never included'

    # ------------------------------------------------------------------ browsing activity
    Write-Host ''
    Write-Host 'Browsing activity (sandbox only)' -ForegroundColor Cyan
    $activityRoot = Join-Path $sandbox 'ActivityBrowser\User Data'
    $activityGone = @('Default\History', 'Default\History-journal', 'Default\Top Sites', 'Default\Shortcuts', 'Default\Network Action Predictor', 'Profile 2\History')
    $activityKept = @('Default\Login Data', 'Default\Login Data-journal', 'Default\Login Data For Account', 'Default\Cookies', 'Default\Network\Cookies',
                      'Default\Web Data', 'Default\Bookmarks', 'Default\Bookmarks.bak', 'Default\Preferences', 'Default\Secure Preferences', 'Default\Favicons',
                      'Default\Sessions\Session_1', 'Default\Extensions\abc\manifest.json', 'Default\Local Storage\leveldb\000001.log', 'Default\History Backup',
                      'Default\Sub\History', 'Guest Profile\History', 'Local State')
    foreach ($relative in ($activityGone + $activityKept)) { [void](New-TestFile -Path (Join-Path $activityRoot $relative)) }
    $activityTargets = @(& $module { param($p) Get-ChromiumHistoryTarget -DataPath $p } $activityRoot)
    $activityRule = New-TestRule -Id 'activity' -MinAgeDays 0 -Processes @('CleanerNoSuchProcess') -Targets $activityTargets
    $activityScan = @(Invoke-CleanerScan -Rule @($activityRule))[0]
    Assert ($activityScan.Count -eq $activityGone.Count) ('analysis finds only the activity files ({0} of {1})' -f $activityScan.Count, $activityGone.Count)
    [void](Invoke-CleanerClean -ScanResult @($activityScan))
    Assert (@($activityGone | Where-Object { Test-Exists (Join-Path $activityRoot $_) }).Count -eq 0) 'history files are removed'
    $activityLost = @($activityKept | Where-Object { -not (Test-Exists (Join-Path $activityRoot $_)) })
    Assert ($activityLost.Count -eq 0) ('passwords, cookies, bookmarks, settings, extensions and open tabs stay' + $(if ($activityLost) { ': lost ' + ($activityLost -join ', ') } else { '' }))
    $historyRules = @(Get-CleanerRule -IncludeUnavailable | Where-Object { $_.Id -like '*-history' })
    Assert ($historyRules.Count -ge 6 -and @($historyRules | Where-Object { $_.Recommended -or -not $_.Caution -or $_.Processes.Count -eq 0 }).Count -eq 0) 'history items are never preselected and need the browser closed'
    $historyNames = @(& $module { $script:ChromiumHistoryFiles })
    Assert (@($historyNames | Where-Object { $_ -match '[*?\[\]]|Login|Cookies|Web Data|Bookmarks|Preferences|Sessions|Local State' }).Count -eq 0) 'the history file list has no wildcards and no password, cookie or bookmark file'

    # ------------------------------------------------------------------ File Explorer recent folders (read-only)
    Write-Host ''
    Write-Host 'File Explorer recent folders (read-only)' -ForegroundColor Cyan
    $explorerRule = @(Get-CleanerRule | Where-Object { $_.Id -eq 'explorer-recent' })
    Assert ($explorerRule.Count -eq 1 -and $explorerRule[0].Kind -eq 'ExplorerRecent') 'File Explorer recent folders item exists'
    $pinnedSeen = @(& (Get-Module CleanerEngine) { Get-CleanerExplorerRecentItem } | Where-Object { $_.Item.ExtendedProperty('System.Home.IsPinned') -ne $false })
    Assert ($pinnedSeen.Count -eq 0) 'pinned Quick Access folders are never listed for removal'
    $explorerCheck = & (Get-Module CleanerEngine) {
        $p = Get-CleanerQuickAccessPinned
        $entries = @(Get-CleanerExplorerRecentEntry)
        @{ Pinned = $p.Count; Entries = $entries.Count; PinnedInList = @($entries | Where-Object { $p.Contains($_) }).Count; NotText = @($entries | Where-Object { $_ -isnot [string] }).Count }
    }
    Assert ($explorerCheck.NotText -eq 0) ('recent entries are read one by one ({0} found, {1} pinned folders)' -f $explorerCheck.Entries, $explorerCheck.Pinned)
    Assert ($explorerCheck.PinnedInList -eq 0) 'pinned folders are never listed for removal from the taskbar list either'

    # ------------------------------------------------------------------ real locations (read-only)
    Write-Host ''
    Write-Host 'Real cleanup locations (analysis only, nothing is deleted)' -ForegroundColor Cyan
    $realRules = @(Get-CleanerRule)
    Assert ($realRules.Count -gt 0) "built-in rules found: $($realRules.Count)"
    $realScan = @(Invoke-CleanerScan -Rule $realRules)
    $errors = @($realScan | Where-Object { $_.State -eq 'Error' })
    Assert ($errors.Count -eq 0) ('no rule failed to analyze' + $(if ($errors) { ': ' + (($errors | ForEach-Object { "$($_.RuleId): $($_.Message)" }) -join '; ') } else { '' }))
    foreach ($result in $realScan) {
        Write-Host ('        {0,-16} {1,-12} {2,10}  {3}' -f $result.RuleId, $result.State, (Format-CleanerSize $result.Bytes), $result.Message) -ForegroundColor DarkGray
    }
}
finally {
    foreach ($handle in $handles) { try { $handle.Dispose() } catch { } }
    # Remove links first (only the links themselves), then the sandbox.
    if (Test-Path -LiteralPath $sandbox) {
        Get-ChildItem -LiteralPath $sandbox -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { if ($_.PSIsContainer) { [IO.Directory]::Delete($_.FullName) } else { [IO.File]::Delete($_.FullName) } }
        Get-ChildItem -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { } }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
$color = if ($script:Failed -eq 0) { 'Green' } else { 'Red' }
Write-Host ('{0} passed, {1} failed' -f $script:Passed, $script:Failed) -ForegroundColor $color
if ($script:Failed -gt 0) { exit 1 }
