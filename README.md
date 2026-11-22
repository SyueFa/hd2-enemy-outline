# hd2-enemy-outline

Helldivers 2 模組「**敵人描邊(死亡自動關閉)**」的原始碼。版本：**1.5**

敵人身上有淺藍綠色的描邊（來自 exo6 的「敌人高亮」／HD2EnemyHull），敵人死亡時本模組會把那一隻的描邊關掉。

## 依賴

| 項目 | 版本 | 用途 |
|---|---|---|
| MDL3 | 3.0.0-dev.57 | Lua 模組載入器 |
| HD2 Data Hub | 0.6.6 | 提供 `entity_spawned`、`entity_died`、`entity_damaged`、`mission()`（不能修改） |
| HD2EnemyHull（敌人高亮，exo6） | 0.0.22 | 描邊模型與材質，打包時合併進同一個 patch；原檔在 `original/` |

## 目錄

```
src/enemy_outline_off.lua   模組本體
tools/merge_lua.py          把 Lua 資源加進 HD2EnemyHull 的 patch
tools/unpack_patch.py       把 patch 拆成一個資源一個檔
tools/pack_patch.py         從拆開的資源還原 patch（與原作逐位元組相同）
tools/murmur.py             MurmurHash64A（資源名稱雜湊）
original/HD2EnemyHull-0.0.22/  原作 exo6《敌人高亮》發布包的全部內容（patch 已拆開）
package/                    manifest.json 與玩家用 README.txt
```

## 開發方式

本專案大幅度使用 Claude 協助開發。

## 免責聲明

使用與否由個人決定，任何風險自行承擔，作者均不承擔任何責任。

## 出處與授權

- 原作者：**exo6** — https://ayakamods.com/members/exo6.388952/
- 原作：《敌人高亮》（HD2EnemyHull 0.0.22）— https://ayakamods.com/mods/%E6%95%8C%E4%BA%BA%E9%AB%98%E4%BA%AE.5564/
- 原作相關內容（`original/` 內的模型、材質、貼圖與設定，以及打包進模組的描邊資源）所有權歸原作者所有，不在本專案授權範圍內。
- 本專案的程式碼（`src/`、`tools/`、`package/`）：[MIT](LICENSE) © 2026 SyueFa。
