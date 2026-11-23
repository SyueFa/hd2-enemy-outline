-- HD2-Addon: mods/combat/enemy_outline_off
-- 敵人描邊(死亡自動關閉) 1.6
-- 1.6: parts, vehicles, turrets.
--  * Parts (weapons, backpacks, shields, flags, tongues, vehicle guns, unnamed small parts) are
--    linked to their body: over the part's first 5 s the body whose distance stays smallest owns
--    it (the real owner moves with it); hand-held gear is one per body. When a body goes dark,
--    its linked parts and any unlinked part sitting on it go dark in the same frame. Parts with
--    no body of their group within 15 m go dark (1 s grace after they appear).
--  * Impaler tentacles are left alone (they pop up away from the impaler and retract by themselves).
--  * The two machine-gun emplacements are never outlined.
--  * Vehicle guns that stand alone are fixed turrets: they stay lit. The Hub reports fixed turrets
--    (turret_heavycannon, turret_autocannons, tank_turret_heavycannon) with enemy=false; those
--    deaths are now handled, so a destroyed turret goes dark at once. An unclaimed death within
--    6 m of a fixed turret also hides it, and a new turret part appearing where a fixed turret's
--    unit vanished is treated as its wreck.
--  * Vehicles: small parts reach 6 m (a walker's head sits metres above its root). Two body models
--    whose offset stays the same over their first 5 s are one machine (armoured scout walker =
--    walker model + unnamed armour model); one going dark takes the other, and an unowned unnamed
--    vehicle model within 6 m, with it.
--  * Unnamed models ('#ID[<hex>]') are found by scanning World.units and reading each unit's name
--    with tostring (every 3 s while their type was seen in the last 20 s, otherwise every 15 s).
--  * Type learning only body -> body and never infantry for a vehicle type. New type maps:
--    2A12104F2853AE16 / conscript_machinegunner -> conscripts, walker_scout_tier2 -> unnamed
--    walker models + scout walker, fixed turret types -> turret models.
--  * Unit lists refresh every 0.5 s. A hit on an enemy without a spawn record no longer errors.
--  * Learning log at mission end: missed deaths by type, learned types, non-kill deaths of unknown
--    types, what is still lit near a dead vehicle, fixed turret wrecks.
-- 1.5: type -> model learning. The folder-based type map can be wrong (charger_tier2 is not the
--      cha_charger model). When a spawn finds no new unit among its mapped models, it binds to
--      the new outlined body (any model) that appeared at the spawn spot and remembers that
--      model for the type. A typed death with no candidate falls back to any outlined body
--      within 2 m and learns that model too. Learned pairs and missed deaths by type are logged.
--      charger_tier2 (learned in game) now maps to cha_charger_bull.
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
local VERSION = '1.6'
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
local BIND_R = 15.0         -- a bound unit must be within 6 m of the death position
local EARLY_R = 4.0        -- early spawns (before/during settle): unit within 4 m ...
local EARLY_MARGIN = 1.5   -- ... and the next unbound unit of that type 1.5 m further
local OVERRULE = 3         -- hit votes overrule a binding when ahead by this many
local RETRY = 1.5         -- seconds an unmatched death is retried
local REFRESH = 0.5       -- seconds between unit list refreshes / attachment pass

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
    -- models without a known name, looked up by hash
    ['#ID[34dfd23365472e9e]']={m=10,o={9,10},t='34DFD23365472E9E',g={'illuminate'}},
    ['#ID[ee00bfe8ff769f70]']={m=32,o={25,26,27,28,29,30,31,32},t='EE00BFE8FF769F70',g={'cyborg_vehicle','cyborg'}},
    ['#ID[d3cd6f0ca83bb51e]']={m=32,o={25,26,27,28,29,30,31,32},t='D3CD6F0CA83BB51E',g={'cyborg_vehicle','cyborg'}},
    ['#ID[08886d27a6f6db8c]']={m=11,o={10,11},t='08886D27A6F6DB8C',p='any',r=3},
    ['#ID[1338b552afe68f0a]']={m=10,o={9,10},t='1338B552AFE68F0A',p='any',r=3},
    ['#ID[67381f685e9b69a8]']={m=11,o={10,11},t='67381F685E9B69A8',p='any',r=3},
    ['#ID[7ea558204d0ffc29]']={m=2,o={2},t='7EA558204D0FFC29',p='any',r=8},
    ['#ID[8372619b2702d743]']={m=10,o={10},t='8372619B2702D743',p='any',r=3},
    ['#ID[9ab036439f74c115]']={m=10,o={10},t='9AB036439F74C115',p='any',r=3},
    ['#ID[b29af893b9c188a9]']={m=20,o={17,18,19,20},t='B29AF893B9C188A9',p='any',r=5},
    ['#ID[d778e7fdf9eca866]']={m=2,o={2},t='D778E7FDF9ECA866',p='any',r=8},
    ['#ID[e5b14182b25f7f7d]']={m=9,o={8,9},t='E5B14182B25F7F7D',p='any',r=3},
}

-- entity type (Hub) -> outlined model resources it can use (same folder)
local EXTRA_TYPES={
    -- fixed turrets: the Hub marks them enemy=false (no kill credit), so they were dropped before 1.6
    ['2CF3488C4845F8BD']={'content/fac_cyborgs/turrets/cyborg_tank_turret_cannon/cyborg_tank_turret_cannon'},   -- turret_heavycannon (bot cannon turret)
    ['8FB47DD28B398CF7']={'content/fac_cyborgs/turrets/cyborg_tank_turret_cannon/cyborg_tank_turret_cannon'},   -- tank_turret_heavycannon
    ['AEAEF7A1851E6C9D']={'content/fac_cyborgs/turrets/cyborg_tank_turret_autocannons/cyborg_tank_turret_autocannons','content/fac_cyborgs/turrets/cyborg_turret_small_autocannon/cyborg_turret_small_autocannon'},   -- turret_autocannons
    ['2A12104F2853AE16']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},   -- seen in game: dies on cha_conscript
    ['B4ED319B39F5457B']={'content/fac_cyborgs/cha_conscript/cha_conscript','content/fac_cyborgs/cha_conscript/cha_conscript_tier_2'},   -- conscript_machinegunner
    ['9076EEED17FCEE35']={'#ID[d3cd6f0ca83bb51e]','#ID[ee00bfe8ff769f70]','content/fac_cyborgs/vehicles/cyborg_walker_scout/cyborg_walker_scout'},   -- cyborg_walker_scout_tier2
    ['6021E22338333D88']={'content/fac_bugs/cha_boomer_nurser/cha_boomer_nurser'},
    ['A05BD1EC67B3AC4C']={'content/fac_bugs/cha_charger_bull/cha_charger_bull'},   -- charger_tier2: learned in game
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
    ['08E6FFC2474287BD']={'content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff','content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff_fake'},
    ['D63FCBFF0851B7AF']={'content/fac_illuminate/cha_tripod/cha_tripod'},
}
for _,d in pairs(OUTLINE_UNITS) do if d.g then d.g[#d.g+1]='any' end end
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
local WANTS_ID={}
for key,list in pairs(CANDS) do for _,r in ipairs(list) do if r:sub(1,4)=='#ID[' then WANTS_ID[key]=true end end end
local learned_log={}
local function learn(key,res,how)
    if not key or not res or not OUTLINE_UNITS[res] or not OUTLINE_UNITS[res].g then return end
    if OUTLINE_UNITS[key] then return end            -- model keys never learn (a part's death is not a body)
    if not CANDS[key] then CANDS[key]={};IN[key]={} end
    if IN[key][res] then return end
    -- a vehicle type never learns an infantry model (the walker's pilot / a bot standing next to it)
    local function veh(r) local d=OUTLINE_UNITS[r];if d and d.g then for _,g in ipairs(d.g) do if g=='cyborg_vehicle' or g=='warmachine' then return true end end end return false end
    if not veh(res) then for _,c in ipairs(CANDS[key]) do if veh(c) then return end end end
    if CANDS[key][1]==key and #CANDS[key]==1 then CANDS[key]={key} end   -- model keys keep their own list
    CANDS[key][#CANDS[key]+1]=res;IN[key][res]=true
    local tag=tostring(key)..'->'..(res:match('([^/]+)$') or res)
    if not learned_log[tag] then learned_log[tag]=true end
    return tag,how
end

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
local id_next,id_want=0,-1e9   -- unnamed-model scan schedule
local part_of={}           -- part unit -> body unit it belongs to
local part_track={}        -- part unit -> {body unit -> largest squared distance seen in its first 5 s}
local part_final={}        -- part unit -> true once its body is decided
local part_owner={}             -- body unit -> {part resource -> part unit}: one part of each kind per body
local LINK_WINDOW=5
-- vehicle guns: the same model also stands alone as a fixed turret (the bot cannon turret is a tank turret on a base).
-- These go dark only with the vehicle they belong to; a lone one keeps its outline.
local STANDS_ALONE={cyborg_vehicle=true,warmachine=true}
-- parts left alone: impaler tentacles pop up away from their impaler and retract by themselves when it dies
local NO_FOLLOW={impaler=true}
-- vehicles are big: a walker's head/cockpit sits metres above its root, so small parts reach further
local VEH_R=6.0
local function is_vehicle(name) local d=OUTLINE_UNITS[name];if not d or not d.g then return false end
    for _,g in ipairs(d.g) do if STANDS_ALONE[g] then return true end end return false end
local twin_track={}        -- vehicle body -> {other vehicle body -> largest squared distance in its first 5 s}
local twins={}             -- vehicle body -> {other body model of the same machine -> true}
local veh_checks={}        -- learning: lit things around a vehicle 1 s after it went dark
local fixed_pos={}         -- fixed turret unit -> {x,y,z,name}
local wrecks={}            -- spots where a fixed turret unit disappeared: {x,y,z,t}
local orphan_since={}      -- part unit -> clock since no body of its group is within 15 m
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
    if e.enemy~=true and not name then
        -- learning: deaths the Hub does not count as kills (structures, turrets) of types we do not know
        if e.faction and e.faction~='helldivers' and e.faction~='super_earth' then
            stats.nonkill=stats.nonkill or {}
            local k=tostring(e.semantic_id or e.type):gsub('^enemy/v1/','');stats.nonkill[k]=(stats.nonkill[k] or 0)+1
        end
        return
    end
    if name and WANTS_ID[name] then id_want=clock end
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
local function current_epoch_entity(en)
    if type(en)~='table' or type(en.is_valid)~='function' or not hub then return nil end
    local ok,m=pcall(hub.mission)
    if ok and type(m)=='table' and en.epoch~=nil and en.epoch==m.epoch then return en end
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
local function on_spawned(e)
    if type(e)~='table' or e.avatar==true then return end
    local name=type_name(e); local id=e.entity_id
    if name and WANTS_ID[name] then if clock-id_want>=20 then id_next=clock end;id_want=clock end
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
        log('mission types: learned type -> model: '..list(stats.learned))
        log('mission types: missed deaths by type: '..list(stats.missed_types))
        log('mission check: fixed turrets destroyed (death type): '..list(stats.fixed_killed))
        log('mission learn: non-kill deaths of unknown types (ignored): '..list(stats.nonkill))
        log('mission learn: fixed turret units gone='..(stats.fixed_gone or 0)..' | new model on that spot hidden: '..list(stats.wreck_hidden)..' | older lit model still on that spot: '..list(stats.wreck_left))
        log('mission learn: vehicle dark -> still lit within 8 m after 1 s (h=height m, B=bound F=free L=part of): '..list(stats.veh_left)..' | stacked body models hidden together='..(stats.veh_stacked or 0)..' | twin body models paired='..(stats.twin_n or 0)..' hidden together='..(stats.twin_hidden or 0)..' | free unnamed model next to it hidden='..(stats.veh_free or 0))
        log('mission check: unnamed models seen (max at once): '..list(stats.idseen))
        log(string.format('mission check: parts linked to a body=%d hidden with their body=%d (same frame=%d) fixed turrets left lit=%d | hidden near a dead body=%d thrown away (<8 m)=%d no body within 15 m=%d',stats.att_linked_n or 0,stats.att_linked or 0,stats.att_instant or 0,(function() local n=0 for _ in pairs(stats.fixed_seen or {}) do n=n+1 end return n end)(),stats.att_near or 0,stats.att_flung or 0,stats.att_orphan or 0))
        log(string.format('mission check: unnamed-model scans=%d largest World.units=%d',stats.id_scans or 0,stats.id_scan_max or 0))
        log(string.format('mission check: emplacements turned off=%d',stats.emp_off or 0))
        log('mission lit: bound to an enemy the Hub no longer knows (max at once): '..list(stats.sus_gone))
        log('mission lit: not bound, not moving 30 s+ (max at once): '..list(stats.sus_still))
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
    stats=new_stats();spawns=kept;bind={};bound={};first_seen={};last_move={};last_pos={};ents={};gone_since={};emp_shown={};veh_checks={};twin_track={};twins={};fixed_pos={};wrecks={};orphan_since={};part_of={};part_track={};part_final={};part_owner={};id_units={}
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

-- unnamed models: found by name via tostring over World.units
local ID_NAMES={}
for name in pairs(OUTLINE_UNITS) do
    local hx=name:match('^#ID%[(%x+)%]$')
    if hx then ID_NAMES[hx:lower()]=name end
end
local id_units={}          -- '#ID[..]' model -> units found by the last scan
local function id_scan()
    local W=sr.Application.main_world()
    if not W or type(sr.World.units)~='function' then return end
    local ok,all=pcall(sr.World.units,W)
    if not ok or type(all)~='table' then return end
    local found={}
    for _,u in ipairs(all) do
        local ok2,str=pcall(tostring,u)
        if ok2 and type(str)=='string' then
            local hx=str:match('#ID%[(%x+)%]')
            local name=hx and ID_NAMES[hx:lower()]
            if name then local t=found[name];if not t then t={};found[name]=t end;t[#t+1]=u end
        end
    end
    id_units=found
    stats.id_scans=(stats.id_scans or 0)+1
    if #all>(stats.id_scan_max or 0) then stats.id_scan_max=#all end
end
local function units_of(W,name)
    if name:sub(1,4)=='#ID[' then
        local out={}
        for _,u in ipairs(id_units[name] or {}) do
            local ok,alive=pcall(sr.Unit.alive,u)
            if ok and alive then out[#out+1]=u end
        end
        return out
    end
    local ok,list=pcall(sr.World.units_by_resource,W,name)
    return (ok and type(list)=='table') and list or {}
end
local function refresh_lists()
    local W=sr.Application.main_world()
    if not W then return false end
    local seen={}
    if clock>=id_next then
        id_next=clock+((clock-id_want<20) and 3 or 15)
        local ok,err=pcall(id_scan);if not ok then report('id scan: '..tostring(err)) end
    end
    for name in pairs(OUTLINE_UNITS) do
        local list=units_of(W,name)
        lists[name]=list
        for _,u in ipairs(list) do seen[u]=name; if not first_seen[u] then first_seen[u]=clock end end
        if #list>0 and name:sub(1,4)=='#ID[' then
            stats.idseen=stats.idseen or {}
            if (stats.idseen[name] or 0)<#list then stats.idseen[name]=#list end
        end
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
    for u,fp in pairs(fixed_pos) do
        if not seen[u] then
            fixed_pos[u]=nil;stats.fixed_gone=(stats.fixed_gone or 0)+1
            if #wrecks<40 then wrecks[#wrecks+1]={x=fp[1],y=fp[2],z=fp[3],t=clock,n=short(fp[4])} end
        end
    end
    for u in pairs(last_move) do if not seen[u] then last_move[u]=nil;last_pos[u]=nil end end
    for u in pairs(hist) do if not seen[u] then hist[u]=nil end end
    for u in pairs(hidden) do if not seen[u] then hidden[u]=nil end end
    for u in pairs(part_of) do if not seen[u] then part_of[u]=nil end end
    for u in pairs(twin_track) do if not seen[u] then twin_track[u]=nil end end
    for u,t in pairs(twins) do if not seen[u] then twins[u]=nil else for w in pairs(t) do if not seen[w] then t[w]=nil end end end end
    for u in pairs(part_track) do if not seen[u] then part_track[u]=nil end end
    for u in pairs(part_final) do if not seen[u] then part_final[u]=nil end end
    for b,t in pairs(part_owner) do
        if not seen[b] then part_owner[b]=nil else for nm,pu in pairs(t) do if not seen[pu] then t[nm]=nil end end end
    end
    return true
end
local function refresh_one(key)
    local W=sr.Application.main_world()
    if not W then return end
    for _,name in ipairs(CANDS[key] or {key}) do
        local list=units_of(W,name)
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

local hide
function hide(u,name)
    if hidden[u] or not mesh_ok[name] then return false end
    local okA,alive=pcall(sr.Unit.alive,u)
    if not okA or not alive then return false end
    for _,i in ipairs(OUTLINE_UNITS[name].o) do
        local ok,err=pcall(sr.Unit.set_mesh_visibility,u,i,false)
        if not ok then report('set_mesh_visibility: '..tostring(err));return false end
    end
    hidden[u]=true
    -- the other body model of the same machine goes dark with it
    for w in pairs(twins[u] or {}) do
        if not hidden[w] and owner_of[w] and hide(w,owner_of[w]) then stats.twin_hidden=(stats.twin_hidden or 0)+1 end
    end
    -- a body goes dark: every part linked to it goes dark in the same frame
    if OUTLINE_UNITS[name].g then
        for pu,b in pairs(part_of) do
            if b==u and not hidden[pu] and owner_of[pu] and hide(pu,owner_of[pu]) then
                stats.att_linked=(stats.att_linked or 0)+1
                stats.att_instant=(stats.att_instant or 0)+1
            end
        end
        -- parts not linked to anyone, sitting on this body: same frame too
        local bx,by,bz=pos(u)
        local veh=is_vehicle(name)
        if bx and veh then
            -- another body model stacked on the same spot is the same enemy (armour / variant model)
            for bn,bd in pairs(OUTLINE_UNITS) do
                if bd.g and is_vehicle(bn) then
                    for _,w in ipairs(lists[bn] or {}) do
                        if w~=u and not hidden[w] and (not bound[w] or bound[w]==bound[u]) then
                            local x,y,z=pos(w)
                            if x and (x-bx)^2+(y-by)^2<=4.0 and hide(w,bn) then stats.veh_stacked=(stats.veh_stacked or 0)+1 end
                        end
                    end
                end
            end
            -- an unnamed vehicle model nobody owns (no spawn, no pair) right next to it: same machine
            for bn,bd in pairs(OUTLINE_UNITS) do
                if bd.g and bn:sub(1,4)=='#ID[' and is_vehicle(bn) then
                    for _,w in ipairs(lists[bn] or {}) do
                        if w~=u and not hidden[w] and not bound[w] and not next(twins[w] or {}) then
                            local x,y,z=pos(w)
                            if x and (x-bx)^2+(y-by)^2<=36 and math.abs(z-bz)<=4 and hide(w,bn) then stats.veh_free=(stats.veh_free or 0)+1 end
                        end
                    end
                end
            end
            if #veh_checks<50 then veh_checks[#veh_checks+1]={x=bx,y=by,z=bz,t=clock+1,n=short(name)} end
        end
        if bx then
            local mine={};for _,g in ipairs(OUTLINE_UNITS[name].g) do mine[g]=true end
            for pn,d in pairs(OUTLINE_UNITS) do
                if d.p and (mine[d.p] or d.p=='any') and not STANDS_ALONE[d.p] and not NO_FOLLOW[d.p] then
                    for _,pu in ipairs(lists[pn] or {}) do
                        if not hidden[pu] and not part_of[pu] then
                            local x,y,z=pos(pu)
                            local rr=(veh and d.p=='any') and VEH_R or d.r
                            if x and (x-bx)^2+(y-by)^2+(z-bz)^2<=rr*rr and hide(pu,pn) then
                                stats.att_near=(stats.att_near or 0)+1
                                stats.att_instant=(stats.att_instant or 0)+1
                            end
                        end
                    end
                end
            end
        end
    end
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
        if not (b1 and d1<=R*R) and not s.early then
            -- no new unit among the mapped models: any new outlined body at the spawn spot
            local a1,e1,e2=nil,math.huge,math.huge
            for res,d in pairs(OUTLINE_UNITS) do
                if d.g and not IN[s.name][res] then
                    for _,u in ipairs(lists[res] or {}) do
                        if not bound[u] and not hidden[u] and (first_seen[u] or 0)>=s.t-BORN_SLACK then
                            local dd=dist2_at(u,s,s.t)
                            if dd then if dd<e1 then a1,e2,e1=u,e1,dd elseif dd<e2 then e2=dd end end
                        end
                    end
                end
            end
            if a1 and e1<=SPAWN_R*SPAWN_R and math.sqrt(math.min(e2,d1))-math.sqrt(e1)>=SPAWN_MARGIN then
                local tag=learn(s.name,owner_of[a1],'spawn')
                if tag then stats.learned=stats.learned or {};stats.learned[tag]=(stats.learned[tag] or 0)+1 end
                b1,d1,d2=a1,e1,math.huge
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
        if not b then
            -- none of the mapped models exists: any outlined body within 2 m, and learn it
            local bu,bd=nil,4.0
            for res,d in pairs(OUTLINE_UNITS) do
                if d.g then
                    local u,dd=rank(res,p,p.t)
                    if u and dd<bd then bu,bd=u,dd end
                end
            end
            if bu then
                local tag=learn(p.name,owner_of[bu],'death')
                if tag then stats.learned=stats.learned or {};stats.learned[tag]=(stats.learned[tag] or 0)+1 end
                return bu,owner_of[bu],'pos'
            end
        end
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
                    local b={x,y,z,hidden[u]==true,u,is_vehicle(name)}
                    for _,g in ipairs(d.g) do
                        local t=bodies[g];if not t then t={};bodies[g]=t end
                        t[#t+1]=b
                    end
                end
            end
        end
    end
    -- two body models that move together for their first 5 s are one machine (armoured walker = walker + armour model)
    local vb={}
    for name,d in pairs(OUTLINE_UNITS) do
        if d.g and is_vehicle(name) then
            for _,u in ipairs(lists[name] or {}) do
                local x,y,z=pos(u);if x then vb[#vb+1]={u,name,x,y,z} end
            end
        end
    end
    for _,a in ipairs(vb) do
        local u=a[1];local age=clock-(first_seen[u] or clock)
        local tr=twin_track[u]
        if age<=LINK_WINDOW then
            if not tr then tr={};twin_track[u]=tr end
            for _,b in ipairs(vb) do
                -- only with an unnamed (armour / variant) model, so a dropship carrying a tank is never paired
                if b[1]~=u and b[2]~=a[2] and (a[2]:sub(1,4)=='#ID[' or b[2]:sub(1,4)=='#ID[') then
                    local ox,oy,oz=b[3]-a[3],b[4]-a[4],b[5]-a[5]
                    local t=tr[b[1]]
                    if t then
                        -- same machine: the offset between the two models stays the same
                        local dev=(ox-t.ox)^2+(oy-t.oy)^2+(oz-t.oz)^2
                        if dev>t.dev then t.dev=dev end
                        local mv=(a[3]-t.ax)^2+(a[4]-t.ay)^2
                        if mv>t.mv then t.mv=mv end
                    elseif ox*ox+oy*oy+oz*oz<=36 then
                        tr[b[1]]={ox=ox,oy=oy,oz=oz,d0=ox*ox+oy*oy+oz*oz,dev=0,mv=0,ax=a[3],ay=a[4]}
                    end
                end
            end
        elseif tr then
            for w,t in pairs(tr) do
                -- offset steady within 0.7 m, and either they moved together or sit within 3 m of each other
                if t.dev<=0.49 and (t.mv>=2.25 or t.d0<=9) then
                    twins[u]=twins[u] or {};twins[u][w]=true
                    twins[w]=twins[w] or {};twins[w][u]=true
                    stats.twin_n=(stats.twin_n or 0)+1
                end
            end
            twin_track[u]=nil
        end
    end
    for name,d in pairs(OUTLINE_UNITS) do
        local group=d.p and not NO_FOLLOW[d.p] and (bodies[d.p] or {})
        if group and mesh_ok[name] then
            local r2=d.r*d.r
            for _,u in ipairs(lists[name] or {}) do
                if not hidden[u] then
                    local x,y,z=pos(u)
                    if x then
                        local best,bd=nil,math.huge
                        for _,b in ipairs(group) do
                            local d2=(b[1]-x)^2+(b[2]-y)^2+(b[3]-z)^2
                            if d2<bd then best,bd=b,d2 end
                        end
                        -- one piece with its body: link when first seen (nearest live body within r),
                        -- then the part goes dark together with that body
                        -- the real owner moves with the part, so over the first 5 s its distance stays smallest;
                        -- a neighbour that happened to stand closer at spawn drifts away
                        if not part_final[u] then
                            local age=clock-(first_seen[u] or clock)
                            local tr=part_track[u]
                            if age<=LINK_WINDOW then
                                if not tr then tr={};part_track[u]=tr end
                                for _,b in ipairs(group) do
                                    local d2=(b[1]-x)^2+(b[2]-y)^2+(b[3]-z)^2
                                    local old=tr[b[5]]
                                    if old then if d2>old then tr[b[5]]=d2 end
                                    elseif (d2<=r2 or (b[6] and d.p=='any' and d2<=VEH_R*VEH_R)) and not b[4] then tr[b[5]]=d2 end
                                end
                            end
                            if tr then
                                local pick,pd=nil,math.huge
                                for bu,v in pairs(tr) do
                                    -- one per body only for hand-held gear (r<=3); tentacles, vehicle guns etc. can be several
                                    local o=d.r<=3 and part_owner[bu] and part_owner[bu][name]
                                    if v<pd and (not o or o==u) then pick,pd=bu,v end
                                end
                                part_of[u]=pick
                                if age>LINK_WINDOW then
                                    part_final[u]=true;part_track[u]=nil
                                    if pick then
                                        part_owner[pick]=part_owner[pick] or {};part_owner[pick][name]=u
                                        stats.att_linked_n=(stats.att_linked_n or 0)+1
                                    end
                                end
                            end
                        end
                        local pb=part_of[u]
                        if pb and (hidden[pb] or not owner_of[pb]) then
                            if hide(u,name) then stats.att_linked=(stats.att_linked or 0)+1 end
                        end
                        if hidden[u] or STANDS_ALONE[d.p] then
                            -- vehicle guns follow only their own vehicle; a lone one is a fixed turret and stays lit
                            if not hidden[u] and part_final[u] and not pb then stats.fixed_seen=stats.fixed_seen or {};stats.fixed_seen[u]=true;fixed_pos[u]={x,y,z,name} end
                        elseif bd>225 and clock-(first_seen[u] or clock)>=1 then
                            -- no body of its group within 15 m: dark right away
                            -- (only skip parts seen < 1 s, so a part that spawns a moment before its body is not hit)
                            if hide(u,name) then stats.att_orphan=(stats.att_orphan or 0)+1 end
                        elseif best and best[4] then
                            if bd<=r2 then
                                if hide(u,name) then stats.att_near=(stats.att_near or 0)+1 end
                            elseif bd<=64 then
                                if hide(u,name) then stats.att_flung=(stats.att_flung or 0)+1 end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- emplacements: outline only while manned
local MANNED_R = 2.0
local EMPLACEMENTS={
    ['content/fac_cyborgs/emplacements/cyborg_emplacement_hmg/cyborg_emplacement_hmg']=true,
    ['content/fac_cyborgs/emplacements/cyborg_emplacement_mg/cyborg_emplacement_mg']=true,
}
local emp_shown={}         -- unit -> true/false: current outline state set by the manned pass
local function set_outline(u,name,on)
    if not mesh_ok[name] then return false end
    local okA,alive=pcall(sr.Unit.alive,u)
    if not okA or not alive then return false end
    for _,i in ipairs(OUTLINE_UNITS[name].o) do
        local ok,err=pcall(sr.Unit.set_mesh_visibility,u,i,on)
        if not ok then report('set_mesh_visibility: '..tostring(err));return false end
    end
    return true
end
local function manned_pass()
    local ops={}
    for name,d in pairs(OUTLINE_UNITS) do
        if d.g and not EMPLACEMENTS[name] and name:find('fac_cyborgs/cha_',1,true) then
            for _,u in ipairs(lists[name] or {}) do
                if not hidden[u] then
                    local x,y,z=pos(u)
                    if x then ops[#ops+1]={x,y,z} end
                end
            end
        end
    end
    for name in pairs(EMPLACEMENTS) do
        if mesh_ok[name] then
            for _,u in ipairs(lists[name] or {}) do
                if not hidden[u] then
                    local x,y,z=pos(u)
                    if x then
                        local bd=math.huge
                        for _,o in ipairs(ops) do
                            local d2=(o[1]-x)^2+(o[2]-y)^2+(o[3]-z)^2
                            if d2<bd then bd=d2 end
                        end
                        local d=math.sqrt(bd)
                        local b=d<1 and '<1m' or d<2 and '1-2m' or d<3 and '2-3m' or d<5 and '3-5m' or '5m+'
                        stats.emp_dist=stats.emp_dist or {}
                        stats.emp_dist[b]=(stats.emp_dist[b] or 0)+1
                        local on=false   -- emplacements are never outlined
                        if emp_shown[u]~=on and set_outline(u,name,on) then
                            emp_shown[u]=on
                            if on then stats.emp_on=(stats.emp_on or 0)+1 else stats.emp_off=(stats.emp_off or 0)+1 end
                        end
                    end
                end
            end
        end
    end
    for u in pairs(emp_shown) do if not owner_of[u] then emp_shown[u]=nil end end
end
local snap_next=0
local function suspicious_snapshot()
    local gone,still={},{}
    for name,d in pairs(OUTLINE_UNITS) do
        if mesh_ok[name] and not EMPLACEMENTS[name] then
            local k=(name:match('([^/]+)$') or name)..(d.p and '(part)' or '')
            local g,st=0,0
            for _,u in ipairs(lists[name] or {}) do
                if not hidden[u] then
                    local id=bound[u]
                    if id then
                        local en=ents[id]
                        if en then local ok,v=pcall(en.is_valid,en); if ok and v==false then g=g+1 end end
                    elseif last_move[u] and clock-last_move[u]>30 then
                        st=st+1
                    end
                end
            end
            if g>0 then gone[k]=g end
            if st>0 then still[k]=st end
        end
    end
    stats.sus_gone=stats.sus_gone or {}; stats.sus_still=stats.sus_still or {}
    for k,v in pairs(gone) do if v>(stats.sus_gone[k] or 0) then stats.sus_gone[k]=v end end
    for k,v in pairs(still) do if v>(stats.sus_still[k] or 0) then stats.sus_still[k]=v end end
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
-- a death nobody claimed, right on a fixed turret: that turret was destroyed
local FIXED_R=6.0
local function fixed_turret_at(p)
    if not p.x then return nil end
    local best,bd,bn=nil,FIXED_R*FIXED_R,nil
    for u in pairs(stats.fixed_seen or {}) do
        if not hidden[u] and owner_of[u] then
            local x,y,z=pos(u)
            if x then
                local d2=(x-p.x)^2+(y-p.y)^2+(z-(p.z or z))^2
                if d2<bd then best,bd,bn=u,d2,owner_of[u] end
            end
        end
    end
    return best,bn
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
            if not u and not p.tried then
                -- nothing claims it on the first try and a fixed turret stands right there: dark now, no retry wait
                p.tried=true
                local fu,fn=fixed_turret_at(p)
                if fu then u,name,how=fu,fn,'fixed' end
            end
            if u then
                hide(u,name)
                stats[how]=(stats[how] or 0)+1
                if how=='fixed' then
                    stats.fixed_killed=stats.fixed_killed or {}
                    local k=tostring(p.etype);stats.fixed_killed[k]=(stats.fixed_killed[k] or 0)+1
                end
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
            elseif (function()
                    local fu,fn=fixed_turret_at(p)
                    if fu and hide(fu,fn) then
                        stats.fixed_killed=stats.fixed_killed or {}
                        local k=tostring(p.etype);stats.fixed_killed[k]=(stats.fixed_killed[k] or 0)+1
                        if p.id then votes[p.id]=nil;last_vote[p.id]=nil;bind[p.id]=nil;ents[p.id]=nil end
                        return true
                    end
                end)() then
            else
                stats.miss=stats.miss+1
                stats.missed_types=stats.missed_types or {}
                local k=p.name and (p.name:match('([^/]+)$') or p.name) or ('untyped:'..tostring(p.etype))
                stats.missed_types[k]=(stats.missed_types[k] or 0)+1
                if p.id then votes[p.id]=nil;last_vote[p.id]=nil;local w=bind[p.id];bind[p.id]=nil;if w then bound[w]=nil end end
            end
        end
    end
    if fresh then gone_pass();attachment_pass();manned_pass() end
    if fresh and #wrecks>0 then
        -- a fixed turret's unit went away: whatever lit model shows up on that spot is its wreck
        local keep={}
        for _,w in ipairs(wrecks) do
            for nm,d in pairs(OUTLINE_UNITS) do
                -- only part models (turret pieces); never an enemy that happens to walk onto the spot
                for _,v in ipairs(d.p and lists[nm] or {}) do
                    if not hidden[v] and not bound[v] then
                        local x,y,z=pos(v)
                        if x and (x-w.x)^2+(y-w.y)^2<=6.25 then
                            local new=(first_seen[v] or 0)>=w.t-1
                            if new and hide(v,nm) then
                                stats.wreck_hidden=stats.wreck_hidden or {};local k=w.n..'>'..short(nm);stats.wreck_hidden[k]=(stats.wreck_hidden[k] or 0)+1
                            elseif not new and clock-w.t>=2 and not w.logged then
                                stats.wreck_left=stats.wreck_left or {};local k=w.n..'>'..short(nm);stats.wreck_left[k]=(stats.wreck_left[k] or 0)+1
                            end
                        end
                    end
                end
            end
            if clock-w.t>=2 then w.logged=true end
            if clock-w.t<15 then keep[#keep+1]=w end
        end
        wrecks=keep
    end
    if #veh_checks>0 and veh_checks[1].t<=clock then
        local c=table.remove(veh_checks,1)
        for nm,d in pairs(OUTLINE_UNITS) do
            if not EMPLACEMENTS[nm] then
                for _,w in ipairs(lists[nm] or {}) do
                    if not hidden[w] then
                        local x,y,z=pos(w)
                        if x and (x-c.x)^2+(y-c.y)^2<=64 then
                            stats.veh_left=stats.veh_left or {}
                            -- B=bound to a spawn, L:<model>=part of that lit body, F=free
                            local tag=bound[w] and 'B' or (part_of[w] and ('L:'..short(owner_of[part_of[w]] or '?'))) or 'F'
                            local k=c.n..'>'..short(nm)..string.format('(h%+.0f,%s)',z-c.z,tag)
                            stats.veh_left[k]=(stats.veh_left[k] or 0)+1
                        end
                    end
                end
            end
        end
    end
    if clock>=snap_next then snap_next=clock+30;local ok,err=pcall(suspicious_snapshot);if not ok then report('snapshot: '..tostring(err)) end end
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
