#Requires -Version 7.0
<#
    一键卸载（本 zip 专用版）

        .\UNINSTALL.ps1 -GameRoot "D:\SteamLibrary\steamapps\common\PBZ"

    顺序：
      1. 要求游戏已退出（插件文件被占用时无法替换）
      2. 用 GameInput 把四通道（握把 + 左右扳机）各写一帧 0
         —— 一次性解除"卡住的震动状态"，不做任何持久设置；
            下次启动游戏，原生震动完全照旧
      3. 还原原版 AkMotion.dll
      4. 删除 Lua 事件层
#>
param(
    [Parameter(Mandatory=$true)][string]$GameRoot
)

$ErrorActionPreference = 'Stop'

$proc = Get-Process PBZ -ErrorAction SilentlyContinue
if ($proc) {
    Write-Warning "检测到游戏仍在运行 (pid $($proc.Id))。请完全退出游戏后重新运行本脚本。"
    exit 1
}

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
    if ($resetOk) { Write-Host "已用 GameInput 清零四通道（握把 + 左右扳机）" }
    else { Write-Warning "未找到 GameInput 手柄，已退回 XInput 清零握把（扳机可能未清零）" }
} catch {
    Write-Warning "清零失败: $($_.Exception.Message)"
}

$bin  = Join-Path $GameRoot 'ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin'
$ue   = Join-Path $GameRoot 'platform\steam\ue4ss'
$dll  = Join-Path $bin 'AkMotion.dll'
$orig = Join-Path $bin 'AkMotion_orig.dll'

if (Test-Path $orig) {
    Remove-Item $dll -Force -ErrorAction SilentlyContinue
    Rename-Item $orig 'AkMotion.dll' -Force
    Write-Host "已恢复原版 AkMotion.dll —— 游戏原生震动不受影响"
} else {
    Write-Warning "未找到 AkMotion_orig.dll，无法恢复原版"
}

$modDst = Join-Path $ue 'Mods\PBZHaptics'
if (Test-Path $modDst) { Remove-Item $modDst -Recurse -Force; Write-Host "已移除 Lua 事件层" }

Write-Host ""
Write-Host "卸载完成：原生震动就是游戏原样，本工具不会关闭或削弱它。"
if (-not $resetOk) {
    Write-Host "若扳机仍在空转：拔掉 USB 线 5 秒后重插，或长按 Xbox 键关机再开机。"
}
