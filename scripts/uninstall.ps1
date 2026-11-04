#Requires -Version 7.0
<#
    Undo install.ps1: restore the original AkMotion.dll and remove the mod.

        .\uninstall.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\PBZ"
#>
param(
    [Parameter(Mandatory=$true)][string]$GameRoot
)

$ErrorActionPreference = 'Stop'

$bin  = Join-Path $GameRoot 'ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin'
$ue   = Join-Path $GameRoot 'platform\steam\ue4ss'

$dll  = Join-Path $bin 'AkMotion.dll'
$keep = Join-Path $bin 'AkMotion_orig.dll'

if (Test-Path $keep) {
    Remove-Item $dll -Force -ErrorAction SilentlyContinue
    Rename-Item $keep 'AkMotion.dll' -Force
    Write-Host "original AkMotion.dll restored"
} else {
    Write-Warning "AkMotion_orig.dll not found - nothing to restore"
}

$modDst = Join-Path $ue 'Mods\PBZHaptics'
if (Test-Path $modDst) { Remove-Item $modDst -Recurse -Force; Write-Host "mod removed" }

Write-Host "Signature scripts were left in place (they are harmless for other mods);"
Write-Host "delete them from ue4ss\UE4SS_Signatures\ if you want a pristine install."
