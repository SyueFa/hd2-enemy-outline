-- HD2-Addon: mods/combat/enemy_outline_off
-- 敵人描邊(死亡自動關閉) 1.3
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
local VERSION = '1.3'
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

local TYPE={}
for name,d in pairs(OUTLINE_UNITS) do TYPE[d.t]=name end

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
    if type(e)~='table' or e.avatar==true or not in_since then return end
    local name=type_name(e)
    if e.enemy~=true and not name then return end
    local p=event_position(e.position)
    if not p and type(e.entity)=='table' and type(e.entity.position)=='function' then
        local ok,v=pcall(e.entity.position,e.entity);if ok then p=event_position(v) end
    end
    if p then
        deaths[#deaths+1]={x=p.x,y=p.y,z=p.z,name=name,id=e.entity_id,t=event_time(e),till=clock+RETRY}
    end
end
local function on_damaged(e)
    if type(e)~='table' or e.avatar==true or not in_since then return end
    local id=e.entity_id
    local name=type_name(e)
    if not name or type(id)~='number' then return end
    if last_vote[id] and clock-last_vote[id]<HIT_GAP then return end
    local p=type(e.entity)=='table' and event_position(e.entity.pos)
    if not p then return end
    last_vote[id]=clock
    if #hits<200 then hits[#hits+1]={x=p.x,y=p.y,z=p.z,name=name,id=id,t=event_time(e)} end
end
local function reset()
    lists={};owner_of={};hidden={};hist={};deaths={};hits={};votes={};last_vote={};in_since=nil
end
local function clear_subscriptions()
    for _,s in pairs(subs) do if s and type(s.unsubscribe)=='function' then pcall(s.unsubscribe,s) end end
    subs={}
end
local function connect(D)
    clear_subscriptions()
    hub=D
    for ev,fn in pairs({entity_died=on_died,entity_damaged=on_damaged,mission_started=reset,mission_ended=reset}) do
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
        for _,u in ipairs(list) do seen[u]=name end
    end
    owner_of=seen
    for u in pairs(hist) do if not seen[u] then hist[u]=nil end end
    for u in pairs(hidden) do if not seen[u] then hidden[u]=nil end end
    return true
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
    for _,u in ipairs(lists[name] or {}) do
        if not hidden[u] then
            local d=dist2_at(u,p,t)
            if d then
                if d<d1 then b1,d2,d1=u,d1,d elseif d<d2 then d2=d end
            end
        end
    end
    return b1,d1,d2
end

local function hide(u,name)
    if hidden[u] or not mesh_ok[name] then return false end
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
        end
    end
end
local function voted(id,name,p,t)
    local v=id and votes[id]
    if not v then return nil end
    local best,bc=nil,0
    for u,c in pairs(v) do
        if c>bc and not hidden[u] and owner_of[u]==name then best,bc=u,c end
    end
    if best then
        local d=dist2_at(best,p,t)
        if d and d<=VOTE_R*VOTE_R then return best end
    end
end
local function match(p)
    if p.name then
        local u=voted(p.id,p.name,p,p.t)
        if u then return u,p.name end
        local b,d1,d2=rank(p.name,p,p.t)
        if b and d1<=TYPED_R*TYPED_R then return b,p.name end
        -- a lone unit of that type a bit further out (big bodies) is still unambiguous
        if b and d1<=LONE_R*LONE_R and math.sqrt(d2)-math.sqrt(d1)>=LONE_MARGIN then return b,p.name end
        return nil
    end
    local bu,bd,bn=nil,ANY_R*ANY_R,nil
    for name,d in pairs(OUTLINE_UNITS) do
        if d.g then
            local u,d1=rank(name,p,p.t)
            if u and d1<bd then bu,bd,bn=u,d1,name end
        end
    end
    return bu,bn
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

local function work()
    local fresh=false
    if clock>=list_next then
        list_next=clock+REFRESH
        fresh=refresh_lists()
        check_meshes()
    end
    sample()
    process_hits()
    if #deaths>0 then
        local list=deaths;deaths={}
        for _,p in ipairs(list) do
            local u,name=match(p)
            if u then
                hide(u,name)
                if p.id then votes[p.id]=nil;last_vote[p.id]=nil end
            elseif clock<p.till then
                deaths[#deaths+1]=p
            elseif p.id then
                votes[p.id]=nil;last_vote[p.id]=nil
            end
        end
    end
    if fresh then attachment_pass() end
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
    if epoch and m.epoch~=epoch then reset() end
    epoch=m.epoch
    if not m.in_mission then if in_since then reset() end;return end
    if not in_since then in_since=clock end
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
