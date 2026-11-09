#requires -Version 5.1
<#
.SYNOPSIS
    Cleaner - frees disk space and clears activity history, safely.

.DESCRIPTION
    Start it by double-clicking Cleaner.cmd.
      Clean     analyze your PC (nothing is deleted), then clean with one click
      Items     choose exactly what to clean and see every file before it goes
      Tools     shortcuts to the Windows storage and cleanup tools
      Safety    what Cleaner never touches and the checks every file must pass
      Settings  theme, administrator rights and statistics

    All cleanup rules and safety checks live in CleanerEngine.psm1 (same folder).
    Settings: %LOCALAPPDATA%\Cleaner\settings.json    Log: %LOCALAPPDATA%\Cleaner\Logs

.PARAMETER Restarted
    Used internally when Cleaner restarts itself (for example with administrator rights).
#>
[CmdletBinding()]
param(
    [switch]$Restarted
)

$ErrorActionPreference = 'Stop'
$script:AppVersion   = '2.1'
$script:ScriptPath   = $PSCommandPath
$script:AppRoot      = $PSScriptRoot
$script:EnginePath   = Join-Path $PSScriptRoot 'CleanerEngine.psm1'
$script:IsDotSourced = ($MyInvocation.InvocationName -eq '.')
$script:Ellipsis     = [string][char]0x2026
$script:Dot          = ' ' + [char]0x00B7 + ' '
$script:Bullet       = [string][char]0x2022
$script:Nbsp         = [string][char]0x00A0

# Windows Forms needs a single-threaded apartment (Windows PowerShell uses one by default).
if (-not $script:IsDotSourced -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $script:ScriptPath)
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    Import-Module -Name $script:EnginePath -Force -DisableNameChecking -ErrorAction Stop
}
catch {
    [void][System.Windows.Forms.MessageBox]::Show(
        ("Cleaner could not start because its engine did not load:`r`n`r`n{0}`r`n`r`nKeep CleanerEngine.psm1 in the same folder as Cleaner.ps1." -f $_.Exception.Message),
        'Cleaner', 'OK', 'Error')
    return
}

# ------------------------------------------------------------------------------------------------
#  One instance at a time
# ------------------------------------------------------------------------------------------------
$script:Mutex = $null
if (-not $script:IsDotSourced) {
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\Programix.Cleaner')
    $owned = $false
    try { $owned = $script:Mutex.WaitOne($(if ($Restarted) { 15000 } else { 0 })) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        [void][System.Windows.Forms.MessageBox]::Show('Cleaner is already open.', 'Cleaner', 'OK', 'Information')
        return
    }
}

# ------------------------------------------------------------------------------------------------
#  Display setup (sharp text on high-DPI screens)
# ------------------------------------------------------------------------------------------------
[void][CleanerNative.Ui]::EnableDpiAwareness()
[System.Windows.Forms.Application]::EnableVisualStyles()
try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { }
if (-not $script:IsDotSourced) { [void][CleanerNative.Ui]::HideOwnConsoleWindow() }

$script:Scale = 1.0
try {
    $graphics = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:Scale = [Math]::Max(1.0, $graphics.DpiX / 96.0)
    $graphics.Dispose()
}
catch { }

function S([double]$Value) { [int][Math]::Round($Value * $script:Scale) }
function New-Point([double]$X, [double]$Y) { New-Object System.Drawing.Point((S $X), (S $Y)) }
function New-Size([double]$Width, [double]$Height) { New-Object System.Drawing.Size((S $Width), (S $Height)) }
function New-UiFont([single]$Size, [string]$Style = 'Regular', [string]$Family = 'Segoe UI') {
    New-Object System.Drawing.Font($Family, $Size, [System.Drawing.FontStyle]$Style)
}


$script:Fonts = @{
    NavLabel   = New-UiFont 10 'Regular' 'Segoe UI Semibold'
    Badge      = New-UiFont 8.25 'Bold'
    HeroTitle  = New-UiFont 22 'Regular' 'Segoe UI Semibold'
    HeroSub    = New-UiFont 10
    HeroButton = New-UiFont 13 'Regular' 'Segoe UI Semibold'
    PageTitle  = New-UiFont 18 'Regular' 'Segoe UI Semibold'
    PageSub    = New-UiFont 9.5
    CardTitle  = New-UiFont 11 'Regular' 'Segoe UI Semibold'
    Stat       = New-UiFont 14 'Regular' 'Segoe UI Semibold'
    Section    = New-UiFont 8.25 'Bold'
    RowTitle   = New-UiFont 10 'Regular' 'Segoe UI Semibold'
    RowText    = New-UiFont 8.5
    Result     = New-UiFont 10 'Regular' 'Segoe UI Semibold'
    Small      = New-UiFont 8.25
    Body       = New-UiFont 9
    Button     = New-UiFont 10.5 'Regular' 'Segoe UI Semibold'
    Pill       = New-UiFont 7 'Bold'
    Dialog     = New-UiFont 14 'Regular' 'Segoe UI Semibold'
}

# Names of Cleaner's own vector icons (drawn by Draw-Icon).
$script:Glyph = @{
    Broom = 'clean'; Items = 'items'; Tools = 'tools'; Shield = 'shield'; Settings = 'settings'; Admin = 'admin'
    Folder = 'folder'; Lock = 'lock'; Drive = 'database'; Disk = 'disk'; Apps = 'apps'; Document = 'document'
    Chip = 'chip'; Check = 'check'; History = 'history'; Trash = 'trash'; Gauge = 'gauge'; Power = 'power'
    Open = 'open'; Monitor = 'monitor'; Sun = 'sun'; Moon = 'moon'; Sparkle = 'sparkle'
}

function New-Rgb([int]$Red, [int]$Green, [int]$Blue) { [System.Drawing.Color]::FromArgb($Red, $Green, $Blue) }

$script:Palettes = @{
    Dark  = @{
        Window       = New-Rgb 17 24 39
        Rail         = New-Rgb 17 24 39
        Card         = New-Rgb 25 35 51
        CardHover    = New-Rgb 32 46 64
        CardBorder   = New-Rgb 43 56 73
        Text         = New-Rgb 255 255 255
        Muted        = New-Rgb 160 177 198
        NavText      = New-Rgb 196 196 196
        NavSelected  = New-Rgb 27 65 69
        NavHover     = New-Rgb 18 27 41
        Accent       = New-Rgb 30 164 144
        AccentHover  = New-Rgb 38 182 160
        AccentDown   = New-Rgb 24 138 121
        AccentText   = New-Rgb 86 212 190
        AccentSoft   = New-Rgb 30 64 60
        OnAccent     = New-Rgb 255 255 255
        Coral        = New-Rgb 246 96 96
        Success      = New-Rgb 86 206 130
        Warning      = New-Rgb 242 176 82
        WarningSoft  = New-Rgb 74 57 31
        Badge        = New-Rgb 232 72 78
        Line         = New-Rgb 38 51 69
        Track        = New-Rgb 58 58 58
        Button       = New-Rgb 32 46 64
        ButtonHover  = New-Rgb 42 59 79
        ButtonDown   = New-Rgb 26 38 54
        ButtonBorder = New-Rgb 65 83 105
        CheckBorder  = New-Rgb 140 140 140
        Disabled     = New-Rgb 110 110 110
        FrameBorder  = New-Rgb 58 58 58
    }
    Light = @{
        Window       = New-Rgb 244 247 251
        Rail         = New-Rgb 244 247 251
        Card         = New-Rgb 255 255 255
        CardHover    = New-Rgb 247 247 247
        CardBorder   = New-Rgb 226 226 226
        Text         = New-Rgb 26 26 26
        Muted        = New-Rgb 96 96 96
        NavText      = New-Rgb 72 72 72
        NavSelected  = New-Rgb 212 236 233
        NavHover     = New-Rgb 224 232 241
        Accent       = New-Rgb 18 150 130
        AccentHover  = New-Rgb 24 166 144
        AccentDown   = New-Rgb 14 128 111
        AccentText   = New-Rgb 10 126 110
        AccentSoft   = New-Rgb 212 240 234
        OnAccent     = New-Rgb 255 255 255
        Coral        = New-Rgb 214 62 62
        Success      = New-Rgb 22 134 68
        Warning      = New-Rgb 176 96 6
        WarningSoft  = New-Rgb 254 241 219
        Badge        = New-Rgb 222 56 62
        Line         = New-Rgb 230 230 230
        Track        = New-Rgb 222 222 222
        Button       = New-Rgb 255 255 255
        ButtonHover  = New-Rgb 245 245 245
        ButtonDown   = New-Rgb 235 235 235
        ButtonBorder = New-Rgb 208 208 208
        CheckBorder  = New-Rgb 128 128 128
        Disabled     = New-Rgb 170 170 170
        FrameBorder  = New-Rgb 214 214 214
    }
}

# ------------------------------------------------------------------------------------------------
#  State
# ------------------------------------------------------------------------------------------------
$script:IsAdmin        = Test-CleanerAdmin
$script:Settings       = Read-CleanerSettings
$script:Rules          = @(Get-CleanerRule)
$script:Groups         = Get-CleanerGroup
$script:Rows           = New-Object System.Collections.ArrayList
$script:RowById        = @{}
$script:NavItems       = @{}
$script:Pages          = @{}
$script:CurrentPage    = 'clean'
$script:Job            = $null
$script:Runspace       = $null
$script:Loading        = $true
$script:LastClean      = $null
$script:LastScanAt     = $null
$script:CloseWhenIdle  = $false
$script:Palette        = $null
$script:IsDark         = $false
$script:AppIcon        = $null
$script:HeroImage      = $null
$script:HeroParts      = @()
$script:HeroAction     = 'analyze'
$script:HeroLinkAction = 'items'
$script:AnimationTime  = 0.0
$script:ShowFocus      = $false
$script:StaleMinutes   = 10
$script:ClosingApps    = $false

$script:GroupNotes = @{
    Browsers  = 'Cleaned only while the browser is closed'
    Activity  = 'Passwords, cookies and bookmarks stay'
    Apps      = 'Cleaned only while the app is closed'
    Privacy   = 'Your files are never touched'
    Developer = 'Downloaded again when needed'
    Graphics  = 'Rebuilt automatically'
    Admin     = 'Running as administrator'
}

# Floating light particles of the illustration (fixed seed: the same picture every time).
$script:Particles = New-Object System.Collections.ArrayList
$random = New-Object System.Random(11)
for ($i = 0; $i -lt 30; $i++) {
    [void]$script:Particles.Add(@{
            X = $random.NextDouble() * 92 - 46; Speed = 16 + $random.NextDouble() * 28; Phase = $random.NextDouble() * 150
            Size = 1.1 + $random.NextDouble() * 1.9; Alpha = 90 + $random.Next(140); White = ($random.NextDouble() -lt 0.3)
        })
}

Remove-CleanerOldLog -KeepDays 30

# ------------------------------------------------------------------------------------------------
#  Small helpers
# ------------------------------------------------------------------------------------------------
function Format-Count([long]$Count, [string]$Unit) {
    if ($Count -eq 1) { return ('1 {0}' -f $Unit) }
    return ('{0:N0} {1}s' -f $Count, $Unit)
}

function Format-RelativeTime($Time) {
    if ($Time -isnot [DateTime]) { return '' }
    $span = [DateTime]::Now - $Time
    if ($span.TotalSeconds -lt 60) { return 'just now' }
    if ($span.TotalMinutes -lt 60) { $n = [int][Math]::Floor($span.TotalMinutes); return $(if ($n -eq 1) { '1 minute ago' } else { "$n minutes ago" }) }
    if ($span.TotalHours -lt 24) { $n = [int][Math]::Floor($span.TotalHours); return $(if ($n -eq 1) { '1 hour ago' } else { "$n hours ago" }) }
    if ($span.TotalDays -lt 2) { return 'yesterday' }
    if ($span.TotalDays -lt 30) { return ('{0} days ago' -f [int][Math]::Floor($span.TotalDays)) }
    return ('on ' + $Time.ToString('d'))
}

function Format-ShortPath([string]$Path) {
    foreach ($pair in @(
            @([Environment]::GetFolderPath('LocalApplicationData'), '%LOCALAPPDATA%'),
            @([Environment]::GetFolderPath('ApplicationData'), '%APPDATA%'),
            @([Environment]::GetFolderPath('CommonApplicationData'), '%PROGRAMDATA%'),
            @([Environment]::GetFolderPath('Windows'), '%WINDIR%'),
            @([Environment]::GetFolderPath('UserProfile'), '%USERPROFILE%'))) {
        if ($pair[0] -and $Path.StartsWith($pair[0], [StringComparison]::OrdinalIgnoreCase)) {
            return $pair[1] + $Path.Substring($pair[0].Length)
        }
    }
    return $Path
}

function Test-SystemDarkMode {
    try {
        $value = Get-ItemPropertyValue -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction Stop
        return ($value -eq 0)
    }
    catch { return $false }
}

function Invoke-Safely([scriptblock]$Action, [string]$What = 'This action') {
    try { & $Action }
    catch {
        $message = $_.Exception.Message
        try { Add-CleanerLogEntry -Kind 'UI-ERROR' -Message ('{0}: {1}' -f $What, $_) } catch { }
        [void][System.Windows.Forms.MessageBox]::Show(("{0} did not work:`r`n`r`n{1}" -f $What, $message), 'Cleaner', 'OK', 'Warning')
    }
}

function Set-DoubleBuffered($Control) {
    $property = $Control.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance, NonPublic')
    if ($null -ne $property) { $property.SetValue($Control, $true, $null) }
    # Repaint the whole control when its size changes; otherwise centered and rounded drawings keep their old place.
    $setStyle = $Control.GetType().GetMethod('SetStyle', [Reflection.BindingFlags]'Instance, NonPublic')
    if ($null -ne $setStyle) { [void]$setStyle.Invoke($Control, @([System.Windows.Forms.ControlStyles]::ResizeRedraw, $true)) }
}

function ConvertTo-ColorRef([System.Drawing.Color]$Color) { [int]$Color.R + 256 * [int]$Color.G + 65536 * [int]$Color.B }

function Get-BackColor($Control) {
    # The color behind a control: rounded cards paint their own color, everything else uses BackColor.
    $current = $Control
    while ($null -ne $current) {
        $tag = $current.Tag
        if ($tag -is [hashtable] -and $tag.Role -eq 'cardhost') {
            return $(if ($tag.Hover) { $script:Palette.CardHover } else { $script:Palette.Card })
        }
        if ($current.BackColor.A -eq 255) { return $current.BackColor }
        $current = $current.Parent
    }
    return $script:Palette.Window
}

function Open-LogFolder {
    $folder = Get-CleanerLogFolder
    if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
}

function Open-DataFolder {
    $folder = Get-CleanerDataFolder
    if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
}

# ------------------------------------------------------------------------------------------------
#  Drawing primitives
# ------------------------------------------------------------------------------------------------
$script:CenterText = [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter, SingleLine, NoPadding, NoPrefix'

function New-RoundedPath([single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $Radius = [Math]::Max([single]1, [Math]::Min($Radius, [Math]::Min($Width, $Height) / 2))
    $d = $Radius * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $Width - $d, $Y + $Height - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Fill-RoundRect($G, $Color, [single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius) {
    $path = New-RoundedPath $X $Y $Width $Height $Radius
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $G.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
}

# ------------------------------------------------------------------------------------------------
#  Cleaner's own icons and logo: vector drawings made for Cleaner (no icon fonts, no image files).
#  Icons are drawn on a 24 x 24 grid with round 1.7 strokes, so they stay sharp at every size.
# ------------------------------------------------------------------------------------------------
function P([double]$X, [double]$Y) { [System.Drawing.PointF]::new([single]$X, [single]$Y) }

function Add-RoundRect($Path, [single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Radius) {
    $d = [single]($Radius * 2)
    $Path.AddArc($X, $Y, $d, $d, [single]180, [single]90)
    $Path.AddArc([single]($X + $Width - $d), $Y, $d, $d, [single]270, [single]90)
    $Path.AddArc([single]($X + $Width - $d), [single]($Y + $Height - $d), $d, $d, [single]0, [single]90)
    $Path.AddArc($X, [single]($Y + $Height - $d), $d, $d, [single]90, [single]90)
    $Path.CloseFigure()
}
function Draw-Ellipse($G, $Pen, [single]$X, [single]$Y, [single]$Width, [single]$Height) { $G.DrawEllipse($Pen, $X, $Y, $Width, $Height) }
function Fill-Ellipse($G, $Brush, [single]$X, [single]$Y, [single]$Width, [single]$Height) { $G.FillEllipse($Brush, $X, $Y, $Width, $Height) }
function Draw-Arc($G, $Pen, [single]$X, [single]$Y, [single]$Width, [single]$Height, [single]$Start, [single]$Sweep) { $G.DrawArc($Pen, $X, $Y, $Width, $Height, $Start, $Sweep) }

function Get-SparklePoint([double]$CenterX, [double]$CenterY, [double]$Outer, [double]$Inner) {
    $points = New-Object 'System.Drawing.PointF[]' 8
    for ($i = 0; $i -lt 8; $i++) {
        $angle = [Math]::PI / 4 * $i - [Math]::PI / 2
        $radius = if ($i % 2 -eq 0) { $Outer } else { $Inner }
        $points[$i] = P ($CenterX + $radius * [Math]::Cos($angle)) ($CenterY + $radius * [Math]::Sin($angle))
    }
    return , $points
}

function Add-ShieldPath($Path) {
    $Path.AddLine((P 12 3), (P 19 5.8))
    $Path.AddLine((P 19 5.8), (P 19 11))
    $Path.AddBezier((P 19 11), (P 19 15.6), (P 16 19), (P 12 21))
    $Path.AddBezier((P 12 21), (P 8 19), (P 5 15.6), (P 5 11))
    $Path.AddLine((P 5 11), (P 5 5.8))
    $Path.CloseFigure()
}

function Draw-Icon($G, [string]$Name, [single]$X, [single]$Y, [single]$Size, [System.Drawing.Color]$Color) {
    $saved = $G.Save()
    $pen = New-Object System.Drawing.Pen($Color, [single][Math]::Max(1.7, 1.6 * 24.0 / [Math]::Max(1, $Size)))   # at least ~1.6 px on screen
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $brush = New-Object System.Drawing.SolidBrush($Color)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    try {
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $G.TranslateTransform($X, $Y)
        $G.ScaleTransform([single]($Size / 24.0), [single]($Size / 24.0))
        switch ($Name) {
            'clean' {
                $G.DrawPolygon($pen, [System.Drawing.PointF[]]@((P 9 10), (P 14 15), (P 10.5 21), (P 3 13.5)))
                $G.DrawLine($pen, (P 11.5 12.5), (P 20 4))
                $G.DrawLine($pen, (P 10.7 11.7), (P 6.6 15.2))
                $G.DrawLine($pen, (P 12.3 13.3), (P 8.8 17.6))
            }
            'items' {
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 3.5 6.5), (P 5 8), (P 7.5 5)))
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 3.5 12.5), (P 5 14), (P 7.5 11)))
                Draw-Ellipse $G $pen 3.6 16.7 3.8 3.8
                foreach ($y in 6.5, 12.5, 18.6) { $G.DrawLine($pen, (P 11 $y), (P 20.5 $y)) }
            }
            'tools' {
                Draw-Arc $G $pen 12 3 9 9 345 300
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 20.85 6.34), (P 17.4 6.6), (P 17.66 3.15)))
                $G.DrawLine($pen, (P 13.3 10.7), (P 4.6 19.4))
            }
            'shield' {
                Add-ShieldPath $path
                $G.DrawPath($pen, $path)
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 8.8 12.2), (P 11 14.4), (P 15.4 9.8)))
            }
            'admin' {
                Add-ShieldPath $path
                $G.DrawPath($pen, $path)
                Fill-Ellipse $G $brush 10.4 8.4 3.2 3.2
                $G.DrawLine($pen, (P 12 11.5), (P 12 15.2))
            }
            'settings' {
                $teeth = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
                for ($t = 0; $t -lt 8; $t++) {
                    foreach ($pair in @(@(-15, 7.3), @(-8.5, 9.7), @(8.5, 9.7), @(15, 7.3))) {
                        $angle = ($t * 45 + $pair[0]) * [Math]::PI / 180
                        $teeth.Add((P (12 + $pair[1] * [Math]::Cos($angle)) (12 + $pair[1] * [Math]::Sin($angle))))
                    }
                }
                $G.DrawPolygon($pen, $teeth.ToArray())
                Draw-Ellipse $G $pen 8.9 8.9 6.2 6.2
            }
            'folder' {
                $G.DrawPolygon($pen, [System.Drawing.PointF[]]@((P 3 6), (P 9.5 6), (P 11.5 8.2), (P 21 8.2), (P 21 19), (P 3 19)))
                $G.DrawLine($pen, (P 3 11), (P 21 11))
            }
            'lock' {
                Add-RoundRect $path 5 10.5 14 10 2.2
                $G.DrawPath($pen, $path)
                Draw-Arc $G $pen 8 3.5 8 8 180 180
                $G.DrawLine($pen, (P 8 7.5), (P 8 10.5))
                $G.DrawLine($pen, (P 16 7.5), (P 16 10.5))
                Fill-Ellipse $G $brush 10.8 14.3 2.4 2.4
            }
            'database' {
                Draw-Ellipse $G $pen 5 3.5 14 5
                $G.DrawLine($pen, (P 5 6), (P 5 18))
                $G.DrawLine($pen, (P 19 6), (P 19 18))
                Draw-Arc $G $pen 5 15.5 14 5 0 180
                Draw-Arc $G $pen 5 9.6 14 5 0 180
            }
            'disk' {
                Add-RoundRect $path 3 6 18 12 2.5
                $G.DrawPath($pen, $path)
                $G.DrawLine($pen, (P 3 13), (P 21 13))
                Fill-Ellipse $G $brush 16 14.6 1.9 1.9
            }
            'apps' {
                foreach ($corner in @(@(3.5, 3.5), @(13.5, 3.5), @(3.5, 13.5), @(13.5, 13.5))) { Add-RoundRect $path $corner[0] $corner[1] 7 7 1.8 }
                $G.DrawPath($pen, $path)
            }
            'document' {
                $G.DrawPolygon($pen, [System.Drawing.PointF[]]@((P 5 3), (P 14 3), (P 19 8), (P 19 21), (P 5 21)))
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 14 3), (P 14 8), (P 19 8)))
                $G.DrawLine($pen, (P 8.5 13), (P 15.5 13))
                $G.DrawLine($pen, (P 8.5 16.5), (P 13.5 16.5))
            }
            'chip' {
                Add-RoundRect $path 6 6 12 12 2
                Add-RoundRect $path 9.5 9.5 5 5 1
                $G.DrawPath($pen, $path)
                foreach ($v in 9, 12, 15) {
                    $G.DrawLine($pen, (P $v 3), (P $v 6)); $G.DrawLine($pen, (P $v 18), (P $v 21))
                    $G.DrawLine($pen, (P 3 $v), (P 6 $v)); $G.DrawLine($pen, (P 18 $v), (P 21 $v))
                }
            }
            'check' { $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 5 12.5), (P 10 17), (P 19 7.5))) }
            'history' {
                Draw-Arc $G $pen 4 4 16 16 200 300
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 3.6 5.6), (P 4.48 9.26), (P 8.1 8.5)))
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 12 7.6), (P 12 12), (P 15 13.8)))
            }
            'trash' {
                $G.DrawLine($pen, (P 4 6.5), (P 20 6.5))
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 9.5 6.5), (P 9.5 4), (P 14.5 4), (P 14.5 6.5)))
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 6 6.5), (P 7.2 20.2), (P 16.8 20.2), (P 18 6.5)))
                $G.DrawLine($pen, (P 10 10.5), (P 10 16.5))
                $G.DrawLine($pen, (P 14 10.5), (P 14 16.5))
            }
            'gauge' {
                Draw-Arc $G $pen 3.5 5 17 17 150 240
                $G.DrawLine($pen, (P 12 13.5), (P 15.6 9.6))
                Fill-Ellipse $G $brush 10.6 12.1 2.8 2.8
            }
            'power' {
                Draw-Arc $G $pen 5 5.5 14 14 300 300
                $G.DrawLine($pen, (P 12 3), (P 12 10.5))
            }
            'open' {
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 11 5), (P 5 5), (P 5 19), (P 19 19), (P 19 13)))
                $G.DrawLines($pen, [System.Drawing.PointF[]]@((P 14 4), (P 20 4), (P 20 10)))
                $G.DrawLine($pen, (P 20 4), (P 11.5 12.5))
            }
            'monitor' {
                Add-RoundRect $path 3 4 18 12.5 2.2
                $G.DrawPath($pen, $path)
                $G.DrawLine($pen, (P 12 16.5), (P 12 20))
                $G.DrawLine($pen, (P 8 20), (P 16 20))
            }
            'sun' {
                Draw-Ellipse $G $pen 8 8 8 8
                for ($r = 0; $r -lt 8; $r++) {
                    $angle = $r * [Math]::PI / 4
                    $G.DrawLine($pen, (P (12 + 6.6 * [Math]::Cos($angle)) (12 + 6.6 * [Math]::Sin($angle))), (P (12 + 9.2 * [Math]::Cos($angle)) (12 + 9.2 * [Math]::Sin($angle))))
                }
            }
            'moon' {
                $path.AddBezier((P 15.5 4), (P 11 4.5), (P 6.5 8), (P 6.5 13))
                $path.AddBezier((P 6.5 13), (P 6.5 17.5), (P 10 20.5), (P 14 20.5))
                $path.AddBezier((P 14 20.5), (P 16.8 20.5), (P 19.2 18.8), (P 20.3 16.3))
                $path.AddBezier((P 20.3 16.3), (P 15.5 17), (P 11.5 13.5), (P 11.8 9))
                $path.AddBezier((P 11.8 9), (P 11.9 7), (P 13.3 5.2), (P 15.5 4))
                $path.CloseFigure()
                $G.DrawPath($pen, $path)
            }
            'sparkle' {
                $G.FillPolygon($brush, (Get-SparklePoint 11 13 8.5 2.2))
                $G.FillPolygon($brush, (Get-SparklePoint 18.5 5.5 3.6 1))
            }
            default { Draw-Ellipse $G $pen 5 5 14 14 }
        }
    }
    finally {
        $G.Restore($saved)
        $pen.Dispose(); $brush.Dispose(); $path.Dispose()
    }
}

function Draw-BrandMark($G, [single]$X, [single]$Y, [single]$Size, [System.Drawing.Color]$Color, [switch]$Simple) {
    # Cleaner's mark (100 x 100 grid): an open ring - the C of Cleaner - with a dot in its opening.
    $saved = $G.Save()
    $pen = New-Object System.Drawing.Pen($Color, [single]11)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $brush = New-Object System.Drawing.SolidBrush($Color)
    try {
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $G.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $G.TranslateTransform($X, $Y)
        $G.ScaleTransform([single]($Size / 100.0), [single]($Size / 100.0))
        Draw-Arc $G $pen 25 25 50 50 0 280
        Fill-Ellipse $G $brush 62.6 27.3 13.2 13.2
    }
    finally {
        $G.Restore($saved)
        $pen.Dispose(); $brush.Dispose()
    }
}

function New-LogoBitmap([int]$Size) {
    $bitmap = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $path = New-RoundedPath 0 0 ($Size - 1) ($Size - 1) ([Math]::Max(2, $Size * 0.26))
        $gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point($Size, $Size)), (New-Rgb 30 196 168), (New-Rgb 78 84 226))
        $g.FillPath($gradient, $path)
        $g.SetClip($path)
        $shineHeight = [Math]::Max(2, [int]($Size * 0.55))
        $shine = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, ($shineHeight + 1))), [System.Drawing.Color]::FromArgb(56, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255))
        $g.FillRectangle($shine, 0, 0, $Size, $shineHeight)
        $g.ResetClip()
        Draw-BrandMark $g ([single]($Size * 0.06)) ([single]($Size * 0.06)) ([single]($Size * 0.88)) ([System.Drawing.Color]::White) -Simple:($Size -lt 32)
        $shine.Dispose(); $gradient.Dispose(); $path.Dispose()
    }
    finally { $g.Dispose() }
    return $bitmap
}

function ConvertTo-IconDib([System.Drawing.Bitmap]$Bitmap) {
    # One 32-bit image of an .ico file (header, bottom-up BGRA pixels, empty mask: the alpha decides).
    $size = $Bitmap.Width
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    $writer.Write([uint32]40); $writer.Write([int32]$size); $writer.Write([int32]($size * 2))
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]0); $writer.Write([uint32]0)
    $writer.Write([int32]0); $writer.Write([int32]0); $writer.Write([uint32]0); $writer.Write([uint32]0)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $pixels = New-Object byte[] ($data.Stride * $size)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    $Bitmap.UnlockBits($data)
    for ($row = $size - 1; $row -ge 0; $row--) { $writer.Write($pixels, ($row * $data.Stride), ($size * 4)) }
    $writer.Write((New-Object byte[] ([int]([Math]::Ceiling($size / 32.0) * 4) * $size)))
    $writer.Flush()
    return , $stream.ToArray()
}

function New-IconBytes([int[]]$Sizes, [switch]$PngForLarge) {
    $images = New-Object 'System.Collections.Generic.List[byte[]]'
    foreach ($size in $Sizes) {
        $bitmap = New-LogoBitmap $size
        try {
            if ($PngForLarge -and $size -ge 256) {
                $png = New-Object System.IO.MemoryStream
                $bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
                $images.Add($png.ToArray())
            }
            else { $images.Add((ConvertTo-IconDib $bitmap)) }
        }
        finally { $bitmap.Dispose() }
    }
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$Sizes.Count)
    $offset = 6 + 16 * $Sizes.Count
    for ($i = 0; $i -lt $Sizes.Count; $i++) {
        $side = $(if ($Sizes[$i] -ge 256) { 0 } else { $Sizes[$i] })
        $writer.Write([byte]$side); $writer.Write([byte]$side); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($image in $images) { $writer.Write($image) }
    $writer.Flush()
    return , $stream.ToArray()
}

function Save-CleanerIcon([string]$Path) {
    $folder = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($folder)) { [void][IO.Directory]::CreateDirectory($folder) }
    [IO.File]::WriteAllBytes($Path, (New-IconBytes @(16, 20, 24, 32, 40, 48, 64, 128, 256) -PngForLarge))
}

function New-IconBox($Parent, [string]$Name, [double]$X, [double]$Y, [double]$Size = 20, [string]$Color = 'AccentText') {
    $box = New-Object System.Windows.Forms.Panel
    $box.Location = New-Point $X $Y
    $box.Size = New-Size $Size $Size
    $box.Tag = @{ Role = 'iconbox'; Name = $Name; Color = $Color }
    Set-DoubleBuffered $box
    $box.Add_Paint({
            param($s, $e)
            try {
                $e.Graphics.Clear((Get-BackColor $s.Parent))
                Draw-Icon $e.Graphics $s.Tag.Name 0 0 $s.Width $script:Palette[$s.Tag.Color]
            }
            catch { }
        })
    if ($null -ne $Parent) { $Parent.Controls.Add($box) }
    return $box
}

function New-DesktopShortcut {
    $iconPath = Join-Path $script:AppRoot 'Assets\Cleaner.ico'
    if (-not [IO.File]::Exists($iconPath)) { Save-CleanerIcon $iconPath }
    $link = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Cleaner.lnk'
    if ([IO.File]::Exists($link)) {
        $answer = [System.Windows.Forms.MessageBox]::Show('A shortcut named "Cleaner" is already on your desktop. Replace it?', 'Cleaner', 'YesNo', 'Question')
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($link)
        $shortcut.TargetPath = $(if ([IO.File]::Exists((Join-Path $script:AppRoot 'Cleaner.exe'))) { Join-Path $script:AppRoot 'Cleaner.exe' } else { Join-Path $script:AppRoot 'Cleaner.cmd' })
        $shortcut.WorkingDirectory = $script:AppRoot
        $shortcut.IconLocation = $iconPath + ',0'
        $shortcut.WindowStyle = 7
        $shortcut.Description = 'Cleaner - free up space safely'
        $shortcut.Save()
    }
    finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
    [void][System.Windows.Forms.MessageBox]::Show('A Cleaner shortcut with its own icon is now on your desktop.', 'Cleaner', 'OK', 'Information')
}

# ------------------------------------------------------------------------------------------------
#  The illustration on the Clean page (drawn in code: no image files)
# ------------------------------------------------------------------------------------------------
function New-HeroArt([int]$Width, [int]$Height, [bool]$Dark) {
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        $k = $Width / 460.0
        $cx = 230.0
        $cy = 212.0

        function Iso([double]$U, [double]$V, [double]$Z) {
            New-Object System.Drawing.PointF(([single](($cx + $U - $V) * $k)), ([single](($cy + ($U + $V) / 2.0 - $Z) * $k)))
        }
        function Rgba([int]$Alpha, [int]$Red, [int]$Green, [int]$Blue) { [System.Drawing.Color]::FromArgb($Alpha, $Red, $Green, $Blue) }
        function Fill-Polygon($Color, [System.Drawing.PointF[]]$Points) {
            $brush = New-Object System.Drawing.SolidBrush($Color)
            $g.FillPolygon($brush, $Points)
            $brush.Dispose()
        }
        function Fill-Glow([double]$X, [double]$Y, [double]$RadiusX, [double]$RadiusY, $Color) {
            $path = New-Object System.Drawing.Drawing2D.GraphicsPath
            $path.AddEllipse([single](($X - $RadiusX) * $k), [single](($Y - $RadiusY) * $k), [single](2 * $RadiusX * $k), [single](2 * $RadiusY * $k))
            $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
            $brush.CenterColor = $Color
            $brush.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, $Color))
            $g.FillPath($brush, $path)
            $brush.Dispose(); $path.Dispose()
        }
        function Draw-Block([double]$OffsetU, [double]$OffsetV, [double]$Half, [double]$Bottom, [double]$Top, $TopLight, $TopDark, $Left, $Right, $Edge) {
            $pt = Iso ($OffsetU - $Half) ($OffsetV - $Half) $Top
            $pr = Iso ($OffsetU + $Half) ($OffsetV - $Half) $Top
            $pb = Iso ($OffsetU + $Half) ($OffsetV + $Half) $Top
            $pl = Iso ($OffsetU - $Half) ($OffsetV + $Half) $Top
            $pr0 = Iso ($OffsetU + $Half) ($OffsetV - $Half) $Bottom
            $pb0 = Iso ($OffsetU + $Half) ($OffsetV + $Half) $Bottom
            $pl0 = Iso ($OffsetU - $Half) ($OffsetV + $Half) $Bottom
            Fill-Polygon $Left ([System.Drawing.PointF[]]@($pl, $pb, $pb0, $pl0))
            Fill-Polygon $Right ([System.Drawing.PointF[]]@($pb, $pr, $pr0, $pb0))
            $face = [System.Drawing.PointF[]]@($pt, $pr, $pb, $pl)
            $gradient = New-Object System.Drawing.Drawing2D.LinearGradientBrush($pt, $pb, $TopLight, $TopDark)
            $g.FillPolygon($gradient, $face)
            $gradient.Dispose()
            if ($null -ne $Edge) {
                $pen = New-Object System.Drawing.Pen($Edge, [single](1.2 * $k))
                $g.DrawPolygon($pen, $face)
                $pen.Dispose()
            }
        }

        # Soft glow under everything
        Fill-Glow 230 232 225 92 (Rgba $(if ($Dark) { 80 } else { 52 }) 34 196 180)

        function Draw-Disc([double]$CenterY, [double]$RadiusX, [double]$RadiusY, [double]$Thickness, $TopLight, $TopDark, $SideLight, $SideDark, $Rim) {
            $left = ($cx - $RadiusX) * $k
            $width = 2 * $RadiusX * $k
            $height = 2 * $RadiusY * $k
            $upper = ($CenterY - $RadiusY) * $k
            $drop = $Thickness * $k
            $side = New-Object System.Drawing.Drawing2D.GraphicsPath
            $side.AddArc([single]$left, [single]$upper, [single]$width, [single]$height, [single]0, [single]180)
            $side.AddArc([single]$left, [single]($upper + $drop), [single]$width, [single]$height, [single]180, [single]-180)
            $side.CloseFigure()
            $sideBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P $left 0), (P ($left + $width) 0), $SideDark, $SideLight)
            $g.FillPath($sideBrush, $side)
            $topBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P $left $upper), (P ($left + $width) ($upper + $height)), $TopLight, $TopDark)
            $g.FillEllipse($topBrush, [single]$left, [single]$upper, [single]$width, [single]$height)
            $rimPen = New-Object System.Drawing.Pen($Rim, [single](1.4 * $k))
            $g.DrawEllipse($rimPen, [single]$left, [single]$upper, [single]$width, [single]$height)
            $sideBrush.Dispose(); $topBrush.Dispose(); $rimPen.Dispose(); $side.Dispose()
        }

        # A round, glowing pedestal: a wide base with a dial, a smaller disc and a core of light
        Draw-Disc 238 160 64 16 (Rgba 255 74 68 206) (Rgba 255 38 46 148) (Rgba 255 50 52 140) (Rgba 255 24 26 84) (Rgba 190 124 116 255)
        $tick = New-Object System.Drawing.Pen((Rgba 130 72 232 212), [single](1.3 * $k))
        for ($i = 0; $i -lt 64; $i++) {
            $angle = $i * [Math]::PI * 2 / 64
            $inner = $(if ($i % 4 -eq 0) { 0.86 } else { 0.91 })
            $g.DrawLine($tick, (P (($cx + 146 * [Math]::Cos($angle)) * $k) ((238 + 58 * [Math]::Sin($angle)) * $k)), (P (($cx + 146 * $inner * [Math]::Cos($angle)) * $k) ((238 + 58 * $inner * [Math]::Sin($angle)) * $k)))
        }
        $tick.Dispose()
        Draw-Disc 222 108 44 14 (Rgba 255 52 206 196) (Rgba 255 22 118 150) (Rgba 255 24 112 132) (Rgba 255 14 70 96) (Rgba 220 160 255 242)
        $dash = New-Object System.Drawing.Pen((Rgba 170 200 255 246), [single](1.2 * $k))
        $dash.DashPattern = [single[]]@(3, 3)
        $g.DrawEllipse($dash, [single](($cx - 78) * $k), [single](190 * $k), [single](156 * $k), [single](64 * $k))
        $dash.Dispose()

        # Light rising from the core
        $beamBottom = [single](222 * $k)
        $beamTop = [single](8 * $k)
        $beam = [System.Drawing.PointF[]]@((P (($cx - 50) * $k) $beamBottom), (P (($cx + 50) * $k) $beamBottom), (P (($cx + 32) * $k) $beamTop), (P (($cx - 32) * $k) $beamTop))
        $beamBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P 0 $beamBottom), (P 0 $beamTop), (Rgba 110 44 224 204), (Rgba 0 44 224 204))
        $g.FillPolygon($beamBrush, $beam)
        $beamBrush.Dispose()
        Fill-Glow $cx 222 62 26 (Rgba 240 230 255 250)     # core of light, drawn over the foot of the beam

        # Old files lifted away by the light: they fade as they rise
        foreach ($card in @(@(112, 150, -16, 1.0, 210), @(350, 128, 14, 0.9, 180), @(150, 72, -8, 0.65, 115), @(318, 50, 10, 0.55, 80))) {
            $cardState = $g.Save()
            $g.TranslateTransform([single]($card[0] * $k), [single]($card[1] * $k))
            $g.RotateTransform([single]$card[2])
            $g.ScaleTransform([single]($card[3] * $k), [single]($card[3] * $k))
            $paper = New-Object System.Drawing.Drawing2D.GraphicsPath
            $paper.AddLine((P -13 -17), (P 6 -17)); $paper.AddLine((P 6 -17), (P 13 -10))
            $paper.AddLine((P 13 -10), (P 13 17)); $paper.AddLine((P 13 17), (P -13 17))
            $paper.CloseFigure()
            $paperFill = New-Object System.Drawing.SolidBrush((Rgba ([int]($card[4] * 0.35)) 120 240 225))
            $paperEdge = New-Object System.Drawing.Pen((Rgba $card[4] 140 245 230), [single]1.6)
            $paperEdge.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $paperEdge.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $paperEdge.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $g.FillPath($paperFill, $paper)
            $g.DrawPath($paperEdge, $paper)
            $g.DrawLines($paperEdge, [System.Drawing.PointF[]]@((P 6 -17), (P 6 -10), (P 13 -10)))
            $g.DrawLine($paperEdge, (P -7 -2), (P 7 -2))
            $g.DrawLine($paperEdge, (P -7 4), (P 7 4))
            $g.DrawLine($paperEdge, (P -7 10), (P 2 10))
            $g.Restore($cardState)
            $paperFill.Dispose(); $paperEdge.Dispose(); $paper.Dispose()
        }

        # Orbit around the shield
        $orbit = New-Object System.Drawing.Pen((Rgba 120 120 240 225), [single](1.2 * $k))
        $g.DrawEllipse($orbit, [single](($cx - 76) * $k), [single](($cy - 150) * $k), [single](152 * $k), [single](32 * $k))
        $orbit.Dispose()
        $orbitDot = New-Object System.Drawing.SolidBrush((Rgba 230 150 250 235))
        foreach ($degrees in 25, 155, 250) {
            $angle = $degrees * [Math]::PI / 180
            $dotX = ($cx + 76 * [Math]::Cos($angle)) * $k
            $dotY = ($cy - 134 + 16 * [Math]::Sin($angle)) * $k
            $g.FillEllipse($orbitDot, [single]($dotX - 3 * $k), [single]($dotY - 3 * $k), [single](6 * $k), [single](6 * $k))
        }
        $orbitDot.Dispose()
        # A glowing shield with a check mark floating in the light: everything is checked before it is cleaned
        Fill-Glow $cx ($cy - 132) 66 66 (Rgba 135 70 236 214)
        $saved = $g.Save()
        $shieldSize = 70 * $k
        $g.TranslateTransform([single](($cx * $k) - $shieldSize / 2), [single]((($cy - 134) * $k) - $shieldSize / 2))
        $g.ScaleTransform([single]($shieldSize / 24), [single]($shieldSize / 24))
        $shield = New-Object System.Drawing.Drawing2D.GraphicsPath
        Add-ShieldPath $shield
        $shieldFill = New-Object System.Drawing.Drawing2D.LinearGradientBrush((P 12 3), (P 12 21), (Rgba 255 255 255 255), (Rgba 255 170 244 228))
        $g.FillPath($shieldFill, $shield)
        $shieldEdge = New-Object System.Drawing.Pen((Rgba 120 255 255 255), [single]0.6)
        $g.DrawPath($shieldEdge, $shield)
        $checkPen = New-Object System.Drawing.Pen((Rgba 255 22 148 130), [single]2.3)
        $checkPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $checkPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $checkPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.DrawLines($checkPen, [System.Drawing.PointF[]]@((P 8.6 12.2), (P 11 14.6), (P 15.6 9.7)))
        $g.Restore($saved)
        $shieldFill.Dispose(); $shieldEdge.Dispose(); $checkPen.Dispose(); $shield.Dispose()
    }
    finally { $g.Dispose() }
    return $bitmap
}

function Draw-HeroOverlay($G, [int]$Width) {
    $k = $Width / 460.0
    $cx = 230.0
    $cy = 212.0
    $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $t = $script:AnimationTime
    if ($null -ne $script:Job) {
        # A pulsing light over the core while Cleaner is working
        $pulse = 0.5 + 0.5 * [Math]::Sin($t * 4.0)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddEllipse([single](($cx - 80) * $k), [single](($cy - 22) * $k), [single](160 * $k), [single](64 * $k))
        $brush = New-Object System.Drawing.Drawing2D.PathGradientBrush($path)
        $brush.CenterColor = [System.Drawing.Color]::FromArgb([int](30 + 80 * $pulse), 90, 240, 220)
        $brush.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, 90, 240, 220))
        $G.FillPath($brush, $path)
        $brush.Dispose(); $path.Dispose()
    }
    foreach ($particle in $script:Particles) {
        $travel = 150.0
        $offset = ($particle.Phase + $t * $particle.Speed) % $travel
        $fade = 1.0 - $offset / $travel
        $x = ($cx + $particle.X * (0.55 + 0.45 * $fade)) * $k
        $y = ($cy + 2 - $offset) * $k
        $alpha = [int][Math]::Max(0, [Math]::Min(255, $particle.Alpha * $fade))
        $color = $(if ($particle.White) { [System.Drawing.Color]::FromArgb($alpha, 235, 255, 252) } else { [System.Drawing.Color]::FromArgb($alpha, 70, 232, 212) })
        $radius = $particle.Size * $k
        $brush = New-Object System.Drawing.SolidBrush($color)
        $G.FillEllipse($brush, [single]($x - $radius), [single]($y - $radius), [single]($radius * 2), [single]($radius * 2))
        $brush.Dispose()
    }
}

# ------------------------------------------------------------------------------------------------
#  Owner-drawn controls
# ------------------------------------------------------------------------------------------------
function Draw-RoundButton($Button, $G) {
    try {
        $p = $script:Palette
        $state = $Button.Tag
        $G.Clear((Get-BackColor $Button.Parent))
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $enabled = $Button.Enabled
        $border = $null
        $accentLook = ($state.Kind -eq 'primary') -or ($state.Kind -eq 'segment' -and $state.Selected)
        if ($accentLook) {
            if (-not $enabled) { $back = $p.Track; $fore = $p.Muted }
            elseif ($state.Down) { $back = $p.AccentDown; $fore = $p.OnAccent }
            elseif ($state.Hover) { $back = $p.AccentHover; $fore = $p.OnAccent }
            else { $back = $p.Accent; $fore = $p.OnAccent }
        }
        else {
            $fore = $(if ($enabled) { $p.Text } else { $p.Disabled })
            $back = $(if ($state.Down) { $p.ButtonDown } elseif ($state.Hover -and $enabled) { $p.ButtonHover } else { $p.Button })
            $border = $p.ButtonBorder
        }
        $path = New-RoundedPath 0.5 0.5 ($Button.Width - 2) ($Button.Height - 2) $state.Radius
        $brush = New-Object System.Drawing.SolidBrush($back)
        $G.FillPath($brush, $path)
        $brush.Dispose()
        if ($null -ne $border) {
            $pen = New-Object System.Drawing.Pen($border, 1)
            $G.DrawPath($pen, $path)
            $pen.Dispose()
        }
        $path.Dispose()

        $flags = [System.Windows.Forms.TextFormatFlags]'NoPadding, SingleLine, NoPrefix, VerticalCenter'
        $textSize = [System.Windows.Forms.TextRenderer]::MeasureText($Button.Text, $Button.Font, (New-Object System.Drawing.Size(4000, 400)), $flags)
        $glyphWidth = 0
        $gap = 0
        if ($state.Glyph) {
            $glyphWidth = S 16
            $gap = S 8
        }
        $x = [int](($Button.Width - ($glyphWidth + $gap + $textSize.Width)) / 2)
        if ($state.Glyph) { Draw-Icon $G $state.Glyph $x ([int](($Button.Height - $glyphWidth) / 2)) $glyphWidth $fore }
        [System.Windows.Forms.TextRenderer]::DrawText($G, $Button.Text, $Button.Font, (New-Object System.Drawing.Rectangle(($x + $glyphWidth + $gap), 0, ($textSize.Width + 2), $Button.Height)), $fore, $flags)

        if ($Button.Focused -and $script:ShowFocus) {
            $focusPath = New-RoundedPath 3 3 ($Button.Width - 7) ($Button.Height - 7) ([Math]::Max(2, $state.Radius - 3))
            $focusPen = New-Object System.Drawing.Pen($fore, 1)
            $focusPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
            $G.DrawPath($focusPen, $focusPath)
            $focusPen.Dispose(); $focusPath.Dispose()
        }
    }
    catch { }
}

function Draw-NavItem($Item, $G) {
    try {
        $p = $script:Palette
        $state = $Item.Tag
        $G.Clear($p.Rail)
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $selected = ($script:CurrentPage -eq $state.Id)
        $box = New-Object System.Drawing.Rectangle((S 10), (S 4), ($Item.Width - (S 20)), (S 44))
        if ($selected -or $state.Hover) {
            Fill-RoundRect $G $(if ($selected) { $p.NavSelected } else { $p.NavHover }) $box.X $box.Y $box.Width $box.Height (S 10)
        }
        $color = $(if ($selected) { $p.AccentText } elseif ($state.Hover) { $p.Text } else { $p.NavText })
        # Optical bounds of each drawing on the 24-unit grid, including its stroke.
        # Fit the visible artwork, rather than its empty canvas, into a shared 22px slot.
        $bounds = switch ($state.Glyph) {
            'clean'    { @(2.15, 3.15, 20.85, 21.85) }
            'items'    { @(2.65, 4.15, 21.35, 21.35) }
            'tools'    { @(3.75, 2.15, 21.85, 20.25) }
            'shield'   { @(4.15, 2.15, 19.85, 21.85) }
            'settings' { @(1.45, 1.45, 22.55, 22.55) }
            default    { @(0, 0, 24, 24) }
        }
        $opticalScale = (S 22) / [Math]::Max(($bounds[2] - $bounds[0]), ($bounds[3] - $bounds[1]))
        $iconSize = [single](24 * $opticalScale)
        $iconX = [single]((S 35) - (($bounds[0] + $bounds[2]) / 2) * $opticalScale)
        $iconY = [single](($Item.Height / 2) - (($bounds[1] + $bounds[3]) / 2) * $opticalScale)
        Draw-Icon $G $state.Glyph $iconX $iconY $iconSize $color
        $label = New-Object System.Drawing.Rectangle((S 58), 0, ($Item.Width - (S 112)), $Item.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($G, $state.Text, $script:Fonts.NavLabel, $label, $color, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, NoPrefix')
        if ($state.Badge -gt 0) {
            $text = $(if ($state.Badge -gt 99) { '99+' } else { [string]$state.Badge })
            $measure = [System.Windows.Forms.TextRenderer]::MeasureText($text, $script:Fonts.Badge, (New-Object System.Drawing.Size(200, 50)), $script:CenterText)
            $height = S 22
            $width = [Math]::Max($height, $measure.Width + (S 8))
            $x = $box.Right - $width - (S 10)
            $y = $box.Top + [int](($box.Height - $height) / 2)
            Fill-RoundRect $G $p.AccentSoft $x $y $width $height (S 7)
            [System.Windows.Forms.TextRenderer]::DrawText($G, $text, $script:Fonts.Badge, (New-Object System.Drawing.Rectangle($x, $y, $width, $height)), $p.AccentText, $script:CenterText)
        }
    }
    catch { }
}

function Draw-CheckBox($Check, $G) {
    try {
        $p = $script:Palette
        $state = $Check.Tag
        $G.Clear((Get-BackColor $Check.Parent))
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $size = [single](S 18)
        $x = [single](($Check.Width - $size) / 2)
        $y = [single](($Check.Height - $size) / 2)
        $path = New-RoundedPath $x $y $size $size (S 4)
        if ($Check.Checked) {
            $brush = New-Object System.Drawing.SolidBrush($(if ($state.Locked) { $p.Disabled } else { $p.Accent }))
            $G.FillPath($brush, $path)
            $brush.Dispose()
            $pen = New-Object System.Drawing.Pen($p.OnAccent, [single]([Math]::Max(1.5, 2 * $script:Scale)))
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
            $mark = [System.Drawing.PointF[]]@(
                (New-Object System.Drawing.PointF(($x + $size * 0.26), ($y + $size * 0.53))),
                (New-Object System.Drawing.PointF(($x + $size * 0.44), ($y + $size * 0.71))),
                (New-Object System.Drawing.PointF(($x + $size * 0.76), ($y + $size * 0.33))))
            $G.DrawLines($pen, $mark)
            $pen.Dispose()
        }
        else {
            $color = $(if ($state.Locked) { $p.Disabled } elseif ($state.Hover) { $p.Accent } else { $p.CheckBorder })
            $pen = New-Object System.Drawing.Pen($color, [single]([Math]::Max(1.0, 1.5 * $script:Scale)))
            $G.DrawPath($pen, $path)
            $pen.Dispose()
        }
        $path.Dispose()
        if ($Check.Focused -and $script:ShowFocus) {
            $ring = New-RoundedPath ($x - 3) ($y - 3) ($size + 6) ($size + 6) (S 6)
            $focusPen = New-Object System.Drawing.Pen($p.Accent, 1)
            $focusPen.DashStyle = [System.Drawing.Drawing2D.DashStyle]::Dot
            $G.DrawPath($focusPen, $ring)
            $focusPen.Dispose(); $ring.Dispose()
        }
    }
    catch { }
}

function Draw-Pill($Label, $G) {
    try {
        $p = $script:Palette
        $G.Clear((Get-BackColor $Label.Parent))
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        Fill-RoundRect $G $p.WarningSoft 0 0 ($Label.Width - 1) ($Label.Height - 1) (($Label.Height - 1) / 2)
        [System.Windows.Forms.TextRenderer]::DrawText($G, $Label.Text, $script:Fonts.Pill, $Label.ClientRectangle, $p.Warning, $script:CenterText)
    }
    catch { }
}

function Draw-Card($Card, $G) {
    try {
        $p = $script:Palette
        $G.Clear((Get-BackColor $Card.Parent))
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $path = New-RoundedPath 0.5 0.5 ($Card.Width - 2) ($Card.Height - 2) (S 10)
        $brush = New-Object System.Drawing.SolidBrush($(if ($Card.Tag.Hover) { $p.CardHover } else { $p.Card }))
        $G.FillPath($brush, $path)
        $brush.Dispose()
        $pen = New-Object System.Drawing.Pen($p.CardBorder, 1)
        $G.DrawPath($pen, $path)
        $pen.Dispose(); $path.Dispose()
    }
    catch { }
}

function Draw-Tile($Tile, $G) {
    try {
        $p = $script:Palette
        $state = $Tile.Tag
        Draw-Card $Tile $G
        $icon = New-Object System.Drawing.Rectangle((S 18), [int](($Tile.Height - (S 44)) / 2), (S 44), (S 44))
        Fill-RoundRect $G $p.AccentSoft $icon.X $icon.Y $icon.Width $icon.Height (S 10)
        Draw-Icon $G $state.Glyph ($icon.X + (S 10)) ($icon.Y + (S 10)) (S 24) $p.AccentText
        $left = S 78
        [System.Windows.Forms.TextRenderer]::DrawText($G, $state.Title, $script:Fonts.CardTitle, (New-Object System.Drawing.Rectangle($left, (S 17), ($Tile.Width - $left - (S 44)), (S 24))), $p.Text, [System.Windows.Forms.TextFormatFlags]'Left, Top, SingleLine, EndEllipsis, NoPrefix')
        [System.Windows.Forms.TextRenderer]::DrawText($G, $state.Text, $script:Fonts.Body, (New-Object System.Drawing.Rectangle($left, (S 43), ($Tile.Width - $left - (S 18)), ($Tile.Height - (S 50)))), $p.Muted, [System.Windows.Forms.TextFormatFlags]'Left, Top, WordBreak, EndEllipsis, NoPrefix')
        Draw-Icon $G $script:Glyph.Open ($Tile.Width - (S 36)) (S 18) (S 16) $p.Muted
    }
    catch { }
}

function Draw-Chip($Chip, $G) {
    try {
        $p = $script:Palette
        $state = $Chip.Tag
        $G.Clear((Get-BackColor $Chip.Parent))
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        if ($state.Hover -and $state.Clickable) { Fill-RoundRect $G $p.NavHover 0 0 ($Chip.Width - 1) ($Chip.Height - 1) (S 6) }
        $color = $(if ($state.Clickable) { $p.Text } else { $p.Muted })
        Draw-Icon $G $state.Glyph (S 9) ([int](($Chip.Height - (S 17)) / 2)) (S 17) $color
        [System.Windows.Forms.TextRenderer]::DrawText($G, $state.Text, $script:Fonts.Body, (New-Object System.Drawing.Rectangle((S 32), 0, ($Chip.Width - (S 36)), $Chip.Height)), $color, [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, NoPrefix')
    }
    catch { }
}

function Draw-Progress($Bar, $G) {
    try {
        $p = $script:Palette
        $state = $Bar.Tag
        $G.Clear((Get-BackColor $Bar.Parent))
        $G.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $height = $Bar.Height - 1
        $track = New-RoundedPath 0 0 ($Bar.Width - 1) $height ($height / 2)
        $trackBrush = New-Object System.Drawing.SolidBrush($p.Track)
        $G.FillPath($trackBrush, $track)
        $trackBrush.Dispose()
        $G.SetClip($track)
        if ($state.Indeterminate) {
            $block = [int]($Bar.Width * 0.3)
            Fill-RoundRect $G $p.Accent ($state.Offset - $block) 0 $block $height ($height / 2)
        }
        elseif ($state.Value -gt 0) {
            $width = [Math]::Max($height, [int](($Bar.Width - 1) * [Math]::Min(100, $state.Value) / 100.0))
            Fill-RoundRect $G $p.Accent 0 0 $width $height ($height / 2)
        }
        $G.ResetClip()
        $track.Dispose()
    }
    catch { }
}

function Draw-HeroHeading($Panel, $G) {
    try {
        $p = $script:Palette
        $G.Clear((Get-BackColor $Panel.Parent))
        $flags = [System.Windows.Forms.TextFormatFlags]'NoPadding, SingleLine, NoPrefix'
        $proposed = New-Object System.Drawing.Size(4000, 400)
        $sizes = @()
        $total = 0
        $height = 0
        foreach ($part in $script:HeroParts) {
            $size = [System.Windows.Forms.TextRenderer]::MeasureText($G, $part.Text, $script:Fonts.HeroTitle, $proposed, $flags)
            $sizes += $size
            $total += $size.Width
            $height = [Math]::Max($height, $size.Height)
        }
        $gap = S 10
        $total += $gap * [Math]::Max(0, $script:HeroParts.Count - 1)
        $x = [int](($Panel.Width - $total) / 2)
        $y = [int](($Panel.Height - $height) / 2)
        for ($i = 0; $i -lt $script:HeroParts.Count; $i++) {
            $part = $script:HeroParts[$i]
            [System.Windows.Forms.TextRenderer]::DrawText($G, $part.Text, $script:Fonts.HeroTitle, (New-Object System.Drawing.Point($x, $y)), $p[$part.Color], $flags)
            $x += $sizes[$i].Width + $gap
        }
    }
    catch { }
}

function Draw-HeroArt($Panel, $G) {
    try {
        $G.Clear((Get-BackColor $Panel.Parent))
        if ($null -eq $script:HeroImage -or $script:HeroImage.Width -ne $Panel.Width) {
            if ($null -ne $script:HeroImage) { $script:HeroImage.Dispose() }
            $script:HeroImage = New-HeroArt $Panel.Width $Panel.Height $script:IsDark
        }
        $G.DrawImageUnscaled($script:HeroImage, 0, 0)
        Draw-HeroOverlay $G $Panel.Width
    }
    catch { }
}

# ------------------------------------------------------------------------------------------------
#  Control factories
# ------------------------------------------------------------------------------------------------
function New-Label {
    param($Parent, [string]$Text, [double]$X = 0, [double]$Y = 0, [double]$Width = 100, [double]$Height = 20,
        [string]$Role = 'text', $Font, [string]$Align = 'TopLeft', [switch]$AutoSize, [switch]$Ellipsis)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Point $X $Y
    if ($AutoSize) { $label.AutoSize = $true } else { $label.Size = New-Size $Width $Height }
    $label.Font = $(if ($null -ne $Font) { $Font } else { $script:Fonts.Body })
    $label.TextAlign = [System.Drawing.ContentAlignment]$Align
    $label.AutoEllipsis = [bool]$Ellipsis
    $label.UseMnemonic = $false
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Tag = $Role
    if ($null -ne $Parent) { $Parent.Controls.Add($label) }
    return $label
}

function New-LinkLabel($Parent, [string]$Text, [double]$X = 0, [double]$Y = 0, $Font) {
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = $Text
    $link.AutoSize = $true
    $link.Location = New-Point $X $Y
    $link.Font = $(if ($null -ne $Font) { $Font } else { $script:Fonts.Small })
    $link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $link.UseMnemonic = $false
    $link.BackColor = [System.Drawing.Color]::Transparent
    $link.Tag = 'link'
    if ($null -ne $Parent) { $Parent.Controls.Add($link) }
    return $link
}

function New-RoundButton {
    param($Parent, [string]$Text, [double]$X = 0, [double]$Y = 0, [double]$Width = 120, [double]$Height = 40,
        [string]$Kind = 'secondary', $Font, [string]$Glyph = '', [double]$Radius = 8)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Point $X $Y
    $button.Size = New-Size $Width $Height
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button.Font = $(if ($null -ne $Font) { $Font } else { $script:Fonts.Button })
    $button.Tag = @{ Role = 'round'; Kind = $Kind; Hover = $false; Down = $false; Glyph = $Glyph; Radius = (S $Radius); Selected = $false; Value = '' }
    Set-DoubleBuffered $button
    $button.Add_Paint({ param($s, $e) Draw-RoundButton $s $e.Graphics })
    $button.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $button.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Tag.Down = $false; $s.Invalidate() })
    $button.Add_MouseDown({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $s.Tag.Down = $true; $s.Invalidate() } })
    $button.Add_MouseUp({ param($s, $e) $s.Tag.Down = $false; $s.Invalidate() })
    $button.Add_EnabledChanged({ param($s, $e) $s.Invalidate() })
    $button.Add_GotFocus({ param($s, $e) $s.Invalidate() })
    $button.Add_LostFocus({ param($s, $e) $s.Invalidate() })
    if ($null -ne $Parent) { $Parent.Controls.Add($button) }
    return $button
}

function New-CardPanel($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height) {
    # Pixel units. A card paints its own rounded background; put content inside with some margin.
    $card = New-Object System.Windows.Forms.Panel
    $card.SetBounds($X, $Y, $Width, $Height)
    $card.Tag = @{ Role = 'cardhost'; Hover = $false }
    Set-DoubleBuffered $card
    $card.Add_Paint({ param($s, $e) Draw-Card $s $e.Graphics })
    if ($null -ne $Parent) { $Parent.Controls.Add($card) }
    return $card
}

function New-Tile($Parent, [string]$Glyph, [string]$Title, [string]$Text, [scriptblock]$Action) {
    $tile = New-Object System.Windows.Forms.Panel
    $tile.Size = New-Size 400 92
    $tile.Margin = New-Object System.Windows.Forms.Padding(0, 0, (S 14), (S 14))
    $tile.Cursor = [System.Windows.Forms.Cursors]::Hand
    $tile.Tag = @{ Role = 'tile'; Glyph = $Glyph; Title = $Title; Text = $Text; Hover = $false; Action = $Action }
    Set-DoubleBuffered $tile
    $tile.Add_Paint({ param($s, $e) Draw-Tile $s $e.Graphics })
    $tile.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $tile.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $tile.Add_Click({ param($s, $e) Invoke-Safely $s.Tag.Action ('Opening ' + $s.Tag.Title) })
    $Parent.Controls.Add($tile)
    return $tile
}

function New-PageHeader($Parent, [string]$Title, [string]$Subtitle) {
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = S 96
    $header.Tag = 'window'
    [void](New-Label -Parent $header -Text $Title -X 2 -Y 16 -AutoSize -Role 'text' -Font $script:Fonts.PageTitle)
    [void](New-Label -Parent $header -Text $Subtitle -X 4 -Y 58 -AutoSize -Role 'muted' -Font $script:Fonts.PageSub)
    $Parent.Controls.Add($header)
    return $header
}

function New-Page([string]$Id) {
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.Tag = 'window'
    $page.Visible = $false
    $pagesHost.Controls.Add($page)
    $script:Pages[$Id] = $page
    return $page
}

function Set-ColumnBounds($Page, $Column, [int]$MaxWidth) {
    $width = [Math]::Max((S 320), [Math]::Min($Page.ClientSize.Width - (S 64), $MaxWidth))
    $Column.SetBounds([int](($Page.ClientSize.Width - $width) / 2), (S 16), $width, [Math]::Max((S 200), $Page.ClientSize.Height - (S 32)))
}

# ------------------------------------------------------------------------------------------------
#  Window: navigation rail on the left, pages on the right
# ------------------------------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = $(if ($script:IsAdmin) { 'Cleaner (Administrator)' } else { 'Cleaner' })
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.ClientSize = New-Size 1220 780
$form.MinimumSize = New-Size 1120 720
$form.Font = $script:Fonts.Body
$form.KeyPreview = $true
$form.Tag = 'window'
try {
    $script:AppIcon = New-Object System.Drawing.Icon([System.IO.MemoryStream]::new((New-IconBytes @(16, 20, 24, 32, 40, 48, 64))))
    $form.Icon = $script:AppIcon
}
catch { }

$script:ToolTip = New-Object System.Windows.Forms.ToolTip
$script:ToolTip.AutoPopDelay = 20000
$script:ToolTip.InitialDelay = 450
$script:ToolTip.ReshowDelay = 150

$rail = New-Object System.Windows.Forms.Panel
$rail.Dock = [System.Windows.Forms.DockStyle]::Left
$rail.Width = S 184
$rail.Tag = 'rail'
$railLine = New-Object System.Windows.Forms.Panel
$railLine.Dock = [System.Windows.Forms.DockStyle]::Right
$railLine.Width = 1
$railLine.Tag = 'window'
$rail.Controls.Add($railLine)
$railLogo = New-Object System.Windows.Forms.PictureBox
$railLogo.SetBounds((S 20), (S 24), (S 38), (S 38))
$railLogo.BackColor = [System.Drawing.Color]::Transparent
$railLogo.Image = New-LogoBitmap (S 38)
$rail.Controls.Add($railLogo)
$brandLabel = New-Label -Parent $rail -Text 'Cleaner' -X 68 -Y 30 -Width 110 -Height 26 -Role 'text' -Font $script:Fonts.CardTitle
$script:ToolTip.SetToolTip($railLogo, ('Cleaner {0}' -f $script:AppVersion))

$content = New-Object System.Windows.Forms.Panel
$content.Dock = [System.Windows.Forms.DockStyle]::Fill
$content.Tag = 'window'
$pagesHost = New-Object System.Windows.Forms.Panel
$pagesHost.Dock = [System.Windows.Forms.DockStyle]::Fill
$pagesHost.Tag = 'window'
$content.Controls.Add($pagesHost)

$form.Controls.Add($content)
$form.Controls.Add($rail)

function New-NavItem([string]$Id, [string]$Glyph, [string]$Text, [int]$Top) {
    $item = New-Object System.Windows.Forms.Panel
    $item.SetBounds(0, $Top, ($rail.Width - 1), (S 52))
    $item.Cursor = [System.Windows.Forms.Cursors]::Hand
    $item.Tag = @{ Role = 'nav'; Id = $Id; Glyph = $Glyph; Text = $Text; Hover = $false; Badge = 0 }
    Set-DoubleBuffered $item
    $item.Add_Paint({ param($s, $e) Draw-NavItem $s $e.Graphics })
    $item.Add_MouseEnter({ param($s, $e) $s.Tag.Hover = $true; $s.Invalidate() })
    $item.Add_MouseLeave({ param($s, $e) $s.Tag.Hover = $false; $s.Invalidate() })
    $item.Add_Click({ param($s, $e) Invoke-Safely { Show-Page $s.Tag.Id } 'Opening the page' })
    $rail.Controls.Add($item)
    $script:NavItems[$Id] = $item
    return $item
}

$navTop = S 100
foreach ($nav in @(
        @('clean', $script:Glyph.Broom, 'Clean'),
        @('items', $script:Glyph.Items, 'Items'),
        @('tools', $script:Glyph.Tools, 'Tools'),
        @('safety', $script:Glyph.Shield, 'Safety'))) {
    [void](New-NavItem -Id $nav[0] -Glyph $nav[1] -Text $nav[2] -Top $navTop)
    $navTop += S 56
}
$navSettings = New-NavItem -Id 'settings' -Glyph $script:Glyph.Settings -Text 'Settings' -Top (S 600)
$rail.Add_Resize({ try { $navSettings.Top = $rail.ClientSize.Height - $navSettings.Height - (S 12) } catch { } })

function Update-ChromeLayout {
    $navSettings.Top = $rail.ClientSize.Height - $navSettings.Height - (S 16)
}
# ------------------------------------------------------------------------------------------------
#  Page: Clean (home)
# ------------------------------------------------------------------------------------------------
$homePage = New-Page 'clean'

$heroHeading = New-Object System.Windows.Forms.Panel
$heroHeading.Tag = @{ Role = 'heading' }
Set-DoubleBuffered $heroHeading
$heroHeading.Add_Paint({ param($s, $e) Draw-HeroHeading $s $e.Graphics })
$homePage.Controls.Add($heroHeading)

$heroSub = New-Label -Parent $homePage -Text '' -Width 600 -Height 24 -Role 'muted' -Font $script:Fonts.HeroSub -Align 'MiddleCenter' -Ellipsis

$heroProgress = New-Object System.Windows.Forms.Panel
$heroProgress.Size = New-Size 340 6
$heroProgress.Tag = @{ Role = 'progress'; Value = 0; Indeterminate = $false; Offset = 0 }
$heroProgress.Visible = $false
Set-DoubleBuffered $heroProgress
$heroProgress.Add_Paint({ param($s, $e) Draw-Progress $s $e.Graphics })
$homePage.Controls.Add($heroProgress)

$heroButton = New-RoundButton -Parent $homePage -Text 'Analyze' -Width 220 -Height 54 -Kind 'primary' -Font $script:Fonts.HeroButton -Radius 10
$heroLink = New-LinkLabel -Parent $homePage -Text 'Choose what to clean' -Font $script:Fonts.PageSub

$heroArt = New-Object System.Windows.Forms.Panel
$heroArt.Size = New-Size 460 330
$heroArt.Tag = @{ Role = 'art' }
Set-DoubleBuffered $heroArt
$heroArt.Add_Paint({ param($s, $e) Draw-HeroArt $s $e.Graphics })
$homePage.Controls.Add($heroArt)

$heroFooter = New-Label -Parent $homePage -Text 'Preview first. Review your selection before confirming cleanup.' -Width 600 -Height 20 -Role 'muted' -Font $script:Fonts.Small -Align 'MiddleCenter'

function Update-HomeLayout {
    $width = $homePage.ClientSize.Width
    $height = $homePage.ClientSize.Height
    if ($width -le 0 -or $height -le 0) { return }
    $headingHeight = S 52
    # The illustration grows and shrinks with the window (same proportions), so the page stays balanced.
    $fixed = $headingHeight + (S 6) + (S 24) + (S 28) + $heroButton.Height + (S 14) + (S 22) + (S 18) + (S 30) + (S 40)
    $artHeight = [int][Math]::Max((S 260), [Math]::Min((S 380), $height - $fixed))
    $artWidth = [int]($artHeight * 460 / 330)
    if ($artWidth -gt $width - (S 40)) { $artWidth = [Math]::Max((S 300), $width - (S 40)); $artHeight = [int]($artWidth * 330 / 460) }
    if ($heroArt.Width -ne $artWidth -or $heroArt.Height -ne $artHeight) { $heroArt.Size = New-Object System.Drawing.Size($artWidth, $artHeight) }
    $block = $headingHeight + (S 6) + (S 24) + (S 28) + $heroButton.Height + (S 14) + (S 22) + (S 18) + $heroArt.Height
    $top = [Math]::Max((S 8), [int](($height - $block - (S 30)) / 2))
    $heroHeading.SetBounds(0, $top, $width, $headingHeight)
    $heroSub.SetBounds((S 24), ($heroHeading.Bottom + (S 6)), ($width - (S 48)), (S 24))
    $heroProgress.Location = New-Object System.Drawing.Point([int](($width - $heroProgress.Width) / 2), ($heroSub.Bottom + (S 11)))
    $heroButton.Location = New-Object System.Drawing.Point([int](($width - $heroButton.Width) / 2), ($heroSub.Bottom + (S 28)))
    $heroLink.Location = New-Object System.Drawing.Point([int](($width - $heroLink.Width) / 2), ($heroButton.Bottom + (S 14)))
    $heroArt.Location = New-Object System.Drawing.Point([int](($width - $heroArt.Width) / 2), ($heroLink.Bottom + (S 18)))
    $heroFooter.SetBounds((S 24), ($height - (S 30)), ($width - (S 48)), (S 20))
    $heroFooter.Visible = ($heroArt.Bottom + (S 6)) -lt $heroFooter.Top
    $heroHeading.Invalidate()
    $heroArt.Invalidate()
}
$homePage.Add_Resize({ try { Update-HomeLayout } catch { } })

# ------------------------------------------------------------------------------------------------
#  Page: Items (the detailed list)
# ------------------------------------------------------------------------------------------------
$itemsPage = New-Page 'items'
$itemsColumn = New-Object System.Windows.Forms.Panel
$itemsColumn.Tag = 'window'
$itemsPage.Controls.Add($itemsColumn)

$itemsCard = New-CardPanel -Parent $itemsColumn -X 0 -Y 0 -Width (S 600) -Height (S 400)
$itemsCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$itemsCard.Padding = New-Object System.Windows.Forms.Padding((S 6))
$listPanel = New-Object System.Windows.Forms.Panel
$listPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$listPanel.AutoScroll = $true
$listPanel.Tag = 'card'
$listPanel.Add_HandleCreated({ param($s,$e) [CleanerNative.Ui]::SetControlTheme($s.Handle, $script:IsDark) })
$itemsCard.Controls.Add($listPanel)

$itemsHeader = New-PageHeader -Parent $itemsColumn -Title 'Cleanup items' -Subtitle 'Review your selection. Click a result to inspect the files before cleaning.'
$itemsHeader.Height = S 126
$linkNone = New-LinkLabel -Parent $itemsHeader -Text 'None' -Font $script:Fonts.Body
$linkAll = New-LinkLabel -Parent $itemsHeader -Text 'All' -Font $script:Fonts.Body
$linkRecommended = New-LinkLabel -Parent $itemsHeader -Text 'Recommended' -Font $script:Fonts.Body
$script:ToolTip.SetToolTip($linkRecommended, 'Select the items that are safe for everyday cleaning.')

$itemsBar = New-Object System.Windows.Forms.Panel
$itemsBar.Dock = [System.Windows.Forms.DockStyle]::Bottom
$itemsBar.Height = S 84
$itemsBar.Tag = 'window'
$itemsColumn.Controls.Add($itemsBar)
$itemsTotal = New-Label -Parent $itemsBar -Text '' -X 2 -Y 16 -Width 520 -Height 30 -Role 'text' -Font $script:Fonts.Stat -Ellipsis
$itemsDetail = New-Label -Parent $itemsBar -Text '' -X 4 -Y 48 -Width 520 -Height 20 -Role 'muted' -Font $script:Fonts.Body -Ellipsis
$itemsClean = New-RoundButton -Parent $itemsBar -Text 'Clean now' -Width 170 -Height 46 -Kind 'primary'
$itemsAnalyze = New-RoundButton -Parent $itemsBar -Text 'Analyze' -Width 140 -Height 46 -Kind 'secondary'
$script:ToolTip.SetToolTip($itemsAnalyze, 'See what can be removed (F5). Nothing is deleted.')

function Update-ItemsLayout {
    Set-ColumnBounds $itemsPage $itemsColumn (S 1040)
    $right = $itemsHeader.ClientSize.Width - (S 4)
    foreach ($link in @($linkNone, $linkAll, $linkRecommended)) {
        $right -= $link.Width
        $link.Location = New-Object System.Drawing.Point($right, (S 91))
        $right -= (S 14)
    }
    $itemsClean.Location = New-Object System.Drawing.Point(($itemsBar.ClientSize.Width - $itemsClean.Width - (S 2)), (S 18))
    $itemsAnalyze.Location = New-Object System.Drawing.Point(($itemsClean.Left - $itemsAnalyze.Width - (S 10)), (S 18))
    $itemsTotal.Width = [Math]::Max((S 120), $itemsAnalyze.Left - (S 16))
    $itemsDetail.Width = $itemsTotal.Width
}
$itemsPage.Add_Resize({ try { Update-ItemsLayout } catch { } })

# ------------------------------------------------------------------------------------------------
#  Page: Tools
# ------------------------------------------------------------------------------------------------
$toolsPage = New-Page 'tools'
$toolsColumn = New-Object System.Windows.Forms.Panel
$toolsColumn.Tag = 'window'
$toolsPage.Controls.Add($toolsColumn)
$toolsFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$toolsFlow.Dock = [System.Windows.Forms.DockStyle]::Fill
$toolsFlow.AutoScroll = $true
$toolsFlow.Tag = 'window'
$toolsFlow.Add_HandleCreated({ param($s,$e) [CleanerNative.Ui]::SetControlTheme($s.Handle, $script:IsDark) })
$toolsColumn.Controls.Add($toolsFlow)
[void](New-PageHeader -Parent $toolsColumn -Title 'Tools' -Subtitle 'Windows tools for storage and cleanup. They open in Windows; Cleaner changes nothing here.')

[void](New-Tile $toolsFlow $script:Glyph.Gauge 'Storage Sense' 'Let Windows remove temporary files automatically, on a schedule.' { Start-Process 'ms-settings:storagepolicies' })
[void](New-Tile $toolsFlow $script:Glyph.Disk 'Storage overview' 'See what uses the space on each drive.' { Start-Process 'ms-settings:storagesense' })
[void](New-Tile $toolsFlow $script:Glyph.Broom 'Disk Cleanup' 'Remove Windows Update leftovers and other system files.' { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cleanmgr.exe') })
[void](New-Tile $toolsFlow $script:Glyph.Power 'Startup apps' 'Turn off apps that start with Windows and slow down sign-in.' { Start-Process 'ms-settings:startupapps' })
[void](New-Tile $toolsFlow $script:Glyph.Apps 'Installed apps' 'Uninstall apps you no longer use.' { Start-Process 'ms-settings:appsfeatures' })
[void](New-Tile $toolsFlow $script:Glyph.Trash 'Recycle Bin' 'Open the Recycle Bin to restore or delete files.' { Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:RecycleBinFolder' })
[void](New-Tile $toolsFlow $script:Glyph.Monitor 'Start menu settings' 'Hide recently added apps and recommendations in Start.' { Start-Process 'ms-settings:personalization-start' })
[void](New-Tile $toolsFlow $script:Glyph.History 'Cleaner log' 'See every file Cleaner removed, day by day.' { Open-LogFolder })

function Update-ToolsLayout {
    Set-ColumnBounds $toolsPage $toolsColumn (S 1040)
    $available = $toolsFlow.ClientSize.Width - (S 4)
    $tileWidth = [int][Math]::Floor(($available - 2 * (S 14)) / 2)
    if ($tileWidth -lt (S 300)) { $tileWidth = $available - (S 14) }
    foreach ($tile in $toolsFlow.Controls) { $tile.Width = $tileWidth }
}
$toolsPage.Add_Resize({ try { Update-ToolsLayout } catch { } })

# ------------------------------------------------------------------------------------------------
#  Page: Safety
# ------------------------------------------------------------------------------------------------
$safetyPage = New-Page 'safety'
$safetyColumn = New-Object System.Windows.Forms.Panel
$safetyColumn.Tag = 'window'
$safetyPage.Controls.Add($safetyColumn)
[void](New-PageHeader -Parent $safetyColumn -Title 'Safety' -Subtitle 'Cleaner only looks inside a fixed list of cache and temporary folders, and checks every file again before deleting it.')

function Add-CardLines($Card, [string]$Title, [object[]]$Lines) {
    [void](New-Label -Parent $Card -Text $Title -X 20 -Y 18 -AutoSize -Role 'accent' -Font $script:Fonts.Section)
    $y = 50
    foreach ($line in $Lines) {
        [void](New-IconBox -Parent $Card -Name $line[0] -X 20 -Y $y -Size 20)
        $text = New-Label -Parent $Card -Text $line[1] -X 52 -Y $y -Width 340 -Height 34 -Role 'text' -Font $script:Fonts.Body
        $text.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
        $y += 36
    }
}

$neverCard = New-CardPanel -Parent $safetyColumn -X 0 -Y (S 96) -Width (S 410) -Height (S 316)
Add-CardLines $neverCard 'NEVER TOUCHED' @(
    @($script:Glyph.Folder, 'Desktop, Documents, Downloads, Pictures, Music, Videos and OneDrive'),
    @($script:Glyph.Lock, 'Browser passwords, cookies, bookmarks and extensions'),
    @($script:Glyph.Drive, 'AI models, disk images, keys and databases'),
    @($script:Glyph.Document, 'Office documents and PDFs, even inside temporary folders'),
    @($script:Glyph.Chip, 'NVIDIA ComputeCache, Hugging Face, Ollama, Docker and WSL data'),
    @($script:Glyph.Apps, 'Program Files, Windows system folders, installed apps and the registry'))

$checksCard = New-CardPanel -Parent $safetyColumn -X (S 426) -Y (S 96) -Width (S 410) -Height (S 316)
Add-CardLines $checksCard 'CHECKED BEFORE EVERY DELETION' @(
    @($script:Glyph.Check, 'Older than the age limit of its item (7, 14 or 30 days)'),
    @($script:Glyph.Check, 'Not open in any program at that moment'),
    @($script:Glyph.Check, 'Not read-only, system, hard-linked or a cloud placeholder'),
    @($script:Glyph.Check, 'Never reached through a junction or symbolic link'),
    @($script:Glyph.Check, 'Unchanged since the analysis and still inside its folder'),
    @($script:Glyph.Check, 'Browser and app caches only while that program is closed'),
    @($script:Glyph.Check, 'Only empty folders are removed'))

$logCard = New-CardPanel -Parent $safetyColumn -X 0 -Y (S 428) -Width (S 836) -Height (S 64)
[void](New-IconBox -Parent $logCard -Name $script:Glyph.History -X 20 -Y 21 -Size 20)
[void](New-Label -Parent $logCard -Text 'Every deletion, skip and error is written to the log, kept for 30 days.' -X 52 -Y 21 -AutoSize -Role 'text')
$safetyLogLink = New-LinkLabel -Parent $logCard -Text 'Open log folder' -Font $script:Fonts.Body

function Update-SafetyLayout {
    Set-ColumnBounds $safetyPage $safetyColumn (S 1040)
    $width = $safetyColumn.ClientSize.Width
    $half = [int](($width - (S 16)) / 2)
    $neverCard.SetBounds(0, (S 96), $half, (S 316))
    $checksCard.SetBounds(($half + (S 16)), (S 96), ($width - $half - (S 16)), (S 316))
    $logCard.SetBounds(0, (S 428), $width, (S 64))
    $safetyLogLink.Location = New-Object System.Drawing.Point(($logCard.Width - $safetyLogLink.Width - (S 20)), (S 21))
}
$safetyPage.Add_Resize({ try { Update-SafetyLayout } catch { } })

# ------------------------------------------------------------------------------------------------
#  Page: Settings
# ------------------------------------------------------------------------------------------------
$settingsPage = New-Page 'settings'
$settingsColumn = New-Object System.Windows.Forms.Panel
$settingsColumn.Tag = 'window'
$settingsPage.Controls.Add($settingsColumn)
[void](New-PageHeader -Parent $settingsColumn -Title 'Settings' -Subtitle 'Appearance, administrator rights and statistics.')

$themeCard = New-CardPanel -Parent $settingsColumn -X 0 -Y (S 96) -Width (S 760) -Height (S 132)
[void](New-Label -Parent $themeCard -Text 'Theme' -X 20 -Y 16 -AutoSize -Role 'text' -Font $script:Fonts.CardTitle)
[void](New-Label -Parent $themeCard -Text 'System follows your Windows setting for apps (dark or light).' -X 20 -Y 44 -AutoSize -Role 'muted')
$script:ThemeButtons = @()
$segmentX = 20
foreach ($choice in @(@('System', $script:Glyph.Monitor), @('Dark', $script:Glyph.Moon), @('Light', $script:Glyph.Sun))) {
    $segment = New-RoundButton -Parent $themeCard -Text $choice[0] -X $segmentX -Y 76 -Width 116 -Height 36 -Kind 'segment' -Font $script:Fonts.Body -Glyph $choice[1]
    $segment.Tag.Value = $choice[0]
    $segment.Add_Click({ param($s, $e) Invoke-Safely { Set-AppTheme $s.Tag.Value } 'Changing the theme' })
    $script:ThemeButtons += $segment
    $segmentX += 124
}

$adminCard = New-CardPanel -Parent $settingsColumn -X 0 -Y (S 244) -Width (S 760) -Height (S 136)
[void](New-IconBox -Parent $adminCard -Name $script:Glyph.Admin -X 20 -Y 18 -Size 22)
[void](New-Label -Parent $adminCard -Text 'Administrator rights' -X 52 -Y 16 -AutoSize -Role 'text' -Font $script:Fonts.CardTitle)
$adminText = New-Label -Parent $adminCard -Text '' -X 52 -Y 44 -Width 680 -Height 38 -Role 'muted'
$adminText.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
$adminRestart = New-RoundButton -Parent $adminCard -Text 'Restart as administrator' -X 52 -Y 86 -Width 230 -Height 36 -Kind 'primary' -Font $script:Fonts.Body -Glyph $script:Glyph.Admin

$aboutCard = New-CardPanel -Parent $settingsColumn -X 0 -Y (S 396) -Width (S 760) -Height (S 196)
$aboutLogo = New-Object System.Windows.Forms.PictureBox
$aboutLogo.SetBounds((S 18), (S 16), (S 26), (S 26))
$aboutLogo.BackColor = [System.Drawing.Color]::Transparent
$aboutLogo.Image = New-LogoBitmap (S 26)
$aboutCard.Controls.Add($aboutLogo)
[void](New-Label -Parent $aboutCard -Text ('Cleaner {0}' -f $script:AppVersion) -X 52 -Y 16 -AutoSize -Role 'text' -Font $script:Fonts.CardTitle)
$aboutTotal = New-Label -Parent $aboutCard -Text '' -X 52 -Y 46 -Width 680 -Height 20 -Role 'text'
$aboutLast = New-Label -Parent $aboutCard -Text '' -X 52 -Y 68 -Width 680 -Height 20 -Role 'muted'
$aboutFolder = New-Label -Parent $aboutCard -Text 'Settings and logs are stored in %LOCALAPPDATA%\Cleaner.' -X 52 -Y 104 -AutoSize -Role 'muted'
$aboutFolderLink = New-LinkLabel -Parent $aboutCard -Text 'Open folder' -Font $script:Fonts.Body
foreach ($label in @($aboutTotal, $aboutLast)) { $label.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right' }
$shortcutButton = New-RoundButton -Parent $aboutCard -Text 'Create desktop shortcut' -X 52 -Y 138 -Width 230 -Height 36 -Kind 'secondary' -Font $script:Fonts.Body -Glyph $script:Glyph.Monitor
$script:ToolTip.SetToolTip($shortcutButton, 'Puts a Cleaner shortcut with its own icon on your desktop.')

function Update-SettingsLayout {
    Set-ColumnBounds $settingsPage $settingsColumn (S 760)
    $width = $settingsColumn.ClientSize.Width
    foreach ($card in @($themeCard, $adminCard, $aboutCard)) { $card.Width = $width }
    $aboutFolderLink.Location = New-Object System.Drawing.Point(($aboutFolder.Right + (S 8)), $aboutFolder.Top)
}
$settingsPage.Add_Resize({ try { Update-SettingsLayout } catch { } })

function Update-SettingsPage {
    foreach ($button in $script:ThemeButtons) {
        $button.Tag.Selected = ($button.Tag.Value -eq [string]$script:Settings.Theme)
        $button.Invalidate()
    }
    if ($script:IsAdmin) {
        $adminText.Text = 'Cleaner is running as administrator, so Windows temporary files and system error reports can be cleaned too.'
        $adminRestart.Visible = $false
    }
    else {
        $adminText.Text = 'Cleaner is running as a standard user. Restart it as administrator to also clean Windows temporary files and system error reports.'
        $adminRestart.Visible = $true
    }
    $total = [long]$script:Settings.TotalFreedBytes
    $aboutTotal.Text = $(if ($total -gt 0) { 'Total freed so far: ' + (Format-CleanerSize $total) } else { 'Nothing cleaned yet.' })
    $aboutLast.Text = $(if ($script:Settings.LastCleanedAt -is [DateTime]) {
            'Last cleaned {0}{1}{2} freed' -f (Format-RelativeTime $script:Settings.LastCleanedAt), $script:Dot, (Format-CleanerSize $script:Settings.LastFreedBytes)
        }
        else { 'Engine {0}{1}PowerShell {2}.{3}' -f (Get-CleanerVersion), $script:Dot, $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor })
}

# ------------------------------------------------------------------------------------------------
#  Item rows (Items page)
# ------------------------------------------------------------------------------------------------
function Get-RuleTooltip($Rule) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Rule.Description)
    if ($Rule.Kind -eq 'Files') {
        if ($Rule.MinAgeDays -gt 0) { $lines.Add(('Only files older than {0} days are removed.' -f $Rule.MinAgeDays)) }
        if ($Rule.AppName) { $lines.Add(('Cleaned only while {0} is closed.' -f $Rule.AppName)) }
    }
    if ($Rule.Note) { $lines.Add($Rule.Note) }
    if ($Rule.RequiresAdmin -and -not $script:IsAdmin) { $lines.Add('Needs administrator rights: use "Run as administrator".') }
    $locations = @($Rule.Locations)
    if ($locations.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Locations:')
        foreach ($location in ($locations | Select-Object -First 6)) { $lines.Add('   ' + (Format-ShortPath $location)) }
        if ($locations.Count -gt 6) { $lines.Add(('   ... and {0} more' -f ($locations.Count - 6))) }
    }
    return ($lines -join "`r`n")
}

$script:RowHoverHandler = {
    param($s, $e)
    try {
        $row = $script:RowById[$s.Name]
        if ($null -ne $row) { Update-RowHover $row }
    }
    catch { }
}

function Update-RowHover($Row) {
    $panel = $Row.Panel
    $inside = $panel.ClientRectangle.Contains($panel.PointToClient([System.Windows.Forms.Cursor]::Position))
    if ($inside -eq $Row.Hover) { return }
    $Row.Hover = $inside
    $panel.BackColor = $(if ($inside) { $script:Palette.CardHover } else { $script:Palette.Card })
    $Row.Check.Invalidate()
    if ($null -ne $Row.Pill) { $Row.Pill.Invalidate() }
}

function Add-GroupHeader([string]$GroupId, [int]$Top, [int]$Width) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.SetBounds(0, $Top, $Width, (S 38))
    $panel.Tag = 'row'
    $listPanel.Controls.Add($panel)
    [void](New-Label -Parent $panel -Text ([string]$script:Groups[$GroupId]).ToUpperInvariant() -X 16 -Y 16 -AutoSize -Role 'accent' -Font $script:Fonts.Section)

    $noteWidth = S 340
    $noteLeft = $Width - (S 18) - $noteWidth
    if ($GroupId -eq 'Admin' -and -not $script:IsAdmin) {
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = 'Run as administrator to include these'
        $link.Font = $script:Fonts.Small
        $link.TextAlign = [System.Drawing.ContentAlignment]::TopRight
        $link.SetBounds($noteLeft, (S 16), $noteWidth, (S 18))
        $link.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
        $link.BackColor = [System.Drawing.Color]::Transparent
        $link.Tag = 'link'
        $link.Add_LinkClicked({ Invoke-Safely { Restart-Elevated } 'Restart as administrator' })
        $panel.Controls.Add($link)
        $link.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
    }
    elseif ($script:GroupNotes.ContainsKey($GroupId)) {
        $note = New-Label -Parent $panel -Text $script:GroupNotes[$GroupId] -Role 'muted' -Font $script:Fonts.Small -Align 'TopRight'
        $note.SetBounds($noteLeft, (S 16), $noteWidth, (S 18))
        $note.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
    }
    return $panel
}

function Add-RuleRow($Rule, [int]$Top, [int]$Width) {
    $panel = New-Object System.Windows.Forms.Panel
    $panel.SetBounds(0, $Top, $Width, (S 58))
    $panel.Tag = 'row'
    $panel.Name = $Rule.Id
    $panel.Cursor = [System.Windows.Forms.Cursors]::Hand
    $listPanel.Controls.Add($panel)

    $resultWidth = S 190
    $rightEdge = $Width - (S 18)

    $check = New-Object System.Windows.Forms.CheckBox
    $check.Name = $Rule.Id
    $check.Text = ''
    $check.AutoSize = $false
    $check.SetBounds((S 14), (S 17), (S 24), (S 24))
    $check.Cursor = [System.Windows.Forms.Cursors]::Hand
    $check.Tag = @{ Role = 'check'; Hover = $false; Locked = $false }
    Set-DoubleBuffered $check
    $check.Add_Paint({ param($s, $e) Draw-CheckBox $s $e.Graphics })
    $panel.Controls.Add($check)

    $title = New-Label -Parent $panel -Text $Rule.Name -X 48 -Y 9 -AutoSize -Role 'text' -Font $script:Fonts.RowTitle
    $title.Name = $Rule.Id

    $pill = $null
    if ($Rule.Caution) {
        $pill = New-Object System.Windows.Forms.Label
        $pill.Name = $Rule.Id
        $pill.Text = 'REVIEW'
        $pill.Font = $script:Fonts.Pill
        $pill.Tag = 'pill'
        $pill.Size = New-Size 52 17
        $pill.Location = New-Object System.Drawing.Point(($title.Right + (S 8)), (S 12))
        $pill.Add_Paint({ param($s, $e) Draw-Pill $s $e.Graphics })
        $panel.Controls.Add($pill)
    }

    $desc = New-Label -Parent $panel -Text $Rule.Description -Role 'muted' -Font $script:Fonts.RowText -Ellipsis
    $desc.Name = $Rule.Id
    $desc.SetBounds((S 48), (S 33), ($rightEdge - $resultWidth - (S 16) - (S 48)), (S 18))

    $result = New-Object System.Windows.Forms.LinkLabel
    $result.Name = $Rule.Id
    $result.Font = $script:Fonts.Result
    $result.TextAlign = [System.Drawing.ContentAlignment]::TopRight
    $result.SetBounds(($rightEdge - $resultWidth), (S 9), $resultWidth, (S 22))
    $result.LinkBehavior = [System.Windows.Forms.LinkBehavior]::HoverUnderline
    $result.AutoEllipsis = $true
    $result.UseMnemonic = $false
    $result.BackColor = [System.Drawing.Color]::Transparent
    $result.Tag = 'result'
    $panel.Controls.Add($result)

    $sub = New-Label -Parent $panel -Text '' -Role 'muted' -Font $script:Fonts.Small -Align 'TopRight' -Ellipsis
    $sub.Name = $Rule.Id
    $sub.SetBounds(($rightEdge - $resultWidth), (S 33), $resultWidth, (S 18))

    $line = New-Object System.Windows.Forms.Panel
    $line.Name = $Rule.Id
    $line.SetBounds((S 16), ($panel.Height - 1), ($Width - (S 32)), 1)
    $line.Tag = 'line'
    $panel.Controls.Add($line)

    $desc.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
    $result.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
    $sub.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
    $line.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'

    $allowed = -not ($Rule.RequiresAdmin -and -not $script:IsAdmin)
    $row = @{
        Rule = $Rule; Panel = $panel; Check = $check; Title = $title; Desc = $desc; Result = $result; Sub = $sub; Pill = $pill
        Allowed = $allowed; Hover = $false; State = $(if ($allowed) { 'Idle' } else { 'AdminOnly' }); Scan = $null; Clean = $null
    }

    if ($allowed) {
        $saved = $script:Settings.Rules
        $check.Checked = $(if ($saved.ContainsKey($Rule.Id)) { [bool]$saved[$Rule.Id] } else { [bool]$Rule.Recommended })
        $check.Add_CheckedChanged({ Invoke-Safely { Update-AfterSelectionChange } 'Changing the selection' })
    }
    else {
        # Needs administrator rights: readable, but cannot be ticked. A click offers to restart.
        $check.Checked = $false
        $check.AutoCheck = $false
        $check.Tag.Locked = $true
        $title.Tag = 'muted'
        $check.Add_Click({ Invoke-Safely { Request-Elevation } 'Restart as administrator' })
    }

    $tip = Get-RuleTooltip $Rule
    foreach ($control in @($check, $title, $desc)) { $script:ToolTip.SetToolTip($control, $tip) }
    foreach ($control in @($panel, $title, $desc)) {
        $control.Add_Click({ param($s, $e) Invoke-Safely { Switch-RowCheck $s.Name } 'Changing the selection' })
    }
    foreach ($control in @($panel, $check, $title, $desc, $result, $sub, $line, $pill)) {
        if ($null -eq $control) { continue }
        $control.Add_MouseEnter($script:RowHoverHandler)
        $control.Add_MouseLeave($script:RowHoverHandler)
    }
    $result.Add_LinkClicked({ param($s, $e) Invoke-Safely { Open-RowLink $s.Name } 'Opening the details' })

    [void]$script:Rows.Add($row)
    $script:RowById[$Rule.Id] = $row
    return $row
}

function Build-RuleList {
    $listPanel.SuspendLayout()
    $width = S 900     # nominal width; Update-RowWidths fits the rows to the list afterwards
    $top = S 2
    foreach ($groupId in $script:Groups.Keys) {
        $groupRules = @($script:Rules | Where-Object { $_.Group -eq $groupId })
        if ($groupRules.Count -eq 0) { continue }
        $groupHeader = Add-GroupHeader -GroupId $groupId -Top $top -Width $width
        $top += $groupHeader.Height
        foreach ($rule in $groupRules) {
            $row = Add-RuleRow -Rule $rule -Top $top -Width $width
            $top += $row.Panel.Height
        }
    }
    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.SetBounds(0, $top, $width, (S 8))
    $spacer.Tag = 'row'
    $listPanel.Controls.Add($spacer)
    $listPanel.ResumeLayout()
}

function Update-RowWidths {
    $width = $listPanel.Width - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - 1
    if ($width -lt (S 420)) { return }
    $listPanel.SuspendLayout()
    foreach ($control in $listPanel.Controls) { if ($control.Width -ne $width) { $control.Width = $width } }
    $listPanel.ResumeLayout()
}
$listPanel.Add_Resize({ try { Update-RowWidths } catch { } })

function Get-SelectedRows {
    foreach ($row in $script:Rows) {
        if ($row.Allowed -and $row.Check.Checked) { $row }
    }
}

function Switch-RowCheck([string]$Id) {
    $row = $script:RowById[$Id]
    if ($null -eq $row) { return }
    if (-not $row.Allowed) { Request-Elevation; return }
    if ($row.Check.AutoCheck) { $row.Check.Checked = -not $row.Check.Checked }
}

function Open-RowLink([string]$Id) {
    $row = $script:RowById[$Id]
    if ($null -eq $row) { return }
    if ($row.State -in @('Blocked', 'CleanBlocked')) { Close-AppsForRows @($row); return }
    if ($row.State -eq 'Ready' -and $null -ne $row.Scan) { Show-RuleDetails $row }
}

function Save-UiSettings {
    if ($script:Loading) { return }
    foreach ($row in $script:Rows) {
        if ($row.Allowed) { $script:Settings.Rules[$row.Rule.Id] = [bool]$row.Check.Checked }
    }
    try { Save-CleanerSettings -Settings $script:Settings }
    catch { [void][System.Windows.Forms.MessageBox]::Show(('Your choices could not be saved: {0}' -f $_.Exception.Message), 'Cleaner', 'OK', 'Warning') }
}

function Update-AfterSelectionChange {
    if ($script:Loading) { return }
    $script:LastClean = $null
    Save-UiSettings
    Update-Summary
}

function Set-Selection([string]$Mode) {
    if ($null -ne $script:Job) { return }     # choices are locked while working
    $script:Loading = $true
    try {
        foreach ($row in $script:Rows) {
            if (-not $row.Allowed) { continue }
            $row.Check.Checked = switch ($Mode) {
                'All' { $true }
                'None' { $false }
                default { [bool]$row.Rule.Recommended }
            }
        }
    }
    finally { $script:Loading = $false }
    $script:LastClean = $null
    Save-UiSettings
    Update-Summary
}

# ------------------------------------------------------------------------------------------------
#  Theme
# ------------------------------------------------------------------------------------------------
function Set-LinkColors($Link, $Color) {
    $Link.LinkColor = $Color
    $Link.ActiveLinkColor = $Color
    $Link.VisitedLinkColor = $Color
    $Link.DisabledLinkColor = $script:Palette.Disabled
}

function Set-ControlTheme($Control) {
    $p = $script:Palette
    $tag = $Control.Tag
    $role = $(if ($tag -is [hashtable]) { [string]$tag.Role } else { [string]$tag })
    switch ($role) {
        'window'     { $Control.BackColor = $p.Window; $Control.ForeColor = $p.Text }
        'rail'       { $Control.BackColor = $p.Rail; $Control.ForeColor = $p.Text }
        'card'       { $Control.BackColor = $p.Card; $Control.ForeColor = $p.Text }
        'row'        { $Control.BackColor = $p.Card; $Control.ForeColor = $p.Text }
        'line'       { $Control.BackColor = $p.Line }
        'text'       { $Control.ForeColor = $p.Text }
        'muted'      { $Control.ForeColor = $p.Muted }
        'accent'     { $Control.ForeColor = $p.AccentText }
        'warning'    { $Control.ForeColor = $p.Warning }
        'icon'       { $Control.ForeColor = $p.AccentText }
        'link'       { Set-LinkColors $Control $p.AccentText }
        'nav'        { $Control.BackColor = $p.Rail }
        { $_ -in @('cardhost', 'round', 'chip', 'tile', 'progress', 'heading', 'art', 'check', 'pill', 'iconbox') } {
            if ($null -ne $Control.Parent) { $Control.BackColor = Get-BackColor $Control.Parent }
        }
    }
    foreach ($child in $Control.Controls) { Set-ControlTheme $child }
}

function Set-WindowFrame {
    if (-not $form.IsHandleCreated) { return }
    $p = $script:Palette
    [CleanerNative.Ui]::StyleTitleBar($form.Handle, $script:IsDark, (ConvertTo-ColorRef $p.Window), (ConvertTo-ColorRef $p.Line), $true)
    foreach ($scroller in @($listPanel, $toolsFlow)) {
        if ($scroller.IsHandleCreated) { [CleanerNative.Ui]::SetControlTheme($scroller.Handle, $script:IsDark) }
    }
}

function Update-Theme([switch]$Force) {
    $dark = switch ([string]$script:Settings.Theme) {
        'Dark' { $true }
        'Light' { $false }
        default { Test-SystemDarkMode }
    }
    $dark = [bool]$dark
    if (-not $Force -and $null -ne $script:Palette -and $dark -eq $script:IsDark) { return }
    $script:IsDark = $dark
    $script:Palette = $(if ($dark) { $script:Palettes.Dark } else { $script:Palettes.Light })
    if ($null -ne $script:HeroImage) { $script:HeroImage.Dispose(); $script:HeroImage = $null }
    $form.SuspendLayout()
    try {
        Set-ControlTheme $form
        foreach ($row in $script:Rows) {
            $row.Hover = $false
            $row.Panel.BackColor = $script:Palette.Card
            Update-RowDisplay $row
        }
        Update-Summary
        Update-SettingsPage
    }
    finally { $form.ResumeLayout() }
    Set-WindowFrame
    $form.Invalidate($true)
}

function Set-AppTheme([string]$Theme) {
    $script:Settings.Theme = $Theme
    Save-UiSettings
    Update-Theme -Force
}

# ------------------------------------------------------------------------------------------------
#  Display: rows, Clean page, Items page, badge
# ------------------------------------------------------------------------------------------------
function Get-UnavailableReason([string]$Message) {
    if ($Message -match 'administrator') { return 'Needs administrator rights' }
    if ($Message -match 'link') { return 'Folder is a link' }
    if ($Message -match 'protected') { return 'Protected location' }
    return 'Not available'
}

function Update-RowDisplay($Row) {
    $p = $script:Palette
    if ($null -eq $p) { return }
    $text = ''; $sub = ''; $color = $p.Muted; $isLink = $false; $tip = $null
    $scan = $Row.Scan
    $clean = $Row.Clean
    $app = $(if ($Row.Rule.AppName) { $Row.Rule.AppName } else { 'the app' })

    switch ($Row.State) {
        'AdminOnly' { $text = 'Admin only'; $sub = 'Run as administrator' }
        'Scanning' { $text = 'Analyzing' + $script:Ellipsis }
        'Cleaning' { $text = 'Cleaning' + $script:Ellipsis }
        'Closing' { $text = 'Closing' + $script:Ellipsis; $sub = $app }
        'Ready' {
            $text = Format-CleanerSize $scan.Bytes
            $color = $p.Text
            $isLink = $true
            $sub = Format-Count $scan.Count $(if ($Row.Rule.Kind -eq 'RecycleBin') { 'item' } else { 'file' })
            if ($scan.LimitReached) { $sub += ' (first part)' }
            $tip = 'Click to see what will be removed.'
            if ($Row.Rule.Kind -eq 'ExplorerRecent') {
                $text = Format-Count $scan.Count 'folder'; $isLink = $false; $sub = 'Pinned folders stay'
                $names = @($scan.Notes | Select-Object -First 12)
                $tip = "Removed from File Explorer's list only. The folders themselves are not touched.`r`n`r`n" + ($names -join "`r`n")
            }
        }
        'Empty' {
            $text = 'Nothing to clean'
            if ($null -ne $scan -and $scan.SkippedRecent -gt 0) { $sub = (Format-Count $scan.SkippedRecent 'recent file') + ' kept' }
        }
        'Blocked' {
            $text = 'Close app'; $color = $p.Warning; $isLink = $true; $sub = "$app is open"
            $tip = "Click to close $app so its cache can be cleaned. Or close it yourself, then analyze again."
        }
        'Unavailable' { $text = 'Skipped'; $color = $p.Warning; if ($scan) { $sub = Get-UnavailableReason $scan.Message; $tip = $scan.Message } }
        'Error' { $text = 'Not analyzed'; $color = $p.Warning; $sub = 'Hover for details'; if ($scan) { $tip = $scan.Message } }
        'Cancelled' { $text = 'Cancelled' }
        'Cleaned' {
            $text = 'Freed ' + (Format-CleanerSize $clean.Bytes)
            $color = $p.Success
            $sub = (Format-Count $clean.Deleted $(if ($Row.Rule.Kind -eq 'RecycleBin') { 'item' } else { 'file' })) + ' removed'
            $kept = $clean.InUse + $clean.Changed + $clean.Denied + $clean.Protected + $clean.Failed
            if ($kept -gt 0) { $sub += ', {0:N0} kept' -f $kept }
            $tip = 'Files that were in use or had changed were kept. See the log for details.'
            if ($Row.Rule.Kind -eq 'ExplorerRecent') {
                $text = 'Cleared ' + (Format-Count $clean.Deleted 'folder'); $sub = 'Pinned folders kept'
                $tip = "Only File Explorer's list was cleared. The folders themselves were not touched."
            }
        }
        'CleanedNone' {
            $text = 'Nothing removed'
            $kept = $clean.InUse + $clean.Changed + $clean.Denied + $clean.Protected + $clean.Failed
            if ($clean.InUse -gt 0) { $sub = (Format-Count $clean.InUse 'file') + ' in use' }
            elseif ($kept -gt 0) { $sub = '{0:N0} kept' -f $kept }
        }
        'CleanBlocked' { $text = 'Close app'; $color = $p.Warning; $isLink = $true; $sub = "$app was opened again"; $tip = "Click to close $app so its cache can be cleaned." }
        'CleanError' { $text = 'Not cleaned'; $color = $p.Warning; $sub = 'Hover for details'; $tip = $clean.Message }
    }

    $result = $Row.Result
    $result.Text = $text
    if ($isLink -and $text) {
        $result.LinkArea = New-Object System.Windows.Forms.LinkArea(0, $text.Length)
        Set-LinkColors $result $color
        $result.Cursor = [System.Windows.Forms.Cursors]::Hand
    }
    else {
        $result.LinkArea = New-Object System.Windows.Forms.LinkArea(0, 0)
        $result.ForeColor = $color
        $result.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    $Row.Sub.Text = $sub
    $script:ToolTip.SetToolTip($result, $tip)
    $script:ToolTip.SetToolTip($Row.Sub, $tip)
}

function Set-HeroHeading([object[]]$Parts) {
    $script:HeroParts = $Parts
    $heroHeading.Invalidate()
}

function Set-HeroButton([string]$Text, [string]$Action) {
    $heroButton.Text = $Text
    $heroButton.Tag.Kind = 'primary'
    $heroButton.Enabled = $true
    $script:HeroAction = $Action
    $heroButton.Invalidate()
}

function Set-HeroLink([string]$Text, [string]$Action) {
    $heroLink.Text = $Text
    $heroLink.LinkArea = New-Object System.Windows.Forms.LinkArea(0, $Text.Length)
    $script:HeroLinkAction = $Action
}

function Get-LastCleanedText {
    if ($script:Settings.LastCleanedAt -is [DateTime]) {
        return ('Last cleaned {0}{1}{2} freed' -f (Format-RelativeTime $script:Settings.LastCleanedAt), $script:Dot, (Format-CleanerSize $script:Settings.LastFreedBytes))
    }
    return ('Not cleaned yet' + $script:Dot + 'nothing is deleted until you click Clean')
}

function Update-Summary {
    $p = $script:Palette
    if ($null -eq $p) { return }
    $selected = @(Get-SelectedRows)
    $ready = @($selected | Where-Object { $null -ne $_.Scan -and $_.Scan.State -eq 'Ready' })
    $analyzed = @($selected | Where-Object { $null -ne $_.Scan -and $_.Scan.State -in @('Ready', 'Empty') })
    $blocked = @($selected | Where-Object { $null -ne $_.Scan -and $_.Scan.State -eq 'Blocked' }).Count
    [long]$bytes = 0
    [long]$files = 0
    foreach ($row in $ready) { $bytes += $row.Scan.Bytes; if ($row.Rule.Kind -ne 'ExplorerRecent') { $files += $row.Scan.Count } }
    $state = @{
        Selected = $selected.Count; Allowed = @($script:Rows | Where-Object { $_.Allowed }).Count
        Ready = $ready.Count; Analyzed = $analyzed.Count; Blocked = $blocked; Bytes = $bytes; Files = $files
    }
    if ($null -ne $script:Job) { return }      # while working, the progress view owns these texts

    $script:NavItems['items'].Tag.Badge = $(if ($null -eq $script:LastClean) { $ready.Count } else { 0 })
    $script:NavItems['items'].Invalidate()
    Update-HomeView $state
    Update-ItemsView $state
}

function Get-SkippedText($State) {
    if ($State.Blocked -gt 0) { return ($script:Dot + (Format-Count $State.Blocked 'item') + ' skipped (app open)') }
    return ''
}

function Update-HomeView($State) {
    $last = $script:LastClean
    $heroLink.Visible = $true
    if ($null -ne $last) {
        if ($last.Bytes -gt 0 -or $last.Files -gt 0) {
            Set-HeroHeading @(@{ Text = 'Done:'; Color = 'Text' }, @{ Text = (Format-CleanerSize $last.Bytes) + ' freed'; Color = 'Success' })
            $sub = '{0} removed' -f (Format-Count $last.Files 'file')
            if ($last.Kept -gt 0) { $sub += $script:Dot + ('{0} kept because they were in use or had changed' -f (Format-Count $last.Kept 'file')) }
        }
        else {
            Set-HeroHeading @(@{ Text = 'Nothing was removed'; Color = 'Text' })
            $sub = 'Everything that was found is in use or had changed.'
        }
        if ($last.Cancelled) { $sub = 'Cleaning was stopped' + $script:Dot + $sub }
        $heroSub.Text = $sub
        Set-HeroButton 'Analyze again' 'analyze'
        Set-HeroLink 'Open the log' 'log'
    }
    elseif ($State.Analyzed -eq 0) {
        Set-HeroHeading @(@{ Text = 'Clean up your PC'; Color = 'Text' })
        $heroSub.Text = Get-LastCleanedText
        Set-HeroButton 'Analyze' 'analyze'
        Set-HeroLink ('Choose what to clean ({0} of {1} selected)' -f $State.Selected, $State.Allowed) 'items'
    }
    elseif ($State.Ready -eq 0) {
        Set-HeroHeading @(@{ Text = 'Your PC is'; Color = 'Text' }, @{ Text = 'clean'; Color = 'Success' })
        $heroSub.Text = ('Nothing to remove in the selected items' + $script:Dot + 'analyzed ' + (Format-RelativeTime $script:LastScanAt) + (Get-SkippedText $State))
        Set-HeroButton 'Analyze again' 'analyze'
        Set-HeroLink 'Review items' 'items'
    }
    else {
        Set-HeroHeading @(@{ Text = 'Clean up your PC:'; Color = 'Text' }, @{ Text = (Format-CleanerSize $State.Bytes) + ' found'; Color = 'Coral' })
        $heroSub.Text = ('{0}{1}{2}{1}analyzed {3}{4}' -f (Format-Count $State.Ready 'item'), $script:Dot, (Format-Count $State.Files 'file'), (Format-RelativeTime $script:LastScanAt), (Get-SkippedText $State))
        Set-HeroButton 'Clean now' 'clean'
        Set-HeroLink 'Review items' 'items'
    }
    if ($null -eq $last -and $State.Blocked -gt 0) {
        Set-HeroLink ('Close {0} to clean {1} too' -f (Format-Count $State.Blocked 'open app'), $(if ($State.Blocked -eq 1) { 'it' } else { 'them' })) 'closeapps'
    }
    Update-HomeLayout
}

function Update-ItemsView($State) {
    $p = $script:Palette
    $itemsAnalyze.Text = 'Analyze'
    $itemsAnalyze.Enabled = $true
    $itemsClean.Text = 'Clean now'
    $itemsClean.Enabled = ($State.Selected -gt 0)
    $itemsTotal.ForeColor = $p.Text
    $last = $script:LastClean
    if ($null -ne $last) {
        $itemsTotal.Text = (Format-CleanerSize $last.Bytes) + ' freed'
        $itemsTotal.ForeColor = $p.Success
        $itemsDetail.Text = ('{0} removed{1}{2} kept' -f (Format-Count $last.Files 'file'), $script:Dot, (Format-Count $last.Kept 'file'))
    }
    elseif ($State.Analyzed -eq 0) {
        $itemsTotal.Text = '{0} of {1} items selected' -f $State.Selected, $State.Allowed
        $itemsDetail.Text = 'Analyze to see how much space they use. Nothing is deleted.'
    }
    elseif ($State.Ready -eq 0) {
        $itemsTotal.Text = 'Nothing to clean'
        $itemsDetail.Text = ('in the {0}{1}' -f (Format-Count $State.Selected 'selected item'), (Get-SkippedText $State))
    }
    else {
        $itemsTotal.Text = (Format-CleanerSize $State.Bytes) + ' selected'
        $itemsDetail.Text = ('{0}{1}{2}{3}' -f (Format-Count $State.Ready 'item'), $script:Dot, (Format-Count $State.Files 'file'), (Get-SkippedText $State))
    }
    $itemsAnalyze.Invalidate()
    $itemsClean.Invalidate()
}

function Set-ProgressValue([int]$Percent) {
    $state = $heroProgress.Tag
    if ($Percent -lt 0) {
        $state.Indeterminate = $true
        $block = [int]($heroProgress.Width * 0.3)
        $state.Offset = ($state.Offset + (S 9)) % ($heroProgress.Width + $block)
    }
    else {
        $state.Indeterminate = $false
        $state.Value = [Math]::Min(100, [Math]::Max(0, $Percent))
    }
    $heroProgress.Invalidate()
}

function Set-Busy([bool]$Busy, [string]$Kind = '') {
    if ($Busy) {
        $heroButton.Text = 'Stop'
        $heroButton.Tag.Kind = 'secondary'
        $itemsAnalyze.Text = 'Stop'
        $itemsClean.Enabled = $false
        $heroLink.Visible = $false
    }
    else {
        $heroButton.Tag.Kind = 'primary'
        $itemsAnalyze.Text = 'Analyze'
    }
    $heroButton.Enabled = $true
    $itemsAnalyze.Enabled = $true
    # Lock the choices while working, without greying them out.
    foreach ($row in $script:Rows) { if ($row.Allowed) { $row.Check.AutoCheck = -not $Busy } }
    # Dim the quick-select links instead of disabling them (disabled text looks blurry on a transparent background).
    foreach ($link in @($linkRecommended, $linkAll, $linkNone)) { Set-LinkColors $link $(if ($Busy) { $script:Palette.Disabled } else { $script:Palette.AccentText }) }
    $heroProgress.Visible = $Busy
    if (-not $Busy) { $heroProgress.Tag.Value = 0; $heroProgress.Tag.Indeterminate = $false }
    $heroButton.Invalidate()
    $itemsAnalyze.Invalidate()
}

# ------------------------------------------------------------------------------------------------
#  Background work (the window stays responsive while analyzing or cleaning)
# ------------------------------------------------------------------------------------------------
$script:WorkerScript = @'
param([string]$EnginePath, [string]$Kind, $Payload, [hashtable]$Sync)
$ErrorActionPreference = 'Stop'
if (-not (Get-Module -Name CleanerEngine)) { Import-Module -Name $EnginePath -DisableNameChecking }
if ($Kind -eq 'Scan') { [void](Invoke-CleanerScan -Rule $Payload -Sync $Sync) }
else { [void](Invoke-CleanerClean -ScanResult $Payload -Sync $Sync) }
'@

function Get-WorkerRunspace {
    if ($null -eq $script:Runspace -or $script:Runspace.RunspaceStateInfo.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        $state = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        try { $state.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($state)
        $runspace.ApartmentState = [System.Threading.ApartmentState]::STA
        $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $runspace.Open()
        $script:Runspace = $runspace
    }
    return $script:Runspace
}

function Start-Worker([string]$Kind, [object[]]$Payload, [hashtable]$Context) {
    $sync = [hashtable]::Synchronized(@{
            Cancel  = $false
            Status  = $(if ($Kind -eq 'Scan') { 'Starting the analysis' } else { 'Starting to clean' })
            Detail  = ''
            Percent = -1
            Current = ''
            Checked = [long]0
            Queue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        })
    $shell = [System.Management.Automation.PowerShell]::Create()
    $shell.Runspace = Get-WorkerRunspace
    [void]$shell.AddScript($script:WorkerScript)
    [void]$shell.AddArgument($script:EnginePath)
    [void]$shell.AddArgument($Kind)
    [void]$shell.AddArgument($Payload)
    [void]$shell.AddArgument($sync)
    $script:Job = @{
        Kind = $Kind; Shell = $shell; Sync = $sync; Context = $Context
        Results = New-Object System.Collections.ArrayList; Handle = $null
    }
    Set-Busy $true $Kind
    $script:Job.Handle = $shell.BeginInvoke()
    $script:Timer.Start()
}

function Stop-Worker {
    if ($null -eq $script:Job) { return }
    $script:Job.Sync['Cancel'] = $true
    foreach ($button in @($heroButton, $itemsAnalyze)) {
        $button.Text = 'Stopping' + $script:Ellipsis
        $button.Enabled = $false
    }
}

function Receive-WorkerItem($Job, $Item) {
    [void]$Job.Results.Add($Item)
    if (-not $script:RowById.ContainsKey($Item.RuleId)) { return }
    $row = $script:RowById[$Item.RuleId]
    if ($Job.Kind -eq 'Scan') {
        $row.Scan = $Item
        $row.Clean = $null
        $row.State = switch ($Item.State) {
            'Ready' { 'Ready' }
            'Empty' { 'Empty' }
            'Blocked' { 'Blocked' }
            'Unavailable' { 'Unavailable' }
            'Cancelled' { 'Cancelled' }
            default { 'Error' }
        }
    }
    else {
        $row.Clean = $Item
        $row.Scan = $null
        $row.State = switch ($Item.State) {
            'Done' { $(if ($Item.Deleted -gt 0) { 'Cleaned' } else { 'CleanedNone' }) }
            'Cancelled' { $(if ($Item.Deleted -gt 0) { 'Cleaned' } else { 'Cancelled' }) }
            'Blocked' { 'CleanBlocked' }
            'Error' { 'CleanError' }
            default { 'Idle' }
        }
    }
    Update-RowDisplay $row
}

function Update-WorkerProgress {
    $job = $script:Job
    if ($null -eq $job) { $script:Timer.Stop(); return }
    $sync = $job.Sync
    $item = $null
    while ($sync['Queue'].TryDequeue([ref]$item)) { Receive-WorkerItem $job $item }

    $current = [string]$sync['Current']
    if ($current -and $script:RowById.ContainsKey($current)) {
        $row = $script:RowById[$current]
        if ($row.State -eq 'Queued') {
            $row.State = $(if ($job.Kind -eq 'Scan') { 'Scanning' } else { 'Cleaning' })
            Update-RowDisplay $row
        }
    }
    $status = [string]$sync['Status']
    $detail = [string]$sync['Detail']
    if ($sync['Cancel']) { $status = 'Stopping' + $script:Ellipsis; $detail = '' }
    $line = $(if ($detail) { $status + $script:Dot + $detail } else { $status })
    $percent = [int]$sync['Percent']
    if ($job.Kind -eq 'Clean') {
        Set-HeroHeading @(@{ Text = 'Cleaning'; Color = 'Text' }, @{ Text = ('{0}%' -f [Math]::Max(0, $percent)); Color = 'AccentText' })
        $itemsTotal.Text = 'Cleaning {0}%' -f [Math]::Max(0, $percent)
    }
    else {
        Set-HeroHeading @(@{ Text = 'Analyzing your PC' + $script:Ellipsis; Color = 'Text' })
        $itemsTotal.Text = 'Analyzing' + $script:Ellipsis
    }
    $itemsTotal.ForeColor = $script:Palette.Text
    $heroSub.Text = $line
    $itemsDetail.Text = $line
    Set-ProgressValue $percent
    $script:AnimationTime += 0.06
    if ($heroArt.Visible) { $heroArt.Invalidate() }

    if ($job.Handle.IsCompleted) { Complete-Worker }
}

function Complete-Worker {
    $job = $script:Job
    $script:Timer.Stop()
    $errorText = $null
    try { [void]$job.Shell.EndInvoke($job.Handle) }
    catch { $errorText = $_.Exception.Message }
    if (-not $errorText -and $job.Shell.Streams.Error.Count -gt 0) { $errorText = $job.Shell.Streams.Error[0].ToString() }
    $item = $null
    while ($job.Sync['Queue'].TryDequeue([ref]$item)) { Receive-WorkerItem $job $item }
    $job.Shell.Dispose()
    $script:Job = $null
    if ($errorText) { try { Add-CleanerLogEntry -Kind 'UI-ERROR' -Message ('{0}: {1}' -f $job.Kind, $errorText) } catch { } }

    Set-Busy $false
    $heroArt.Invalidate()
    if ($job.Kind -eq 'Scan') { Complete-Scan $job $errorText } else { Complete-Clean $job $errorText }
    if ($script:CloseWhenIdle) { $form.Close() }
}

function Complete-Scan($Job, [string]$ErrorText) {
    foreach ($row in $script:Rows) {
        if ($row.State -in @('Queued', 'Scanning')) {
            $row.State = $(if ($row.Allowed) { 'Idle' } else { 'AdminOnly' })
            Update-RowDisplay $row
        }
    }
    if (-not $ErrorText) { $script:LastScanAt = [DateTime]::Now }
    Update-Summary
    if ($ErrorText) {
        [void][System.Windows.Forms.MessageBox]::Show(("The analysis stopped because of an error:`r`n`r`n{0}" -f $ErrorText), 'Cleaner', 'OK', 'Warning')
        return
    }
    if ($Job.Context.ThenClean -and -not $Job.Sync['Cancel'] -and -not $script:CloseWhenIdle) { Request-Clean -AfterAnalysis }
}

function Complete-Clean($Job, [string]$ErrorText) {
    [long]$bytes = 0; [long]$files = 0; [long]$kept = 0; $items = 0
    foreach ($result in $Job.Results) {
        $bytes += $result.Bytes
        $files += $result.Deleted
        $kept += $result.InUse + $result.Changed + $result.Denied + $result.Protected + $result.Failed
        if ($result.Deleted -gt 0) { $items++ }
    }
    foreach ($row in $script:Rows) {
        if ($row.State -in @('Queued', 'Cleaning')) { $row.State = 'Idle'; Update-RowDisplay $row }
    }
    $script:LastClean = @{ Bytes = $bytes; Files = $files; Kept = $kept; Items = $items; Cancelled = [bool]$Job.Sync['Cancel'] }
    if ($bytes -gt 0) {
        $script:Settings.LastCleanedAt = [DateTime]::Now
        $script:Settings.LastFreedBytes = $bytes
        $script:Settings.TotalFreedBytes = [long]$script:Settings.TotalFreedBytes + $bytes
        try { Save-CleanerSettings -Settings $script:Settings } catch { }
        Update-SettingsPage
    }
    Update-Summary
    if ($ErrorText) {
        [void][System.Windows.Forms.MessageBox]::Show(("Cleaning stopped because of an error:`r`n`r`n{0}`r`n`r`nNothing else was changed. Details are in the log." -f $ErrorText), 'Cleaner', 'OK', 'Warning')
    }
}

function Start-Analysis([object[]]$Rows, [switch]$ThenClean) {
    if ($null -ne $script:Job -or $script:ClosingApps) { return }
    if ($null -eq $Rows -or $Rows.Count -eq 0) { $Rows = @($script:Rows | Where-Object { $_.Allowed }) }
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { return }
    $script:LastClean = $null
    foreach ($row in $Rows) {
        $row.State = 'Queued'
        $row.Scan = $null
        $row.Clean = $null
        Update-RowDisplay $row
    }
    Set-HeroHeading @(@{ Text = 'Analyzing your PC' + $script:Ellipsis; Color = 'Text' })
    $heroSub.Text = 'Nothing is deleted during the analysis.'
    Start-Worker -Kind 'Scan' -Payload @($Rows | ForEach-Object { $_.Rule }) -Context @{ ThenClean = [bool]$ThenClean }
}

function Test-RowFresh($Row) {
    if ($null -eq $Row.Scan -or $Row.Scan.State -notin @('Ready', 'Empty')) { return $false }
    return (([DateTime]::Now - $Row.Scan.ScannedAt).TotalMinutes -lt $script:StaleMinutes)
}

function Request-Clean([switch]$AfterAnalysis) {
    if ($null -ne $script:Job -or $script:ClosingApps) { return }
    $selected = @(Get-SelectedRows)
    if ($selected.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Select at least one item to clean on the Items page.', 'Cleaner', 'OK', 'Information')
        return
    }
    if (-not $AfterAnalysis) {
        $stale = @($selected | Where-Object { -not (Test-RowFresh $_) })
        if ($stale.Count -gt 0) { Start-Analysis -Rows $stale -ThenClean; return }
    }
    $ready = @($selected | Where-Object { $null -ne $_.Scan -and $_.Scan.State -eq 'Ready' })
    $skipped = @($selected | Where-Object { $null -eq $_.Scan -or $_.Scan.State -notin @('Ready', 'Empty') })
    if ($ready.Count -eq 0) { Update-Summary; return }
    if (-not (Show-CleanConfirm -Ready $ready -Skipped $skipped)) { return }

    $script:LastClean = $null
    foreach ($row in $ready) { $row.State = 'Queued'; Update-RowDisplay $row }
    Set-HeroHeading @(@{ Text = 'Cleaning' + $script:Ellipsis; Color = 'Text' })
    $heroSub.Text = 'Each file is checked again right before it is removed.'
    Start-Worker -Kind 'Clean' -Payload @($ready | ForEach-Object { $_.Scan }) -Context @{}
}

# ------------------------------------------------------------------------------------------------
#  Dialogs
# ------------------------------------------------------------------------------------------------
function New-DialogForm([string]$Title, [double]$Width, [double]$Height, [switch]$Resizable) {
    $p = $script:Palette
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.FormBorderStyle = $(if ($Resizable) { [System.Windows.Forms.FormBorderStyle]::Sizable } else { [System.Windows.Forms.FormBorderStyle]::FixedDialog })
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = [bool]$Resizable
    $dialog.ShowInTaskbar = $false
    $dialog.ClientSize = New-Size $Width $Height
    $dialog.Font = $script:Fonts.Body
    $dialog.BackColor = $p.Window
    $dialog.ForeColor = $p.Text
    $dialog.Tag = 'window'
    $dialog.KeyPreview = $true
    if ($null -ne $script:AppIcon) { $dialog.Icon = $script:AppIcon }
    return $dialog
}

function Show-DialogThemed($Dialog) {
    Set-ControlTheme $Dialog
    $p = $script:Palette
    [CleanerNative.Ui]::StyleTitleBar($Dialog.Handle, $script:IsDark, (ConvertTo-ColorRef $p.Window), (ConvertTo-ColorRef $p.FrameBorder), $false)
    $result = $Dialog.ShowDialog($form)
    $Dialog.Dispose()
    return $result
}

function Show-CleanConfirm([object[]]$Ready, [object[]]$Skipped) {
    [long]$bytes = 0
    [long]$files = 0
    foreach ($row in $Ready) { $bytes += $row.Scan.Bytes; $files += $row.Scan.Count }
    $hasRecycleBin = @($Ready | Where-Object { $_.Rule.Kind -eq 'RecycleBin' }).Count -gt 0
    $shown = @($Ready | Select-Object -First 8)
    $more = $Ready.Count - $shown.Count
    $listHeight = 18 + 26 * $shown.Count + $(if ($more -gt 0) { 26 } else { 0 })

    $dialog = New-DialogForm -Title 'Confirm cleanup' -Width 500 -Height 300
    $y = 22
    [void](New-Label -Parent $dialog -Text ('Clean {0}?' -f (Format-CleanerSize $bytes)) -X 24 -Y $y -Width 452 -Height 34 -Role 'text' -Font $script:Fonts.Dialog)
    $y += 42
    [void](New-Label -Parent $dialog -Text ('These items will be permanently removed ({0}):' -f (Format-Count $files 'file')) -X 24 -Y $y -Width 452 -Height 20 -Role 'muted')
    $y += 28

    $card = New-CardPanel -Parent $dialog -X (S 24) -Y (S $y) -Width (S 452) -Height (S $listHeight)
    $lineY = 10
    foreach ($row in $shown) {
        [void](New-Label -Parent $card -Text ($script:Bullet + '  ' + $row.Rule.Name) -X 16 -Y $lineY -Width 290 -Height 22 -Role 'text')
        $amount = $(if ($row.Rule.Kind -eq 'ExplorerRecent') { Format-Count $row.Scan.Count 'folder' } else { Format-CleanerSize $row.Scan.Bytes })
        [void](New-Label -Parent $card -Text $amount -X 306 -Y $lineY -Width 130 -Height 22 -Role 'muted' -Align 'TopRight')
        $lineY += 26
    }
    if ($more -gt 0) { [void](New-Label -Parent $card -Text ('+ {0} more' -f $more) -X 16 -Y $lineY -Width 420 -Height 22 -Role 'muted') }
    $y += $listHeight + 14

    $notIncluded = @($Skipped | ForEach-Object { $_.Rule.Name })
    if ($notIncluded.Count -gt 0) {
        [void](New-Label -Parent $dialog -Text ('Not included (app open or not analyzed): ' + ($notIncluded -join ', ')) -X 24 -Y $y -Width 452 -Height 34 -Role 'warning' -Font $script:Fonts.Small -Ellipsis)
        $y += 38
    }
    if ($hasRecycleBin) {
        [void](New-Label -Parent $dialog -Text 'The Recycle Bin will be emptied. Those files cannot be restored.' -X 24 -Y $y -Width 452 -Height 20 -Role 'warning' -Font $script:Fonts.Small)
        $y += 24
    }
    [void](New-Label -Parent $dialog -Text 'Recent files, files in use and anything outside these folders are always kept. Every deletion is logged. This cannot be undone.' -X 24 -Y $y -Width 452 -Height 36 -Role 'muted' -Font $script:Fonts.Small)
    $y += 48

    $cancel = New-RoundButton -Parent $dialog -Text 'Cancel' -X 366 -Y $y -Width 110 -Height 40 -Kind 'secondary'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $ok = New-RoundButton -Parent $dialog -Text 'Clean now' -X 216 -Y $y -Width 140 -Height 40 -Kind 'primary'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.CancelButton = $cancel
    $dialog.ClientSize = New-Size 500 ($y + 40 + 22)
    $dialog.ActiveControl = $cancel     # Enter never deletes by accident

    return ((Show-DialogThemed $dialog) -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-RuleDetails($Row) {
    $scan = $Row.Scan
    $rule = $Row.Rule
    $p = $script:Palette
    $dialog = New-DialogForm -Title ('{0} - details' -f $rule.Name) -Width 820 -Height 560 -Resizable
    $dialog.MinimumSize = New-Size 600 400
    $clientWidth = $dialog.ClientSize.Width

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = [System.Windows.Forms.DockStyle]::Top
    $top.Height = S 112
    $top.Width = $clientWidth
    $top.Tag = 'window'
    $title = New-Label -Parent $top -Text $rule.Name -X 22 -Y 14 -Width 760 -Height 32 -Role 'text' -Font $script:Fonts.Dialog
    $title.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
    if ($rule.Kind -eq 'RecycleBin') {
        $summaryText = '{0}{1}{2} on all drives' -f (Format-Count $scan.Count 'item'), $script:Dot, (Format-CleanerSize $scan.Bytes)
    }
    else {
        $age = $(if ($rule.MinAgeDays -gt 0) { 'only files older than {0} days' -f $rule.MinAgeDays } elseif ($rule.AppName) { 'all cache files (the app is closed)' } else { 'all entries' })
        $summaryText = '{0}{1}{2}{1}{3}' -f (Format-Count $scan.Count 'file'), $script:Dot, (Format-CleanerSize $scan.Bytes), $age
    }
    $summaryLabel = New-Label -Parent $top -Text $summaryText -X 24 -Y 50 -Width 760 -Height 20 -Role 'text'
    $summaryLabel.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
    $locations = @($scan.Roots | ForEach-Object { Format-ShortPath $_.Path })
    $locationText = $(if ($locations.Count -gt 0) { 'Locations: ' + ($locations -join '; ') } else { $rule.Description })
    $locationLabel = New-Label -Parent $top -Text $locationText -X 24 -Y 74 -Width 772 -Height 34 -Role 'muted' -Font $script:Fonts.Small -Ellipsis
    $locationLabel.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
    $script:ToolTip.SetToolTip($locationLabel, (($scan.Roots | ForEach-Object { $_.Path }) -join "`r`n"))

    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $bottom.Height = S 64
    $bottom.Width = $clientWidth
    $bottom.Tag = 'window'
    $kept = New-Object System.Collections.Generic.List[string]
    if ($scan.SkippedRecent -gt 0) { $kept.Add(('{0:N0} recent' -f $scan.SkippedRecent)) }
    if ($scan.SkippedProtected -gt 0) { $kept.Add(('{0:N0} protected' -f $scan.SkippedProtected)) }
    if ($scan.SkippedLinks -gt 0) { $kept.Add(('{0:N0} links' -f $scan.SkippedLinks)) }
    if ($scan.SkippedUnreadable -gt 0) { $kept.Add(('{0:N0} unreadable' -f $scan.SkippedUnreadable)) }
    $noteText = $(if ($kept.Count -gt 0) { 'Kept: ' + ($kept -join ', ') + '.' } else { '' })
    if ($rule.Kind -eq 'Files' -and $scan.Count -gt 1000) { $noteText = ($noteText + ' Showing the 1,000 largest files.').Trim() }
    $note = New-Label -Parent $bottom -Text $noteText -X 22 -Y 22 -Width 480 -Height 20 -Role 'muted' -Font $script:Fonts.Small -Ellipsis
    $note.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Left, Right'
    $close = New-RoundButton -Parent $bottom -Text 'Close' -Y 12 -Width 110 -Height 40 -Kind 'secondary'
    $close.Left = $clientWidth - (S 22) - $close.Width
    $close.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
    $close.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $open = New-RoundButton -Parent $bottom -Text $(if ($rule.Kind -eq 'RecycleBin') { 'Open Recycle Bin' } else { 'Open folder' }) -Y 12 -Width 160 -Height 40 -Kind 'secondary' -Glyph $script:Glyph.Folder
    $open.Left = $close.Left - (S 10) - $open.Width
    $open.Anchor = [System.Windows.Forms.AnchorStyles]'Top, Right'
    $dialog.CancelButton = $close

    if ($rule.Kind -eq 'RecycleBin') {
        $body = New-Object System.Windows.Forms.Label
        $body.Dock = [System.Windows.Forms.DockStyle]::Fill
        $body.Padding = New-Object System.Windows.Forms.Padding((S 24), (S 10), (S 24), 0)
        $body.Text = 'Open the Recycle Bin to check that you no longer need anything in it. Emptying it removes these files for good.'
        $body.BackColor = [System.Drawing.Color]::Transparent
        $body.Tag = 'muted'
        $dialog.Controls.Add($body)
        $open.Add_Click({ Invoke-Safely { Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:RecycleBinFolder' } 'Opening the Recycle Bin' })
    }
    else {
        $list = New-Object System.Windows.Forms.ListView
        $list.View = [System.Windows.Forms.View]::Details
        $list.FullRowSelect = $true
        $list.HideSelection = $false
        $list.MultiSelect = $false
        $list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
        $list.Dock = [System.Windows.Forms.DockStyle]::Fill
        $list.BackColor = $p.Card
        $list.ForeColor = $p.Text
        [void]$list.Columns.Add('File', (S 520))
        [void]$list.Columns.Add('Size', (S 100), [System.Windows.Forms.HorizontalAlignment]::Right)
        [void]$list.Columns.Add('Last changed', (S 150))
        $list.OwnerDraw = $true
        $list.Add_DrawColumnHeader({
                param($s, $e)
                $pal = $script:Palette
                $brush = New-Object System.Drawing.SolidBrush($pal.Window)
                $e.Graphics.FillRectangle($brush, $e.Bounds)
                $brush.Dispose()
                $flags = [System.Windows.Forms.TextFormatFlags]'VerticalCenter, EndEllipsis, LeftAndRightPadding'
                if ($e.Header.TextAlign -eq [System.Windows.Forms.HorizontalAlignment]::Right) { $flags = $flags -bor [System.Windows.Forms.TextFormatFlags]::Right }
                [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $script:Fonts.Small, $e.Bounds, $pal.Muted, $flags)
                $pen = New-Object System.Drawing.Pen($pal.Line)
                $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1)
                $pen.Dispose()
            })
        $list.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
        $list.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })

        $items = New-Object 'System.Collections.Generic.List[System.Windows.Forms.ListViewItem]'
        foreach ($file in [CleanerNative.SafeIO]::Largest($scan.Files, 1000)) {
            $listItem = New-Object System.Windows.Forms.ListViewItem($file.Path)
            [void]$listItem.SubItems.Add((Format-CleanerSize $file.Size))
            [void]$listItem.SubItems.Add($file.LastChanged.ToString('g'))
            $listItem.Tag = $file.Path
            $items.Add($listItem)
        }
        $list.BeginUpdate()
        $list.Items.AddRange($items.ToArray())
        $list.EndUpdate()
        $dialog.Controls.Add($list)

        $fitColumns = {
            $width = $list.ClientSize.Width - $list.Columns[1].Width - $list.Columns[2].Width
            if ($width -gt (S 120)) { $list.Columns[0].Width = $width }
        }
        $list.Add_Resize({ & $fitColumns })

        $firstRoot = $(if ($scan.Roots.Count -gt 0) { $scan.Roots[0].Path } else { $null })
        $openSelected = {
            $target = $null
            if ($list.SelectedItems.Count -gt 0) { $target = [string]$list.SelectedItems[0].Tag }
            if ($target -and [IO.File]::Exists($target)) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"{0}"' -f $target)
            }
            elseif ($firstRoot) {
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $firstRoot)
            }
        }
        $open.Add_Click({ Invoke-Safely $openSelected 'Opening the folder' })
        $list.Add_DoubleClick({ Invoke-Safely $openSelected 'Opening the folder' })
        $dialog.Add_Shown({
                [CleanerNative.Ui]::SetControlTheme($list.Handle, $script:IsDark)
                & $fitColumns
            })
    }

    $dialog.Controls.Add($top)
    $dialog.Controls.Add($bottom)
    [void](Show-DialogThemed $dialog)
}

function Restart-Elevated {
    if ($null -ne $script:Job) {
        [void][System.Windows.Forms.MessageBox]::Show('Please wait until the current task has finished.', 'Cleaner', 'OK', 'Information')
        return
    }
    $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $arguments = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Restarted' -f $script:ScriptPath
    try {
        Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception) {
            # 1223: the user chose "No" in the Windows security prompt - nothing to report.
            if ($exception -is [System.ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 1223) { return }
            $exception = $exception.InnerException
        }
        if ($_.Exception.Message -match 'cancel') { return }
        [void][System.Windows.Forms.MessageBox]::Show(("Cleaner could not restart as administrator:`r`n`r`n{0}" -f $_.Exception.Message), 'Cleaner', 'OK', 'Warning')
        return
    }
    if ($null -ne $script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch { }
        $script:Mutex.Dispose()
        $script:Mutex = $null
    }
    $form.Close()
}

function Request-Elevation {
    if ($null -ne $script:Job) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "This item cleans Windows system folders, which needs administrator rights.`r`n`r`nRestart Cleaner as administrator now?",
        'Cleaner', 'YesNo', 'Question')
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Elevated }
}

# ------------------------------------------------------------------------------------------------
#  Closing apps whose caches are in use (browsers, Discord, ...)
# ------------------------------------------------------------------------------------------------
function Wait-AppsClosed([object[]]$Rows, [int]$Seconds) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $running = @($Rows | Where-Object { @(Get-CleanerRunningApp -Rule $_.Rule).Count -gt 0 })
        if ($running.Count -eq 0) { break }
        for ($i = 0; $i -lt 5; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    } while ($watch.Elapsed.TotalSeconds -lt $Seconds)
    return , $running
}

function Close-AppsForRows([object[]]$Rows) {
    if ($null -ne $script:Job -or $script:ClosingApps) { return }
    $Rows = @($Rows | Where-Object { $null -ne $_ -and $_.Allowed -and $_.Rule.AppName })
    if ($Rows.Count -eq 0) { return }
    $names = @($Rows | ForEach-Object { $_.Rule.AppName } | Select-Object -Unique)
    $list = ($names | ForEach-Object { $script:Bullet + '  ' + $_ }) -join "`r`n"
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Close these apps so their caches can be cleaned?`r`n`r`n{0}`r`n`r`nSave your work first. Cleaner asks each app to close normally, like clicking its X button." -f $list),
        'Close apps', 'YesNo', 'Question')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $script:ClosingApps = $true
    try {
        foreach ($row in $Rows) {
            $row.State = 'Closing'
            Update-RowDisplay $row
            [void](Close-CleanerApp -Rule $row.Rule)
        }
        try { Add-CleanerLogEntry -Kind 'APP' -Message ('Asked to close: ' + ($names -join ', ')) } catch { }
        $still = Wait-AppsClosed $Rows 10
        if ($still.Count -gt 0) {
            $stillNames = @($still | ForEach-Object { $_.Rule.AppName } | Select-Object -Unique)
            $stillList = ($stillNames | ForEach-Object { $script:Bullet + '  ' + $_ }) -join "`r`n"
            $force = [System.Windows.Forms.MessageBox]::Show(
                ("These apps are still running, in the background or waiting for you to save:`r`n`r`n{0}`r`n`r`nForce them to close? Anything not saved in them will be lost. Browsers normally restore their tabs the next time you open them." -f $stillList),
                'Close apps', 'YesNo', 'Warning', 'Button2')
            if ($force -eq [System.Windows.Forms.DialogResult]::Yes) {
                foreach ($row in $still) { [void](Close-CleanerApp -Rule $row.Rule -Force) }
                try { Add-CleanerLogEntry -Kind 'APP' -Message ('Forced to close: ' + ($stillNames -join ', ')) } catch { }
                [void](Wait-AppsClosed $still 5)
            }
        }
    }
    finally { $script:ClosingApps = $false }
    Start-Analysis -Rows $Rows      # analyze them again: closed apps become ready to clean
}

function Show-Page([string]$Id) {
    if (-not $script:Pages.ContainsKey($Id)) { return }
    $script:CurrentPage = $Id
    foreach ($key in @($script:Pages.Keys)) { $script:Pages[$key].Visible = ($key -eq $Id) }
    foreach ($item in $script:NavItems.Values) { $item.Invalidate() }
    switch ($Id) {
        'clean' { Update-HomeLayout }
        'items' { Update-ItemsLayout; Update-RowWidths }
        'tools' { Update-ToolsLayout }
        'safety' { Update-SafetyLayout }
        'settings' { Update-SettingsLayout; Update-SettingsPage }
    }
    Update-ChromeLayout
}

# ------------------------------------------------------------------------------------------------
#  Events
# ------------------------------------------------------------------------------------------------
$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 60
$script:Timer.Add_Tick({
        try { Update-WorkerProgress }
        catch {
            $script:Timer.Stop()
            try { Add-CleanerLogEntry -Kind 'UI-ERROR' -Message ('Progress: {0}' -f $_) } catch { }
            [void][System.Windows.Forms.MessageBox]::Show(("Something went wrong while showing progress:`r`n`r`n{0}" -f $_.Exception.Message), 'Cleaner', 'OK', 'Warning')
        }
    })

# Keeps "analyzed 3 minutes ago" and similar texts up to date.
$script:ClockTimer = New-Object System.Windows.Forms.Timer
$script:ClockTimer.Interval = 30000
$script:ClockTimer.Add_Tick({ try { if ($null -eq $script:Job) { Update-Summary } } catch { } })

$heroButton.Add_Click({
        Invoke-Safely {
            if ($null -ne $script:Job) { Stop-Worker }
            elseif ($script:HeroAction -eq 'clean') { Request-Clean }
            else { Start-Analysis }
        } 'Clean'
    })
$heroLink.Add_LinkClicked({
        Invoke-Safely {
            if ($script:HeroLinkAction -eq 'log') { Open-LogFolder }
            elseif ($script:HeroLinkAction -eq 'closeapps') { Close-AppsForRows @(Get-SelectedRows | Where-Object { $null -ne $_.Scan -and $_.Scan.State -eq 'Blocked' }) }
            else { Show-Page 'items' }
        } 'Opening'
    })
$itemsAnalyze.Add_Click({ Invoke-Safely { if ($null -ne $script:Job) { Stop-Worker } else { Start-Analysis } } 'Analyze' })
$itemsClean.Add_Click({ Invoke-Safely { Request-Clean } 'Clean' })
$linkRecommended.Add_LinkClicked({ Invoke-Safely { Set-Selection 'Recommended' } 'Changing the selection' })
$linkAll.Add_LinkClicked({ Invoke-Safely { Set-Selection 'All' } 'Changing the selection' })
$linkNone.Add_LinkClicked({ Invoke-Safely { Set-Selection 'None' } 'Changing the selection' })
$safetyLogLink.Add_LinkClicked({ Invoke-Safely { Open-LogFolder } 'Opening the log folder' })
$aboutFolderLink.Add_LinkClicked({ Invoke-Safely { Open-DataFolder } 'Opening the folder' })
$adminRestart.Add_Click({ Invoke-Safely { Restart-Elevated } 'Restart as administrator' })
$shortcutButton.Add_Click({ Invoke-Safely { New-DesktopShortcut } 'Creating the shortcut' })

$form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Tab) { $script:ShowFocus = $true }
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5 -and $null -eq $script:Job) {
            $e.Handled = $true
            Invoke-Safely { Start-Analysis } 'Analyze'
        }
        if ($e.Control) {
            $pages = @{ D1 = 'clean'; D2 = 'items'; D3 = 'tools'; D4 = 'safety'; D5 = 'settings' }
            $key = [string]$e.KeyCode
            if ($pages.ContainsKey($key)) { $e.Handled = $true; Invoke-Safely { Show-Page $pages[$key] } 'Opening the page' }
        }
    })
$form.Add_Activated({ try { if ([string]$script:Settings.Theme -eq 'System') { Update-Theme } } catch { } })
$form.Add_Shown({
        try {
            Set-WindowFrame
            Update-ChromeLayout
            $script:ClockTimer.Start()
        }
        catch { }
    })
$form.Add_FormClosing({
        param($s, $e)
        try {
            if ($script:ClosingApps) { $e.Cancel = $true; return }
            if ($null -eq $script:Job) { return }
            if ($script:Job.Kind -eq 'Clean' -and -not $script:CloseWhenIdle) {
                $answer = [System.Windows.Forms.MessageBox]::Show('Cleaning is still running. Stop it and close Cleaner?', 'Cleaner', 'YesNo', 'Question', 'Button2')
                if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true; return }
            }
            $script:Job.Sync['Cancel'] = $true
            $script:CloseWhenIdle = $true
            $e.Cancel = $true
            Stop-Worker
        }
        catch { }
    })

# ------------------------------------------------------------------------------------------------
#  Start
# ------------------------------------------------------------------------------------------------
Build-RuleList
$script:Loading = $false
Update-Theme -Force
Show-Page 'clean'

if (-not $script:IsDotSourced) {
    [void]$form.Handle                       # create the window now so the title bar is styled before it appears
    Update-Theme -Force
    $form.ActiveControl = $heroButton        # Enter / Space starts the analysis
    try {
        [void]$form.ShowDialog()
    }
    finally {
        $script:Timer.Stop()
        $script:ClockTimer.Stop()
        if ($null -ne $script:Runspace) { try { $script:Runspace.Dispose() } catch { } }
        if ($null -ne $script:Mutex) {
            try { $script:Mutex.ReleaseMutex() } catch { }
            $script:Mutex.Dispose()
        }
        $form.Dispose()
    }
}
