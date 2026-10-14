param([string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if(-not $OutputDirectory) { $OutputDirectory=Join-Path $repo 'agent/output/desktop' }
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$scripts=Join-Path $repo 'plugins/screen-capture/scripts'
$compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if(-not(Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4.x C# compiler was not found.' }
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $scripts 'capture-ui.cs') -ReferencedAssemblies @('System.dll','System.Drawing.dll','System.Windows.Forms.dll')
$iconPath=Join-Path $OutputDirectory 'app.ico'
$icon=[CaptureUi]::TrayIcon()
$iconStream=[IO.File]::Create($iconPath)
try { $icon.Save($iconStream) } finally { $iconStream.Dispose(); $icon.Dispose() }
$output=Join-Path $OutputDirectory 'CodexScreenCapture.exe'
$compilerArgs=@('/nologo','/target:winexe','/platform:anycpu','/optimize+','/codepage:65001','/utf8output',('/out:'+$output),('/win32icon:'+$iconPath),'/reference:System.dll','/reference:System.Windows.Forms.dll',(Join-Path $PSScriptRoot 'Launcher.cs'))
foreach($file in @('hotkey.ps1','capture.ps1','composer-paste.ps1','capture-ui.cs')) { $compilerArgs+=('/resource:'+(Join-Path $scripts $file)+',scripts.'+$file) }
& $compiler @compilerArgs
if($LASTEXITCODE -ne 0) { throw 'EXE compilation failed.' }
Get-Item -LiteralPath $output | Select-Object FullName,Length
Get-FileHash -LiteralPath $output -Algorithm SHA256 | Select-Object Algorithm,Hash
