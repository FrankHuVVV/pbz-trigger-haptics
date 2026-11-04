#Requires -Version 7.0
<#
    Install PBZ trigger haptics.

        .\install.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\PBZ"

    What it does:
      1. renames the original AkMotion.dll to AkMotion_orig.dll (once; the proxy loads it)
      2. copies release\AkMotion.dll into the plugin folder
      3. copies mod\PBZHaptics\ into ue4ss\Mods\
      4. copies the version-agnostic signature scripts into ue4ss\UE4SS_Signatures\
    Uninstall with uninstall.ps1 (restores the original file).
#>
param(
    [Parameter(Mandatory=$true)][string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here

$bin  = Join-Path $GameRoot 'ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin'
$ue   = Join-Path $GameRoot 'platform\steam\ue4ss'

if (-not (Test-Path $bin)) { throw "plugin folder not found: $bin" }
if (-not (Test-Path $ue))  { throw "UE4SS folder not found: $ue (install UE4SS first)" }

$orig = Join-Path $bin 'AkMotion.dll'
$keep = Join-Path $bin 'AkMotion_orig.dll'

if (-not (Test-Path $keep)) {
    Copy-Item $orig $keep -Force
    Write-Host "backed up original -> AkMotion_orig.dll"
} else {
    Write-Host "AkMotion_orig.dll already present, keeping it"
}

Copy-Item (Join-Path $repo 'release\AkMotion.dll') $orig -Force
Write-Host "proxy installed -> AkMotion.dll"

$modDst = Join-Path $ue 'Mods\PBZHaptics'
New-Item -ItemType Directory -Force $modDst | Out-Null
Copy-Item (Join-Path $repo 'mod\PBZHaptics\*') $modDst -Recurse -Force
Write-Host "mod installed -> $modDst"

$sigDst = Join-Path $ue 'UE4SS_Signatures'
New-Item -ItemType Directory -Force $sigDst | Out-Null
Copy-Item (Join-Path $repo 'mod\UE4SS_Signatures\*.lua') $sigDst -Force
Write-Host "signature scripts installed -> $sigDst"

Write-Host ""
Write-Host "Done. Start the game; if it reports a corrupted file, choose 'do not repair'."
