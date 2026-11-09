$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root 'dist\Cleaner'
[void][IO.Directory]::CreateDirectory($out)
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /target:winexe /platform:x64 /optimize+ /reference:System.Windows.Forms.dll ('/win32icon:'+(Join-Path $root 'Assets\Cleaner.ico')) ('/out:'+(Join-Path $root 'Cleaner.exe')) (Join-Path $PSScriptRoot 'Launcher.cs')
if($LASTEXITCODE -ne 0){throw 'Compilation failed'}
foreach($name in 'Cleaner.exe','Cleaner.ps1','CleanerEngine.psm1','Cleaner.cmd','README.md'){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $out -Force}
[void][IO.Directory]::CreateDirectory((Join-Path $out 'Assets'))
Copy-Item -LiteralPath (Join-Path $root 'Assets\Cleaner.ico') -Destination (Join-Path $out 'Assets') -Force
'Built '+(Join-Path $out 'Cleaner.exe')
Copy-Item -LiteralPath (Join-Path $root 'Assets\Cleaner.png') -Destination (Join-Path $out 'Assets') -Force
Copy-Item -LiteralPath (Join-Path $root 'CONTRIBUTING.md') -Destination $out -Force
Copy-Item -LiteralPath (Join-Path $root 'docs') -Destination $out -Recurse -Force
