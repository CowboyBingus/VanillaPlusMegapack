local ffi,bit=require('ffi'),require('bit')
local M={}
-- Deepest water (game units above the native root) where a dive keeps the
-- standing reference. 0.20, tightened after the knee-depth test, is the
-- default and the minimum; Mod Options Menu may raise it up to the standing
-- reference itself (1.30), above which the avatar swims and 'deep_water'
-- applies anyway.
M.MIN_WATER_DEPTH,M.SWIM_DEPTH=0.20,1.30
M.max_water_depth=M.MIN_WATER_DEPTH
function M.set_max_water_depth(depth)
    if type(depth)~='number' or depth~=depth then return false end
    M.max_water_depth=math.max(M.MIN_WATER_DEPTH,math.min(M.SWIM_DEPTH,depth))
    return true
end

-- A check allocates nothing. Every read of a snapshot lands in one reused
-- arena (8-byte aligned), addresses are plain numbers, fields decode in place
-- and pointers decode from two 32-bit halves. Each read, or each record inside
-- a bulk read, is remembered as a guard (address, arena offset, size) for the
-- coherence check before a write.
local ARENA,GUARDS=16384,1024
local arena=ffi.new('uint8_t[?]',ARENA)
local words,floats=ffi.cast('uint32_t *',arena),ffi.cast('float *',arena)
local buffer={data=arena,address=tonumber(ffi.cast('uintptr_t',arena)),size=ARENA}
local recheck=ffi.new('uint8_t[?]',4096)
local recheck_buffer={data=recheck,address=tonumber(ffi.cast('uintptr_t',recheck)),size=4096}
local guard_address,guard_offset=ffi.new('double[?]',GUARDS),ffi.new('int32_t[?]',GUARDS)
local guard_size,guard_identity=ffi.new('int32_t[?]',GUARDS),ffi.new('bool[?]',GUARDS)
-- Float conversions through one union: the JIT treats a store and a load of
-- different types as aliasing only when they share a base, so type punning
-- through two separate pointer views of one cell would read a stale value.
-- The arena is written by ReadProcessMemory calls only, which order its loads.
-- The union is declared once by name: an anonymous one in a type string would
-- add C types to the table all mods share on every load.
if not pcall(ffi.typeof,'SwdFloatBits') then ffi.cdef('typedef union { float f; uint32_t u; } SwdFloatBits;') end
local cell=ffi.new('SwdFloatBits')
local function rounded(n) cell.f=n;return cell.f end
local function float_bits(n) cell.f=n;return cell.u end
-- Four-byte strings, for the write and restore paths only.
local function packed(n) return ffi.string(ffi.new('float[1]',n),4) end
local function bits_packed(b) return ffi.string(ffi.new('uint32_t[1]',b),4) end
local function string_u32(bytes) local w=ffi.new('uint32_t[1]');ffi.copy(w,bytes,4);return w[0] end
local function finite(n) return n==n and math.abs(n)<100000 end
local function partial(before,after,current)
    if not current then return false end
    for cut=0,#after do
        if current==after:sub(1,cut)..before:sub(cut+1) then return true end
    end
    return false
end
local DIVE_TIMEOUT_RVAS={0x23c7110,0x23c7100}
local RESOURCE='\151\250\077\041\077\051\028\077'
local RESOURCE_LOW,RESOURCE_HIGH
do
    local id=ffi.new('uint8_t[8]');ffi.copy(id,RESOURCE,8)
    local halves=ffi.cast('uint32_t *',id);RESOURCE_LOW,RESOURCE_HIGH=halves[0],halves[1]
end
local TIMEOUT,PRONE,CROUCH,SETTINGS_BASE=float_bits(2),float_bits(0.9),float_bits(0.4),float_bits(-1.3)
local function matches(api,guards)
    for _,g in ipairs(guards) do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end
-- Waiting reasons, built once, with the names the earlier error-based waits
-- used: 'waiting_for_<stage>_read', '_pointer' and '_global_<rva>'.
local STAGES={}
for _,name in ipairs({'mission','local_player','local_avatar','water','stance','movement','water_settings'}) do
    STAGES[name]={read='waiting_for_'..name..'_read',pointer='waiting_for_'..name..'_pointer',
        invalid='Invalid '..name..' pointer'}
end
local GLOBAL_WAIT={}
for rva,name in pairs({[0x33266a0]='mission',[0x3326468]='local_player',[0x346bf98]='local_avatar',
    [0x3326d20]='local_avatar',[0x3326a80]='water',[0x3326598]='stance',[0x3326558]='movement'}) do
    GLOBAL_WAIT[rva]=string.format('waiting_for_%s_global_%x',name,rva)
end

-- The running check: adapter, game.dll base address, stage, the reason the
-- last helper returned nil, and the arena bytes and guards used so far.
local reader,base,stage,wait,used,guards
local game_pointer,game_address
local function u(o) return words[o/4] end
local function f(o) return floats[o/4] end
local function guard(address,o,size,identity)
    assert(guards<GUARDS,'Too many snapshot guards')
    guard_address[guards],guard_offset[guards],guard_size[guards]=address,o,size
    guard_identity[guards]=identity==true
    guards=guards+1
end
-- One read without a guard: the caller guards the records it uses.
local function fetch(address,size)
    local o=used
    assert(o+size<=ARENA,'Snapshot exceeds its buffer')
    if not reader.read(address,size,buffer,o) then wait=stage.read;return nil end
    used=o+size+(-size)%8
    return o
end
local function read(address,size,identity)
    local o=fetch(address,size)
    if o then guard(address,o,size,identity) end
    return o
end
local function pointer(o)
    local low,high=words[o/4],words[o/4+1]
    if low==0 and high==0 then wait=stage.pointer;return nil end
    local p=high*4294967296+low
    assert(p>=0x10000 and p<0x800000000000,stage.invalid)
    return p
end
local function global(rva,identity)
    local o=read(base+rva,8,identity)
    if not o then return nil end
    if words[o/4]==0 and words[o/4+1]==0 then wait=GLOBAL_WAIT[rva];return nil end
    return pointer(o)
end
-- Low 32 bits of key*mult from 16-bit halves: exact in doubles, no 64-bit cdata.
local function hash(key,mult)
    local kl,kh,ml,mh=bit.band(key,0xffff),bit.rshift(key,16),bit.band(mult,0xffff),bit.rshift(mult,16)
    return kl*ml+bit.band(kh*ml+kl*mh,0xffff)*65536
end
-- The index stored for key, nil when absent, false while waiting.
local function lookup(header,key,limit,identity)
    local capacity,empty,mult=u(header+8),u(header+12),u(header+16)
    if capacity==0 then return nil end
    assert(capacity<=limit and bit.band(capacity,capacity-1)==0,'Unsupported map')
    local data=pointer(header)
    if not data then return false end
    local product=hash(key,mult)
    for probe=0,math.min(capacity,128)-1 do
        local row=read(data+bit.band(product+probe,capacity-1)*8,8,identity)
        if not row then return false end
        if u(row)==key then return u(row+4) end
        if u(row)==empty then return nil end
    end
end
local function same_record(a,b)
    for i=0,5 do if words[a/4+i]~=words[b/4+i] then return false end end
    return true
end

-- Dive controller: the dive record (+0xb84) and state flags (+0xf80), one read.
local CONTROLLER,CONTROLLER_SIZE,FLAGS=0xb84,0x414,0xf80-0xb84
-- Every field a snapshot returns; the one table is reused by every check.
local S={dive=false,swim=false,ragdoll=false,elapsed=0,landing=0,key=0,entity=0,controller=0,id=0,
    manager=0,table=0,water_address=0,enabled=false,water_gate=false,offset=0,offset_bits=0,drown_elapsed=0,remaining=0,
    surface=0,elapsed_bits=0,deep=false,stance_address=0,stance=0,root_z=0,base=0,prone=0}

-- Returns the reused snapshot table, or nil and a waiting reason. The fields
-- stay valid until the next check; S.entity is an arena offset.
function M.snapshot(api,game,state)
    reader,used,guards=api,0,0
    if type(game)=='number' then base=game
    else
        if game~=game_pointer then game_pointer,game_address=game,tonumber(ffi.cast('uintptr_t',game)) end
        base=game_address
    end
    stage=STAGES.mission
    local mode=global(0x33266a0);if not mode then return nil,wait end
    mode=read(mode,0x44);if not mode then return nil,wait end
    if u(mode+8)==0 or u(mode+0x40)<1 or u(mode+0x40)>7 then return nil,'waiting_for_mission' end
    stage=STAGES.local_player
    local pm=global(0x3326468);if not pm then return nil,wait end
    -- Player counts (+0x84), player pointer (+0xe8) and unit (+0x3a8), one read.
    local p=fetch(pm+0x84,0x328);if not p then return nil,wait end
    guard(pm+0x84,p,8)
    assert(u(p)<=4 and u(p+4)<=4,'Unsupported player count')
    if u(p)==0 or u(p+4)==0 then return nil,'waiting_for_local_player' end
    guard(pm+0xe8,p+0x64,8)
    local player=pointer(p+0x64);if not player then return nil,wait end
    player=read(player,24);if not player then return nil,wait end
    if bit.band(arena[player+20],1)==0 then return nil,'waiting_for_local_player' end
    guard(pm+0x3a8,p+0x324,4)
    local unit=u(p+0x324)
    if unit==0x7fff then return nil,'waiting_for_local_avatar' end
    stage=STAGES.local_avatar
    local owner=global(0x346bf98,true);if not owner then return nil,wait end
    local header=read(owner+0xf22ec8,20);if not header then return nil,wait end
    local ei=lookup(header,unit,1048576);if ei==false then return nil,wait end
    if not ei or ei==0xffffffff then return nil,'waiting_for_local_avatar' end
    assert(ei<262144,'Unsupported entity index')
    local entity_address=owner+0xf32f18+ei*24
    local entity=read(entity_address,24,true);if not entity then return nil,wait end
    assert(u(entity)==RESOURCE_LOW and u(entity+4)==RESOURCE_HIGH,'Unsupported avatar resource')
    if bit.band(arena[entity+20],1)==0 then return nil,'waiting_for_local_avatar' end
    local id=u(entity+8)
    local am=global(0x3326d20,true);if not am then return nil,wait end
    -- Avatar count (+0x6c), map header (+0xf8) and registry (+0x110), one read.
    local a=fetch(am+0x6c,0xe4);if not a then return nil,wait end
    guard(am+0xf8,a+0x8c,20)
    local ai=lookup(a+0x8c,id,64);if ai==false then return nil,wait end
    if not ai or ai==0xffffffff then return nil,'waiting_for_local_avatar' end
    guard(am+0x6c,a,4)
    local count=u(a)
    if count==0 then return nil,'waiting_for_local_avatar' end
    assert(count<=8 and ai<count,'Unsupported avatar index')
    guard(am+0x110+ai*8,a+0xa4+ai*8,8,true)
    local registered=pointer(a+0xa4+ai*8);if not registered then return nil,wait end
    registered=read(registered,24,true);if not registered then return nil,wait end
    assert(same_record(registered,entity),'Avatar registry mismatch')
    local controller=am+0x53d900+ai*0x1238
    local c=fetch(controller+CONTROLLER,CONTROLLER_SIZE);if not c then return nil,wait end
    guard(controller+CONTROLLER,c,20);guard(controller+0xf80,c+FLAGS,24)
    assert(u(c)==id,'Dive controller identity mismatch')
    S.dive=bit.band(u(c+FLAGS+12),0x20)~=0
    S.swim=bit.band(u(c+FLAGS+8),0x80000000)~=0
    S.ragdoll=bit.band(u(c+FLAGS+12),0x10)~=0
    S.elapsed,S.landing=f(c+8),f(c+12)
    S.key,S.entity,S.controller,S.id=entity_address,entity,controller,id
    if not S.dive then
        -- Outside a dive, apply() needs only the identity and the dive timer
        -- (it answers 'dive_ended' before reading anything else), so the water,
        -- stance, movement and settings records wait for a dive. They are still
        -- fully read and validated on every dive frame, before any write.
        assert(finite(S.elapsed) and finite(S.landing),'Invalid movement or water value')
        return S
    end
    stage=STAGES.water
    local dm=global(0x3326a80,true);if not dm then return nil,wait end
    -- Record capacity (+8), map header (+32) and the owner, data and enabled
    -- pointers (+56, +64, +72), one read.
    local d=fetch(dm+8,72);if not d then return nil,wait end
    guard(dm+32,d+24,20,true)
    local di=lookup(d+24,id,32768,true);if di==false then return nil,wait end
    guard(dm+8,d,4)
    local capacity=u(d)
    if not di or di==0xffffffff or capacity==0 then return nil,'waiting_for_water_record' end
    assert(di<capacity and capacity<=16384,'Drownable record unavailable')
    guard(dm+56,d+48,8,true)
    local owners=pointer(d+48);if not owners then return nil,wait end
    local drownable=read(owners+8*di,8,true);if not drownable then return nil,wait end
    drownable=pointer(drownable);if not drownable then return nil,wait end
    drownable=read(drownable,24,true);if not drownable then return nil,wait end
    assert(same_record(drownable,entity),'Drownable identity mismatch')
    guard(dm+64,d+56,8,true)
    local data=pointer(d+56);if not data then return nil,wait end
    S.manager,S.table,S.water_address=dm,data,data+28*di
    local water=read(S.water_address,28);if not water then return nil,wait end
    guard(dm+72,d+64,8)
    local enabled=pointer(d+64);if not enabled then return nil,wait end
    enabled=read(enabled+2*di,2);if not enabled then return nil,wait end
    S.enabled,S.water_gate=arena[enabled]~=0,arena[enabled+1]~=0
    assert(u(water+4)==0,'Unsupported water reference node')
    S.offset,S.offset_bits=f(water+8),u(water+8)
    S.drown_elapsed,S.remaining,S.surface=f(water+16),f(water+20),f(water+24)
    S.elapsed_bits=u(water+16)
    S.deep=arena[water+1]~=0
    stage=STAGES.stance
    local sm=global(0x3326598,true);if not sm then return nil,wait end
    -- Map header (+24) and stance data pointer (+56), one read.
    local st=fetch(sm+24,40);if not st then return nil,wait end
    guard(sm+24,st,20,true)
    local si=lookup(st,id,8192,true);if si==false then return nil,wait end
    if not si or si==0xffffffff then return nil,'waiting_for_stance_record' end
    assert(si<4096,'Unsupported stance index')
    guard(sm+56,st+32,8,true)
    local stances=pointer(st+32);if not stances then return nil,wait end
    S.stance_address=stances+56*si+28
    local stance=read(S.stance_address,4);if not stance then return nil,wait end
    S.stance=u(stance)
    if S.stance==3 then return nil,'waiting_for_stance' end
    assert(S.stance<=2,'Unsupported stance')
    stage=STAGES.movement
    local mm=global(0x3326558);if not mm then return nil,wait end
    -- Map header (+0x48a0) and position data pointer (+0x48d8), one read.
    local mv=fetch(mm+0x48a0,64);if not mv then return nil,wait end
    guard(mm+0x48a0,mv,20)
    local mi=lookup(mv,id,16384);if mi==false then return nil,wait end
    if not mi or mi==0xffffffff then return nil,'waiting_for_movement_record' end
    assert(mi<8192,'Unsupported movement index')
    guard(mm+0x48d8,mv+0x38,8)
    local positions=pointer(mv+0x38);if not positions then return nil,wait end
    local pos=read(positions+44*mi,44);if not pos then return nil,wait end
    if arena[pos+32]==0 then return nil,'waiting_for_movement_reference' end
    S.root_z=f(pos+8)
    stage=STAGES.water_settings
    local components=read(owner+0xf12e20,8);if not components then return nil,wait end
    components=pointer(components);if not components then return nil,wait end
    -- The 122-slot resource map and the first six resources, one read.
    local map=fetch(components,122*16+6*64);if not map then return nil,wait end
    guard(components,map,122*16)
    local index
    for slot=0,121 do
        local o=map+slot*16
        if u(o)==RESOURCE_LOW and u(o+4)==RESOURCE_HIGH then index=u(o+8);break end
    end
    if index==nil then return nil,'waiting_for_water_settings' end
    assert(index==5,'Unsupported Drownable resource')
    local resource=map+122*16+64*index
    guard(components+122*16+64*index,resource,64)
    assert(u(resource)==0x4a182741 and u(resource+4)==SETTINGS_BASE,'Drownable settings changed')
    S.base=f(resource+4)
    S.prone=rounded(S.base+rounded(0.9))
    if not (state and state.constants_verified) then
        -- The dive timeout (2.0) and both stance offsets are game.dll read-only
        -- data: verified on the first dive of a session, not on every frame.
        -- Build 25480438 shifted this constant block by 0x10 (both stance
        -- constants below moved); the timeout kept its old address by mistake.
        -- The exact 2.0 value remains the gate; the old address is a fallback.
        local timeout_ok=false
        for i=1,#DIVE_TIMEOUT_RVAS do
            if reader.read(base+DIVE_TIMEOUT_RVAS[i],4,buffer,used) and u(used)==TIMEOUT then timeout_ok=true;break end
        end
        if not timeout_ok then
            -- Evidence for the next migration: every 2.0 near the expected block.
            local window,two=reader.read(base+0x23c7080,0x100) or '',packed(2)
            local found={}
            for o=0,#window-4,4 do if window:sub(o+1,o+4)==two then found[#found+1]=string.format('0x%x',0x23c7080+o) end end
            error(string.format('Native dive timeout changed (2.0 near expected block at: %s)',
                #found>0 and table.concat(found,',') or 'none'),0)
        end
        local prone=read(base+0x23c6ccc,4);if not prone then return nil,wait end
        assert(u(prone)==PRONE,'Stance offsets changed')
        local crouch=read(base+0x23c69f8,4);if not crouch then return nil,wait end
        assert(u(crouch)==CROUCH,'Stance offsets changed')
        if state then state.constants_verified=true end
    end
    assert(finite(S.elapsed) and finite(S.landing) and finite(S.offset) and finite(S.drown_elapsed)
        and finite(S.remaining) and finite(S.surface) and finite(S.root_z),'Invalid movement or water value')
    return S
end

-- Returns a reason rather than changing the game. The native landing timer is
-- zero in flight and becomes positive when the native land_dodge path begins.
function M.reason(s)
    if not s.dive then return 'dive_ended' end
    if s.swim or s.ragdoll or s.stance~=2 then return 'other_state' end
    if not s.enabled or s.remaining<=0 then return 'water_disabled_or_drowned' end
    if s.landing~=0 then return 'landing' end
    if s.elapsed<0 or s.elapsed>=2 then return 'native_timeout' end
    -- A disabled secondary gate makes surface_z a reset value, not a plane.
    if s.deep or s.water_gate and s.surface>s.root_z-s.base then return 'deep_water' end
    -- A reset surface value is not evidence of water. Restrict the assistance
    -- to the configured depth (lower shin by default); deeper water keeps the
    -- game's normal dive decision.
    if not s.water_gate then return 'water_surface_unavailable' end
    local depth=s.surface-s.root_z
    if depth<=0 then return 'not_in_shallow_water' end
    if depth>M.max_water_depth+0.00001 then return 'water_too_deep' end
    return nil
end

-- reuse: the caller just saw a normal dive end with a fresh snapshot, so the
-- page check made when this lease began still covers its record once the
-- identity below (the table pointer included) matches. Every other caller
-- (shutdown, stops, waits, failed writes) checks the page again.
function M.restore(api,pending,reuse)
    if not pending then return true,'nothing_to_restore' end
    if not matches(api,pending.identity) then return true,'retired_identity' end
    local checked=reuse and pending.checked
    if pending.elapsed_recovery then
        local e=pending.elapsed_recovery
        local current=api.read(e.address,4)
        if partial(e.before,e.after,current) and current~=e.before then
            api.write(e.address,e.before,checked)
            if api.read(e.address,4)~=e.before then return false,'startup_restore_failed' end
        end
        pending.elapsed_recovery=nil
    end
    local current=api.read(pending.address,4)
    local ours=current==pending.after
        or pending.failed_write and partial(pending.before,pending.after,current)
        or pending.recovery and partial(pending.recovery.before,pending.recovery.after,current)
    if not ours then return true,'offset_changed_by_engine' end
    local stance=api.read(pending.stance_address,4)
    if not stance then return false,'stance_unavailable' end
    local index=string_u32(stance)
    if index>2 then return false,'stance_unavailable' end
    -- A native transition to standing may already have written the same bytes
    -- we used. Restore the CURRENT stance's default, never stale prone bytes.
    local target=packed(rounded(pending.base+(index==2 and rounded(0.9) or index==1 and rounded(0.4) or 0)))
    if current==target then return true,'already_restored' end
    if not matches(api,pending.identity) then return true,'retired_identity' end
    pending.recovery={before=current,after=target}
    if not api.write(pending.address,target,checked) then return false,'offset_not_writable' end
    return api.read(pending.address,4)==target,'restored'
end

-- Re-reads the current snapshot's guards (all, or the identity ones) and
-- compares them byte for byte with what the snapshot saw.
local function guards_match(api,identity_only)
    for i=0,guards-1 do
        if guard_identity[i] or not identity_only then
            local o,size=guard_offset[i],guard_size[i]
            if not api.read(guard_address[i],size,recheck_buffer,0) then return false end
            for j=0,size-1 do if recheck[j]~=arena[o+j] then return false end end
        end
    end
    return true
end
-- The identity guards as strings, kept by a lease for restore().
local function identity_list()
    local list={}
    for i=0,guards-1 do
        if guard_identity[i] then
            list[#list+1]={address=guard_address[i],bytes=ffi.string(arena+guard_offset[i],guard_size[i])}
        end
    end
    return list
end
local function release(api,state,reason,reuse)
    local ok=M.restore(api,state.pending,reuse)
    if ok then state.pending=nil;state.restored=state.restored+1 end
    return ok,ok and reason or 'restore_failed',false
end
local function same_entity(seen,o)
    for i=0,5 do if seen[i]~=words[o/4+i] then return false end end
    return true
end

-- Page check for the two water-record writes. A protection query costs about
-- 0.2-0.3 ms in game, so one runs per record table, not per write: the span
-- it approved is kept while the same Drownable manager, table and avatar are
-- in use (the guards re-read the table pointer and the record's owner right
-- before every write) and is dropped on any wait, avatar change or failed
-- write. A table seen at a new address while one was kept counts as a move.
local function writable(api,state,s)
    local low,high=s.water_address+8,s.water_address+20
    local c=state.write_check
    if c and c.manager==s.manager and c.table==s.table and c.key==state.key and c.low<=low and high<=c.high then
        return true
    end
    if c and (c.manager~=s.manager or c.table~=s.table) then state.table_moves=state.table_moves+1 end
    state.write_check=nil
    local ok,from,to=api.writable_data(low,high-low)
    if not ok then return false end
    state.write_check={manager=s.manager,table=s.table,key=state.key,low=from,high=to}
    return true
end

-- Idle gate. After a full check found the local avatar, the next GATE_CHECKS
-- checks read only its dive controller: the same avatar id, no dive flag and
-- finite timers mean 'dive_ended', exactly what the full check answers there.
-- Anything else (a dive, another id, a failed read) runs the full check at
-- once, and every GATE_CHECKS+1-th check is a full one to follow avatar and
-- mission changes (about 0.25 s at 60 FPS with both boundaries).
local GATE_CHECKS=30
local function idle(api,state)
    if not api.read(state.gate_controller+CONTROLLER,CONTROLLER_SIZE,buffer,0) or words[0]~=state.gate_id
        or bit.band(words[(FLAGS+12)/4],0x20)~=0 then return false end
    return finite(floats[2]) and finite(floats[3])
end

function M.apply(api,game,exe,state)
    if state.gate_controller and state.gate_left>0 and not (state.pending or state.retry_start or state.was_dive) then
        state.gate_left=state.gate_left-1
        if idle(api,state) then return true,'dive_ended',false end
    end
    local s,waiting=M.snapshot(api,game,state)
    if not s then
        -- Clear only what is set: storing nil under a missing key still adds
        -- the key, and the resize that can follow allocates on waiting checks.
        if state.gate_controller then state.gate_controller=nil end
        if state.write_check then state.write_check=nil end
        if state.key then state.key=nil end
        state.was_dive=false;state.retry_start=false
        if state.pending then return release(api,state,waiting) end
        return true,waiting,false
    end
    local seen=state.entity_words
    if not seen then seen=ffi.new('uint32_t[6]');state.entity_words=seen end
    if state.key~=s.key or not same_entity(seen,s.entity) then
        if state.pending then
            local ok=M.restore(api,state.pending)
            if not ok then return false,'restore_failed',false end
            state.pending=nil
        end
        state.key=s.key;state.was_dive=false;state.retry_start=false
        if state.write_check then state.write_check=nil end
        for i=0,5 do seen[i]=words[s.entity/4+i] end
    end
    state.gate_controller,state.gate_id,state.gate_left=s.controller,s.id,GATE_CHECKS
    local new_dive=s.dive and not state.was_dive
    if new_dive then state.observed=state.observed+1 end
    if state.was_dive and not s.dive and s.elapsed<=0.02 then state.short_ends=state.short_ends+1 end
    state.was_dive=s.dive
    local reason=M.reason(s)
    if state.pending then
        if reason then return release(api,state,reason,true) end
        if s.offset_bits~=state.pending.after_bits then return release(api,state,'offset_changed_by_engine') end
        return true,'airborne_reference',true
    end
    if reason then state.retry_start=false;return true,reason,false end
    -- Do not acquire an old dive after module load or rescue an ongoing swim.
    if not (new_dive or state.retry_start) or s.elapsed>0.05 then return true,'waiting_for_dive_start',false end
    state.retry_start=false
    if s.drown_elapsed>0.05 or s.drown_elapsed>0 and not s.water_gate then
        return true,'existing_submersion',false
    end
    if s.offset_bits~=float_bits(s.prone) then return true,'different_reference_owner',false end
    local address=s.water_address+8
    if not guards_match(api,false) then
        -- Retry a coherent snapshot at the other update boundary in this frame.
        state.retry_start=true
        return true,'snapshot_changed',false
    end
    -- Both floats of the record in one page check, kept per table (see
    -- writable). A refused page stops the mod before anything is written.
    if not writable(api,state,s) then return false,'reference_write_failed',false end
    state.pending={address=address,before=bits_packed(s.offset_bits),after=packed(s.base),
        after_bits=float_bits(s.base),identity=identity_list(),stance_address=s.stance_address,base=s.base,
        checked=true}
    local ok=api.write(address,state.pending.after,true)
    if not ok or api.read(address,4)~=state.pending.after then
        -- A partially written float can contain neither complete value. We own
        -- this exact attempted write, and the entity/record must still match.
        -- The kept page check is dropped; the restore checks the page again.
        state.write_check=nil
        state.pending.failed_write=true
        ok=M.restore(api,state.pending)
        if ok then state.pending=nil end
        return false,'reference_write_failed',false
    end
    -- The water update may already have counted the first prone frame. Clear
    -- only that startup debt, once, while the standing reference is above water.
    if s.drown_elapsed>0 and s.drown_elapsed<=0.05 and s.water_gate then
        local elapsed_address,elapsed_bytes,zero=s.water_address+16,bits_packed(s.elapsed_bits),packed(0)
        if not guards_match(api,true) then return release(api,state,'identity_changed') end
        if api.read(elapsed_address,4)~=elapsed_bytes then return release(api,state,'water_changed') end
        local cleared=api.write(elapsed_address,zero,true) and api.read(elapsed_address,4)==zero
        if not cleared then
            state.write_check=nil
            state.pending.elapsed_recovery={address=elapsed_address,before=elapsed_bytes,after=zero}
            release(api,state,'startup_write_failed')
            return false,'startup_write_failed',false
        end
        state.startup_clears=state.startup_clears+1
    elseif s.drown_elapsed>0 then
        return release(api,state,'existing_submersion')
    end
    state.protected=state.protected+1
    return true,'airborne_reference',true
end

-- The full snapshot is long straight-line code that runs every 31st idle
-- check and on dive frames. Compiled, it took 50-74 KB of the LuaJIT code
-- cache every mod and the game share, to save about 6 us per dive-frame check
-- (measured in the game's lua51.dll); interpreted, the helpers it calls still
-- compile and the mod's machine code stays at 9-13 KB. The idle gate is
-- unaffected. This only marks this one function; it flushes nothing else.
if jit and jit.off then jit.off(M.snapshot) end

return M
