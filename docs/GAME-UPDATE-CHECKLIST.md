# 游戏更新后的检查清单

《影之刃零》每次更新都可能打破两处：**UE4SS 特征码**与**震动写入路径**。按顺序做。

## 1. UE4SS 能否启动

看 `<游戏>\platform\steam\ue4ss\UE4SS.log`：

```
[PBZ auto] GNatives resolved: 0x...      ← 正常
[PBZ auto] GUObjectArray resolved: 0x... ← 正常
```

若出现 `AOB scans could not be completed`：

1. 用 `tools/scan_signature.ps1` 扫新版 exe，看两段特征码是否仍命中：

   ```powershell
   .\tools\scan_signature.ps1 `
     -Exe "D:\SteamLibrary\steamapps\common\PBZ\platform\steam\PBZ.exe" `
     -LuaFiles "<...>\GNatives.lua,<...>\GUObjectArray.lua"
   ```

2. **仍命中** → 只需确认 `mod\UE4SS_Signatures\*.lua` 是仓库里的版本（已自动推导模块基址，
   不再写死 RVA / 镜像大小 / SHA-256）。
3. **不命中** → 需要重新定位函数并更新 `Pattern` 字符串（对照旧版反汇编找同样功能的新序列）。

## 2. 扳机震动是否还在

看代理日志（源码里默认写 `D:\PBZ_Xbox\router\akmotion\log.txt`，可按需改路径）：

```
SetRumbleState vtable hooked      ← 钩子装上
ext#1 lo=0.65 hi=0.40 …           ← 截获到游戏的握把值
pump#… lt=0.16 rt=0.16 ext=0.65/0.40   ← 扳机镜像输出
```

| 现象 | 判断 | 处理 |
|---|---|---|
| `ext#` 有值 | 链路正常 | — |
| `ext#` 恒为 0 | 游戏的震动改走别的通道 | 重新找写入入口 |
| 没有 `ext#` | 插件没在用 GameInput 写 | 同上 |
| 有 `pump#` 但握把反而不震 | 我们的写入覆盖了游戏 | 确认"空闲不写"逻辑还在 |

## 3. 事件层是否还在

- `events.log` 是否增长；
- 弹反 / 闪避是否仍产生 `Deflect.*` / `PerfectDodge.*` 标签；
- 若 tag 名称变了，改 `main.lua` 里的 `classify()`。

## 4. 记录

更新后请把：exe 大小、特征码是否命中、`ext#` 是否非零，记到 issue 里，方便对比。
