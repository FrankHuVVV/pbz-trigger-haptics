#Requires -Version 7.0
<#
    Build the AkMotion proxy DLL.

    Needs a C compiler that can see the Windows SDK or MinGW headers.
    Tested with MinGW-w64 (winlibs) gcc 16.2.0:

        .\build.ps1 -Gcc "D:\tools\mingw64\bin\gcc.exe"

    The output is written to ..\release\AkMotion.dll
#>
param(
    [string]$Gcc = "gcc",
    [switch]$PassthroughOnly
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $here '..\src\AkMotionProxy'
$out  = Join-Path $here '..\release\AkMotion.dll'

# gcc needs a writable temp dir; point it inside the repo to avoid sandbox/ACL surprises
$env:TMP  = Join-Path $here '..\obj'
$env:TEMP = $env:TMP
New-Item -ItemType Directory -Force $env:TMP | Out-Null

$args = @('-shared', '-O2', '-static-libgcc', '-o', $out,
          (Join-Path $src 'akmotion_proxy.c'),
          (Join-Path $src 'akmotion_proxy.def'))

if ($PassthroughOnly) { $args = @('-DPASSTHROUGH_ONLY=1') + $args }

Push-Location $here
try   { & $Gcc @args }
finally { Pop-Location }

if (-not (Test-Path $out)) { throw 'build failed: no output produced' }

Write-Host ("built: " + (Get-Item $out).FullName + "  (" + (Get-Item $out).Length + " bytes)")
Write-Host ("sha256: " + (Get-FileHash $out -Algorithm SHA256).Hash)
