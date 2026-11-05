#Requires -Version 7.0
<#
    卸载（自动识别布局，zip 包与仓库通用）

        .\UNINSTALL.ps1 -GameRoot "D:\...\PBZ"

    安全前提：只还原"确实是我们改过的"文件。
      * 若 AkMotion.dll 已被 Steam 修复/更新成游戏原版，则保留它，只删除我们留下的副本；
      * 若特征码脚本已被更新替换，则不覆盖，仅清理备份。

    顺序：
      1. 游戏必须已退出
      2. GameInput 四通道各写一帧 0（一次性解除卡住状态，无持久设置）
      3. 判断并还原 AkMotion.dll
      4. 删除 Lua 事件层（安装前就存在的同名目录则保留）
      5. 特征码脚本按清单还原（仅当我们那份仍在位）
      6. 删除安装清单
#>
param(
    [Parameter(Mandatory=$true)][string]$GameRoot
)

$ErrorActionPreference = 'Stop'

if (Get-Process PBZ -ErrorAction SilentlyContinue) {
    Write-Warning "检测到游戏仍在运行。请完全退出游戏后重新运行。"
    exit 1
}

$bin = Join-Path $GameRoot 'ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin'
$ue  = Join-Path $GameRoot 'platform\steam\ue4ss'
$sigDst = Join-Path $ue 'UE4SS_Signatures'
$manifestPath = Join-Path $sigDst 'pbzhaptics-install.json'

$manifest = $null
if (Test-Path $manifestPath) {
    try { $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json } catch { $manifest = $null }
}

# ---------------------------------------------------------------- helpers
function Test-IsOurProxy([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    $len = (Get-Item $path).Length
    if ($len -gt 120000) { return $false }          # 原版 186,856 字节；代理约 57 KB
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $text  = [System.Text.Encoding]::Latin1.GetString($bytes)
        return ($text.Contains('AkMotion_orig.dll') -and $text.Contains('SetRumbleState'))
    } catch { return $false }
}

function Test-IsOurSignature([string]$path) {
    if (-not (Test-Path $path)) { return $false }
    try {
        $text = Get-Content $path -Raw -ErrorAction Stop
        return $text.Contains('[PBZ auto]')
    } catch { return $false }
}

# ---------------------------------------------------------------- 1. 清零
$resetOk = $false
try {
    if (-not ('PBZHapticsReset' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class PBZHapticsReset
{
    [StructLayout(LayoutKind.Sequential)]
    public struct VIB { public ushort Left, Right; }

    [DllImport("GameInput.dll", CallingConvention = CallingConvention.StdCall)]
    static extern int GameInputCreate(out IntPtr gameInput);

    [DllImport("xinput1_4.dll", EntryPoint = "XInputSetState")]
    static extern uint XInputSetState(uint index, ref VIB vib);

    delegate int RegDevFn(IntPtr self, IntPtr dev, uint kind, uint status, uint enumKind,
                          IntPtr ctx, DeviceCb cb, out ulong token);
    delegate void StopCbFn(IntPtr self, ulong token);
    delegate void RelFn(IntPtr self);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate void DeviceCb(ulong token, IntPtr ctx, IntPtr dev, ulong ts, uint cur, uint prev);
    delegate void RumbleFn(IntPtr self, IntPtr p);

    static IntPtr _dev = IntPtr.Zero;
    static DeviceCb _cb;

    static IntPtr Slot(IntPtr obj, int idx)
    {
        IntPtr vt = Marshal.ReadIntPtr(obj);
        return Marshal.ReadIntPtr(vt, idx * IntPtr.Size);
    }

    static void OnDevice(ulong token, IntPtr ctx, IntPtr dev, ulong ts, uint cur, uint prev)
    {
        if (dev != IntPtr.Zero && _dev == IntPtr.Zero)
        {
            var addRef = (RelFn)Marshal.GetDelegateForFunctionPointer(Slot(dev, 1), typeof(RelFn));
            addRef(dev);
            _dev = dev;
        }
    }

    public static bool ZeroAll()
    {
        bool ok = false;
        IntPtr gi = IntPtr.Zero;
        ulong token = 0;
        try
        {
            if (GameInputCreate(out gi) == 0 && gi != IntPtr.Zero)
            {
                _cb = OnDevice;
                var reg = (RegDevFn)Marshal.GetDelegateForFunctionPointer(Slot(gi, 9), typeof(RegDevFn));
                if (reg(gi, IntPtr.Zero, 0x0004000Eu, 0x00FFFFFFu, 2u, IntPtr.Zero, _cb, out token) == 0)
                {
                    for (int i = 0; i < 20 && _dev == IntPtr.Zero; i++) Thread.Sleep(100);
                }
                if (_dev != IntPtr.Zero)
                {
                    var rumble = (RumbleFn)Marshal.GetDelegateForFunctionPointer(Slot(_dev, 10), typeof(RumbleFn));
                    IntPtr p = Marshal.AllocHGlobal(16);
                    try
                    {
                        for (int i = 0; i < 3; i++)
                        {
                            Marshal.WriteInt32(p, 0, 0);
                            Marshal.WriteInt32(p, 4, 0);
                            Marshal.WriteInt32(p, 8, 0);
                            Marshal.WriteInt32(p, 12, 0);
                            rumble(_dev, p);
                            Thread.Sleep(20);
                        }
                        ok = true;
                    }
                    finally { Marshal.FreeHGlobal(p); }
                }
                if (token != 0)
                {
                    var stop = (StopCbFn)Marshal.GetDelegateForFunctionPointer(Slot(gi, 12), typeof(StopCbFn));
                    stop(gi, token);
                }
            }
        }
        catch { }

        try
        {
            for (uint i = 0; i < 4; i++)
            {
                VIB v = new VIB();
                XInputSetState(i, ref v);
            }
        }
        catch { }

        return ok;
    }
}
'@
    }
    $resetOk = [PBZHapticsReset]::ZeroAll()
    if ($resetOk) { Write-Host "已用 GameInput 清零四通道（握把 + 左右扳机，一次性）" }
    else { Write-Warning "未找到 GameInput 手柄，已退回 XInput 清零握把" }
} catch {
    Write-Warning "清零失败: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- 2. AkMotion.dll
$dll  = Join-Path $bin 'AkMotion.dll'
$orig = Join-Path $bin 'AkMotion_orig.dll'

if (Test-IsOurProxy $dll) {
    # 我们还是当前生效的那份 -> 用备份还原
    if (Test-Path $orig) {
        Remove-Item $dll -Force
        Rename-Item $orig 'AkMotion.dll' -Force
        Write-Host "已还原原版 AkMotion.dll"
    } else {
        Write-Warning "当前是我们的代理，但找不到 AkMotion_orig.dll 备份；请用 Steam“验证完整性”恢复原版"
    }
} else {
    # 已被 Steam 修复或更新成游戏自己的版本 -> 绝不覆盖
    if (Test-Path $dll) {
        Write-Host "AkMotion.dll 已是游戏原版（或更新版），保留不动"
    } else {
        Write-Warning "未找到 AkMotion.dll，请用 Steam“验证游戏文件完整性”补回"
    }
    if (Test-Path $orig) {
        Remove-Item $orig -Force
        Write-Host "已删除安装时留下的 AkMotion_orig.dll 副本（内容已由 Steam 提供）"
    }
}

# ---------------------------------------------------------------- 3. Mod
$modDst = Join-Path $ue 'Mods\PBZHaptics'
$modPreexisted = $false
if ($manifest -and $null -ne $manifest.modExisted) { $modPreexisted = [bool]$manifest.modExisted }
if (Test-Path $modDst) {
    if ($modPreexisted) { Write-Warning "安装前已存在 Mods\PBZHaptics（非本工具创建），保留" }
    else { Remove-Item $modDst -Recurse -Force; Write-Host "已移除 Lua 事件层" }
}

# ---------------------------------------------------------------- 4. 特征码
$ours = @()
if ($manifest -and $manifest.signatures) { $ours = @($manifest.signatures) }
if ($ours.Count -eq 0) {
    $ours = @([pscustomobject]@{ name = 'GNatives.lua' }, [pscustomobject]@{ name = 'GUObjectArray.lua' })
}

foreach ($item in $ours) {
    $name   = [string]$item.name
    $target = Join-Path $sigDst $name
    $backup = "$target.pre-pbzhaptics.bak"

    if (Test-Path $backup) {
        if (Test-IsOurSignature $target) {
            Move-Item $backup $target -Force
            Write-Host "已还原 $name（来自预装备份）"
        } else {
            Remove-Item $backup -Force
            Write-Host "$name 已被更新替换（非本工具版本），保留现状并清理备份"
        }
        continue
    }

    if (-not (Test-Path $target)) { continue }

    if (Test-IsOurSignature $target) {
        Remove-Item $target -Force
        Write-Host "已删除本工具安装的 $name（安装前不存在）"
    } else {
        Write-Host "$name 不是本工具安装的，保留不动"
    }
}

# ---------------------------------------------------------------- 5. 清单
if (Test-Path $manifestPath) { Remove-Item $manifestPath -Force; Write-Host "已删除安装清单" }

Write-Host ""
Write-Host "卸载完成：只还原了本工具改过的文件；Steam 修复/更新过的一律保留。"
Write-Host "原生震动由游戏自行驱动，未做任何持久修改。"
if (-not $resetOk) {
    Write-Host "若手柄仍在空转：拔掉 USB 线 5 秒后重插，或长按 Xbox 键关机再开机。"
}
