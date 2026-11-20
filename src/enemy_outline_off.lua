-- HD2-Addon: mods/combat/enemy_outline_off
-- Enemy Outline Off: hides the HD2EnemyHull outline of an enemy when it dies.
-- Needs MDL3 + stock HD2 Data Hub 0.6.6 + HD2EnemyHull (outline models).
--
-- How: the Hub reports each death with its position. Among the outlined enemy
-- units (looked up by resource name only - never a full unit scan), the one
-- within 1 m of that position is the dead enemy; if its mesh count matches the
-- HD2EnemyHull resource table, its outline meshes are hidden.
-- No drawing, no camera, no raycasts.

local OWNER = 'mods/combat/enemy_outline_off'
local VERSION = '1.0'
local sr = rawget(_G, 'stingray')
if type(sr) ~= 'table' then return {version=VERSION, error='no stingray'} end

local SETTLE = 3          -- seconds after the mission starts before touching units
local RADIUS2 = 1.0       -- match radius squared (1 m)
local REFRESH = 1         -- seconds between unit list refreshes

-- resource name -> {m = mesh count, o = outline mesh indices (1-based)}
-- (parsed from HD2EnemyHull 0.0.22 unit resources)
local OUTLINE_UNITS={
    ['content/env_illuminate/gameplay/il_turret_01']={m=40,o={17,18,19,20,37,38,39,40}},
    ['content/env_illuminate/gameplay/il_turret_tactical_obj']={m=40,o={17,18,19,20,37,38,39,40}},
    ['content/fac_bugs/cha_boomer/cha_boomer']={m=11,o={10,11}},
    ['content/fac_bugs/cha_boomer/cha_boomer_tier_2']={m=31,o={30,31}},
    ['content/fac_bugs/cha_boomer_burrower/cha_boomer_burrower']={m=31,o={30,31}},
    ['content/fac_bugs/cha_boomer_defiler/cha_boomer_defiler']={m=11,o={10,11}},
    ['content/fac_bugs/cha_boomer_nurser/cha_boomer_nurser']={m=31,o={30,31}},
    ['content/fac_bugs/cha_charger/cha_charger']={m=12,o={10,11,12}},
    ['content/fac_bugs/cha_charger_acid/cha_charger_acid']={m=11,o={10,11}},
    ['content/fac_bugs/cha_charger_bull/cha_charger_bull']={m=11,o={10,11}},
    ['content/fac_bugs/cha_charger_burrower/cha_charger_burrower']={m=11,o={10,11}},
    ['content/fac_bugs/cha_dragon/cha_dragon']={m=24,o={11,12,23,24}},
    ['content/fac_bugs/cha_hive_lord/cha_hive_lord']={m=52,o={43,44,45,46,47,48,49,50,51,52}},
    ['content/fac_bugs/cha_hunter/cha_hunter']={m=34,o={33,34}},
    ['content/fac_bugs/cha_hunter/cha_hunter_tier3']={m=22,o={10,11,21,22}},
    ['content/fac_bugs/cha_impaler/cha_impaler']={m=11,o={10,11}},
    ['content/fac_bugs/cha_scavenger/cha_scavenger']={m=33,o={32,33}},
    ['content/fac_bugs/cha_scavenger/cha_scavenger_gloom']={m=35,o={33,34,35}},
    ['content/fac_bugs/cha_scavenger_defiler/cha_scavenger_defiler']={m=33,o={32,33}},
    ['content/fac_bugs/cha_scavenger_predator/cha_scavenger_predator']={m=33,o={32,33}},
    ['content/fac_bugs/cha_scavenger_spitter/cha_scavenger_spitter']={m=33,o={32,33}},
    ['content/fac_bugs/cha_shrieker/cha_shrieker']={m=16,o={14,15,16}},
    ['content/fac_bugs/cha_stalker/cha_stalker']={m=36,o={35,36}},
    ['content/fac_bugs/cha_strider/cha_strider']={m=31,o={31}},
    ['content/fac_bugs/cha_strider/cha_strider_gloom']={m=32,o={31,32}},
    ['content/fac_bugs/cha_warrior/cha_warrior']={m=29,o={28,29}},
    ['content/fac_bugs/cha_warrior/cha_warrior_tier_1']={m=29,o={28,29}},
    ['content/fac_bugs/cha_warrior_acid/cha_warrior_acid']={m=29,o={28,29}},
    ['content/fac_bugs/cha_warrior_big/cha_warrior_big']={m=29,o={28,29}},
    ['content/fac_bugs/cha_warrior_big/cha_warrior_big_tier2']={m=29,o={28,29}},
    ['content/fac_bugs/cha_warrior_burrower/cha_warrior_burrower']={m=11,o={10,11}},
    ['content/fac_bugs/cha_warrior_plus/cha_warrior_plus']={m=29,o={28,29}},
    ['content/fac_cyborgs/cha_berserker/cha_berserker']={m=33,o={30,31,32,33}},
    ['content/fac_cyborgs/cha_conscript/cha_conscript']={m=27,o={27}},
    ['content/fac_cyborgs/cha_conscript/cha_conscript_tier_2']={m=28,o={27,28}},
    ['content/fac_cyborgs/cha_conscript_commander/cha_conscript_commander']={m=27,o={27}},
    ['content/fac_cyborgs/cha_lieutenant_assault/cha_lieutenant_assault']={m=20,o={9,10,19,20}},
    ['content/fac_cyborgs/cha_soldier/cha_soldier']={m=33,o={30,31,32,33}},
    ['content/fac_cyborgs/cha_soldier/cha_soldier_rocket']={m=31,o={30,31}},
    ['content/fac_cyborgs/emplacements/cyborg_emplacement_hmg/cyborg_emplacement_hmg']={m=21,o={18,19,20,21}},
    ['content/fac_cyborgs/emplacements/cyborg_emplacement_mg/cyborg_emplacement_mg']={m=7,o={7}},
    ['content/fac_cyborgs/turrets/cyborg_turret_small_autocannon/cyborg_turret_small_autocannon']={m=2,o={2}},
    ['content/fac_illuminate/cha_beamer_champion/cha_beamer_champion']={m=20,o={17,18,19,20}},
    ['content/fac_illuminate/cha_bodyhorror_bladed/cha_bodyhorror_bladed']={m=20,o={19,20}},
    ['content/fac_illuminate/cha_bodyhorror_helmetguy/cha_bodyhorror_helmetguy']={m=16,o={16}},
    ['content/fac_illuminate/cha_corrupted/cha_corrupted']={m=20,o={19,20}},
    ['content/fac_illuminate/cha_exomech_melee/cha_exomech_melee']={m=71,o={70,71}},
    ['content/fac_illuminate/cha_exomech_ranged/cha_exomech_ranged']={m=51,o={50,51}},
    ['content/fac_illuminate/cha_illuminate_guy_staff/cha_illuminate_guy_staff']={m=18,o={17,18}},
    ['content/fac_illuminate/cha_jet_champion/cha_jet_champion']={m=36,o={17,18,35,36}},
    ['content/fac_illuminate/cha_meatglue/cha_meatglue']={m=2,o={1,2}},
    ['content/fac_illuminate/cha_observer/cha_observer']={m=10,o={9,10}},
    ['content/fac_illuminate/cha_tripod/cha_tripod']={m=22,o={21,22}},
}

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
local lists={}            -- resource name -> units
local list_next=0
local mesh_ok={}          -- resource name -> true / false after the first check
local hidden={}           -- unit -> true
local deaths={}           -- pending death positions

local function death_position(e)
    local p=e.position
    if type(p)~='table' and type(e.entity)=='table' and type(e.entity.position)=='function' then
        local ok,v=pcall(e.entity.position,e.entity);if ok then p=v end
    end
    if type(p)=='table' and finite(p.x) and finite(p.y) and finite(p.z) then return {x=p.x,y=p.y,z=p.z} end
end
local function on_died(e)
    if type(e)~='table' or e.avatar==true or e.enemy~=true then return end
    local p=death_position(e)
    if p and in_since then deaths[#deaths+1]=p end
end
local function reset()
    lists={};hidden={};deaths={};in_since=nil
end
local function clear_subscriptions()
    for _,s in pairs(subs) do if s and type(s.unsubscribe)=='function' then pcall(s.unsubscribe,s) end end
    subs={}
end
local function connect(D)
    clear_subscriptions()
    hub=D
    for ev,fn in pairs({entity_died=on_died,mission_started=reset,mission_ended=reset}) do
        local s=D.on(ev,function(e) local ok,err=pcall(fn,e);if not ok then report(ev..': '..tostring(err)) end end,
            {owner=OWNER,id=ev})
        if not s then error('subscription unavailable: '..ev) end
        subs[ev]=s
    end
    log('connected to HD2 Data Hub '..tostring(D.version))
end

local function refresh_lists(now)
    if now<list_next then return end
    list_next=now+REFRESH
    local W=sr.Application.main_world()
    if not W then return end
    for name in pairs(OUTLINE_UNITS) do
        local ok,list=pcall(sr.World.units_by_resource,W,name)
        lists[name]=(ok and type(list)=='table') and list or {}
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
local function nearest(p)
    local best,bd,bn=nil,RADIUS2,nil
    for name,list in pairs(lists) do
        for _,u in ipairs(list) do
            if not hidden[u] then
                local ok,x,y,z=pcall(function()
                    if not sr.Unit.alive(u) then return nil end
                    return v3(sr.Unit.world_position(u,1))
                end)
                if ok and finite(x) then
                    local d2=(x-p.x)^2+(y-p.y)^2+(z-p.z)^2
                    if d2<bd then best,bd,bn=u,d2,name end
                end
            end
        end
    end
    return best,bn
end
local function hide(u,name)
    if not mesh_ok[name] then return end
    for _,i in ipairs(OUTLINE_UNITS[name].o) do
        local ok,err=pcall(sr.Unit.set_mesh_visibility,u,i,false)
        if not ok then report('set_mesh_visibility: '..tostring(err));return end
    end
    hidden[u]=true
end
local function work(now)
    refresh_lists(now)
    check_meshes()
    if #deaths>0 then
        local list=deaths;deaths={}
        for _,p in ipairs(list) do
            local u,name=nearest(p)
            if u then hide(u,name) end
        end
    end
end

local function tick()
    local now=os.clock()
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
    if not in_since then in_since=now end
    if now-in_since<SETTLE then deaths={};return end
    local ok,err=pcall(work,now)
    if not ok then report('work: '..tostring(err)) end
end

local original_update=rawget(_G,'update')
update=function(dt,...)
    local ok,err=pcall(tick)
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
