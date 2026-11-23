param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'NewLook.exe'),
    [string]$Version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -TotalCount 1)
)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
$automation = [System.Management.Automation.PowerShell].Assembly.Location
$source = Join-Path $PSScriptRoot 'NewLook.Host.cs'
$updater = Join-Path $PSScriptRoot 'NewLook.Update.cs'
$script = Join-Path $PSScriptRoot 'NewLook.ps1'
$icon = Join-Path $PSScriptRoot 'Shelfside.ico'
$output = [IO.Path]::GetFullPath($OutputPath)

if ($Version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Version must be MAJOR.MINOR.PATCH.' }
$versionSource = Join-Path ([IO.Path]::GetTempPath()) ('NewLook-' + [guid]::NewGuid() + '.cs')
try {
    [IO.File]::WriteAllText($versionSource, @"
[assembly: System.Reflection.AssemblyTitle("Shelfside")]
[assembly: System.Reflection.AssemblyProduct("Shelfside")]
[assembly: System.Reflection.AssemblyVersion("$Version.0")]
[assembly: System.Reflection.AssemblyFileVersion("$Version.0")]
"@)
    & $compiler /nologo /target:winexe /optimize+ /codepage:65001 "/reference:$automation" /reference:System.Windows.Forms.dll /reference:System.Net.Http.dll /reference:System.Web.Extensions.dll "/resource:$script,NewLook.ps1" "/win32icon:$icon" "/resource:$icon,Shelfside.ico" "/out:$output" $source $updater $versionSource
    if ($LASTEXITCODE -ne 0) { throw "NewLook compilation failed ($LASTEXITCODE)." }
} finally { [IO.File]::Delete($versionSource) }
