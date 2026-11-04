# 架构

## 数据流

```
PBZ.exe
 ├─ AkMotion.dll（本仓库代理，替换游戏自带插件）
 │    ├─ 加载 AkMotion_orig.dll，把 g_pAKPluginList 的值复制给自己的同名导出 → Wwise 插件链完好
 │    ├─ 钩 IGameInputDevice::SetRumbleState（虚表 slot 10）
 │    │     └─ 记录任何调用者写入的 low/high（Wwise Motion 插件就是走这条路）
 │    ├─ 轮询：钩 XInput1_4 / XInput9_1_0 的 XInputSetState（旧版游戏的震动入口）
 │    └─ 8 ms 泵线程：扳机 = 握把 × 增益，仅在有事可写时调用 GameInput
 │
 └─ UE4SS（Lua 运行时）
      └─ mods/PBZHaptics/Scripts/main.lua
           ├─ 钩 SendGameplayEventToActor → 解析 FGameplayTag
           ├─ 弹反 → LT 脉冲；完美闪避 → RT 脉冲；处决/命中 → 双通道
           ├─ InCombat / OffCombat → 战斗标志
           └─ LoopAsync(10 ms) → 写 trigger.bin
```

进程外没有任何常驻程序：代理由游戏（Wwise）加载，Lua 由 UE4SS 加载。

## 为什么这么绕

| 尝试 | 结果 |
|---|---|
| 把 `xinput1_4.dll` 放游戏目录做代理 | 无效 —— 游戏用受限搜索/全路径加载 System32 那份 |
| 进程外写 GameInput | 无效 —— 游戏每帧写 XInput 会把扳机清零 |
| UE4SS 里放 C++ mod DLL | 必须导出 `start_mod`/`uninstall_mod`，否则 UE4SS 启动即崩 |
| 共享内存传值 | 游戏进程内读不到，改用文件通道 `trigger.bin` |
| 只钩 `XInputSetState` | 新版本游戏把强震动移到 Wwise Motion 插件（走 GameInput），XInput 只剩 0.0x |
| **钩 GameInput 虚表 slot 10** | **有效** —— 能拿到插件写入的真实握把值，用于镜像 |

## trigger.bin 协议（16 字节，小端 float）

| 偏移 | 含义 |
|---|---|
| 0–3 | `lt` 事件脉冲（0..1） |
| 4–7 | `rt` 事件脉冲（0..1） |
| 8–11 | `combat` 标志（1 = 战斗中） |
| 12–15 | 非战斗增益（默认 0.25） |

规则：事件脉冲存在时**独占**扳机（另一侧归零）；否则扳机 = 截获的握把值 × 增益。
增益按 300 ms 平滑过渡，避免进出战斗时突变。

## 关键约束

- **必须有线（GIP）**：蓝牙下 Windows 不暴露扳机马达（GameInput 枚举不到设备，WGI 写入是空实现）。
- **不能持续写**：游戏自己的震动来自插件，任何空闲时的写入都会把它的值清掉（这是 2026-11-04 更新后"全灭"的原因）。
- **只保留一个写入方**：不要同时启用 UE4SS 的 C++ mod DLL 与本代理，二者会互相覆盖。
