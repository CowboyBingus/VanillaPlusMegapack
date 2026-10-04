-- Behavioral regression: a player who leaves a category once its visible tiles
-- are drawn, before offscreen cards finish, still finds those tiles cached.
-- Policy only: the adapter below records handoffs and makes no native calls.
local root=assert(arg[1])
local images=dofile(root..'/src/images.lua')
local s
local a={freezes={}}
function a:snapshot()return s end
function a:restore()end
function a:prune()end
function a:destroy()end
function a:capture(row)
    local e={}
    for _,i in ipairs(row.items)do if i.ready and i.pixels_ready~=false then e[i.key]={uv=i.key}end end
    if not next(e)then return end
    return {atlas=row.atlas,layout=row.layout,bytes=1024,entries=e}
end
function a:freeze(row,p)
    local same=(row.can_freeze_idle or row.can_freeze_rebind or row.can_freeze_visible)
        and p.request_id==row.capture_id
    assert((row.can_freeze or same) and row.atlas==p.atlas,'Unsafe atlas handoff')
    self.freezes[#self.freezes+1]=row.can_freeze_visible and 'visible' or 'idle'
    return {handle=p.atlas,replacement='fresh-'..#self.freezes,bytes=p.bytes}
end
function a:apply(row,entries)
    local hits=0
    for _,w in ipairs(row.widgets)do if entries[w.key]then hits=hits+1 end end
    return hits,#row.widgets-hits
end
-- Two visible tiles (card 0) and one offscreen item (card 1). ready: cards
-- the native pipeline completed; blank: completed cards whose pixels a
-- previous handoff left behind in the retained atlas.
local function row(atlas,ready,flags,blank)
    blank=blank or {}
    local items={}
    for _,v in ipairs({{'armor1',0},{'armor2',0},{'armor3',1}})do
        local done=ready[v[2]]==true
        items[#items+1]={key=v[1],card=v[2],ready=done,pixels_ready=done and not blank[v[2]]}
    end
    local widgets={}
    for i=1,2 do widgets[i]={key=items[i].key,native_ready=items[i].ready,pixels_ready=items[i].pixels_ready}end
    local r={context='world',atlas=atlas,layout='layout',bytes=1024,screen='grid',
        capture_id=atlas..'armor',complete=ready[0]==true and ready[1]==true,items=items,widgets=widgets}
    for k,v in pairs(flags or {})do r[k]=v end
    return r
end
local cache=images.new(a,{})
-- First visit: nothing is drawn yet, so no boundary is offered.
s=row('native',{});cache:tick(false)
assert(#a.freezes==0)
-- The visible card composed while the offscreen card is still preparing.
s=row('native',{[0]=true},{can_freeze_visible=true});cache:tick(false)
assert(#a.freezes==1 and a.freezes[1]=='visible','Keep the visible tiles before offscreen work finishes')
assert(cache.entries.armor1 and cache.entries.armor2 and not cache.entries.armor3)
assert(cache.visible_retained==1 and cache.idle_retained==0 and cache.partial_retained==1)
assert(cache.last_hits==2,'Retained crops are bound in the handoff callback')
assert(cache.grid_hits==2 and cache.preselect_hits==0,'Grid hits are reported separately')
-- The replacement atlas holds card 0 only as blank space. The adapter keeps
-- offering the visible boundary; the policy must not detach again.
s=row('fresh-1',{[0]=true},{can_freeze_visible=true},{[0]=true});cache:tick(false)
assert(#a.freezes==1,'A visible handoff happens once per request')
-- Offscreen card completes. Blank-card tiles are served from crops, so the
-- remaining item is retained too.
s=row('fresh-1',{[0]=true,[1]=true},{can_freeze_rebind=true},{[0]=true});cache:tick(false)
assert(#a.freezes==2 and a.freezes[2]=='idle' and cache.entries.armor3,'Retain offscreen cards after the visible handoff')
assert(cache.entries.armor1.texture~=cache.entries.armor3.texture,'Blank regions are never captured again')
assert(cache.idle_retained==1)
-- Warm revisit: the native pipeline regenerates everything. Visible tiles are
-- already cached, so no extra replacement atlas is allocated early.
s=row('fresh-2',{});cache:tick(false)
assert(cache.last_hits==2 and cache.last_early_hits==0)
s=row('fresh-2',{[0]=true},{can_freeze_visible=true});cache:tick(false)
assert(#a.freezes==2,'Warm visits keep the single whole-request refresh')
s=row('fresh-2',{[0]=true,[1]=true},{can_freeze_idle=true});cache:tick(false)
assert(#a.freezes==3 and a.freezes[3]=='idle')
-- A blank-region tile without a crop (for example one evicted in between)
-- forbids the rebind boundary: detaching would leave that tile empty.
local fresh=images.new(a,{})
s=row('native',{[0]=true,[1]=true},{can_freeze_rebind=true},{[0]=true});fresh:tick(false)
assert(#a.freezes==3 and not next(fresh.textures),'Never detach under an uncovered blank tile')
print('PASS: visible handoff keeps a short visit; one visible handoff per request; offscreen cards retained later without recapturing blank regions; warm visits allocate no extra atlas; uncovered blank tiles block detach; grid hits reported')
