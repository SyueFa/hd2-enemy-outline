-- HD2-Addon: mods/combat/enemy_outline_off
-- 敵人描邊(死亡自動關閉) 1.4
-- 1.4: birth binding.
--  * Every entity_spawned event (Hub entity id, type, spawn position) is bound to the Lua unit
--    of that type that appeared at that spot at that moment; a death with a bound id hides
--    exactly that unit. Hit votes can overrule a binding; unbound deaths use the 1.3 matching.
--  * Entity types that are not a model resource (scavenger_tier_1, conscript_flamer,
--    cyborg_tank_heavycannon, ...) are mapped to the outlined models in the same folder
--    (68 types, from the Data Hub catalog + community hash lists).
--  * Deaths the Hub never reports (health record gone, no corpse found): the unit is hidden when
--    its Hub Entity has been invalid for 2 s and the unit is still listed and alive.
--  * hide() checks Unit.alive first: touching a unit that is being destroyed crashed the game.
--  * A short summary per mission goes to the MDL log (deaths by binding/vote/position, spawns,
--    hits, game kill counter vs Hub deaths).
-- Hides the HD2EnemyHull outline of an enemy when it dies.
-- Needs MDL3 + stock HD2 Data Hub 0.6.6 + HD2EnemyHull outline models (same package).
--
-- How the dead unit is found (1.3):
--  1. Position history: every outlined unit's position is sampled each frame (last ~1 s).
--     The Hub reports where the enemy was at the moment it died (in the Hub's own clock);
--     the delivery lag is measured (mission().now - event.time) and each candidate is
--     compared at that moment, not where it is now. Fast movers and ragdolls no longer
--     pull the match onto a neighbour.
--  2. Damage tracking: every hit (entity_damaged) votes for the unit that was at the hit
--     position at the time of the hit, but only when that unit is clearly the closest.
--     On death, the unit with the most votes for that entity wins.
--  3. Only units of the dead entity's own type are considered (type = unit resource hash).
--     Untyped deaths fall back to any outlined body within 1 m.
--  Attachments (weapons, backpacks, turrets, tongues, tentacles) follow their body.

local OWNER = 'mods/combat/enemy_outline_off'
local VERSION = '1.4'
local sr = rawget(_G, 'stingray')
if type(sr) ~= 'table' then return {version=VERSION, error='no stingray'} end

local SETTLE = 3          -- seconds after the mission starts before touching units
local TYPED_R = 2.0       -- typed death: max distance at the moment of death (m)
local LONE_R = 4.0        -- ... or within 4 m when it is the only one around
local LONE_MARGIN = 3.0   -- (next of that type at least 3 m further)
local VOTE_R = 3.0        -- voted unit must be within this at the moment of death (m)
local ANY_R = 1.0         -- untyped death: any outlined body within 1 m
local HIT_R = 1.0         -- a hit votes only if the closest unit is within 1 m ...
local HIT_MARGIN = 0.5    -- ... and the second closest is at least 0.5 m further
local HIT_GAP = 0.2       -- one vote per entity per 0.2 s
local WINDOW = 0.15       -- history samples within +-0.15 s of the event time
local HISTORY = 1.2       -- seconds of position history kept
local MAX_LAG = 1.0
local SPAWN_R = 2.0        -- spawn binding: unit within 2 m of the spawn position ...
local SPAWN_MARGIN = 0.5   -- ... and the next new unit of that type at least 0.5 m further
local SPAWN_WAIT = 2.0     -- seconds a spawn waits for its unit to appear
local BORN_SLACK = 1.0     -- a unit counts as new if first seen at most 1 s before the spawn
local BIND_R = 6.0         -- a bound unit must be within 6 m of the death position
local EARLY_R = 4.0        -- early spawns (before/during settle): unit within 4 m ...
local EARLY_MARGIN = 1.5   -- ... and the next unbound unit of that type 1.5 m further
local OVERRULE = 3         -- hit votes overrule a binding when ahead by this many
local RETRY = 1.5         -- seconds an unmatched death is retried
local REFRESH = 1         -- seconds between unit list refreshes / attachment pass

-- resource -> m = mesh count, o = outline mesh indices (1-based), t = entity type hash,
-- g = link groups (bodies), p = parent group + r = link radius in m (attachments)
local OUTLINE_UNITS={
    ['content/env_illuminate/gameplay/il_turret_01']={m=20,o={17,18,19,20},t='0883366204E1CCC5',g={}},
    ['content/env_illuminate/gameplay/il_turret_tactical_obj']={m=20,o={17,18,19,20},t='1448D494665D01A0',g={}},
    ['content/fac_bugs/cha_boomer/cha_boomer']={m=11,o={10,11},t='36AA99CCE5E60146',g={}},
    ['content/fac_bugs/cha_boomer/cha_boomer_tier_2']={m=31,o={30,31},t='CCAE5264ACD591B7',g={}},
    ['content/fac_bugs/cha_boomer_burrower/cha_boomer_burrower']={m=31,o={30,31},t='A381A11C07D3EB94',g={}},
    ['content/fac_bugs/cha_boomer_defiler/cha_boomer_defiler']={m=11,o={10,11},t='662A7907531B45E5',g={}},
    ['content/fac_bugs/cha_boomer_nurser/cha_boomer_nurser']={m=31,o={30,31},t='CC7022FDD172089B',g={}},
    ['content/fac_bugs/cha_charger/cha_charger']={m=12,o={10,11,12},t='1A7FCDFF98C664B0',g={}},
    ['content/fac_bugs/cha_charger_acid/cha_charger_acid']={m=11,o={10,11},t='6B202392F4AB605E',g={}},
    ['content/fac_bugs/cha_charger_bull/cha_charger_bull']={m=11,o={10,11},t='3AFF5FD7D5450B99',g={}},
    ['content/fac_bugs/cha_charger_burrower/cha_charger_burrower']={m=11,o={10,11},t='0AB7B92B131C228C',g={}},
    ['content/fac_bugs/cha_dragon/cha_dragon']={m=12,o={11,12},t='960B48A421A3FAAA',g={}},
    ['content/fac_bugs/cha_hive_lord/cha_hive_lord']={m=52,o={43,44,45,46,47,48,49,50,51,52},t='D465D9C7F77A07CB',g={}},
    ['content/fac_bugs/cha_hunter/cha_hunter']={m=34,o={33,34},t='A478D36A62A861F4',g={'hunter'}},
    ['content/fac_bugs/cha_hunter/cha_hunter_gloom_tier1']={m=34,o={33,34},t='C28B3482E73D1EA9',g={'hunter'}},
    ['content/fac_bugs/cha_hunter/cha_hunter_tier3']={m=11,o={10,11},t='D7E2C78B1EF4A8E1',g={'hunter'}},
    ['content/fac_bugs/cha_hunter/cha_hunter_tongue']={m=2,o={2},t='E6F4C24C54537229',p='hunter',r=8},
    ['content/fac_bugs/cha_impaler/cha_impaler']={m=11,o={10,11},t='DCF8E74212FBEE3B',g={'impaler'}},
    ['content/fac_bugs/cha_impaler/cha_impaler_tentacle']={m=12,o={11,12},t='672F7DA17F3BA34A',p='impaler',r=40},
    ['content/fac_bugs/cha_scavenger/cha_scavenger']={m=33,o={32,33},t='C14E0E887E7D2106',g={}},
    ['content/fac_bugs/cha_scavenger/cha_scavenger_captive']={m=33,o={32,33},t='5B968CD78F8BC7A0',g={}},
    ['content/fac_bugs/cha_scavenger/cha_scavenger_gloom']={m=35,o={33,34,35},t='DB964631BE1CF501',g={}},
    ['content/fac_bugs/cha_scavenger_defiler/cha_scavenger_defiler']={m=33,o={32,33},t='8AB62629DB3D6AC8',g={}},
    ['content/fac_bugs/cha_scavenger_predator/cha_scavenger_predator']={m=33,o={32,33},t='AAB438596F5E8FD9',g={}},
    ['content/fac_bugs/cha_scavenger_spitter/cha_scavenger_spitter']={m=33,o={32,33},t='72A83E49CED6DB3D',g={}},
    ['content/fac_bugs/cha_shrieker/cha_shrieker']={m=16,o={14,15,16},t='64090088502435DD',g={}},
    ['content/fac_bugs/cha_stalker/cha_stalker']={m=36,o={35,36},t='F540CA9D9D4A422E',g={'stalker'}},
    ['content/fac_bugs/cha_stalker/stalker_tongue']={m=2,o={2},t='4ABDEE603735E373',p='stalker',r=8},
    ['content/fac_bugs/cha_strider/cha_strider']={m=31,o={31},t='9E2E17F2CCCCAFDD',g={}},
    ['content/fac_bugs/cha_strider/cha_strider_gloom']={m=32,o={31,32},t='EF04CB84D097A497',g={}},
    ['content/fac_bugs/cha_warrior/cha_warrior']={m=29,o={28,29},t='09872E66D1276E1F',g={}},
    ['content/fac_bugs/cha_warrior/cha_warrior_gloom_tier_1']={m=11,o={10,11},t='1BAEEF36A88AE579',g={}},
    ['content/fac_bugs/cha_warrior/cha_warrior_tier_1']={m=29,o={28,29},t='BE39E313A1E46BB9',g={}},
    ['content/fac_bugs/cha_warrior_acid/cha_warrior_acid']={m=29,o={28,29},t='10081ACEF6163EF6',g={}},
    ['content/fac_bugs/cha_warrior_big/cha_warrior_big']={m=29,o={28,29},t='D522FD4748D443A5',g={}},
    ['content/fac_bugs/cha_warrior_big/cha_warrior_big_tier2']={m=29,o={28,29},t='F79CD8BB654397DF',g={}},
    ['content/fac_bugs/cha_warrior_burrower/cha_warrior_burrower']={m=11,o={10,11},t='A35207C6F2150806',g={}},
    ['content/fac_bugs/cha_warrior_plus/cha_warrior_plus']={m=29,o={28,29},t='A1F37BF2A40FBDE4',g={}},
    ['content/fac_cyborgs/cha_berserker/cha_berserker']={m=33,o={30,31,32,33},t='A6A68D8AF177F3A1',g={'cyborg'}},
    ['content/fac_cyborgs/cha_berserker/cha_berserker_iron_fleet']={m=33,o={30,31,32,33},t='54E107DACF6929CB',g={'cyborg'}},
    ['content/fac_cyborgs/cha_conscript/cha_conscript']={m=27,o={27},t='B2B3056BDF28E57B',g={'cyborg'}},
    ['content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet']={m=28,o={27,28},t='9821303BD499CD62',g={'cyborg'}},
    ['content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion']={m=29,o={28,29},t='9F57782F00E6ED20',g={'cyborg'}},
    ['content/fac_cyborgs/cha_conscript/cha_conscript_tier_2']={m=28,o={27,28},t='64BA5F030B114EC1',g={'cyborg'}},
    ['content/fac_cyborgs/cha_conscript_commander/cha_conscript_commander']={m=27,o={27},t='A71AAFD82C6EBC92',g={'cyborg'}},
    ['content/fac_cyborgs/cha_cyborg_elite/cha_cyborg_elite_rusher']={m=39,o={36,37,38,39},t='746A7F3BEDA32699',g={'cyborg'}},
    ['content/fac_cyborgs/cha_cyborg_elite/cha_elite_female']={m=45,o={42,43,44,45},t='9F44121C554DAE89',g={'cyborg'}},
    ['content/fac_cyborgs/cha_lieutenant/cha_lieutenant']={m=10,o={9,10},t='846BC06C6B213A06',g={'cyborg'}},
    ['content/fac_cyborgs/cha_lieutenant_assault/cha_lieutenant_assault']={m=10,o={9,10},t='B16493B009EEC762',g={'cyborg'}},
    ['content/fac_cyborgs/cha_soldier/cha_soldier']={m=33,o={30,31,32,33},t='AE63E525853D7044',g={'cyborg'}},
    ['content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon']={m=31,o={30,31},t='3D9C95BD03C0C7CF',g={'cyborg'}},
    ['content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet']={m=33,o={30,31,32,33},t='C626D2BB495A202D',g={'cyborg'}},
    ['content/fac_cyborgs/cha_soldier/cha_soldier_rocket']={m=31,o={30,31},t='DB7139323C40AE6F',g={'cyborg'}},
    ['content/fac_cyborgs/emplacements/cyborg_emplacement_hmg/cyborg_emplacement_hmg']={m=21,o={18,19,20,21},t='A98F8B559C7993D8',g={'cyborg'}},
    ['content/fac_cyborgs/emplacements/cyborg_emplacement_mg/cyborg_emplacement_mg']={m=7,o={7},t='2C1A7790C435FD67',g={'cyborg'}},
    ['content/fac_cyborgs/equipment/attachment/lieutenant_flag/lieutenant_flag']={m=13,o={9,10,11,12,13},t='8FC2784308E9BA99',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/backpacks/conscript_backpack_lmg/conscript_backpack_lmg']={m=10,o={9,10},t='426B3DF007BE9F18',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/backpacks/conscript_jumppack/conscript_jumppack']={m=6,o={6},t='E2E62FDD39407FE3',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/backpacks/lieutenant_jetpack/lieutenant_jetpack']={m=9,o={8,9},t='B940C889D77F8219',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/backpacks/soldier_jumppack/soldier_jumppack']={m=6,o={6},t='33B3E0CE8D179EEC',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/conscript_cannon/conscript_cannon']={m=11,o={10,11},t='71B285B6D2B161C9',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/conscript_flamer/conscript_flamer']={m=6,o={6},t='F4C0B6C9218FB571',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/conscript_handgun/conscript_handgun']={m=10,o={9,10},t='CBCE5F5F0310EF15',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/conscript_lmg/conscript_lmg']={m=14,o={10,11,12,13,14},t='68BA814FF35BF19C',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/conscript_melee_claw/conscript_melee_claw']={m=11,o={10,11},t='2D1636F2EE8A6306',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/conscript_smg/conscript_smg']={m=11,o={10,11},t='BCB3210CF8EF49D3',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/lieutenant_cannon/lieutenant_cannon']={m=7,o={6,7},t='4D61156DD350A82B',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/lieutenant_launcher/lieutenant_launcher']={m=7,o={6,7},t='7B5C9BDD385D0516',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/lieutenant_saw/lieutenant_saw']={m=11,o={10,11},t='C89ED7AC3E425B25',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/lieutenant_saw/lieutenant_saw_ivory_legion']={m=11,o={10,11},t='BB37F12D0F46690F',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/soldier_chainsaw/soldier_chainsaw']={m=10,o={9,10},t='4FB6077F1597691D',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/soldier_machinegun/soldier_machinegun']={m=5,o={5},t='2ED3696E12A14D4C',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/soldier_riotgun/soldier_riotgun']={m=5,o={5},t='DFB610642EFF47D7',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/soldier_shield/soldier_shield']={m=8,o={7,8},t='F96257FCAE258CAA',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/soldier_shield/soldier_shield_ivory_legion']={m=8,o={7,8},t='FEB484EE972469F7',p='cyborg',r=3},
    ['content/fac_cyborgs/equipment/weapons/soldier_standard_rifle/soldier_standard_rifle']={m=11,o={10,11},t='070BC8D3E18BB8F9',p='cyborg',r=3},
    ['content/fac_cyborgs/turrets/cyborg_big_walker_turret_cannon/cyborg_big_walker_turret_cannon']={m=11,o={10,11},t='843D18D4B5512B63',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/turrets/cyborg_tank_hull_hmg/cyborg_tank_hull_mg']={m=2,o={2},t='16023E554FEE830E',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/turrets/cyborg_tank_turret_autocannons/cyborg_tank_turret_autocannons']={m=12,o={10,11,12},t='49674794A165EDA8',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/turrets/cyborg_tank_turret_cannon/cyborg_tank_turret_cannon']={m=11,o={10,11},t='CECD6979CF7BB0F2',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/turrets/cyborg_tank_turret_rocketlauncher/cyborg_tank_turret_rocketlauncher']={m=11,o={10,11},t='5D142C3A73EBC634',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/turrets/cyborg_turret_command_bunker_hmg/cyborg_turret_command_bunker_hmg']={m=7,o={6,7},t='CD28A27A79BE53D5',g={'cyborg'}},
    ['content/fac_cyborgs/turrets/cyborg_turret_small_autocannon/cyborg_turret_small_autocannon']={m=2,o={2},t='9926876B2375A1BB',g={'cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_assault_walker/cyborg_assault_walker']={m=21,o={20,21},t='EF570293245A17C2',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_dropship/cyborg_dropship']={m=17,o={16,17},t='DB90077E76FAA025',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_gunship/cyborg_gunship']={m=18,o={16,17,18},t='282EB766C1FFA6A1',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_siege_engine/cyborg_siege_engine']={m=61,o={56,57,58,59,60,61},t='BC242702FB46B7E7',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_spawner/cyborg_spawner']={m=23,o={22,23},t='D37E8D120D2836E3',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_tank/cyborg_tank']={m=11,o={10,11},t='00BCF8247A544CDC',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_cyborgs/vehicles/cyborg_walker_scout/cyborg_walker_scout']={m=21,o={19,20,21},t='F8131632AA867107',g={'cyborg_vehicle','cyborg'}},
    ['content/fac_illuminate/cha_beamer_champion/cha_beamer_champion']={m=20,o={17,18,19,20},t='E8F19A0AA958E46D',g={'illuminate'}},
    ['content/fac_illuminate/cha_bodyhorror_bladed/cha_bodyhorror_bladed']={m=20,o={19,20},t='CC188F0C80505C6C',g={'illuminate'}},
    ['content/fac_illuminate/cha_bodyhorror_helmetguy/cha_bodyhorror_helmetguy']={m=16,o={16},t='905809A4C28D8A45',g={'illuminate'}},
    ['content/fac_illuminate/cha_corrupted/cha_corrupted']={m=20,o={19,20},t='78E1497571012C47',g={'illuminate'}},
    ['content/fac_illuminate/cha_corrupted/cha_corrupted_v2']={m=20,o={19,20},t='0ADC9F9173AD8E1D',g={'illuminate'}},
    ['content/fac_illuminate/cha_corrupted/cha_corrupted_v3']={m=20,o={19,20},t='44458A2C52B002FB',g={'illuminate'}},
    ['content/fac_illuminate/cha_exomech_melee/cha_exomech_melee']={m=71,o={70,71},t='20B9C7734DAEAD65',g={'illuminate'}},
    ['content/fac_illuminate/cha_exomech_ranged/cha_exomech_ranged']={m=51,o={50,51},t='453FE22C634EB30F',g={'illuminate'}},
    ['content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff']={m=18,o={17,18},t='DA40BB347C7447F2',g={'illuminate'}},
    ['content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff_fake']={m=5,o={5},t='F1610AC48CDC5240',g={'illuminate'}},
    ['content/fac_illuminate/cha_jet_champion/cha_jet_champion']={m=18,o={17,18},t='604A794EC45BB820',g={'illuminate'}},
    ['content/fac_illuminate/cha_meatglue/cha_meatglue']={m=12,o={11,12},t='67DC32DCA4F02D33',g={'illuminate'}},
    ['content/fac_illuminate/cha_observer/cha_observer']={m=10,o={9,10},t='AC60E78435098C9D',g={'illuminate'}},
    ['content/fac_illuminate/cha_tripod/cha_tripod']={m=22,o={21,22},t='965EAE5A51ACDD4A',g={'illuminate'}},
    ['content/fac_illuminate/equipment/weapons/beamer_champion_gun/beamer_champion_gun']={m=11,o={10,11},t='705362AD578943F6',p='illuminate',r=3},
    ['content/fac_illuminate/equipment/weapons/helmetguy_cleaver/helmetguy_cleaver']={m=2,o={2},t='258BD988CD66C94B',p='illuminate',r=3},
    ['content/fac_illuminate/equipment/weapons/jet_champion_rifle/jet_champion_rifle']={m=9,o={8,9},t='0CF9B9B95EDFEF81',p='illuminate',r=3},
    ['content/fac_illuminate/equipment/weapons/pathfinder_lightspear/pathfinder_lightspear']={m=5,o={5},t='9C7EF47A463D5327',p='illuminate',r=3},
    ['content/fac_illuminate/vehicles/armaments/illuminate_turret_warmachine/illuminate_turret_wm_cannon']={m=7,o={6,7},t='4E342031A9D5C4F9',p='warmachine',r=10},
    ['content/fac_illuminate/vehicles/illuminate_attack_ship/illuminate_attack_ship']={m=23,o={20,21,22,23},t='19E18B46EC55D94A',g={'illuminate'}},
    ['content/fac_illuminate/vehicles/illuminate_dropship/illuminate_dropship']={m=14,o={13,14},t='74E2285C01DA4F71',g={'illuminate'}},
    ['content/fac_illuminate/vehicles/illuminate_war_machine/illuminate_war_machine']={m=16,o={15,16},t='F22D027B37BEF107',g={'warmachine','illuminate'}},
    ['content/fac_cyborgs/vehicles/armaments/wep_scoutwalker_hmg/wep_scoutwalker_hmg']={m=2,o={2},t='2A346BF4552997E2',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/vehicles/armaments/cyborg_top_turret_mg/cyborg_top_turret_mg']={m=13,o={11,12,13},t='48C91E42B9F16512',p='cyborg_vehicle',r=10},
    ['content/fac_cyborgs/equipment/backpacks/conscript_backpack_flamer/conscript_backpack_flamer']={m=11,o={10,11},t='57F11209295752B5',p='cyborg',r=3},
    ['content/fac_cyborgs/vehicles/armaments/cyborg_gunship_turret/cyborg_gunship_turret']={m=8,o={7,8},t='2D62A25F36C08F33',p='cyborg_vehicle',r=10},
}

-- entity type (Hub) -> outlined model resources it can use (same folder)
local EXTRA_TYPES={
    ['6021E22338333D88']={'content/fac_bugs/cha_boomer_nurser/cha_boomer_nurser'},
    ['A05BD1EC67B3AC4C']={'content/fac_bugs/cha_charger/cha_charger'},
    ['FD5247653C897803']={'content/fac_bugs/cha_charger_bull/cha_charger_bull'},
    ['1F0A91729C0004E0']={'content/fac_bugs/cha_hunter/cha_hunter','content/fac_bugs/cha_hunter/cha_hunter_gloom_tier1','content/fac_bugs/cha_hunter/cha_hunter_tier3'},
    ['3D0E03E2D574E1CA']={'content/fac_bugs/cha_hunter/cha_hunter','content/fac_bugs/cha_hunter/cha_hunter_gloom_tier1','content/fac_bugs/cha_hunter/cha_hunter_tier3'},
    ['5CA832447445C0BA']={'content/fac_bugs/cha_hunter/cha_hunter','content/fac_bugs/cha_hunter/cha_hunter_gloom_tier1','content/fac_bugs/cha_hunter/cha_hunter_tier3'},
    ['883401AF2A98A5F6']={'content/fac_bugs/cha_hunter/cha_hunter','content/fac_bugs/cha_hunter/cha_hunter_gloom_tier1','content/fac_bugs/cha_hunter/cha_hunter_tier3'},
    ['D9511E9F6BD62E3F']={'content/fac_bugs/cha_hunter/cha_hunter','content/fac_bugs/cha_hunter/cha_hunter_gloom_tier1','content/fac_bugs/cha_hunter/cha_hunter_tier3'},
    ['51EEA86BF6997E4E']={'content/fac_bugs/cha_scavenger/cha_scavenger','content/fac_bugs/cha_scavenger/cha_scavenger_captive','content/fac_bugs/cha_scavenger/cha_scavenger_gloom'},
    ['8FF0A839830A7692']={'content/fac_bugs/cha_scavenger/cha_scavenger','content/fac_bugs/cha_scavenger/cha_scavenger_captive','content/fac_bugs/cha_scavenger/cha_scavenger_gloom'},
    ['9A8A3AAE287B230C']={'content/fac_bugs/cha_scavenger/cha_scavenger','content/fac_bugs/cha_scavenger/cha_scavenger_captive','content/fac_bugs/cha_scavenger/cha_scavenger_gloom'},
    ['DFBACBD977A948DC']={'content/fac_bugs/cha_scavenger/cha_scavenger','content/fac_bugs/cha_scavenger/cha_scavenger_captive','content/fac_bugs/cha_scavenger/cha_scavenger_gloom'},
    ['F0B26FA9258128D3']={'content/fac_bugs/cha_shrieker/cha_shrieker'},
    ['32541FC4EC7C9CDC']={'content/fac_bugs/cha_warrior/cha_warrior','content/fac_bugs/cha_warrior/cha_warrior_gloom_tier_1','content/fac_bugs/cha_warrior/cha_warrior_tier_1'},
    ['4E97FB073BDC7A4B']={'content/fac_bugs/cha_warrior/cha_warrior','content/fac_bugs/cha_warrior/cha_warrior_gloom_tier_1','content/fac_bugs/cha_warrior/cha_warrior_tier_1'},
    ['728421351D440EBC']={'content/fac_bugs/cha_warrior/cha_warrior','content/fac_bugs/cha_warrior/cha_warrior_gloom_tier_1','content/fac_bugs/cha_warrior/cha_warrior_tier_1'},
    ['B2A6FA1E4284C7E6']={'content/fac_bugs/cha_warrior/cha_warrior','content/fac_bugs/cha_warrior/cha_warrior_gloom_tier_1','content/fac_bugs/cha_warrior/cha_warrior_tier_1'},
    ['EACEE39FA017B495']={'content/fac_bugs/cha_warrior/cha_warrior','content/fac_bugs/cha_warrior/cha_warrior_gloom_tier_1','content/fac_bugs/cha_warrior/cha_warrior_tier_1'},
    ['B5DBC0C240C921AD']={'content/fac_cyborgs/cha_berserker/cha_berserker','content/fac_cyborgs/cha_berserker/cha_berserker_iron_fleet'},
    ['D5792F6856B06BA4']={'content/fac_cyborgs/cha_berserker/cha_berserker','content/fac_cyborgs/cha_berserker/cha_berserker_iron_fleet'},
    ['0002BA767DF856F3']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['089833D2880D9E06']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['257D805CAA7E10C0']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['30CF04B2EC8C9BD4']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['4019623142351CB6']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['52018DEB9AB6827E']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['7B48CACDBACB3881']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['7ECE5304F868F6B3']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['82A87AD8D595B2BA']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['856E9710E45E760F']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['A4552F97033392F4']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['AE57FCDB49F74E98']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['AF0F9B3A163787A5']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['B4ED319B39F5457B']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['D8CBC4A807A6D035']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['E683D2CA5618D74A']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['FB9937035D652C43']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_iron_fleet','content/fac_cyborgs/cha_conscript/cha_conscript_ivory_legion','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},
    ['215CE160A17BE4CD']={'content/fac_cyborgs/cha_conscript_commander/cha_conscript_commander'},
    ['09FE0BE51A23396C']={'content/fac_cyborgs/cha_cyborg_elite/cha_cyborg_elite_rusher','content/fac_cyborgs/cha_cyborg_elite/cha_elite_female'},
    ['9D8827FED763650E']={'content/fac_cyborgs/cha_cyborg_elite/cha_cyborg_elite_rusher','content/fac_cyborgs/cha_cyborg_elite/cha_elite_female'},
    ['CBB1BA3366009C3A']={'content/fac_cyborgs/cha_cyborg_elite/cha_cyborg_elite_rusher','content/fac_cyborgs/cha_cyborg_elite/cha_elite_female'},
    ['137988CEA16458F7']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['1897BDD32105D2DC']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['1E66EE1F6F7FD00E']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['32CDEADA234FB8DF']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['3E0537D606438FEA']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['6DAB2EADF5D8B692']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['96BA14C9EBB49CE1']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['E44EC9F9B3FE1D2A']={'content/fac_cyborgs/cha_lieutenant/cha_lieutenant'},
    ['57EED0EAC346CD9D']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['58B2B86C11369241']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['9647B00CC3A9D36F']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['B92435FBF60F0748']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['BE743B2FAA3A6E26']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['C9BCCCB0A54A82A4']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['E0353177F1329573']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['F66D0BAD8693779A']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['F8B5A81A86D5D4EB']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['FC8DEC78BE8AB47D']={'content/fac_cyborgs/cha_soldier/cha_soldier','content/fac_cyborgs/cha_soldier/cha_soldier_heavy_weapon','content/fac_cyborgs/cha_soldier/cha_soldier_iron_fleet','content/fac_cyborgs/cha_soldier/cha_soldier_rocket'},
    ['98152772A72F7838']={'content/fac_cyborgs/vehicles/cyborg_dropship/cyborg_dropship'},
    ['30F2DEE2333F227A']={'content/fac_cyborgs/vehicles/cyborg_spawner/cyborg_spawner'},
    ['31BAE74D2F064D8D']={'content/fac_cyborgs/vehicles/cyborg_tank/cyborg_tank'},
    ['53D8919D7B8ABD67']={'content/fac_cyborgs/vehicles/cyborg_tank/cyborg_tank'},
    ['63DF3D07B7424588']={'content/fac_cyborgs/vehicles/cyborg_tank/cyborg_tank'},
    ['C6449FFD9EA3779C']={'content/fac_cyborgs/vehicles/cyborg_tank/cyborg_tank'},
    ['9076EEED17FCEE35']={'content/fac_cyborgs/vehicles/cyborg_walker_scout/cyborg_walker_scout'},
    ['08E6FFC2474287BD']={'content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff','content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff_fake'},
    ['D63FCBFF0851B7AF']={'content/fac_illuminate/cha_tripod/cha_tripod'},
}
local TYPE={}       -- entity type -> key
local CANDS={}      -- key -> list of model resources
local IN={}         -- key -> set of model resources
for name,d in pairs(OUTLINE_UNITS) do TYPE[d.t]=name;CANDS[name]={name};IN[name]={[name]=true} end
for t,list in pairs(EXTRA_TYPES) do
    local ok={}
    for _,r in ipairs(list) do if OUTLINE_UNITS[r] then ok[#ok+1]=r end end
    if #ok>0 and not TYPE[t] then
        TYPE[t]=t;CANDS[t]=ok;IN[t]={}
        for _,r in ipairs(ok) do IN[t][r]=true end
    end
end
local function owned(u,key,owner) local r=owner[u];return r~=nil and IN[key]~=nil and IN[key][r]==true end

local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e8 end
local function log(line)
    line='[enemy_outline_off] '..tostring(line)
    local M=rawget(_G,'MDL')
    if type(M)=='table' and type(M.log)=='function' and pcall(M.log,line) then return end
    pcall(print,line)
end
local last_error=nil
local function report(err) err=tostring(err);if err~=last_error then last_error=err;log(err) end end
local function short(name) return name:match('([^/]+)$') or name end

local hub,subs,epoch,in_since=nil,{},nil,nil
local clock=0             -- game time, accumulated from update(dt)
local lists={}            -- resource name -> units
local owner_of={}         -- unit -> resource name
local list_next=0
local mesh_ok={}          -- resource name -> true / false after the first check
local hidden={}           -- unit -> true
local hist={}             -- unit -> {n=, i=, t={}, x={}, y={}, z={}}
local deaths={}           -- pending deaths
local hits={}             -- pending hits
local votes={}            -- entity id -> {unit -> count}
local last_vote={}        -- entity id -> clock
local spawns={}            -- pending spawn events
local bind={}              -- entity id -> unit (birth binding)
local bound={}             -- unit -> entity id
local last_move={}         -- unit -> clock of its last movement > 0.3 m
local last_pos={}          -- unit -> {x,y,z} at that movement
local gone_since={}        -- entity id -> clock when its Hub entity was first seen invalid
local ents={}              -- entity id -> Hub Entity handle (from spawn / hit events)
local spawn_ids={}         -- entity id -> true for every spawn event received this mission
local first_seen={}        -- unit -> clock when it first showed up in a unit list
local stats={}
local HN=90               -- ring size (>= 1.2 s at 75 fps)

local function event_time(e)
    -- the event's moment in our clock: now minus the Hub's delivery lag
    local lag=0
    if hub and type(e.time)=='number' then
        local ok,m=pcall(hub.mission)
        if ok and type(m)=='table' and type(m.now)=='number' then lag=m.now-e.time end
    end
    if not finite(lag) or lag<0 then lag=0 elseif lag>MAX_LAG then lag=MAX_LAG end
    return clock-lag
end
local function event_position(p)
    if type(p)=='table' and finite(p.x) and finite(p.y) and finite(p.z) then return p end
end
local function type_name(e)
    return type(e.type)=='string' and TYPE[e.type:upper()] or nil
end
local function on_died(e)
    if type(e)=='table' and in_since and e.avatar~=true then
        stats.deaths_all=(stats.deaths_all or 0)+1
        if e.local_killer==true then stats.deaths_mine=(stats.deaths_mine or 0)+1 end
        if e.observed=='corpse' then stats.deaths_corpse=(stats.deaths_corpse or 0)+1 end
    end
    if type(e)~='table' or e.avatar==true or not in_since then return end
    local name=type_name(e)
    if e.enemy~=true and not name then return end
    if not name then
        stats.untyped=stats.untyped or {}
        local k=tostring(e.type);stats.untyped[k]=(stats.untyped[k] or 0)+1
    end
    local p=event_position(e.position)
    if not p and type(e.entity)=='table' and type(e.entity.position)=='function' then
        local ok,v=pcall(e.entity.position,e.entity);if ok then p=event_position(v) end
    end
    if p then
        deaths[#deaths+1]={x=p.x,y=p.y,z=p.z,name=name,id=e.entity_id,t=event_time(e),till=clock+RETRY,etype=e.type}
    end
end
local function on_damaged(e)
    if type(e)~='table' or e.avatar==true or not in_since then return end
    local id=e.entity_id
    local name=type_name(e)
    if not name or type(id)~='number' then return end
    stats.hit_rx=(stats.hit_rx or 0)+1
    if last_vote[id] and clock-last_vote[id]<HIT_GAP then stats.hit_gap=(stats.hit_gap or 0)+1;return end
    local p=type(e.entity)=='table' and event_position(e.entity.pos)
    if not p then stats.hit_nopos=(stats.hit_nopos or 0)+1;return end
    last_vote[id]=clock
    if not ents[id] then ents[id]=current_epoch_entity(e.entity) end
    if #hits<200 then hits[#hits+1]={x=p.x,y=p.y,z=p.z,name=name,id=id,t=event_time(e)} end
end
local function current_epoch_entity(en)
    if type(en)~='table' or type(en.is_valid)~='function' or not hub then return nil end
    local ok,m=pcall(hub.mission)
    if ok and type(m)=='table' and en.epoch~=nil and en.epoch==m.epoch then return en end
end
local function on_spawned(e)
    if type(e)~='table' or e.avatar==true then return end
    local name=type_name(e); local id=e.entity_id
    if not name and e.enemy==true and in_since then
        stats.untyped_spawn=stats.untyped_spawn or {}
        local k=tostring(e.type);stats.untyped_spawn[k]=(stats.untyped_spawn[k] or 0)+1
    end
    if not name or type(id)~='number' then return end
    stats.spawn_rx=(stats.spawn_rx or 0)+1
    spawn_ids[id]=true
    ents[id]=current_epoch_entity(e.entity) or ents[id]
    local p=type(e.entity)=='table' and event_position(e.entity.pos)
    if not p then return end
    local early=(not in_since) or clock-in_since<SETTLE
    if early then stats.spawn_early=(stats.spawn_early or 0)+1 end
    if #spawns<600 then spawns[#spawns+1]={x=p.x,y=p.y,z=p.z,name=name,id=id,t=event_time(e),till=clock+SPAWN_WAIT,early=early,ep=type(e.entity)=='table' and e.entity.epoch or nil} end
end
local function on_kill(e)
    if type(e)~='table' or not in_since then return end
    local n=tonumber(e.kills) or 0
    stats.kills_game=(stats.kills_game or 0)+n
    stats.kill_src=stats.kill_src or {}
    if type(e.sources)=='table' then
        for _,src in ipairs(e.sources) do
            local k=tostring(src.name or src.type or '?')
            stats.kill_src[k]=(stats.kill_src[k] or 0)+(tonumber(src.kills) or 0)
        end
    end
    if (tonumber(e.unattributed) or 0)>0 then stats.kill_src['(unattributed)']=(stats.kill_src['(unattributed)'] or 0)+e.unattributed end
end
local function new_stats() return {bind=0,vote=0,pos=0,miss=0,spawn_bound=0,spawn_open=0,overruled=0,far=0,
    spawn_rx=0,spawn_early=0,hit_rx=0,hit_gap=0,hit_nopos=0,hit_vote=0,hit_none=0,hit_far=0,hit_amb=0,death_voted=0,hit_logged=0} end
local function reset_stats_if_needed() if not stats.hit_logged then stats=new_stats() end end
local function reset(keep_epoch)
    if in_since and stats.bind then
        log(string.format('mission summary: deaths bind=%d vote=%d position=%d missed=%d | spawns bound=%d unbound=%d | overruled=%d bound_too_far=%d',
            stats.bind,stats.vote,stats.pos,stats.miss,stats.spawn_bound,stats.spawn_open,stats.overruled,stats.far))
        log(string.format('mission detail: spawns received=%d early=%d early_bound=%d | hits received=%d rate_limited=%d no_pos=%d voted=%d no_unit=%d too_far=%d ambiguous=%d | deaths_with_votes=%d position_but_had_votes=%d',
            stats.spawn_rx,stats.spawn_early,stats.early_bound or 0,stats.hit_rx,stats.hit_gap,stats.hit_nopos,stats.hit_vote,stats.hit_none,stats.hit_far,stats.hit_amb,stats.death_voted,stats.pos_voted or 0))
        local w={}
        for k,v in pairs(stats.why or {}) do w[#w+1]=k..'='..v end
        table.sort(w)
        log('mission detail: deaths not by binding because: '..(#w>0 and table.concat(w,' ') or '-'))
        local function list(t) local r={} for k,v in pairs(t or {}) do r[#r+1]=k..'='..v end table.sort(r) return #r>0 and table.concat(r,' ') or '-' end
        log('mission detail: no_spawn by type: '..list(stats.nospawn))
        log('mission types: deaths of types not in the table: '..list(stats.untyped))
        log('mission types: spawns of types not in the table: '..list(stats.untyped_spawn))
        log('mission types: untyped death matched to model: '..list(stats.untyped_match))
        local still=0
        for u in pairs(bound) do if not hidden[u] and last_move[u] and clock-last_move[u]>30 then still=still+1 end end
        log(string.format('mission check: game_kills(mine)=%d hub_deaths(mine)=%d hub_deaths(all)=%d of_which_corpse=%d | outlined_vanished_unhidden=%d bound_vanished=%d bound_still_30s=%d',
            stats.kills_game or 0,stats.deaths_mine or 0,stats.deaths_all or 0,stats.deaths_corpse or 0,stats.vanished_lit or 0,stats.bound_vanished or 0,still))
        log('mission check: game kills by weapon: '..list(stats.kill_src))
        log(string.format('mission check: no death event, hidden because the Hub entity went invalid: bound=%d voted=%d',stats.gone_hidden or 0,stats.gone_hidden_vote or 0))
    end
    local kept={}
    local carry_rx,carry_early=0,0
    if keep_epoch~=nil then
        for _,sp in ipairs(spawns) do sp.early=true;sp.started=nil;kept[#kept+1]=sp end
        carry_rx,carry_early=stats.spawn_rx or 0,stats.spawn_early or 0
    end
    stats=new_stats();spawns=kept;bind={};bound={};first_seen={};last_move={};last_pos={};ents={};gone_since={}
    if keep_epoch==nil then spawn_ids={} end
    stats.spawn_rx,stats.spawn_early=carry_rx,carry_early
    lists={};owner_of={};hidden={};hist={};deaths={};hits={};votes={};last_vote={};in_since=nil
end
local function clear_subscriptions()
    for _,s in pairs(subs) do if s and type(s.unsubscribe)=='function' then pcall(s.unsubscribe,s) end end
    subs={}
end
local function connect(D)
    clear_subscriptions()
    hub=D
    for ev,fn in pairs({entity_died=on_died,entity_damaged=on_damaged,entity_spawned=on_spawned,player_kill_credited=on_kill,mission_started=function(e) reset(true) end,mission_ended=function() reset() end}) do
        local s=D.on(ev,function(e) local ok,err=pcall(fn,e);if not ok then report(ev..': '..tostring(err)) end end,
            {owner=OWNER,id=ev})
        if not s then error('subscription unavailable: '..ev) end
        subs[ev]=s
    end
    log('connected to HD2 Data Hub '..tostring(D.version))
end

local function refresh_lists()
    local W=sr.Application.main_world()
    if not W then return false end
    local seen={}
    for name in pairs(OUTLINE_UNITS) do
        local ok,list=pcall(sr.World.units_by_resource,W,name)
        list=(ok and type(list)=='table') and list or {}
        lists[name]=list
        for _,u in ipairs(list) do seen[u]=name; if not first_seen[u] then first_seen[u]=clock end end
    end
    for u,nm in pairs(owner_of) do
        if not seen[u] and not hidden[u] and OUTLINE_UNITS[nm] and OUTLINE_UNITS[nm].g then
            stats.vanished_lit=(stats.vanished_lit or 0)+1
            if bound[u] then stats.bound_vanished=(stats.bound_vanished or 0)+1 end
        end
    end
    owner_of=seen
    for u in pairs(first_seen) do if not seen[u] then first_seen[u]=nil end end
    for u,id in pairs(bound) do if not seen[u] then bound[u]=nil; bind[id]=nil end end
    for u in pairs(last_move) do if not seen[u] then last_move[u]=nil;last_pos[u]=nil end end
    for u in pairs(hist) do if not seen[u] then hist[u]=nil end end
    for u in pairs(hidden) do if not seen[u] then hidden[u]=nil end end
    return true
end
local function refresh_one(key)
    local W=sr.Application.main_world()
    if not W then return end
    for _,name in ipairs(CANDS[key] or {key}) do
        local ok,list=pcall(sr.World.units_by_resource,W,name)
        list=(ok and type(list)=='table') and list or {}
        lists[name]=list
        for _,u in ipairs(list) do owner_of[u]=name; if not first_seen[u] then first_seen[u]=clock end end
    end
end
local function check_meshes()
    for name,list in pairs(lists) do
        if mesh_ok[name]==nil and #list>0 then
            local u=list[1]
            local ok,n=pcall(function() if not sr.Unit.alive(u) then return nil end return sr.Unit.num_meshes(u) end)
            if ok and type(n)=='number' then
                mesh_ok[name]=(n==OUTLINE_UNITS[name].m)
                if not mesh_ok[name] then log(short(name)..': mesh count '..n..' (expected '..OUTLINE_UNITS[name].m..'), outline left on') end
            elseif not ok then
                mesh_ok[name]=false;log(short(name)..': num_meshes failed: '..tostring(n))
            end
        end
    end
end
local function v3(v) local V=sr.Vector3 return V.x(v),V.y(v),V.z(v) end
local function pos(u)
    local ok,x,y,z=pcall(function()
        if not sr.Unit.alive(u) then return nil end
        return v3(sr.Unit.world_position(u,1))
    end)
    if ok and finite(x) then return x,y,z end
end

-- position history ----------------------------------------------------------------
local function sample()
    for u,name in pairs(owner_of) do
        if not hidden[u] and mesh_ok[name]~=false then
            local x,y,z=pos(u)
            if x then
                local h=hist[u]
                if not h then h={n=0,i=0,t={},x={},y={},z={}};hist[u]=h end
                local i=h.i%HN+1
                h.i=i;if h.n<HN then h.n=h.n+1 end
                h.t[i],h.x[i],h.y[i],h.z[i]=clock,x,y,z
                local lp=last_pos[u]
                if not lp or (lp[1]-x)^2+(lp[2]-y)^2+(lp[3]-z)^2>0.09 then last_pos[u]={x,y,z};last_move[u]=clock end
            end
        end
    end
end
-- squared distance between unit u and point p at time t (closest sample in the window;
-- falls back to the sample nearest in time, then to the current position)
local function dist2_at(u,p,t)
    local h=hist[u]
    local best,bt,bdt=nil,nil,math.huge
    if h then
        for k=1,h.n do
            local dt=math.abs(h.t[k]-t)
            local d2=(h.x[k]-p.x)^2+(h.y[k]-p.y)^2+(h.z[k]-p.z)^2
            if dt<=WINDOW then
                if not best or d2<best then best=d2 end
            elseif dt<bdt then bt,bdt=d2,dt end
        end
    end
    if best then return best end
    if bt and bdt<=HISTORY then return bt end
    local x,y,z=pos(u)
    if x then return (x-p.x)^2+(y-p.y)^2+(z-p.z)^2 end
end
-- closest and second closest unit of resource `name` to p at time t
local function rank(name,p,t)
    local b1,d1,d2=nil,math.huge,math.huge
    for _,res in ipairs(CANDS[name] or {name}) do
    for _,u in ipairs(lists[res] or {}) do
        if not hidden[u] then
            local d=dist2_at(u,p,t)
            if d then
                if d<d1 then b1,d2,d1=u,d1,d elseif d<d2 then d2=d end
            end
        end
    end
    end
    return b1,d1,d2
end

local function hide(u,name)
    if hidden[u] or not mesh_ok[name] then return false end
    local okA,alive=pcall(sr.Unit.alive,u)
    if not okA or not alive then return false end
    for _,i in ipairs(OUTLINE_UNITS[name].o) do
        local ok,err=pcall(sr.Unit.set_mesh_visibility,u,i,false)
        if not ok then report('set_mesh_visibility: '..tostring(err));return false end
    end
    hidden[u]=true
    return true
end

local function process_hits()
    if #hits==0 then return end
    local list=hits;hits={}
    for _,h in ipairs(list) do
        local u,d1,d2=rank(h.name,h,h.t)
        if u and d1<=HIT_R*HIT_R and math.sqrt(d2)-math.sqrt(d1)>=HIT_MARGIN then
            local v=votes[h.id];if not v then v={};votes[h.id]=v end
            v[u]=(v[u] or 0)+1
            stats.hit_vote=stats.hit_vote+1
        else
            if not u then stats.hit_none=stats.hit_none+1
            elseif d1>HIT_R*HIT_R then stats.hit_far=stats.hit_far+1
            else stats.hit_amb=stats.hit_amb+1 end
            if stats.hit_logged<5 then
                stats.hit_logged=stats.hit_logged+1
                log(string.format('hit not voted: %s n=%d d1=%s d2=%s lag=%.2f',short(h.name),#(CANDS[h.name] or {}),
                    u and string.format('%.2f',math.sqrt(d1)) or '-',d2<math.huge and string.format('%.2f',math.sqrt(d2)) or '-',clock-h.t))
            end
        end
    end
end
local function voted(id,name,p,t)
    local v=id and votes[id]
    if not v then return nil end
    local best,bc=nil,0
    for u,c in pairs(v) do
        if c>bc and not hidden[u] and owned(u,name,owner_of) then best,bc=u,c end
    end
    if best then
        local d=dist2_at(best,p,t)
        if d and d<=VOTE_R*VOTE_R then return best end
    end
end
local function process_spawns()
    if #spawns==0 then return end
    local list=spawns;spawns={}
    local fresh={}
    for _,s in ipairs(list) do
        if not fresh[s.name] then refresh_one(s.name);fresh[s.name]=true end
        if s.early and not s.started then s.started=true;s.till=clock+SPAWN_WAIT end
        local R,M=SPAWN_R,SPAWN_MARGIN
        if s.early then R,M=EARLY_R,EARLY_MARGIN end
        local b1,d1,d2=nil,math.huge,math.huge
        for _,res in ipairs(CANDS[s.name] or {s.name}) do
        for _,u in ipairs(lists[res] or {}) do
            if not bound[u] and not hidden[u] and (s.early or (first_seen[u] or 0)>=s.t-BORN_SLACK) then
                local d=dist2_at(u,s,s.t)
                if d then if d<d1 then b1,d2,d1=u,d1,d elseif d<d2 then d2=d end end
            end
        end
        end
        if b1 and d1<=R*R and math.sqrt(d2)-math.sqrt(d1)>=M then
            bind[s.id]=b1;bound[b1]=s.id;stats.spawn_bound=stats.spawn_bound+1
            if s.early then stats.early_bound=(stats.early_bound or 0)+1 end
        elseif clock<s.till then
            spawns[#spawns+1]=s
        else
            stats.spawn_open=stats.spawn_open+1
        end
    end
end
local function by_binding(p)
    local u=p.id and bind[p.id]
    if p.why==nil then
        if not p.id then p.why='no_id'
        elseif not u then p.why=spawn_ids[p.id] and 'spawn_not_bound' or 'no_spawn'
        elseif hidden[u] then p.why='bound_unit_already_hidden'
        elseif not owned(u,p.name,owner_of) then p.why='bound_unit_other_type' end
    end
    if not u or hidden[u] or not owned(u,p.name,owner_of) then return nil end
    local d=dist2_at(u,p,p.t)
    if not d or d>BIND_R*BIND_R then stats.far=stats.far+1;return nil end
    local v=votes[p.id]
    if v then
        local mine=v[u] or 0
        for w,c in pairs(v) do
            if w~=u and c>=mine+OVERRULE and not hidden[w] and owned(w,p.name,owner_of) then stats.overruled=stats.overruled+1;return nil end
        end
    end
    return u
end
local function match(p)
    if p.name then
        if p.id and votes[p.id] and not p.counted then p.counted=true;stats.death_voted=stats.death_voted+1 end
        local u=by_binding(p)
        if u then return u,owner_of[u],'bind' end
        u=voted(p.id,p.name,p,p.t)
        if u then return u,owner_of[u],'vote' end
        local b,d1,d2=rank(p.name,p,p.t)
        if p.id and votes[p.id] then stats.pos_voted=(stats.pos_voted or 0)+1 end
        if b and d1<=TYPED_R*TYPED_R then return b,owner_of[b],'pos' end
        -- a lone unit of that type a bit further out (big bodies) is still unambiguous
        if b and d1<=LONE_R*LONE_R and math.sqrt(d2)-math.sqrt(d1)>=LONE_MARGIN then return b,owner_of[b],'pos' end
        return nil
    end
    local bu,bd,bn=nil,ANY_R*ANY_R,nil
    for name,d in pairs(OUTLINE_UNITS) do
        if d.g then
            local u,d1=rank(name,p,p.t)
            if u and d1<bd then bu,bd,bn=u,d1,name end
        end
    end
    return bu,bn,'pos'
end

-- attachments: dark when the nearest body of their parent group is a dead (hidden) one
local function attachment_pass()
    local bodies={}
    for name,d in pairs(OUTLINE_UNITS) do
        if d.g then
            for _,u in ipairs(lists[name] or {}) do
                local x,y,z=pos(u)
                if x then
                    local b={x,y,z,hidden[u]==true}
                    for _,g in ipairs(d.g) do
                        local t=bodies[g];if not t then t={};bodies[g]=t end
                        t[#t+1]=b
                    end
                end
            end
        end
    end
    for name,d in pairs(OUTLINE_UNITS) do
        local group=d.p and bodies[d.p]
        if group and mesh_ok[name] then
            local r2=d.r*d.r
            for _,u in ipairs(lists[name] or {}) do
                if not hidden[u] then
                    local x,y,z=pos(u)
                    if x then
                        local best,bd=nil,r2
                        for _,b in ipairs(group) do
                            local d2=(b[1]-x)^2+(b[2]-y)^2+(b[3]-z)^2
                            if d2<bd then best,bd=b,d2 end
                        end
                        if best and best[4] then hide(u,name) end
                    end
                end
            end
        end
    end
end

local function entity_gone(id)
    local en=ents[id]
    if not en then return false end
    local ok,valid=pcall(en.is_valid,en)
    return ok and valid==false
end
local GONE_WAIT=2.0
local function gone_ripe(id)
    if not entity_gone(id) then gone_since[id]=nil;return false end
    if not gone_since[id] then gone_since[id]=clock;return false end
    return clock-gone_since[id]>=GONE_WAIT
end
local function gone_pass()
    for id,u in pairs(bind) do
        if gone_ripe(id) then
            local name=owner_of[u]
            if name and not hidden[u] and hide(u,name) then stats.gone_hidden=(stats.gone_hidden or 0)+1 end
            bind[id]=nil;bound[u]=nil;ents[id]=nil;votes[id]=nil;last_vote[id]=nil;gone_since[id]=nil
        end
    end
    for id,v in pairs(votes) do
        if gone_ripe(id) then
            local best,bc,second=nil,0,0
            for u,c in pairs(v) do if c>bc then best,second,bc=u,bc,c elseif c>second then second=c end end
            if best and bc>=2 and bc>=second+2 and not hidden[best] and not bound[best] then
                local name=owner_of[best]
                if name and hide(best,name) then stats.gone_hidden_vote=(stats.gone_hidden_vote or 0)+1 end
            end
            votes[id]=nil;last_vote[id]=nil;ents[id]=nil;gone_since[id]=nil
        end
    end
end
local function work()
    local fresh=false
    if clock>=list_next then
        list_next=clock+REFRESH
        fresh=refresh_lists()
        check_meshes()
    end
    sample()
    process_spawns()
    process_hits()
    if #deaths>0 then
        local list=deaths;deaths={}
        for _,p in ipairs(list) do
            local u,name,how=match(p)
            if u and not name then u=nil end
            if u then
                hide(u,name)
                stats[how]=(stats[how] or 0)+1
                if not p.name then
                    stats.untyped_match=stats.untyped_match or {}
                    local k=tostring(p.etype)..'->'..short(name);stats.untyped_match[k]=(stats.untyped_match[k] or 0)+1
                end
                if how~='bind' and p.why then
                    stats.why=stats.why or {}
                    stats.why[p.why]=(stats.why[p.why] or 0)+1
                    if p.why=='no_spawn' then
                        stats.nospawn=stats.nospawn or {}
                        local k=short(name);stats.nospawn[k]=(stats.nospawn[k] or 0)+1
                    end
                end
                if p.id then votes[p.id]=nil;last_vote[p.id]=nil;bind[p.id]=nil;ents[p.id]=nil end
                local id=bound[u];if id then bind[id]=nil;bound[u]=nil end
            elseif clock<p.till then
                deaths[#deaths+1]=p
            else
                stats.miss=stats.miss+1
                if p.id then votes[p.id]=nil;last_vote[p.id]=nil;local w=bind[p.id];bind[p.id]=nil;if w then bound[w]=nil end end
            end
        end
    end
    if fresh then gone_pass();attachment_pass() end
end

local function tick(dt)
    if type(dt)=='number' and dt>0 and dt<1 then clock=clock+dt end
    local D=rawget(_G,'HD2Data')
    if type(D)~='table' or type(D.ready)~='function' or not D.ready() then
        if hub then clear_subscriptions();hub=nil;reset() end
        return
    end
    if D~=hub then
        local ok,err=pcall(connect,D)
        if not ok then clear_subscriptions();hub=nil;report(err);return end
    end
    local m=D.mission and D.mission() or nil
    if type(m)~='table' then return end
    if epoch and m.epoch~=epoch then reset(true) end
    epoch=m.epoch
    if not m.in_mission then if in_since then reset() end;return end
    if not in_since then in_since=clock;reset_stats_if_needed() end
    if clock-in_since<SETTLE then deaths={};hits={};return end
    local ok,err=pcall(work)
    if not ok then report('work: '..tostring(err)) end
end

local original_update=rawget(_G,'update')
update=function(dt,...)
    local ok,err=pcall(tick,dt)
    if not ok then report('update: '..tostring(err)) end
    if type(original_update)=='function' then return original_update(dt,...) end
end
local original_shutdown=rawget(_G,'shutdown')
shutdown=function(...)
    clear_subscriptions();hub=nil;reset()
    if type(original_shutdown)=='function' then return original_shutdown(...) end
end
log(VERSION..' loaded')
return {version=VERSION,uses='HD2 Data Hub 0.6.6 + HD2EnemyHull',status='installed'}
