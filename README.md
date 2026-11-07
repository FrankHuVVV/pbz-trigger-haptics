# 影之刃零 · Xbox 扳机震动（PBZ Trigger Haptics）

给《影之刃零》(Phantom Blade Zero) 的 Xbox 手柄补上**扳机震动**（impulse trigger rumble）。
游戏原生只驱动握把两马达；本模组把游戏的震动镜像到左右扳机，并用战斗事件做左右分道。

> English: adds Xbox impulse-trigger haptics to Phantom Blade Zero by proxying the Wwise
> Motion plugin and mirroring the game's grip rumble onto the triggers.

## 效果

| 场景 | 扳机 |
|---|---|
| 走路 / 挥刀 / 被打 / 处决 | 跟随握把震动（非战斗 **25%**，战斗 **100%**） |
| **弹反成功** | **仅左扳机** |
| **完美闪避** | **仅右扳机** |
| 原生握把震动 | 原样保留，不受影响 |

每把武器的震动包络由游戏自己产生，因此武器差异**自动继承**，无需逐把配置。

---

## 兼容性（实测）

- **Xbox 手柄（原生支持扳机震动）** 已测试，适配良好。
- **不支持扳机震动的 Xbox 授权手柄** 已测试，**不影响游戏原生握把震动**
  （本模组只写入扳机通道，握把值原样转发）。
- **支持扳机震动的 Xbox 手柄，在不安装本模组且禁用 Steam 输入的情况下，仍然没有扳机震动**
  —— 游戏自身不会驱动扳机马达，这正是本模组存在的意义。

> 结论：只要你的手柄本身支持扳机震动，本模组能把这块能力接上；不支持的手柄也不会被搞坏。
> **求测试**：本人没有支持扳机震动的**非 Xbox** 手柄（如 8BitDo / 飞智 / 盖世小鸡等）。
> 如果你的手柄支持扳机震动且不是 Xbox 官方手柄，欢迎试一下本模组并反馈结果 —— 感激不尽！

## 原理（三句话）

1. 用自编译的 `AkMotion.dll` 代理替换游戏自带的同名 Wwise 插件，转发原实现，音频链路不变；
2. 代理内钩住 `IGameInputDevice::SetRumbleState` 的虚表项，截获「谁写了多少震动」，
   再以 `握把 × 增益` 生成扳机值，经 GameInput 一次性写四通道；
3. UE4SS Lua 脚本钩 `SendGameplayEventToActor`，把弹反 / 完美闪避转成左右分道的短脉冲，
   经由 `trigger.bin`（16 字节）交给代理。

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 前置条件

| 需要 | 说明 |
|---|---|
| Windows 10/11 | 已在 Win11 实测 |
| **有线连接的 Xbox 手柄** | USB（GIP 通道）。蓝牙下 Windows 不暴露扳机马达，本模组无效 |
| **UE4SS 3.x** | 提供 Lua 运行时。**本仓库不含**，需自行安装（见第 0 步） |
| 游戏版本 | 已验证 2026-11-04 更新版（`PBZ.exe` 498,913,272 字节） |

> ⚠️ 只替换 DLL 是不完整的：没有 UE4SS 就只有「扳机跟随握把」，
> 弹反 / 完美闪避的左右分道由 Lua 实现，缺失时这两项不工作。

---

# 手动安装（共 5 步）

> 全程只需文件复制与改名，**不需要运行任何脚本**。
> 下面用 `<游戏>` 表示游戏根目录，例如 `D:\SteamLibrary\steamapps\common\PBZ`。

## 第 0 步：安装 UE4SS（前置）

1. 从我的另一个仓库(https://github.com/FrankHuVVV/PBZWallSense)中下载 **UE4SS-v3.0.1-bundle-v2.zip**；
2. 解压到 `<游戏>\platform\steam\`，最终应存在：

   ```
   <游戏>\platform\steam\dwmapi.dll          ← UE4SS 注入代理
   <游戏>\platform\steam\ue4ss\UE4SS.dll
   <游戏>\platform\steam\ue4ss\Mods\
   <游戏>\platform\steam\ue4ss\UE4SS_Signatures\
   ```

3. 启动游戏一次后退出，确认 `<游戏>\platform\steam\ue4ss\UE4SS.log` 有内容
   （出现 `Build configuration: shipping`、`PS scan successful` 等行即为注入成功）。

若日志为空或游戏闪退，先解决 UE4SS 本身，不要继续往下装。

## 第 1 步：替换 AkMotion.dll

进入：

```
<游戏>\ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin\
```

1. 找到 `AkMotion.dll`（游戏原版，约 186 KB），**改名为 `AkMotion_orig.dll`**
   —— 这是备份，代理需要加载它，**不要删除**；
2. 把本仓库 `release\AkMotion.dll`（约 57 KB）复制到该目录，文件名保持 `AkMotion.dll`。

完成后目录内应同时存在：

```
AkMotion.dll        ← 本模组代理（57 KB）
AkMotion_orig.dll   ← 游戏原版（186 KB，被改名）
```

## 第 2 步：安装 Lua 事件层

把本仓库 `mod\PBZHaptics\` 整个目录复制到：

```
<游戏>\platform\steam\ue4ss\Mods\PBZHaptics\
```

最终结构：

```
Mods\PBZHaptics\enabled.txt
Mods\PBZHaptics\Scripts\main.lua
```

要点：

- `enabled.txt` 必须是空文件（内容无所谓，但文件必须存在）；
- **不要**在 `PBZHaptics\` 下创建 `dlls\` 目录 —— UE4SS 会把它误判成 C++ mod，
  日志里出现 `Failed to load C++ mod PBZHaptics, dlls folder must contain…`。
  本模组是纯 Lua，不需要任何 DLL。

## 第 3 步：替换 UE4SS 特征码脚本

把本仓库 `mod\UE4SS_Signatures\` 下的两个文件复制到：

```
<游戏>\platform\steam\ue4ss\UE4SS_Signatures\
```

即覆盖 `GNatives.lua` 与 `GUObjectArray.lua`。

- 这两个文件在上游分发版中是**按具体游戏 build 写死 RVA / 镜像大小 / SHA-256** 的，
  游戏一更新就会 `AOB scans could not be completed` 并闪退；
- 本仓库提供的是**版本无关**重写版：运行时以 64 KB 步长向下扫描 PE 头自动求模块基址，
  只做结构性校验。**建议先把原文件备份**（例如改名加后缀 `.orig`）。

## 第 4 步：启动游戏

若弹出「文件损坏」提示，选择 **不修复 / 继续** ——
这是完整性校验发现插件被替换，属预期现象，不影响游玩。

## 第 5 步：验证

| 检查点 | 期望结果 |
|---|---|
| `<游戏>\platform\steam\ue4ss\UE4SS.log` | 出现 `[PBZ auto] GNatives resolved` 与 `[PBZ auto] GUObjectArray resolved` |
| 事件日志（`main.lua` 顶部 `LOG` 常量指向的文件） | 出现 `BOOT haptics v9 loaded`，并持续写入 `TAG` 行 |
| 代理日志（`akmotion_proxy.c` 中 `log_line()` 的路径） | 出现 `SetRumbleState vtable hooked`、`gameinput: rumble=ok` |
| 实机 | 走路有轻微扳机震动；弹反只震左扳机；完美闪避只震右扳机；握把震动照旧 |

---

# 手动卸载（共 4 步）

> 目标是恢复到**安装前的状态**，包括原生震动。
> **请先完全退出游戏**：插件文件被占用时无法改名/删除。

## 第 1 步：确认游戏已退出

任务管理器确认没有 `PBZ.exe` 残留进程。

## 第 2 步：还原 AkMotion.dll

进入：

```
<游戏>\ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin\
```

1. **删除** `AkMotion.dll`（此时它应是本模组代理，约 57 KB）；
2. 把 `AkMotion_orig.dll` **改回** `AkMotion.dll`。

完成后该目录只剩游戏原版 `AkMotion.dll`（约 186 KB）。

## 第 3 步：删除 Lua 事件层

删除整个目录：

```
<游戏>\platform\steam\ue4ss\Mods\PBZHaptics\
```

## 第 4 步：还原特征码脚本（可选但建议）

若你在第 3 步安装时备份了原文件，把 `GNatives.lua`、`GUObjectArray.lua` 恢复回去；
若没有备份，删除这两个文件也行 —— UE4SS 会在下次启动时重新生成/使用其内置默认逻辑。

## 关于「卸载后手柄还在震」

- 手柄保持的是**最后一次写入**的状态，删除文件本身不会让它停下，这是正常物理行为；
- 正确顺序是**先完全退出游戏，再做第 2 步**；游戏进程退出后马达通常会自停；
- 若扳机仍在空转：**拔掉 USB 线 5 秒后重插**，或长按 Xbox 键关机再开机，
  这是最快、最可靠的硬件复位方式；
- 卸载不会关闭或削弱游戏原生震动：还原 `AkMotion.dll` 后，游戏自己驱动握把震动，无任何持久改动。

---

# 调参

- **非战斗强度**：`mod\PBZHaptics\Scripts\main.lua` 顶部 `OUT_GAIN = 0.25`。
- **弹反 / 闪避的时长与强度**：同一文件的 `PROFILES` 表。
- 改完**重进一次游戏**生效（Lua 只在启动时加载）。
- 代理侧增益平滑与镜像保持时长在 `src\AkMotionProxy\akmotion_proxy.c`
  （`g_gainCur` 的步进、250 ms 保持窗口）。

# 排错

| 现象 | 检查顺序 |
|---|---|
| 完全没有震动 | ① 手柄是否为**有线**；② 代理日志是否有 `gameinput: rumble=ok`；③ `AkMotion_orig.dll` 是否在位 |
| 握把正常、扳机没有 | 代理日志中 `ext#…` 的数值：非零=钩子有效（查 `trigger.bin` / Lua）；恒为 0=游戏改了震动写入方式 |
| 游戏启动闪退 | `UE4SS.log` 是否 `AOB scans could not be completed` → 用本仓库的两个特征码脚本覆盖 |
| 弹反 / 闪避没有左右分道 | 事件日志是否增长；`Mods\PBZHaptics\enabled.txt` 是否存在；是否有空 `dlls\` 目录 |
| 装了之后没有声音 | `AkMotion_orig.dll` 是否缺失（第 1 步是改名，不是删除） |
| 提示文件损坏 | 正常，选「不修复」 |

更多见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

# 游戏更新后怎么办

1. 跑 `tools/scan_signature.ps1`（只读工具）检查两段特征码是否仍能命中；
2. 命中则特征码脚本通常无需改动（已自动推导基址）；
3. 若震动消失，看代理日志 `ext#` 是否恒为 0 —— 那意味着游戏的震动写入方式又变了。

清单见 [docs/GAME-UPDATE-CHECKLIST.md](docs/GAME-UPDATE-CHECKLIST.md)。

# 免责与范围

- 仓库**不包含任何游戏文件**；`release\AkMotion.dll` 为自编译产物，原版插件由用户自行备份。
- 仅用于**单人本地表现**，不修改存档、不触碰联机数据。
- 替换插件会触发游戏完整性提示；安装前请务必备份原文件。

# License

MIT，见 [LICENSE](LICENSE)。
