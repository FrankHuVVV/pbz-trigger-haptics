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

## 前置条件

- **有线连接的 Xbox 手柄**（USB，GIP 通道）。蓝牙下 Windows 不暴露扳机马达，本方案无效。
- **UE4SS 3.x** 已安装到游戏的 `platform\steam\`（提供 Lua 运行时）。
- 已测试版本：2026-11-04 更新后的 `PBZ.exe`（498,913,272 字节）。

## 安装

1. **备份原插件**（关键，回滚全靠它）

   ```
   <游戏>\ProjectPBZ\Plugins\WwiseSoundEngine\ThirdParty\x64_vc170\Release\bin\
       AkMotion.dll            →  改名为 AkMotion_orig.dll
   ```

2. 把本仓库 `release\AkMotion.dll` 放到同一目录（代理会去加载 `AkMotion_orig.dll`）。

3. 把 `mod\PBZHaptics\`（含 `enabled.txt` 与 `Scripts\main.lua`）复制到
   `<游戏>\platform\steam\ue4ss\Mods\PBZHaptics\`。

4. 把 `mod\UE4SS_Signatures\*.lua` 覆盖到 `<游戏>\platform\steam\ue4ss\UE4SS_Signatures\`
   （这两个是**版本无关**的 UE4SS 特征码脚本，解决游戏更新后 `AOB scans failed` 崩溃）。

5. 启动游戏。若弹出「文件损坏」，选择**不修复 / 继续**——这是完整性校验发现插件被替换，属预期。

也可以直接用 `scripts/install.ps1`（自动备份 + 复制，需先改脚本里的游戏路径）。

## 卸载

```
删掉 <...>\bin\AkMotion.dll
把 AkMotion_orig.dll 改名回 AkMotion.dll
删掉 <...>\ue4ss\Mods\PBZHaptics\
```

或用 `scripts/uninstall.ps1`。

## 调参

- **非战斗强度**：`main.lua` 顶部 `OUT_GAIN = 0.25`。
- **弹反 / 闪避的时长与强度**：`main.lua` 里的 `PROFILES` 表。
- 改完不用重开电脑，**重进一次游戏**即可生效（Lua 只在启动时加载）。
- 代理侧增益平滑、镜像保持时长在 `akmotion_proxy.c` 里（`g_gainCur` 步进、250 ms 保持）。

## 排错

| 现象 | 检查 |
|---|---|
| 完全没有震动 | 手柄是否为**有线**；`akmotion_proxy.c` 生成的日志里是否有 `gameinput: rumble=ok` |
| 握把正常、扳机无 | 日志里 `ext#…` 的数值是否为 0。非零=钩子有效（查 `trigger.bin`/Lua）；恒为 0=插件换了写入方式 |
| 游戏启动闪退 | UE4SS 特征码不匹配，见 [docs/GAME-UPDATE-CHECKLIST.md](docs/GAME-UPDATE-CHECKLIST.md) |
| 事件层失效（无弹反分道） | `events.log` 是否还在增长；UE4SS.log 是否报 `AOB scans could not be completed` |

## 游戏更新后怎么办

1. 跑 `tools/scan_signature.ps1` 检查两段特征码是否仍能命中；
2. 若命中，`mod\UE4SS_Signatures\*.lua` 通常无需改动（已自动推导模块基址）；
3. 若震动消失，看代理日志里 `ext#` 是否恒为 0 —— 那意味着游戏的震动写入方式又变了。

## 免责与范围

- 仓库**不包含任何游戏文件**；`AkMotion.dll` 代理为自编译产物，原版插件由用户自行备份。
- 仅用于**单人本地表现**，不修改存档、不触碰联机数据。
- 替换插件会触发游戏完整性提示；请自行评估风险，使用前务必备份。

## License

MIT，见 [LICENSE](LICENSE)。
