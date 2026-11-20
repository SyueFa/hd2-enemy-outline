敵人描邊(死亡自動關閉) 1.0
==========================

單一 patch：HD2EnemyHull 0.0.22 的 396 個描邊資源（與原版逐位元相同）
＋ 1 個 Lua 資源 mods/combat/enemy_outline_off（1.0）。

前置（另外安裝）：MDL3（最高優先級）、HD2 Data Hub 0.6.6（提供敵人死亡事件）。
不要覆蓋遊戲的 generated_entities.dl_bin（HD2EnemyHull 舊的死亡判斷已移除）。

敵人死亡時，關掉死亡位置 1 公尺內那隻描邊敵人的描邊。支援 53 種單位。
不畫任何東西；進任務 3 秒後才動作。

安裝：用模組管理器匯入本包，排在 MDL3 下面，Purge + Deploy。

出處
----
描邊模型、材質、貼圖：exo6《敌人高亮》（HD2EnemyHull 0.0.22）
  https://ayakamods.com/mods/%E6%95%8C%E4%BA%BA%E9%AB%98%E4%BA%AE.5564/
  https://ayakamods.com/members/exo6.388952/
