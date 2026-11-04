# 影之刃零 · Xbox 扳机震动（PBZ Trigger Haptics）

给《影之刃零》(Phantom Blade Zero) 的 Xbox 手柄补上**扳机震动**（impulse trigger rumble）。
游戏原生只驱动握把两马达，这套 mod 把震动镜像到左右扳机，并用战斗事件做左右分道。

> English: adds Xbox impulse-trigger haptics to Phantom Blade Zero by proxying the Wwise
> Motion plugin and mirroring the game's grip rumble onto the triggers.

## 效果

| 场景 | 扳机 |
|---|---|
| 走路 / 挥刀 / 被打 / 处决 | 跟随握把震动（非战斗 **25%**，战斗 **100%**） |
| **弹反成功** | **仅左扳机** |
| **完美闪避** | **仅右扳机** |
| 原生握把震动 | 原样保留，不受影响 |

每把武器的震动包络由游戏自己产生，所以武器差异**自动继承**，不需要逐把配置。

## 原理（三句话）

1. 用自编译的 `AkMotion.dll` 代理替换游戏自带的同名 Wwise 插件，转发原实现、不影响声音；
2. 代理里钩住 `IGameInputDevice::SetRumbleState` 虚表项，截获「谁写了多少震动」，
   再以 `握把 × 增益` 生成扳机值经 GameInput 写回四通道；
3. UE4SS Lua 脚本钩 `SendGameplayEventToActor`，把弹反 / 完美闪避转成左右分道的短脉冲，
   并通过 `trigger.bin`（16 字节）传给代理。

详细设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

# 安装

## 0. 你需要准备什么

| # | 项目 | 来源 | 说明 |
|---|---|---|---|
| 1 | Windows 10/11 | — | 已在 Win11 实测 |
| 2 | **有线 Xbox 手柄** | — | USB 连接（GIP 通道）。蓝牙下 Windows 不暴露扳机马达，本方案无效 |
| 3 | **UE4SS 3.x** | 上游 GitHub release | 提供 Lua 运行时，**本仓库不包含**，必须自行安装 |
| 4 | 游戏 | Steam | 已验证 2026-11-04 更新版（`PBZ.exe` 498,913,272 字节） |

> ⚠️ **只装 DLL 是不够的**：没有 UE4SS，就只会有"扳机跟随握把"，
> 弹反/闪避的左右分道完全没有（那部分由 Lua 实现）。

## 1. 安装 UE4SS（硬前提）

1. 下载 **UE4SS 3.0.1**（或兼容的新 3.x）release 包；
2. 解压到 `<游戏>\platform\steam\`，最终应当是：

   ```
   <游戏>\platform\steam\dwmapi.dll        ← UE4SS 的注入代理
   <游戏>\platform\steam\ue4ss\UE4SS.dll
   <游戏>\platform\steam\ue4ss\Mods\
   ```

3. 启动一次游戏（可以马上退），确认 `<游戏>\platform\steam\ue4ss\UE4SS.log` 有内容且不是空白。

**验证**：`UE4SS.log` 末尾出现 `PS scan successful` / `Build configuration: shipping` 等行，
说明注入成功。若日志为空或游戏闪退，先解决 UE4SS 本身，别继续往下装。

> **关于签名脚本**：`ue4ss\UE4SS_Signatures\GNatives.lua` 与 `GUObjectArray.lua`
> 在本游戏的分发版里是**随 UE4SS 一起提供**的（内容针对具体 build 写死了 RVA / 镜像大小 / SHA-256）。
> 本仓库提供的这两个文件是**版本无关**的重写版：自动推导模块基址，游戏更新后通常无需再改。
> 用上游标准 UE4SS 3.x 时，把这两个文件放进去覆盖即可（机制是标准的 `UE4SS_Signatures`）。

## 2. 安装事件层（Lua）

```
mod\PBZHaptics\            →  <游戏>\platform\steam\ue4ss\Mods\PBZHaptics\
mod\UE4SS_Signatures\*.lua →  <游戏>\platform\steam\ue4ss\UE4SS_Signatures\
```

- `PBZHaptics\` 里必须有 `enabled.txt`（空文件也算）与 `Scripts\main.lua`；
- **不要**在 `PBZHaptics\` 下建 `dlls\` 目录——UE4SS 会把它当成 C++ mod，
  日志里出现 `Failed to load C++ mod PBZHaptics, dlls folder must contain…`（本仓库的 mod 纯 Lua，不需要 DLL）；
- 两个签名脚本是**版本无关**版，解决游戏更新后 `AOB scans could not be completed` 的闪退。

## 3. 安装代理（DLL）

```
<...>\ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin\
    AkMotion.dll      →  改名为 AkMotion_orig.dll      （备份原版，代理会加载它）
    release\AkMotion.dll → 复制到这里
```

**这一步不能漏**：代理需要 `AkMotion_orig.dll` 才能把 Wwise 插件链接上，
改名漏了会导致没有声音 / 插件链断开。

## 4. 启动

游戏若提示「文件损坏」，选择**不修复 / 继续**——这是完整性校验发现插件被替换，属预期。

## 5. 验证装好了没

| 检查点 | 期望 |
|---|---|
| `<游戏>\platform\steam\ue4ss\UE4SS.log` | 出现 `[PBZ auto] GNatives resolved` 与 `GUObjectArray resolved` |
| 事件日志（`main.lua` 顶部 `LOG` 路径） | 出现 `BOOT haptics v9 loaded` 并持续增长 |
| 代理日志（`akmotion_proxy.c` 的 `log_line()` 路径） | `SetRumbleState vtable hooked`、`gameinput: rumble=ok` |
| 实机 | 走路有扳机微震；弹反只震左扳机；完美闪避只震右扳机 |

## 一键脚本

`scripts/install.ps1 -GameRoot "<游戏路径>"` 会自动完成第 2、3 步（含备份）。
卸载用 `scripts/uninstall.ps1 -GameRoot "<游戏路径>"`。

---

# 卸载

```
删掉 <...>\bin\AkMotion.dll
把 AkMotion_orig.dll 改名回 AkMotion.dll
删掉 <游戏>\platform\steam\ue4ss\Mods\PBZHaptics\
```

签名脚本可以留着（对其它 mod 无害），想彻底干净就一并删除 `ue4ss\UE4SS_Signatures\*.lua`。

# 调参

- **非战斗强度**：`main.lua` 顶部 `OUT_GAIN = 0.25`。
- **弹反 / 闪避的时长与强度**：`main.lua` 里的 `PROFILES` 表。
- 改完**重进一次游戏**即可生效（Lua 只在启动时加载）。
- 代理侧增益平滑与镜像保持时长在 `akmotion_proxy.c`（`g_gainCur` 步进、250 ms 保持）。

# 排错

| 现象 | 检查 |
|---|---|
| 完全没有震动 | 手柄是否为**有线**；代理日志是否有 `gameinput: rumble=ok` |
| 握把正常、扳机无 | 日志里 `ext#…` 数值是否为 0：非零=钩子有效（查 `trigger.bin`/Lua）；恒为 0=游戏改了写入方式 |
| 游戏启动闪退 | UE4SS 特征码不匹配，见 [docs/GAME-UPDATE-CHECKLIST.md](docs/GAME-UPDATE-CHECKLIST.md) |
| 弹反没有左右分道 | 事件日志是否增长；`UE4SS_Signatures\*.lua` 是否已替换 |
| 装了没声音 | `AkMotion_orig.dll` 是否缺失（第 3 步） |

更多见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

# 游戏更新后怎么办

1. 跑 `tools/scan_signature.ps1` 检查两段特征码是否仍能命中；
2. 若命中，签名脚本通常无需改动（已自动推导模块基址）；
3. 若震动消失，看代理日志 `ext#` 是否恒为 0 —— 那意味着游戏的震动写入方式又变了。

清单见 [docs/GAME-UPDATE-CHECKLIST.md](docs/GAME-UPDATE-CHECKLIST.md)。

# 免责与范围

- 仓库**不包含任何游戏文件**；`AkMotion.dll` 代理为自编译产物，原版插件由用户自行备份。
- 仅用于**单人本地表现**，不修改存档、不触碰联机数据。
- 替换插件会触发游戏完整性提示；请自行评估风险，安装前务必备份。

# License

MIT，见 [LICENSE](LICENSE)。
