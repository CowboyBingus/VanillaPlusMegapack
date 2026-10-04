local source = assert(arg[1])
local install = assert(loadfile(source..'/install.lua'))()
local model = assert(loadfile(source..'/model.lua'))()
local roster = assert(loadfile(source..'/roster.lua'))()
local roster_data = assert(loadfile(source..'/roster_data.lua'))()
local text = assert(loadfile(source..'/bingus_text.lua'))()
local english = assert(loadfile(source..'/../locales/en.lua'))()
local FOOTER = english.strings['panel.footer']
-- Count roster computations: repeated samples of one mission must reuse it.
local computations,compute = 0,roster.compute
roster.compute = function(...) computations=computations+1 return compute(...) end
local screen,key,valid = nil,'first',true
local ready,complete,matches = true,true,true
local draws,clears,suspends,previous_calls,samples = 0,0,0,0,0
local visible,on_sample,frame_visible,pending_anchor
local descriptor_pending,sample_pending,client,active = false,false,false,true
local hovered
local tags,difficulty = {1},10
local published = {}
local source_object = {}
function source_object:screen() return screen end
function source_object:descriptor()
    assert(valid,'Unavailable')
    if descriptor_pending then return nil,hovered end
    return {key=key,screen=screen,controller_matches=matches},hovered
end
function source_object:sample()
    samples=samples+1
    local snapshot={key=key,screen=screen,tags=tags,difficulty=difficulty,faction=2,
        complete=complete,controller_matches=matches}
    if on_sample then on_sample(snapshot) end
    if sample_pending then return nil end
    return snapshot
end
local surface = {}
function surface:show(m)
    draws=draws+1
    visible=m
    frame_visible=true
    published[#published+1]=m
    return true
end
function surface:clear() clears=clears+1 visible=nil frame_visible=false end
function surface:suspend(anchor)
    pending_anchor=anchor
    suspends=suspends+1
    visible=nil
end
local env = setmetatable({stingray={Gui={},World={}},print=function() end,os={},io=io}, {__index=_G})
env._G = env
env.update = function(dt,marker) previous_calls=previous_calls+1 return 1,nil,marker end
local function api()
    return {module=function() return 1 end}
end
setfenv(install,env)({create_api=api,mission={new=function() return source_object end},resolve={},roster=roster,
    roster_data=roster_data,model=model,panel={new=function() return surface end},
    presentation={new=function() return {sample=function() return ready and {client=client,active=active} or nil end} end},
    text=text,locales={en=english,bundled={}},runtime=assert(loadfile(source..'/bingus_runtime.lua'))(),
    runtime_memory={new=function() return {verify_build=function() return true end} end},
    build={revision='test',game_sha256='same',exe_sha256='same'}})
local a,b,c = env.update(0.1,'marker')
assert(a==1 and b==nil and c=='marker' and draws==0)
screen='map'
env.update(0.1,'marker')
assert(draws==1)
local hover_clears=clears
key='second'
env.update(0.1,'marker')
assert(env.EnemyIntelligence.key=='second')
assert(clears==hover_clears,'Changing highlighted missions must not clear the scroll position')
screen='briefing'
env.update(0.1,'marker')
assert(env.EnemyIntelligence.screen=='briefing')
assert(clears==hover_clears+1,'Changing screens must still reset the strip')
ready=false
local hidden_draws=draws
env.update(0.1,'marker')
assert(draws==hidden_draws and env.EnemyIntelligence.status=='hidden','Loadout or pod entry remained visible')
ready=true
env.update(0.1,'marker')
assert(draws==hidden_draws+1,'Returning to briefing did not restore the panel')
valid=false
env.update(0.1,'marker')
assert(env.EnemyIntelligence.status:find('hidden') and env.EnemyIntelligence.failures==1)
valid=true
screen=nil
local before=draws
env.update(0.1,'marker')
assert(draws==before and clears>=5 and previous_calls==8)

-- Pending data never publishes; the report appears only once complete.
screen,key,complete,matches='map','rapid',false,true
env.update(.001)
assert(not visible,'A pending snapshot must not publish its preliminary sections or footer')
assert(pending_anchor,'Pending presentation requires the current native panel anchor')
local pending_samples=samples
for _=1,9 do env.update(.01) end
assert(samples==pending_samples,'Pending reads must not run every frame')
env.update(.011)
assert(samples==pending_samples+1 and not visible,'Pending data must retry after 100 ms without showing a base report')
complete=true
env.update(.101)
assert(visible and visible.key=='rapid' and #visible.large>0 and visible.headline=='BILE BUGS')
assert(visible.footer=='Possible encounters. Spawns are not guaranteed.')
local resolved_samples,resolved_computations=samples,computations
for _=1,4 do env.update(.1) end
assert(samples==resolved_samples,'Resolved reports must retain the slower refresh cadence')
env.update(.101)
assert(samples==resolved_samples+1)
for _=1,6 do env.update(.501) end
assert(samples>=resolved_samples+6 and computations==resolved_computations,
    'Refreshing an unchanged mission must reuse its roster')

local rapid_clears=clears
for _,next_key in ipairs({'other','rapid','other','rapid'}) do
    key,matches=next_key,false
    local before_samples=samples
    env.update(.001)
    assert(not visible and not env.EnemyIntelligence.complete,'Previous mission intel remained visible while switching')
    assert(frame_visible,'Rapid switching must retain the forecast frame while enemy intel resolves')
    assert(samples==before_samples,'A mismatched controller must not trigger an expensive full read')
end
assert(clears==rapid_clears,'Waiting for mission data must preserve the scroll position')
matches=true
env.update(.001)
assert(visible and visible.key=='rapid','Controller catch-up must publish immediately without waiting 500 ms')

-- Readiness can also be lost without changing the highlighted key.
matches=false
env.update(.001)
assert(not visible,'Loss of controller readiness must hide the previous report immediately')
matches,complete=true,false
env.update(.001)
assert(not visible,'Matched identity alone cannot authorize an incomplete snapshot')
complete=true
env.update(.101)
assert(visible and #visible.large>0 and clears==rapid_clears)
complete=false
env.update(.501)
assert(not visible,'An incomplete refresh must hide rather than replace the complete report')
complete=true
env.update(.101)
assert(visible and visible.footer=='Possible encounters. Spawns are not guaranteed.')

-- Reject both an old sample and a newer sample taken during a selection change.
key='before-read'
on_sample=function() key='after-read' end
env.update(.001)
assert(not visible,'A complete sample from a superseded selection must not appear')
on_sample=nil
env.update(.001)
assert(visible and visible.key=='after-read','A selection changed during sampling must retry on the next frame')
key='before-newer-read'
on_sample=function(snapshot) key='newer-read' snapshot.key=key end
env.update(.001)
assert(not visible,'Do not combine a newer mission sample with the previous selection anchor')
on_sample=nil
env.update(.001)
assert(visible and visible.key=='newer-read')
key='controller-changed-during-read'
on_sample=function() matches=false end
env.update(.001)
assert(not visible,'Controller mismatch after sampling must reject an otherwise complete sample')
on_sample=nil
matches=true
env.update(.001)
assert(visible and visible.key==key)

-- Hiding the native menu cancels pending publication and resets scroll state.
key,complete='never-ready',false
env.update(.001)
for _=1,20 do env.update(.101) end
assert(not visible,'There must be no timeout fallback to provisional intel')
local hidden_samples=samples
ready=false
env.update(.001)
complete=true
for _=1,10 do env.update(.1) end
assert(not visible and samples==hidden_samples,'Loadout must cancel pending reads and publication')
assert(not frame_visible,'The retained forecast frame must still disappear on loadout')
ready=true
env.update(.001)
assert(visible and visible.key=='never-ready','Reopening briefing must read the current selection immediately')
key='screen-change-during-read'
on_sample=function() screen=nil end
env.update(.001)
assert(not visible,'A menu closed during sampling must not publish a report')
on_sample=nil

-- Complete reports may legitimately have one section on low difficulties.
screen,key,difficulty,complete='map','low-difficulty',2,true
env.update(.001)
assert(visible and visible.headline=='BILE BUGS' and #visible.large==0 and #visible.small>0)
assert(visible.footer==FOOTER)

-- Loading or expiring remote packets are normal pending states. They must
-- clear the old report without destroying the frame or resetting its scroll.
client,hovered=true,true
local client_clears,client_failures=clears,env.EnemyIntelligence.failures
descriptor_pending=true
env.update(.01)
assert(not visible and frame_visible and not env.EnemyIntelligence.complete)
assert(clears==client_clears and env.EnemyIntelligence.failures==client_failures)
descriptor_pending=false
env.update(.01)
assert(visible,'A newly available remote packet must publish immediately')
key,sample_pending='remote-sample-race',true
env.update(.01)
assert(not visible and frame_visible and clears==client_clears)
sample_pending=false
env.update(.101)
assert(visible and visible.key==key)
key='remote-final-descriptor-race'
on_sample=function() descriptor_pending=true end
env.update(.01)
assert(not visible and frame_visible and clears==client_clears)
on_sample,descriptor_pending=nil,false
env.update(.01)
assert(visible and visible.key==key)

-- The native card can fade while a mission is still hovered and its packet
-- is loading. Keep the frame based on that hover, without a timer.
for _,gap in ipairs({.05,.16,.30}) do
    active,descriptor_pending=false,true
    local before_samples=samples
    env.update(gap)
    assert(not visible and frame_visible and clears==client_clears)
    assert(samples==before_samples,'No mission reads are needed during an inactive hover')
    active,descriptor_pending=true,false
    key=key..'-next'
    env.update(.01)
    assert(visible and visible.key==key and clears==client_clears)
end
-- Actual unhover clears the native selection before the card finishes fading.
-- All chrome must disappear on this same update, even at zero elapsed time.
hovered,descriptor_pending=false,true
local unhover_samples=samples
env.update(0)
assert(not visible and not frame_visible and env.EnemyIntelligence.status=='hidden',
    'Unhover must hide the entire forecast immediately, including while the native card is fading')
assert(env.EnemyIntelligence.key==nil and not env.EnemyIntelligence.complete)
assert(samples==unhover_samples,'An unhovered mission must not trigger a forecast read')
env.update(.01)
env.update(.5)
assert(not frame_visible and samples==unhover_samples,'No pending timer or packet may restore a dismissed panel')
hovered,descriptor_pending,active=true,false,false
env.update(.001)
assert(visible and frame_visible,'Rehover must restore a ready forecast without waiting for the card fade')
key='unhover-during-read'
on_sample=function() hovered,descriptor_pending=false,true end
env.update(.001)
assert(not visible and not frame_visible,'Unhover during sampling must clear chrome before publishing')
on_sample,hovered,descriptor_pending,active=nil,true,false,true
env.update(.001)
assert(visible and frame_visible)
ready=false
env.update(.001)
assert(not frame_visible,'Closing the left native frame must still hide immediately')
ready,active=true,true
env.update(.01)
descriptor_pending,screen=true,'briefing'
env.update(.001)
assert(not frame_visible,'A screen change must clear the previous GUI even if the new descriptor is pending')
ready=false
env.update(.001)
assert(not frame_visible,'Loadout must stay hidden')
descriptor_pending=false
for _,m in ipairs(published) do
    assert(m.complete and m.footer==FOOTER,
        'Only complete reports and their matching footer may be published')
end
assert(suspends>0 and env.EnemyIntelligence.failures==1,'Expected pending states must not become reader failures')
env.shutdown()
assert(not visible)
print('PASS: complete report publication, rapid selection races, pending retry bounds, footer consistency, hidden states and callback preservation')
