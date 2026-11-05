#Requires -Version 7.0
<#
    安装（自动识别布局，zip 包与仓库通用）

    在 zip 解压目录里：  .\INSTALL.ps1 -GameRoot "D:\...\PBZ"
    在仓库 scripts 里：  .\install.ps1 -GameRoot "D:\...\PBZ"

    会备份被覆盖的原始文件，并写一份清单，卸载时据此精确还原。
#>
param(
    [Parameter(Mandatory=$true)][string]$GameRoot
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- 定位资源（zip 布局 vs 仓库布局）----
if (Test-Path (Join-Path $here 'AkMotion.dll')) {
    $dllSrc  = Join-Path $here 'AkMotion.dll'
    $modSrc  = Join-Path $here 'mod\PBZHaptics'
    $sigSrc  = Join-Path $here 'mod\UE4SS_Signatures'
} else {
    $root    = Split-Path -Parent $here
    $dllSrc  = Join-Path $root 'release\AkMotion.dll'
    $modSrc  = Join-Path $root 'mod\PBZHaptics'
    $sigSrc  = Join-Path $root 'mod\UE4SS_Signatures'
}
foreach ($p in @($dllSrc, $modSrc, $sigSrc)) {
    if (-not (Test-Path $p)) { throw "缺少安装资源: $p" }
}

$bin = Join-Path $GameRoot 'ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin'
$ue  = Join-Path $GameRoot 'platform\steam\ue4ss'
if (-not (Test-Path $bin)) { throw "找不到插件目录: $bin" }
if (-not (Test-Path $ue))  { throw "找不到 UE4SS 目录: $ue （请先安装 UE4SS 3.x）" }

if (Get-Process PBZ -ErrorAction SilentlyContinue) {
    Write-Warning "游戏正在运行。请先完全退出游戏再安装。"
    exit 1
}

$manifest = [ordered]@{
    installedAt = (Get-Date).ToString('o')
    gameRoot    = (Resolve-Path $GameRoot).Path
    signatures  = @()
    modExisted  = (Test-Path (Join-Path $ue 'Mods\PBZHaptics'))
    origExisted = (Test-Path (Join-Path $bin 'AkMotion_orig.dll'))
}

# ---- 1. 插件：备份原版 -> 放代理 ----
$dll  = Join-Path $bin 'AkMotion.dll'
$orig = Join-Path $bin 'AkMotion_orig.dll'
if (-not (Test-Path $orig)) {
    Copy-Item $dll $orig -Force
    Write-Host "已备份原版 AkMotion.dll -> AkMotion_orig.dll"
}
Copy-Item $dllSrc $dll -Force
Write-Host "已安装代理 -> AkMotion.dll"

# ---- 2. Lua 事件层 ----
$modDst = Join-Path $ue 'Mods\PBZHaptics'
if (Test-Path (Join-Path $modDst 'dlls')) { Remove-Item (Join-Path $modDst 'dlls') -Recurse -Force }
New-Item -ItemType Directory -Force $modDst | Out-Null
Copy-Item (Join-Path $modSrc '*') $modDst -Recurse -Force
Write-Host "已安装 Lua 事件层 -> $modDst"

# ---- 3. 特征码脚本：先备份再覆盖 ----
$sigDst = Join-Path $ue 'UE4SS_Signatures'
New-Item -ItemType Directory -Force $sigDst | Out-Null
Get-ChildItem $sigSrc -Filter '*.lua' | ForEach-Object {
    $target = Join-Path $sigDst $_.Name
    $backup = "$target.pre-pbzhaptics.bak"
    $existed = Test-Path $target
    if ($existed -and -not (Test-Path $backup)) {
        Copy-Item $target $backup -Force
        Write-Host "已备份原有 $($_.Name) -> $(Split-Path $backup -Leaf)"
    }
    Copy-Item $_.FullName $target -Force
    $manifest.signatures += [ordered]@{ name = $_.Name; existed = $existed; backup = (Split-Path $backup -Leaf) }
    Write-Host "已安装 $($_.Name)"
}

# ---- 4. 记录清单，供卸载精确还原 ----
$manifestPath = Join-Path $ue 'UE4SS_Signatures\pbzhaptics-install.json'
($manifest | ConvertTo-Json -Depth 5) | Set-Content -Path $manifestPath -Encoding utf8
Write-Host "已写入安装清单 -> $manifestPath"

Write-Host ""
Write-Host "安装完成。启动游戏；若提示“文件损坏”，选择“不修复/继续”。"
