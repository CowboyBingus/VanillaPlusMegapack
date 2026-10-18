local ffi,bit=require('ffi'),require('bit')
local M={}
local ZERO=string.rep('\0',4)
-- Four-byte little-endian fields decode from the string's bytes: no cdata, no
-- substring and no type punning per field. A field must lie inside b.
local function u(b,o)
    local b1,b2,b3,b4=b:byte(o+1,o+4)
    assert(b4,'Field outside the bytes read')
    return b1+b2*256+b3*65536+b4*16777216
end
-- IEEE 754 single precision, exactly (subnormals, infinities and NaN included).
local function f(b,o)
    local b1,b2,b3,b4=b:byte(o+1,o+4)
    assert(b4,'Field outside the bytes read')
    local sign=b4>=128 and -1 or 1
    local exponent=(b4%128)*2+math.floor(b3/128)
    local mantissa=((b3%128)*256+b2)*256+b1
    if exponent==255 then return mantissa==0 and sign*math.huge or 0/0 end
    if exponent==0 then return sign*math.ldexp(mantissa,-149) end
    return sign*math.ldexp(mantissa+8388608,exponent-150)
end
local function word(n) return ffi.string(ffi.new('uint32_t[1]',n),4) end
local function ticks(b)
    local v=ffi.new('uint64_t[1]');ffi.copy(v,b,8);return tonumber(v[0])
end
local function tickword(n) return ffi.string(ffi.new('uint64_t[1]',n),8) end
local function finite(n) return n==n and math.abs(n)<100000 end
local function vector(b)
    return b and #b==12 and finite(f(b,0)) and finite(f(b,4)) and finite(f(b,8))
end
local function nonzero(b) return f(b,0)~=0 or f(b,4)~=0 or f(b,8)~=0 end
local function fromhex(h) return (h:gsub('..',function(p)return string.char(tonumber(p,16))end)) end
-- Resource identity and BehaviorComponent defaults from this build's data.
local profiles={
    [fromhex('701de358cfd685ef')]={name='Gatling',behavior=213,fire_gate={pause=16,resume=4}},
    [fromhex('bb26ba7638e4cd37')]={name='Machine gun',behavior=312,fire_gate={pause=14,resume=3}},
    [fromhex('a8a8ffcf360f0756')]={name='Laser cannon',behavior=308},
    [fromhex('c6e986dc68950737')]={name='Rocket',behavior=611},
    [fromhex('582896febac30c82')]={name='Flamethrower',behavior=207},
    [fromhex('742dce3b2e81a051')]={name='Mortar',behavior=319},
    [fromhex('8b2f0938183a05b2')]={name='EMS mortar',behavior=323},
}
-- EMS mortar uses the same mechanism, with its own resource/profile identity.
M.profiles=profiles
local signatures={
    {0x6bf390,'405741574883ec283b158248dc02450fb6f94c8b158779c6'},
    {0x11cb930,'4883ec288b41083b05e3822b020f84d00000004c8b1526b4'},
    {0x11cba20,'4883ec288b41083b05f3812b020f84d00000004c8b1536b3'},
    {0x755f90,'48894c24085355565741574883ec20'},
}
M.signatures=signatures
-- The field decoders, for the tests.
M.fields={u=u,f=f}
local function matches(api,guards)
    for _,g in ipairs(guards) do
        if api.read(g.address,#g.bytes)~=g.bytes then return false end
    end
    return true
end

-- Reads that must succeed in full, and pointers that must be user-mode.
local function need(api,a,n)
    local b=api.read(a,n);assert(b and #b==n,'Runtime read unavailable');return b
end
local function into(api,a,n,buffer)
    assert(api.read_into(a,n,buffer),'Runtime read unavailable')
end
local function need_pointer(api,b)
    return assert(api.pointer(b),'Runtime pointer unavailable')
end
local NULL=string.rep('\0',8)

-- Guards and windows ------------------------------------------------------------
-- A guard holds bytes that must still be at its address. at is that address as
-- a number: a guard inside memory this check already read (a window) is
-- compared with those bytes instead of being read again.
local function number_of(api,p) if type(p)=='number' then return p end return api.address(p) end
local function guard(api,list,address,bytes)
    list[#list+1]={address=address,bytes=bytes,at=number_of(api,address)}
end
-- Records bytes read at address as window windows.n (window tables are reused).
local function window(api,windows,address,bytes)
    local n=windows.n+1;windows.n=n
    local w=windows[n];if not w then w={};windows[n]=w end
    w.at=number_of(api,address);w.bytes=bytes
    return bytes
end
-- true or false when a window holds the guard's range, nil otherwise.
local function covered(windows,g)
    for k=1,windows.n do
        local w=windows[k];local o=g.at-w.at
        if o>=0 and o+#g.bytes<=#w.bytes then return w.bytes:sub(o+1,o+#g.bytes)==g.bytes end
    end
end
-- Whether every guard still holds; only those outside the windows are read.
local function verified(api,guards,windows)
    for k=1,#guards do
        local g=guards[k];local same=covered(windows,g)
        if same==nil then same=api.read(g.address,#g.bytes)==g.bytes end
        if not same then return false end
    end
    return true
end

-- Cold resolution: registries, maps and components -------------------------------
-- An entity's index in a native hash map, or nil when absent. On a hit the map
-- header and the slot become guards.
local function lookup(api,manager,off,id,limit,guards)
    local h=need(api,manager+off,20);local c=u(h,8)
    if c==0 then return nil end
    assert(c<=limit and bit.band(c,c-1)==0,'Unsupported entity map')
    local data=need_pointer(api,h:sub(1,8));local empty,mul=u(h,12),u(h,16)
    local product=ffi.new('uint64_t',id)*ffi.new('uint64_t',mul)
    for probe=0,math.min(c,128)-1 do
        local slot=bit.band(tonumber(ffi.cast('uint32_t',product))+probe,c-1)
        local address=data+slot*8;local row=need(api,address,8)
        if u(row,0)==id then
            guard(api,guards,manager+off,h);guard(api,guards,address,row)
            return u(row,4)
        end
        if u(row,0)==empty then return nil end
    end
    error('Entity map probe bound exceeded')
end
-- A component's address and bytes in a native array of stride-byte entries;
-- the array pointer becomes a guard.
local function component(api,manager,off,index,stride,size,guards)
    local b=need(api,manager+off,8);local p=need_pointer(api,b)
    guard(api,guards,manager+off,b)
    return p+index*stride,need(api,p+index*stride,size)
end
-- The behavior and turret registries of this check (read once per check, only
-- when a sentry needs them), or nil while a root is empty.
local function components(api,game,c)
    local reg=c.reg
    if reg.bm~=nil then return reg.bm and reg end
    local w,at=c.windows,c.at
    local bmb=window(api,w,at.bm,need(api,at.bm,8))
    local rmb=window(api,w,at.rm,need(api,at.rm,8))
    if bmb==NULL or rmb==NULL then reg.bm=false;return nil end
    -- Pointers and the addresses made from them are kept while their bytes are
    -- unchanged: no new pointer value per check.
    local k=c.kept
    if bmb~=k.bmb then k.bmb,k.bm=bmb,need_pointer(api,bmb);k.bh=k.bm+32 end
    if rmb~=k.rmb then k.rmb,k.rm=rmb,need_pointer(api,rmb);k.rh=k.rm+8 end
    local rh=window(api,w,k.rh,need(api,k.rh,88));local bh=window(api,w,k.bh,need(api,k.bh,80))
    assert(u(rh,16)<=u(rh,12) and u(rh,12)<=u(rh,0) and u(rh,0)<=4096,'Unsupported turret registry')
    assert(u(bh,0)<=16384,'Unsupported behavior registry')
    reg.bm,reg.rm,reg.bmb,reg.rmb,reg.rh,reg.bh=k.bm,k.rm,bmb,rmb,rh,bh
    local rtb,ntb=reg.th:sub(69,76),reg.th:sub(77,84)
    if rtb~=k.rtb then k.rtb,k.rt=rtb,need_pointer(api,rtb) end
    if ntb~=k.ntb then k.ntb,k.nt=ntb,need_pointer(api,ntb) end
    reg.rt,reg.nt=k.rt,k.nt
    return reg
end
-- The roots, the registry's array pointers, the entity pointer and the
-- entity's identity bytes. The authority byte is checked on every check.
local function entity_guards(api,game,reg,e)
    local guards={}
    for _,g in ipairs({{game+0x3326d30,reg.tmb},{game+0x3326740,reg.bmb},{game+0x3326d70,reg.rmb},
        {reg.tm+360,reg.th:sub(53,60)},{reg.tm+376,reg.th:sub(69,76)},{reg.tm+384,reg.th:sub(77,84)},
        {reg.ep+8*e.index,e.pointer},{e.address,e.key}}) do
        guard(api,guards,g[1],g[2])
    end
    return guards
end
-- The target's unit, so its collision surface is not mistaken for terrain. Its
-- guard is the target entity's identity; target removal must never prevent
-- restoring a sentry, so it stays apart from the sentry's guards.
local function locate_target(api,game,id)
    local scratch={}
    local fm=need_pointer(api,need(api,game+0x3326cb8,8))
    local fi=lookup(api,fm,73808,id,131072,scratch)
    if not fi or fi==0xffffffff then return nil end
    assert(fi<16384,'Target faction index out of range')
    local slot=need_pointer(api,need(api,fm+73832,8))+8*fi
    local address=need_pointer(api,need(api,slot,8));local target=need(api,address,20)
    assert(u(target,8)==id,'Target identity changed')
    local guards={};guard(api,guards,address,target)
    return {id=id,unit=u(target,12),guards=guards}
end
-- The firing layout of a Gatling or machine gun: weapon and trigger slots, the
-- fire nodes, the native selection clock and their guards.
local function locate_fire(api,game,e)
    local clock_root=need(api,game+0x3326348,8)
    local selection_guards={};guard(api,selection_guards,game+0x3326348,clock_root)
    local wm=need_pointer(api,need(api,game+0x3326ce0,8))
    local guards={}
    local wi=lookup(api,wm,48,e.id,32768,guards)
    assert(wi and wi~=0xffffffff and wi<16384,'Weapon data unavailable')
    local _,we=component(api,wm,72,wi,8,8,guards)
    assert(we==e.pointer,'Weapon identity mismatch')
    local wr,record=component(api,wm,88,wi,1008,228,guards)
    local mode_address=component(api,wm,96,wi,12,12,guards)
    local count=u(record,216)
    assert(count>0 and count<=24,'Invalid sentry fire nodes')
    local nodes={}
    for i=0,count-1 do nodes[i]=u(record,120+4*i) end
    guard(api,guards,game+0x3326ce0,need(api,game+0x3326ce0,8))
    local cmb=need(api,game+0x3326660,8);local cm=need_pointer(api,cmb)
    guard(api,guards,game+0x3326660,cmb)
    local ci=lookup(api,cm,40,e.id,32768,guards)
    assert(ci and ci~=0xffffffff and ci<16384,'Weapon trigger unavailable')
    -- The trigger array and its manager are guards too: the trigger's address is kept.
    local triggers=need(api,cm+88,8);guard(api,guards,cm+88,triggers)
    return {wm=wm,cm=cm,wm_header=wm+48,cm_header=cm+40,clock_root_address=game+0x3326348,
        guards=guards,selection_guards=selection_guards,clock_root=clock_root,
        clock_address=need_pointer(api,clock_root)+24,node_address=wr+216,nodes=nodes,count=count,
        mode_address=mode_address,trigger_address=need_pointer(api,triggers)+ci,
        index=ffi.new('uint32_t[2]'),network=ffi.new('uint32_t[3]'),trigger=ffi.new('uint8_t[1]'),
        clock=ffi.new('uint32_t[2]')}
end
-- The layout of a locally authoritative sentry whose three map entries agree,
-- or nil: addresses and indices that stay put while its guards hold, reused
-- read buffers and the row the checks refresh in place.
local function locate(api,game,reg,e)
    local guards=entity_guards(api,game,reg,e)
    local ti=lookup(api,reg.tm,336,e.id,16384,guards)
    local bi=lookup(api,reg.bm,64,e.id,32768,guards)
    local ri=lookup(api,reg.rm,40,e.id,8192,guards)
    if ti~=e.index or not bi or not ri or bi==0xffffffff or ri==0xffffffff then return nil end
    assert(bi<u(reg.bh,0) and ri<u(reg.rh,12),'Component index out of range')
    local _,be=component(api,reg.bm,88,bi,8,8,guards)
    local _,re=component(api,reg.rm,64,ri,8,8,guards)
    assert(be==e.pointer and re==e.pointer,'Component identity mismatch')
    local ba=component(api,reg.bm,96,bi,504,160,guards)
    local ca=component(api,reg.rm,88,ri,16,16,guards)
    local i=e.index
    local L={index=i,pointer=e.pointer,address=e.address,key=e.key,guards=guards,profile=e.profile,
        behavior_address=ba,control_address=ca,runtime_address=reg.rt+208*i,network_address=reg.nt+24*i,
        behavior=ffi.new('uint32_t[40]'),control=ffi.new('uint32_t[4]'),runtime=ffi.new('uint32_t[8]'),
        network=ffi.new('uint32_t[6]')}
    L.bytes={behavior=ffi.cast('uint8_t *',L.behavior),control=ffi.cast('uint8_t *',L.control),
        runtime=ffi.cast('uint8_t *',L.runtime)}
    L.floats={behavior=ffi.cast('float *',L.behavior),control=ffi.cast('float *',L.control),
        runtime=ffi.cast('float *',L.runtime)}
    L.at={point=L.bytes.behavior+28,deadline=L.bytes.behavior+152,raw=L.bytes.runtime+8,
        computed=L.bytes.runtime+20,horizontal=L.bytes.control+8,vertical=L.bytes.control+12,
        node=L.bytes.behavior+8,target=L.bytes.behavior+24,source=L.bytes.behavior+96,has=L.bytes.behavior+120}
    local transition={}
    for _,o in ipairs({{8,4},{24,4},{96,4},{120,1}}) do guard(api,transition,ba+o[1],string.rep('\0',o[2])) end
    L.row={id=e.id,key=e.key,entity=e.address,guards=guards,transition_guards=transition,
        profile=e.profile.name,behavior_address=ba,transition_address=ba+8,authority_address=e.address+20,
        raw_address=L.runtime_address+8,computed_address=L.runtime_address+20,
        flags_address=L.network_address+16,control_address=ca}
    if e.profile.fire_gate then
        L.fire=locate_fire(api,game,e)
        L.row.selection={address=ba+152,guards=L.fire.selection_guards}
        L.row.fire={manager=L.fire.wm,mode_address=L.fire.mode_address,guards=L.fire.guards,
            unit=u(e.bytes,12),pause=e.profile.fire_gate.pause,resume=e.profile.fire_gate.resume}
    end
    return L
end

-- Refresh: the live fields of a located sentry ----------------------------------
local function check_components(L)
    local b,c,bf,cf,rf=L.bytes.behavior,L.bytes.control,L.floats.behavior,L.floats.control,L.floats.runtime
    assert(L.behavior[0]==L.profile.behavior,'Unsupported sentry behavior')
    assert(b[120]<=1 and c[0]<=1,'Unsupported component flags')
    assert(finite(rf[2]) and finite(rf[3]) and finite(rf[4]) and finite(rf[5]) and finite(rf[6])
        and finite(rf[7]) and finite(bf[7]) and finite(bf[8]) and finite(bf[9]),'Invalid aim vector')
    assert(finite(cf[2]) and cf[2]>=0 and cf[2]<=1000 and finite(cf[3]) and cf[3]>=0 and cf[3]<=1000,
        'Invalid turret speeds')
end
-- The fire fields: node, mode, trigger and the selection clock. False when the
-- weapon or trigger moved (the sentry is located again).
local function refresh_fire(api,game,L,s,windows)
    local F=L.fire
    -- The weapon and trigger map headers and arrays, one read each; a manager
    -- that is gone reads as moved.
    local wh,ch=api.read(F.wm_header,56),api.read(F.cm_header,56)
    if not wh or not ch then return false end
    window(api,windows,F.wm_header,wh);window(api,windows,F.cm_header,ch)
    if not verified(api,F.guards,windows) then return false end
    if need(api,F.clock_root_address,8)~=F.clock_root then return false end
    into(api,F.node_address,8,F.index)
    local count,index=F.index[0],F.index[1]
    assert(count==F.count and index<count,'Invalid sentry fire nodes')
    into(api,F.mode_address,12,F.network);into(api,F.trigger_address,1,F.trigger)
    into(api,F.clock_address,8,F.clock)
    local node=F.nodes[index]
    assert(node<1024 and F.network[0]<=8,'Invalid sentry weapon state')
    assert(F.trigger[0]<=1,'Invalid sentry trigger')
    local fire=s.fire
    fire.node,fire.mode,fire.trigger=node,F.network[0],F.trigger[0]==1
    fire.target_unit,fire.target_guards,fire.pose,fire.terrain_blocked,fire.query=nil,nil,nil,nil,nil
    s.selection.deadline=ffi.string(L.at.deadline,8)
    s.selection.now=F.clock[0]+F.clock[1]*4294967296
    -- The target is located once per target; prepare_fire checks its guard
    -- around the terrain query and marks it stale when it no longer holds.
    if fire.target_stale then L.target=nil;fire.target_stale=nil end
    if s.target~=0 and s.runtime_target==s.target then
        local T=L.target
        if not (T and T.id==s.target) then T=locate_target(api,game,s.target);L.target=T end
        if T then fire.target_unit,fire.target_guards=T.unit,T.guards end
    end
    return true
end
-- Reads the live components into the sentry's buffers and decodes its row.
-- Unchanged string fields are interned strings: they allocate nothing.
local function refresh(api,game,L,windows)
    into(api,L.behavior_address,160,L.behavior);into(api,L.control_address,16,L.control)
    into(api,L.runtime_address,32,L.runtime);into(api,L.network_address,24,L.network)
    check_components(L)
    local s,at,b=L.row,L.at,L.behavior
    s.node,s.target,s.source_flags,s.has=b[2],b[6],b[24],L.bytes.behavior[120]==1
    s.point=ffi.string(at.point,12)
    s.runtime_target,s.raw,s.computed=L.runtime[0],ffi.string(at.raw,12),ffi.string(at.computed,12)
    s.flags=L.network[4]
    s.horizontal,s.vertical=ffi.string(at.horizontal,4),ffi.string(at.vertical,4)
    s.enabled=L.bytes.control[0]==1
    local t=s.transition_guards
    t[1].bytes,t[2].bytes=ffi.string(at.node,4),ffi.string(at.target,4)
    t[3].bytes,t[4].bytes=ffi.string(at.source,4),ffi.string(at.has,1)
    if L.fire then return refresh_fire(api,game,L,s,windows) end
    return true
end

-- The check: targeting entries, classified once per pointer --------------------
-- A cache keeps, per targeting index, the entity pointer seen there (two
-- 32-bit halves) and its class: false (not a sentry this machine controls),
-- true (a sentry), plus the sentry's layout. Entries are classified again when
-- their pointer changes and on every RESCAN-th check: authority can change in
-- place, and a new entity can take a removed one's address and index (a new
-- sentry is then found within RESCAN checks, about a quarter of a second).
-- Layouts are verified on every check from the memory the check read.
local RESCAN=30
function M.new_cache()
    return {lo={},hi={},class={},layouts={},checks=0,active=0,windows={n=0},rows={},reg={},kept={},
        chunks={},chunk_at={}}
end
local function forget(c,from)
    for i=from,c.active-1 do c.lo[i],c.hi[i],c.class[i],c.layouts[i]=nil,nil,nil,nil end
    c.active=from
end
-- The roots' addresses in game.dll, kept per module base.
local function roots(c,game)
    if c.game~=game then
        c.game=game
        c.at={tm=game+0x3326d30,bm=game+0x3326740,rm=game+0x3326d70}
    end
    return c.at
end
-- This check's targeting registry and entity pointers (windows), or nil.
local function targeting(api,game,c)
    local w,at,k=c.windows,roots(c,game),c.kept;w.n=0
    local reg=c.reg;reg.bm=nil
    local tmb=window(api,w,at.tm,need(api,at.tm,8))
    if tmb==NULL then return nil end
    if tmb~=k.tmb then k.tmb,k.tm=tmb,need_pointer(api,tmb);k.th=k.tm+308 end
    local th=window(api,w,k.th,need(api,k.th,84))
    local cap,total,active=u(th,0),u(th,12),u(th,16)
    assert(active<=total and total<=cap and cap<=8192,'Unsupported targeting registry')
    if active==0 then return nil end
    local epb=th:sub(53,60)
    if epb~=k.epb then
        k.epb,k.ep=epb,need_pointer(api,epb)
        for i in pairs(c.chunk_at) do c.chunk_at[i]=nil end
    end
    reg.tm,reg.tmb,reg.th,reg.active,reg.ep=k.tm,tmb,th,active,k.ep
    for n=0,math.floor((active-1)/256) do
        local first=n*256
        local address=c.chunk_at[n]
        if not address then address=k.ep+8*first;c.chunk_at[n]=address end
        c.chunks[n]=window(api,w,address,need(api,address,math.min(256,active-first)*8))
    end
    return reg
end
-- The layout of entry i whose pointer changed (or a rescan), or nil when it is
-- not a sentry this machine controls. Sets the entry's class.
local function classify(api,game,c,reg,i,pointer)
    local address=need_pointer(api,pointer);local entity=need(api,address,24)
    local profile=profiles[entity:sub(1,8)]
    c.class[i]=profile~=nil and bit.band(entity:byte(21),3)==1
    if not c.class[i] or not components(api,game,c) then return nil end
    return locate(api,game,reg,{index=i,pointer=pointer,address=address,bytes=entity,
        key=entity:sub(1,20),profile=profile,id=u(entity,8)})
end
-- A cached layout still valid this check: its entity keeps the same identity
-- and authority and every guard holds.
local function current(api,game,c,L)
    local w=c.windows
    local entity=api.read(L.address,24)
    if not entity then return false end
    window(api,w,L.address,entity)
    if bit.band(entity:byte(21),3)~=1 then c.class[L.index]=false;return false end
    return components(api,game,c)~=nil and verified(api,L.guards,w)
end
-- The row of entry i, or nil: a cached layout while it holds, otherwise the
-- entry is classified (and a sentry located) again.
local function entry_row(api,game,c,reg,i,moved)
    local L=c.layouts[i]
    if L and not moved and current(api,game,c,L) and refresh(api,game,L,c.windows) then return L.row end
    c.layouts[i]=nil
    local at=(i%256)*8
    L=classify(api,game,c,reg,i,c.chunks[math.floor(i/256)]:sub(at+1,at+8))
    if not L then return nil end
    c.layouts[i]=L
    assert(refresh(api,game,L,c.windows),'Sentry changed while located')
    return L.row
end
function M.snapshot(api,game,c)
    c=c or M.new_cache()
    c.checks=c.checks+1
    local rows=c.rows
    for k=#rows,1,-1 do rows[k]=nil end
    local reg=targeting(api,game,c)
    if not reg then forget(c,0);return rows,'waiting_for_sentries' end
    -- Another targeting registry (a new mission): every entry is new.
    if reg.tmb~=c.tmb then forget(c,0);c.tmb=reg.tmb end
    if reg.active<c.active then forget(c,reg.active) end
    c.active=reg.active
    local rescan=c.checks%RESCAN==0
    for i=0,reg.active-1 do
        local chunk,at=c.chunks[math.floor(i/256)],(i%256)*8
        local lo,hi=u(chunk,at),u(chunk,at+4)
        local moved=lo~=c.lo[i] or hi~=c.hi[i]
        c.lo[i],c.hi[i]=lo,hi
        if moved or rescan or c.class[i]~=false then
            local row=entry_row(api,game,c,reg,i,moved)
            if row then rows[#rows+1]=row end
        end
    end
    return rows,#rows==0 and 'waiting_for_sentries' or 'observing'
end

local function writable(api,s)
    return api.writable_data(s.flags_address,4) and api.writable_data(s.raw_address,24)
        and api.writable_data(s.control_address+8,8)
end
local function same(a,b)
    return a.key==b.key and a.flags_address==b.flags_address
        and a.control_address==b.control_address and a.raw_address==b.raw_address
end

-- Whether a lease may be restored: the same entity, this machine still controls
-- it, and its control memory is private read-write data. Returns nothing to go
-- on, or the release's result. A removed/moved entity owns no writable lease
-- here. Never follow an old slot.
local function release_gate(api,s)
    if not matches(api,s.guards) then return true,'retired' end
    if s.authority_address then
        local flags=api.read(s.authority_address,1)
        if not flags or bit.band(flags:byte(1),1)==0 then return true,'authority_changed' end
    end
    if not writable(api,s) then return false,'restore_memory_unavailable' end
end
-- Whether current holds our write w, whole or cut short at any byte.
local function owned(current,w)
    for cut=0,12 do
        if current==w.after:sub(1,cut)..w.before:sub(cut+1) then return true end
    end
    return false
end
-- Rolls back the aim writes of a hold that did not complete. A derived aim
-- changed by the engine is no longer ours to restore. Returns false when a
-- rollback failed; every owned control is still released.
local function rollback_aim(api,lease,s)
    local restored=true
    for _,w in ipairs(lease.aim_writes or {}) do
        local current=api.read(w.address,12)
        if not current then restored=false
        elseif owned(current,w) and current~=w.before then
            -- writable() verified raw_address..+24 just before. A write inside
            -- that range does not repeat the query; any other one checks itself.
            local checked=w.address>=s.raw_address and w.address+12<=s.raw_address+24
            local called,written=pcall(api.write,w.address,w.before,checked)
            if not called or not written or api.read(w.address,12)~=w.before then restored=false end
        end
    end
    return restored
end
-- Restores both turret speeds still at our zero. Speed changes made by native
-- behavior or another mod are not overwritten.
local function release_speeds(api,native,lease,s)
    local restored=true
    for _,axis in ipairs({{'horizontal',8},{'vertical',12}}) do
        if lease[axis[1]] then
            local address=s.control_address+axis[2];local current=api.read(address,4)
            if current==ZERO then
                local called=pcall(native[axis[1]],s.entity,f(s[axis[1]],0))
                if not called or api.read(address,4)~=s[axis[1]] then restored=false
                else lease[axis[1]]=nil end
            elseif not current then restored=false
            else lease[axis[1]]=nil end
        end
    end
    return restored
end
-- Clears the retention bit while it is still set.
local function release_flag(api,native,lease,s)
    local current=api.read(s.flags_address,4)
    if not current then return false end
    if bit.band(u(current,0),2)~=0 then
        local called=pcall(native.retention,s.id,false)
        if not called or api.read(s.flags_address,4)~=word(bit.band(u(current,0),bit.bnot(2))) then return false end
    end
    lease.flag=nil
    return true
end
function M.release(api,native,lease)
    local s=lease.snapshot
    local done,why=release_gate(api,s)
    if done~=nil then return done,why end
    local restored=true
    if not lease.completed then restored=rollback_aim(api,lease,s) end
    if not release_speeds(api,native,lease,s) then restored=false end
    if lease.flag and not release_flag(api,native,lease,s) then restored=false end
    return restored,restored and 'restored' or 'restore_incomplete'
end

-- A hold may start: no native disable bit, unchanged identity and transition
-- state, and this machine still controls the sentry.
local function may_hold(api,s)
    if s.flags~=0 or not matches(api,s.guards) or not matches(api,s.transition_guards or {}) then return false end
    if not s.authority_address then return true end
    local flags=api.read(s.authority_address,1)
    return flags and bit.band(flags:byte(1),3)==1
end
-- Set the native retention bit first: the engine skips its target-source
-- prepass and fallback path while this bit is owned. AI itself keeps running.
-- Each control is journaled in the lease before its setter runs.
local function hold_controls(api,native,s,lease)
    native.retention(s.id,true)
    if api.read(s.flags_address,4)~=word(2) then return false,'hold_flag_failed' end
    for _,axis in ipairs({{'horizontal',8},{'vertical',12}}) do
        lease[axis[1]]=true
        native[axis[1]](s.entity,0)
        if api.read(s.control_address+axis[2],4)~=ZERO then return false,'hold_speed_failed' end
    end
    return true
end
-- Write the recorded aim into both aim fields, each journaled before its write.
local function hold_aim(api,s,record,lease)
    lease.aim_writes={}
    -- acquire's writable() check verified raw_address..+24 in this check; it holds
    -- both aim fields (computed_address is raw_address+12). No repeated query.
    for _,w in ipairs({{address=s.raw_address,before=s.raw,after=record.raw},
        {address=s.computed_address,before=s.computed,after=record.computed}}) do
        lease.aim_writes[#lease.aim_writes+1]=w
        if not api.write(w.address,w.after,true) then return false,'hold_aim_failed' end
    end
    if api.read(s.raw_address,12)~=record.raw or api.read(s.computed_address,12)~=record.computed then
        return false,'hold_aim_verify_failed'
    end
    return true
end
local function acquire(api,native,s,record,state)
    if not may_hold(api,s) then return true,'busy' end
    if not writable(api,s) then return false,'hold_memory_unavailable' end
    -- The lease keeps its own copy: the row is refreshed in place on every
    -- check, and the hold must keep the turret speeds it saved here.
    local held={};for k,v in pairs(s) do held[k]=v end
    local lease={snapshot=held,flag=true};record.lease=lease
    local ok,why=hold_controls(api,native,s,lease)
    if not ok then return false,why end
    if s.raw~=record.raw then state.late_aim=state.late_aim+1 end
    ok,why=hold_aim(api,s,record,lease)
    if not ok then return false,why end
    state.holds=state.holds+1
    lease.completed=true
    return true,'holding'
end

-- Refresh map guards even when component addresses did not move. A hash-table
-- replacement alone invalidates the old guards and must not retire a live hold
-- without restoring its controls. The saved turret speeds stay.
local function relocate_lease(lease,s)
    local held=lease.snapshot
    for k,v in pairs(s) do
        if k~='horizontal' and k~='vertical' then held[k]=v end
    end
end
-- The aim record of a row: the same instance keeps it; another instance
-- elsewhere releases it first. Returns true and the record (or nil), or false
-- and the failure.
local function aim_record(api,native,state,s)
    local record=state.records[s.id]
    if record and record.snapshot.key==s.key then
        if record.lease then relocate_lease(record.lease,s) end
        record.snapshot=s
    elseif record and not same(record.snapshot,s) then
        if record.lease then
            local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
        end
        record=nil;state.records[s.id]=nil
    end
    return true,record
end
-- A hold ends when the sentry tracks or scans again, is disabled, or its speeds
-- or other disable bits changed. A non-target point on the firing node is the
-- dead-target fallback, not scanning; a zero point is the observed transition
-- placeholder. It also ends when the engine explicitly reclaimed targeting:
-- restore our speed overrides and wait for a fresh target rather than fighting it.
local function hold_ended(s,tracking,scan)
    if tracking or scan or not s.enabled or s.horizontal~=ZERO or s.vertical~=ZERO
        or bit.band(s.flags,bit.bnot(2))~=0 then return true end
    return bit.band(s.flags,2)==0
end
local function release_hold(api,native,state,record)
    local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
    record.lease=nil;record.raw=nil;state.releases=state.releases+1
    return true
end
-- Records the aim of a synchronized target, or holds it once that target is
-- lost (a scan forgets it instead). Returns true and the record (or nil), or
-- false and the failure.
local function track_or_hold(api,native,state,s,record,tracking,scan)
    if tracking and not (record and record.lease) and s.flags==0 and s.runtime_target==s.target then
        record={snapshot=s,node=s.node,source_point=s.point,raw=s.raw,computed=s.computed}
        state.records[s.id]=record
    elseif record and record.raw and not record.lease and not tracking and s.enabled then
        if scan then record.raw=nil
        else
            local ok,why=acquire(api,native,s,record,state)
            if not ok then return false,why end
        end
    end
    return true,record
end
-- One aim row: returns true and its record (or nil), or false and the failure.
local function aim_row(api,native,state,s)
    local ok,result=aim_record(api,native,state,s)
    if not ok then return false,result end
    local record=result
    local tracking=s.enabled and s.has and s.target~=0 and bit.band(s.source_flags,1)~=0
    local scan=record and s.has and s.target==0 and bit.band(s.source_flags,32)~=0
        and s.node~=record.node and nonzero(s.point) and s.point~=record.source_point
    if record and record.lease and hold_ended(s,tracking,scan) then
        ok,result=release_hold(api,native,state,record)
        if not ok then return false,result end
    end
    ok,result=track_or_hold(api,native,state,s,record,tracking,scan)
    if ok and result then result.latest=s end
    return ok,result
end
local function release_unseen_aim(api,native,state,stamp)
    for id,record in pairs(state.records) do
        if record.seen~=stamp then
            if record.lease then
                local ok,why=M.release(api,native,record.lease);if not ok then return false,why end
            end
            state.records[id]=nil
        end
    end
    return true
end
function M.step(api,native,rows,state)
    state.records=state.records or {}
    state.holds=state.holds or 0;state.releases=state.releases or 0;state.late_aim=state.late_aim or 0
    -- Records seen in this step carry its stamp (no table per step).
    state.observed=#rows;local holding=0
    local stamp=(state.aim_stamp or 0)+1;state.aim_stamp=stamp
    for _,s in ipairs(rows) do
        local ok,result=aim_row(api,native,state,s)
        if not ok then return false,result end
        if result then result.seen=stamp end
        if result and result.lease then holding=holding+1 end
    end
    local ok,why=release_unseen_aim(api,native,state,stamp)
    if not ok then return false,why end
    state.holding=holding
    return true,holding>0 and 'holding' or (#rows>0 and 'observing' or 'waiting_for_sentries'),holding>0
end
-- The aim step stays interpreted, as the single step it replaced always was in
-- the game's LuaJIT 2.1.0-alpha: its traces abort on pairs() and on leaving the
-- row loop. acquire and release, which compiled before, keep compiling.
if jit and jit.off then
    for _,fn in ipairs({relocate_lease,aim_record,hold_ended,release_hold,track_or_hold,aim_row,
        release_unseen_aim,M.step}) do
        jit.off(fn,true)
    end
end

-- A short adjustment may keep firing. A broad or prolonged sweep cannot.
-- Separate enter/exit angles and a settle interval avoid rapid mode toggling.
M.fire_policy={settle_seconds=0.06,sweep_seconds=0.20,reselection_seconds=0.10}
local function direction(x,y,z)
    local length=math.sqrt(x*x+y*y+z*z)
    assert(finite(length) and length>0.00001,'Invalid firing direction')
    return {x/length,y/length,z/length}
end
local function angle(a,b)
    return math.deg(math.acos(math.max(-1,math.min(1,a[1]*b[1]+a[2]*b[2]+a[3]*b[3]))))
end
function M.fire_geometry(s)
    local pose=s.fire.pose
    assert(pose and #pose==64 and vector(pose:sub(17,28)) and vector(pose:sub(49,60)),
        'Invalid muzzle pose')
    local forward=direction(f(pose,16),f(pose,20),f(pose,24))
    local aim=direction(f(s.computed,0)-f(pose,48),f(s.computed,4)-f(pose,52),f(s.computed,8)-f(pose,56))
    return forward,angle(forward,aim)
end
local function fire_identity(api,s)
    local authority=s.authority_address and api.read(s.authority_address,1)
    return matches(api,s.guards) and matches(api,s.fire.guards)
        and (not s.authority_address or (authority and bit.band(authority:byte(1),3)==1))
end
function M.release_selection(api,lease)
    local s=lease.snapshot
    if not fire_identity(api,s) or not matches(api,s.selection.guards)
        or api.read(s.behavior_address+8,4)~=word(12) then return true end
    local current=api.read(s.selection.address,8)
    if not current then return false end
    local ours=current==lease.after
    if not lease.completed then
        for cut=0,8 do
            if current==lease.after:sub(1,cut)..lease.before:sub(cut+1) then ours=true;break end
        end
    end
    -- The native handler consumes the request by setting its own new deadline.
    if not ours or current==lease.before then return true end
    if not api.writable_data(s.selection.address,8) then return false end
    -- The deadline was verified just above; the write does not repeat it.
    local ok,written=pcall(api.write,s.selection.address,lease.before,true)
    return ok and written and api.read(s.selection.address,8)==lease.before
end

-- A pending request is released once the sentry tracks again, leaves the
-- firing node or is disabled, and forgotten once the native handler replaced
-- the deadline it holds.
local function follow_selection(api,r,s,tracking)
    r.selection.snapshot=s
    if tracking or not s.enabled or s.node~=12 then
        if not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
        r.selection=nil
        return true
    end
    local current=api.read(s.selection.address,8)
    if not current then return false,'selection_read_failed' end
    if current~=r.selection.after then r.selection=nil end
    return true
end
-- The new deadline for one request after a target loss on the firing node, or
-- nil when the pending deadline is not within a second or no retry is due.
local function selection_due(r,s)
    local q=s.selection;local deadline=ticks(q.deadline)
    local remaining=deadline-q.now
    -- Bound retries if native perception repeatedly offers a target
    -- that is immediately invalidated again.
    local due=math.max(q.now,(r.last_selection or 0)+M.fire_policy.reselection_seconds*1000000)
    if s.enabled and s.node==12 and not r.selection and q.now>0
        and q.now<9007199254740991 and remaining>0 and remaining<=1000000 and due<deadline then
        return due
    end
end
local function request_selection(api,state,r,s,due)
    local q=s.selection
    if not fire_identity(api,s) or not matches(api,q.guards)
        or not matches(api,s.transition_guards or {})
        or api.read(q.address,8)~=q.deadline then return false,'selection_identity_changed' end
    if not api.writable_data(q.address,8) then return false,'selection_memory_unavailable' end
    r.selection={snapshot=s,before=q.deadline,after=tickword(due)}
    -- Only expire the pending query. Native perception, scoring,
    -- range checks and target assignment still choose the enemy.
    -- The deadline was verified just above; the write does not repeat it.
    if not api.write(q.address,r.selection.after,true)
        or api.read(q.address,8)~=r.selection.after then return false,'selection_request_failed' end
    r.selection.completed=true;r.last_selection=due;state.reselections=state.reselections+1
    return true
end
local function selection_row(api,state,s)
    local r=state.fire_records[s.id]
    local tracking=s.enabled and s.node==12 and s.has and s.target~=0
        and bit.band(s.source_flags,1)~=0
    if r.selection then
        local ok,why=follow_selection(api,r,s,tracking)
        if not ok then return false,why end
    end
    if tracking then r.selection_armed=true
    elseif r.selection_armed and s.target==0 then
        r.selection_armed=false -- one request per observed target loss
        local due=selection_due(r,s)
        if due then return request_selection(api,state,r,s,due) end
    elseif not s.enabled or s.node~=12 then r.selection_armed=false end
    return true
end
function M.selection_step(api,rows,state)
    state.reselections=state.reselections or 0
    local pending=0
    for _,s in ipairs(rows) do
        if s.selection then
            local ok,why=selection_row(api,state,s)
            if not ok then return false,why end
            if state.fire_records[s.id].selection then pending=pending+1 end
        end
    end
    state.selections=pending
    return true
end
function M.release_fire(api,native,lease)
    local s=lease.snapshot
    if not fire_identity(api,s) then return true end
    local current=api.read(s.fire.mode_address,4)
    if not current then return false end
    -- Restore only the no-fire mode owned by this module.
    if current~=ZERO then return true end
    if not api.writable_data(s.fire.mode_address,4) then return false end
    local ok=pcall(native.fire_mode,s.fire.manager,s.id,lease.mode)
    return ok and api.read(s.fire.mode_address,4)==word(lease.mode)
end
-- Restores a fire record's pending selection request, then its no-fire mode.
local function release_fire_record(api,native,r)
    if r.selection and not M.release_selection(api,r.selection) then return false,'selection_restore_failed' end
    if r.lease and not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
    return true
end
-- The fire record for a row. Another instance under the same id releases the
-- old record first; leases follow fresh maps after native compaction.
local function fire_record(api,native,state,s)
    local r=state.fire_records[s.id]
    if r and r.snapshot.key~=s.key then
        local ok,why=release_fire_record(api,native,r)
        if not ok then return nil,why end
        r=nil
    end
    r=r or {};state.fire_records[s.id]=r;r.snapshot=s
    if r.lease then r.lease.snapshot=s end
    if r.selection then r.selection.snapshot=s end
    return r
end
local function fire_tracking(s)
    local tracking=s.enabled and s.has and s.target~=0 and bit.band(s.source_flags,1)~=0
    return tracking,tracking and s.runtime_target==s.target
end
-- A retained direction does not imply that there is still a target to shoot.
-- Never reopen a paused burst merely because it is held. Clearance results
-- belong to one target.
local function fire_terrain(r,s,synced,now)
    if r.terrain_target~=s.target then r.terrain_blocked=nil;r.terrain_checked_at=nil;r.query=nil end
    r.terrain_target=s.target
    if synced and s.fire.terrain_blocked~=nil then
        r.terrain_blocked=s.fire.terrain_blocked;r.query=s.fire.query;r.terrain_checked_at=now
    end
    r.terrain_age=r.terrain_checked_at and now-r.terrain_checked_at or nil
end
local function fire_reason(unavailable,tracking,obstructed)
    return unavailable and (tracking and 'aim_pending' or 'target_lost')
        or (obstructed and 'terrain_blocked' or nil)
end
-- Aim held within the resume angle for settle_seconds moves the anchor.
local function fire_settle(r,aligned,forward,now)
    if aligned then
        r.settled_since=r.settled_since or now
        if now-r.settled_since>=M.fire_policy.settle_seconds then
            r.anchor=forward;r.sweep_since=nil
        end
    else r.settled_since=nil end
end
-- Starts the firing-sweep timer on a turn away from the anchor; returns the
-- turn in degrees. Uses r.synced and r.error of this check.
local function fire_sweep(r,s,forward,aligned,now)
    local travel=angle(r.anchor,forward)
    -- Time with shot permission closed is not a continuing firing sweep.
    if r.lease then r.sweep_since=nil end
    if not s.fire.trigger then
        r.anchor=forward;r.sweep_since=nil
    elseif not aligned and (travel>0.5 or (r.synced and r.error>s.fire.resume)) then
        r.sweep_since=r.sweep_since or now
    end
    return travel
end
-- A broad turn: aim far off target, a wide turn with the trigger held, or a
-- firing sweep that stays unsettled too long.
local function fire_broad(r,s,travel,now)
    return (r.synced and r.error>s.fire.pause)
        or (s.fire.trigger and travel>s.fire.pause)
        or (s.fire.trigger and r.sweep_since and now-r.sweep_since>=M.fire_policy.sweep_seconds)
end
-- Updates the record from this check's aim; returns forward, tracking,
-- unavailable, obstructed, broad and settled.
local function assess_fire(r,s,now)
    local forward,error_angle=M.fire_geometry(s)
    r.error=error_angle;r.anchor=r.anchor or forward
    local tracking,synced=fire_tracking(s)
    fire_terrain(r,s,synced,now)
    local unavailable=not synced and s.fire.trigger
    local obstructed=tracking and r.terrain_blocked==true
    r.reason=fire_reason(unavailable,tracking,obstructed)
    r.synced=synced;r.travel=angle(r.anchor,forward)
    local aligned=synced and not obstructed and error_angle<=s.fire.resume
    fire_settle(r,aligned,forward,now)
    local broad=fire_broad(r,s,fire_sweep(r,s,forward,aligned,now),now)
    if not r.reason and broad then r.reason='sweep' end
    local settled=aligned and now-r.settled_since>=M.fire_policy.settle_seconds
    return forward,tracking,unavailable,obstructed,broad,settled
end
-- Losing a target is not itself a broad turn. A close replacement with a
-- fresh clear ray can use the ordinary short-turn allowance. A broad turn or
-- obstruction observed during the pause cancels this shortcut; those pauses
-- still require settled alignment. Returns whether the handoff applies now.
local function fire_handoff(r,s,broad,obstructed)
    if r.lease and s.fire.mode~=0 then r.lease=nil end -- engine/another mod changed the mode
    if r.lease and (broad or obstructed) then r.lease.handoff=false end
    return r.lease and r.lease.handoff and r.synced
        and s.fire.terrain_blocked==false and r.error<=s.fire.pause and not broad
end
local function resume_fire(api,native,state,r,forward)
    if not M.release_fire(api,native,r.lease) then return false,'fire_restore_failed' end
    r.lease=nil;r.anchor=forward;r.sweep_since=nil
    state.fire_resumes=state.fire_resumes+1
    return true
end
local function pause_fire(api,native,state,r,s,handoff)
    if not fire_identity(api,s) or not matches(api,s.transition_guards or {}) then return false,'fire_identity_changed' end
    if not api.writable_data(s.fire.mode_address,4) then return false,'fire_memory_unavailable' end
    r.lease={snapshot=s,mode=s.fire.mode,handoff=handoff}
    -- Journal before invoking the native setter.
    native.fire_mode(s.fire.manager,s.id,0)
    if api.read(s.fire.mode_address,4)~=ZERO then return false,'fire_pause_failed' end
    state.fire_pauses=state.fire_pauses+1
    return true
end
-- One firing row: returns its record, or nil and the failure.
local function fire_row(api,native,state,s,now)
    local r,why=fire_record(api,native,state,s)
    if not r then return nil,why end
    local forward,tracking,unavailable,obstructed,broad,settled=assess_fire(r,s,now)
    local handoff=fire_handoff(r,s,broad,obstructed)
    local ok=true
    if r.lease and (settled or handoff or (not tracking and not s.fire.trigger) or not s.enabled) then
        ok,why=resume_fire(api,native,state,r,forward)
    elseif not r.lease and (broad or unavailable or obstructed) and s.enabled and s.fire.mode~=0 then
        ok,why=pause_fire(api,native,state,r,s,unavailable and not broad and not obstructed)
    end
    if not ok then return nil,why end
    return r
end
local function release_unseen_fire(api,native,state,stamp)
    for id,r in pairs(state.fire_records) do
        if r.seen~=stamp then
            local ok,why=release_fire_record(api,native,r)
            if not ok then return false,why end
            state.fire_records[id]=nil
        end
    end
    return true
end
function M.fire_step(api,native,rows,state,now)
    state.fire_records=state.fire_records or {}
    state.fire_pauses=state.fire_pauses or 0;state.fire_resumes=state.fire_resumes or 0
    -- Records seen in this step carry its stamp (no table per step).
    local paused=0
    local stamp=(state.fire_stamp or 0)+1;state.fire_stamp=stamp
    for _,s in ipairs(rows) do
        if s.fire then
            local r,why=fire_row(api,native,state,s,now)
            if not r then return false,why end
            r.seen=stamp
            if r.lease then paused=paused+1 end
        end
    end
    local ok,why=release_unseen_fire(api,native,state,stamp)
    if not ok then return false,why end
    state.fire_paused=paused
    return true
end
-- The fire path stays interpreted, as the single fire_step it replaced always
-- was: in the game's LuaJIT 2.1.0-alpha its traces abort in fire_geometry's
-- field decoding and on pairs(). Compiled one by one, these helpers added
-- 8.3 KB of machine code to the cache every mod and the game share (offline
-- median 29.7 -> 38.0 KB) for the same time per call (about 3.0 us in the
-- game's lua51.dll). The functions they call compile as before.
if jit and jit.off then
    for _,fn in ipairs({release_fire_record,fire_record,fire_tracking,fire_terrain,fire_reason,fire_settle,
        fire_sweep,fire_broad,assess_fire,fire_handoff,resume_fire,pause_fire,fire_row,release_unseen_fire,
        M.fire_step}) do
        jit.off(fn,true)
    end
end

-- Verifies the native setters, the pose getter and the terrain query once per
-- session, then binds them.
local function bind_natives(api,game,exe)
    for _,s in ipairs(signatures) do
        local expected=fromhex(s[2])
        assert(api.read(game+s[1],#expected)==expected,'Unsupported native sentry setter')
    end
    local pose_signature=fromhex('40534883ec204863dae89206eaff488bc84c8b0041ff90e8')
    assert(exe and api.read(exe+0x1fd220,#pose_signature)==pose_signature,'Unsupported engine pose getter')
    for _,s in ipairs({
        {0x79f860,'33c04c8d05c7b201020f1f800000000049390cc0740cffc083f80475f3'},
        {0x7f4590,'488bc4f30f11582089480855535657415441554156415748'},
    }) do
        local expected=fromhex(s[2])
        assert(api.read(exe+s[1],#expected)==expected,'Unsupported terrain query')
    end
    return api.bind(game,exe)
end
-- The muzzle pose of a firing row and, while it tracks a synchronized target,
-- the terrain clearance to that target.
-- The snapshot verified every guard of the row in this check; the pose getter
-- checks the unit itself. The transition fields are read again in one read.
local transition_window={n=0}
local function prepare_fire(api,native,s)
    s.fire.pose=native.pose(s.fire.unit,s.fire.node)
    if not (s.enabled and s.has and s.target~=0 and s.runtime_target==s.target
        and bit.band(s.source_flags,1)~=0) then return end
    -- Test the current target point before ballistic/lead correction.
    -- A low target remains legal when the terrain does not occlude it.
    if s.fire.target_unit then
        if matches(api,s.fire.target_guards) then
            s.fire.terrain_blocked,s.fire.query=native.terrain_path(
                s.fire.unit,s.fire.pose:sub(49,60),s.raw,s.fire.target_unit)
        end
        if not matches(api,s.fire.target_guards) then
            s.fire.terrain_blocked,s.fire.query,s.fire.target_stale=nil,nil,true
        end
    end
    transition_window.n=0
    window(api,transition_window,s.transition_address,need(api,s.transition_address,113))
    assert(verified(api,s.transition_guards,transition_window),'Terrain target changed')
end
-- Whether a target loss inside the next game update could matter: a sentry
-- tracks a target, holds aim, pauses fire or waits on a search request.
local function engaged(rows,state)
    if state.holding>0 or state.fire_paused>0 or state.selections>0 then return true end
    for k=1,#rows do
        local s=rows[k]
        if s.has and s.target~=0 then return true end
    end
    return false
end
-- One check. The layout cache lives in state.layout; a failed snapshot drops
-- it, so the next check locates every sentry again.
function M.apply(api,game,exe,state)
    state.engaged=false
    state.layout=state.layout or M.new_cache()
    local ok,rows,reason=pcall(M.snapshot,api,game,state.layout)
    if not ok then state.layout=nil;return false,tostring(rows),false end
    if #rows==0 and not state.native then return true,reason,false end
    if not state.native then state.native=bind_natives(api,game,exe) end
    for _,s in ipairs(rows) do
        if s.fire then prepare_fire(api,state.native,s) end
    end
    local accepted,why=M.fire_step(api,state.native,rows,state,api.time())
    if not accepted then return false,why,false end
    accepted,why=M.selection_step(api,rows,state)
    if not accepted then return false,why,false end
    local accepted,why,active=M.step(api,state.native,rows,state)
    if accepted then state.engaged=engaged(rows,state) end
    if accepted and state.fire_paused>0 then return true,'firing_paused',true end
    return accepted,why,active
end

-- Restores every fire record's search request and fire mode. A record that
-- could not be restored stays for the next attempt.
local function stop_fire(api,state)
    local ok=true
    for id,r in pairs(state.fire_records or {}) do
        local selection_ok=not r.selection or M.release_selection(api,r.selection)
        local fire_ok=not r.lease or M.release_fire(api,state.native,r.lease)
        if selection_ok and fire_ok then state.fire_records[id]=nil else ok=false end
    end
    return ok
end
-- Releases every aim hold. A hold that could not be restored stays.
local function stop_aim(api,state)
    local ok=true
    for id,record in pairs(state.records or {}) do
        if record.lease then
            local restored=M.release(api,state.native,record.lease)
            if restored then state.records[id]=nil else ok=false end
        else state.records[id]=nil end
    end
    return ok
end
function M.stop(api,game,exe,state)
    local fire_ok=stop_fire(api,state)
    return stop_aim(api,state) and fire_ok
end
-- Stopping runs once per stop or shutdown and never compiled (its traces abort
-- on pairs()); it stays interpreted. The releases it calls compile as before.
if jit and jit.off then
    for _,fn in ipairs({stop_fire,stop_aim,M.stop}) do jit.off(fn,true) end
end
return M
