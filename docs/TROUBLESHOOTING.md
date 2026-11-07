# 排错

## 完全没有震动（握把也没有）

1. 手柄是否**有线**？蓝牙下扳机无法驱动，且本方案依赖 GIP 设备。
2. 代理日志里是否有 `gameinput: rumble=ok dev=0x...`？若为 `null`：
   手柄未连接，或连接后未重试（代理每秒重试一次，插上线等几秒即可）。
3. `AkMotion_orig.dll` 是否在插件目录？代理启动时加载它，缺失会导致 Wwise 插件链断开。

## 握把正常、扳机没有

1. 日志里 `ext#…` 是否有非零值。
   - 有：检查 `trigger.bin` 是否在更新（Lua 每 10 ms 写一次）；
   - 无：游戏的震动写入方式又变了。
2. `main.lua` 里的 `OUT_GAIN`（非战斗）是否被改成 0。
3. 是否把 UE4SS 的 `dlls\main.dll` 与本代理同时启用（会互相覆盖）。

## 弹反 / 闪避没有左右分道

1. `events.log` 是否在增长；不增长说明 UE4SS 挂了（见 `GAME-UPDATE-CHECKLIST.md`）。
2. 对应标签是否出现：`GameplayEvent.Ability.Action.Deflect.Attacker.*`、
   `GameplayEvent.Ability.Action.PerfectDodge.Attacker`。
3. `main.lua` 的 `classify()` 是否覆盖当前版本的标签命名。

## 游戏启动闪退

- UE4SS 特征码不匹配 → 用仓库里的 `UE4SS_Signatures\*.lua` 覆盖。
- 若刚升级过游戏，先按清单跑一遍。

## "文件损坏"提示

- 属于替换插件的正常代价，选**不修复 / 继续**即可。
- 想彻底避免：只在需要时手动替换 `AkMotion.dll`（保留 `AkMotion_orig.dll` 备份），不玩时按 README 的手动卸载步骤还原。

## 抓日志

代理日志路径写死在源码里（默认 `D:\PBZ_Xbox\router\akmotion\log.txt`），
改 `log_line()` 的路径后重新编译即可。事件层日志在 `main.lua` 顶部 `LOG` 常量。
