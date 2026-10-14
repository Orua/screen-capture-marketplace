param(
    [Parameter(Mandatory=$true)][ValidateSet('region','window','screen')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$Annotate,
    [uint32]$PasteHelperPid = 0,
    [string]$PreviewImage
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'capture-ui.cs') -ReferencedAssemblies @('System.Drawing.dll','System.Windows.Forms.dll','System.dll')
[CaptureUi]::SetProcessDPIAware() | Out-Null
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath))) | Out-Null
if($PreviewImage) { [CaptureUi]::Preview($PreviewImage,$OutputPath); exit 0 }
if($Mode -eq 'region') {
    if(-not [CaptureUi]::Run($OutputPath,$PasteHelperPid)) { exit 2 }
} else { [CaptureUi]::CapturePlain($Mode,$OutputPath) }