#Requires -Version 7.0
<#
    Undo install.ps1: restore the original AkMotion.dll and remove the mod.

        .\uninstall.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\PBZ"

    IMPORTANT: close the game first. The controller keeps whatever rumble state was
    written last, so deleting files alone does not stop a stuck vibration - this script
    sends an explicit "all motors zero" frame before removing anything.
#>
param(
    [Parameter(Mandatory=$true)][string]$GameRoot
)

$ErrorActionPreference = 'Stop'

$process = Get-Process PBZ -ErrorAction SilentlyContinue
if ($process) {
    Write-Warning "PBZ.exe is still running (pid $($process.Id)). Quit the game completely and re-run."
    exit 1
}

# ---- zero the rumble first ----
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PBZHapticsReset {
    [StructLayout(LayoutKind.Sequential)]
    public struct VIB { public ushort Left; public ushort Right; }
    [DllImport("xinput1_4.dll", EntryPoint = "XInputSetState")]
    public static extern uint SetState(uint index, ref VIB vib);
}
'@ -ErrorAction Stop
    for ($i = 0; $i -lt 4; $i++) {
        $v = New-Object PBZHapticsReset+VIB
        [void][PBZHapticsReset]::SetState([uint32]$i, [ref]$v)
    }
    Write-Host "sent zero-rumble to XInput slots 0-3"
} catch {
    Write-Warning "XInput reset failed: $($_.Exception.Message)"
}

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

Write-Host ""
Write-Host "Signature scripts were left in place (harmless for other mods)."
Write-Host "Still vibrating? Unplug USB for 5 s and replug, or power-cycle the pad -"
Write-Host "trigger motors can only be cleared through GameInput, so a replug is the quickest fix."
