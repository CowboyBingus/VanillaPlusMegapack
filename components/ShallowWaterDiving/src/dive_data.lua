local ffi,bit=require('ffi'),require('bit')
local M={}
local MAX_WATER_DEPTH=0.20 -- game units above the native root; tightened after the knee-depth test
-- Fields decode through one reused cell per type. The previous b:sub(o+1)
-- copied the whole rest of the buffer for every field read; out-of-range
-- offsets keep that original path, so every result is unchanged.
local decode_cells={}
local function value(b,o,kind)
    local cell=decode_cells[kind]
    if not cell then cell=ffi.new(kind..'[1]');decode_cells[kind]=cell end
    local size=ffi.sizeof(cell)
    if o>=0 and o+size<=#b then ffi.copy(cell,ffi.cast('const uint8_t *',b)+o,size)
    else ffi.copy(cell,b:sub(o+1),size) end
    return tonumber(cell[0])
end
local function u(b,o) return value(b,o,'uint32_t') end
local function f(b,o) return value(b,o,'float') end
local function packed(n) return ffi.string(ffi.new('float[1]',n),4) end
local function rounded(n) return tonumber(ffi.new('float[1]',n)[0]) end
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
local function matches(api,guards)
    for _,g in ipairs(guards) do if api.read(g.address,#g.bytes)~=g.bytes then return false end end
    return true
end

function M.snapshot(api,game)
    local s={guards={},identity={}}
    local stage='mission'
    local function waiting(detail)
        error({not_ready=true,reason='waiting_for_'..stage..'_'..detail},0)
    end
    local function read(address,size,identity)
        local bytes=api.read(address,size)
        if not bytes then waiting('read') end
        assert(#bytes==size,'Short game read')
        local guard={address=address,bytes=bytes};s.guards[#s.guards+1]=guard
        if identity then s.identity[#s.identity+1]=guard end
        return bytes
    end
    local function pointer(b,o)
        o=o or 0
        assert(b and o>=0 and o+8<=#b,'Invalid pointer bytes')
        if b:sub(o+1,o+8)==string.rep('\0',8) then waiting('pointer') end
        return assert(api.pointer(b,o),'Invalid '..stage..' pointer')
    end
    local function global(rva,identity)
        local bytes=read(game+rva,8,identity)
        if bytes==string.rep('\0',8) then waiting(string.format('global_%x',rva)) end
        return pointer(bytes)
    end
    local function lookup(header,key,limit,identity)
        local capacity,empty,mult=u(header,8),u(header,12),u(header,16)
        if capacity==0 then return nil end
        assert(capacity<=limit and bit.band(capacity,capacity-1)==0,'Unsupported map')
        local data=pointer(header)
        local product=ffi.new('uint64_t',key)*ffi.new('uint64_t',mult)
        for probe=0,math.min(capacity,128)-1 do
            local slot=bit.band(tonumber(ffi.cast('uint32_t',product))+probe,capacity-1)
            local row=read(data+slot*8,8,identity)
            if u(row,0)==key then return u(row,4) end
            if u(row,0)==empty then return nil end
        end
    end
    local mode=read(global(0x33266a0),0x44)
    if u(mode,8)==0 or u(mode,0x40)<1 or u(mode,0x40)>7 then return nil,'waiting_for_mission' end
    stage='local_player'
    local pm=global(0x3326468)
    local counts=read(pm+0x84,8)
    assert(u(counts,0)<=4 and u(counts,4)<=4,'Unsupported player count')
    if u(counts,0)==0 or u(counts,4)==0 then return nil,'waiting_for_local_player' end
    local player=read(pointer(read(pm+0xe8,8)),24)
    if bit.band(player:byte(21),1)==0 then return nil,'waiting_for_local_player' end
    local unit=u(read(pm+0x3a8,4),0)
    if unit==0x7fff then return nil,'waiting_for_local_avatar' end
    stage='local_avatar'
    local owner=global(0x346bf98,true)
    local ei=lookup(read(owner+0xf22ec8,20),unit,1048576)
    if not ei or ei==0xffffffff then return nil,'waiting_for_local_avatar' end
    assert(ei<262144,'Unsupported entity index')
    local entity_address=owner+0xf32f18+ei*24
    local entity=read(entity_address,24,true)
    assert(entity:sub(1,8)==RESOURCE,'Unsupported avatar resource')
    if bit.band(entity:byte(21),1)==0 then return nil,'waiting_for_local_avatar' end
    local id=u(entity,8)
    local am=global(0x3326d20,true)
    local ai=lookup(read(am+0xf8,20),id,64)
    if not ai or ai==0xffffffff then return nil,'waiting_for_local_avatar' end
    local count=u(read(am+0x6c,4),0)
    if count==0 then return nil,'waiting_for_local_avatar' end
    assert(count<=8 and ai<count,'Unsupported avatar index')
    assert(read(pointer(read(am+0x110+ai*8,8,true)),24,true)==entity,'Avatar registry mismatch')
    local ctl=am+0x53d900+ai*0x1238
    local dive=read(ctl+0xb84,20)
    assert(u(dive,0)==id,'Dive controller identity mismatch')
    local flags=read(ctl+0xf80,24)
    s.dive=bit.band(u(flags,12),0x20)~=0
    s.swim=bit.band(u(flags,8),0x80000000)~=0
    s.ragdoll=bit.band(u(flags,12),0x10)~=0
    s.elapsed=f(dive,8);s.landing=f(dive,12)
    if not s.dive then
        -- Outside a dive, apply() needs only the identity and the dive timer
        -- (it answers 'dive_ended' before reading anything else), so the water,
        -- stance, movement and settings records wait for a dive. They are still
        -- fully read and validated on every dive frame, before any write.
        assert(finite(s.elapsed) and finite(s.landing),'Invalid movement or water value')
        s.key=entity_address;s.entity=entity
        return s
    end
    stage='water'
    local dm=global(0x3326a80,true)
    local di=lookup(read(dm+32,20,true),id,32768,true)
    local capacity=u(read(dm+8,4),0)
    if not di or di==0xffffffff or capacity==0 then return nil,'waiting_for_water_record' end
    assert(di and di<capacity and capacity<=16384,'Drownable record unavailable')
    local entities=pointer(read(dm+56,8,true))
    assert(read(pointer(read(entities+8*di,8,true)),24,true)==entity,'Drownable identity mismatch')
    local data=pointer(read(dm+64,8,true))
    s.water_address=data+28*di
    local water=read(s.water_address,28)
    local enabled=read(pointer(read(dm+72,8))+2*di,2)
    s.enabled=enabled:byte(1)~=0;s.water_gate=enabled:byte(2)~=0
    assert(u(water,4)==0,'Unsupported water reference node')
    s.offset=f(water,8);s.offset_bytes=water:sub(9,12)
    s.drown_elapsed=f(water,16);s.remaining=f(water,20);s.surface=f(water,24)
    s.elapsed_bytes=water:sub(17,20)
    s.deep=water:byte(2)~=0
    stage='stance'
    local sm=global(0x3326598,true)
    local si=lookup(read(sm+24,20,true),id,8192,true)
    if not si or si==0xffffffff then return nil,'waiting_for_stance_record' end
    assert(si<4096,'Unsupported stance index')
    local stance_data=pointer(read(sm+56,8,true))
    s.stance_address=stance_data+56*si+28
    s.stance=u(read(s.stance_address,4),0)
    if s.stance==3 then return nil,'waiting_for_stance' end
    assert(s.stance<=2,'Unsupported stance')
    stage='movement'
    local mm=global(0x3326558)
    local mi=lookup(read(mm+0x48a0,20),id,16384)
    if not mi or mi==0xffffffff then return nil,'waiting_for_movement_record' end
    assert(mi<8192,'Unsupported movement index')
    local pos=read(pointer(read(mm+0x48d8,8))+44*mi,44)
    if pos:byte(33)==0 then return nil,'waiting_for_movement_reference' end
    s.root_z=f(pos,8)
    stage='water_settings'
    local components=pointer(read(owner+0xf12e20,8))
    local map=read(components,122*16)
    local index
    for slot=0,121 do
        if map:sub(slot*16+1,slot*16+8)==RESOURCE then index=u(map,slot*16+8);break end
    end
    if index==nil then return nil,'waiting_for_water_settings' end
    assert(index==5,'Unsupported Drownable resource')
    local resource=read(components+122*16+64*index,64)
    assert(u(resource,0)==0x4a182741 and resource:sub(5,8)==packed(-1.3),'Drownable settings changed')
    s.base=f(resource,4)
    s.prone=rounded(s.base+rounded(0.9))
    -- Build 25480438 shifted this constant block by 0x10 (both stance
    -- constants below moved); the timeout kept its old address by mistake.
    -- The exact 2.0 value remains the gate; the old address is a fallback.
    local timeout_ok=false
    for _,rva in ipairs(DIVE_TIMEOUT_RVAS) do
        if api.read(game+rva,4)==packed(2) then timeout_ok=true;break end
    end
    if not timeout_ok then
        -- Evidence for the next migration: every 2.0 near the expected block.
        local window=api.read(game+0x23c7080,0x100) or ''
        local found={}
        for o=0,#window-4,4 do if window:sub(o+1,o+4)==packed(2) then found[#found+1]=string.format('0x%x',0x23c7080+o) end end
        error(string.format('Native dive timeout changed (2.0 near expected block at: %s)',
            #found>0 and table.concat(found,',') or 'none'),0)
    end
    assert(read(game+0x23c6ccc,4)==packed(0.9) and read(game+0x23c69f8,4)==packed(0.4),'Stance offsets changed')
    for _,n in ipairs({s.elapsed,s.landing,s.offset,s.drown_elapsed,s.remaining,s.surface,s.root_z}) do
        assert(finite(n),'Invalid movement or water value')
    end
    s.key=entity_address;s.entity=entity
    return s
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
    -- to lower-shin depth; deeper water keeps the game's normal dive decision.
    if not s.water_gate then return 'water_surface_unavailable' end
    local depth=s.surface-s.root_z
    if depth<=0 then return 'not_in_shallow_water' end
    if depth>MAX_WATER_DEPTH+0.00001 then return 'water_too_deep' end
    return nil
end

function M.restore(api,pending)
    if not pending then return true,'nothing_to_restore' end
    if not matches(api,pending.identity) then return true,'retired_identity' end
    if pending.elapsed_recovery then
        local e=pending.elapsed_recovery
        local current=api.read(e.address,4)
        if partial(e.before,e.after,current) and current~=e.before then
            api.write(e.address,e.before)
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
    local index=u(stance,0)
    if index>2 then return false,'stance_unavailable' end
    -- A native transition to standing may already have written the same bytes
    -- we used. Restore the CURRENT stance's default, never stale prone bytes.
    local target=packed(rounded(pending.base+(index==2 and rounded(0.9) or index==1 and rounded(0.4) or 0)))
    if current==target then return true,'already_restored' end
    if not matches(api,pending.identity) then return true,'retired_identity' end
    if not api.writable_data(pending.address,4) then return false,'offset_not_writable' end
    pending.recovery={before=current,after=target}
    api.write(pending.address,target)
    return api.read(pending.address,4)==target,'restored'
end

function M.apply(api,game,exe,state)
    local called,s,waiting=pcall(M.snapshot,api,game)
    if not called then
        if type(s)=='table' and s.not_ready then waiting=s.reason;s=nil
        else error(s,0) end
    end
    local function release(reason)
        local ok=M.restore(api,state.pending)
        if ok then state.pending=nil;state.restored=state.restored+1 end
        return ok,ok and reason or 'restore_failed',false
    end
    if not s then
        state.was_dive=false;state.key=nil;state.retry_start=false
        if state.pending then return release(waiting) end
        return true,waiting,false
    end
    if state.key~=s.key or state.entity~=s.entity then
        if state.pending then
            local ok=M.restore(api,state.pending)
            if not ok then return false,'restore_failed',false end
            state.pending=nil
        end
        state.key=s.key;state.entity=s.entity;state.was_dive=false;state.retry_start=false
    end
    local new_dive=s.dive and not state.was_dive
    if new_dive then state.observed=state.observed+1 end
    if state.was_dive and not s.dive and s.elapsed<=0.02 then state.short_ends=state.short_ends+1 end
    state.was_dive=s.dive
    local reason=M.reason(s)
    if state.pending then
        if reason then return release(reason) end
        if s.offset_bytes~=state.pending.after then return release('offset_changed_by_engine') end
        return true,'airborne_reference',true
    end
    if reason then state.retry_start=false;return true,reason,false end
    -- Do not acquire an old dive after module load or rescue an ongoing swim.
    if not (new_dive or state.retry_start) or s.elapsed>0.05 then return true,'waiting_for_dive_start',false end
    state.retry_start=false
    if s.drown_elapsed>0.05 or s.drown_elapsed>0 and not s.water_gate then
        return true,'existing_submersion',false
    end
    if s.offset_bytes~=packed(s.prone) then return true,'different_reference_owner',false end
    local address=s.water_address+8
    if not api.writable_data(address,4) or not api.writable_data(s.water_address+16,4) then
        return false,'water_record_not_writable',false
    end
    if not matches(api,s.guards) then
        -- Retry a coherent snapshot at the other update boundary in this frame.
        state.retry_start=true
        return true,'snapshot_changed',false
    end
    state.pending={address=address,before=s.offset_bytes,after=packed(s.base),identity=s.identity,
        stance_address=s.stance_address,base=s.base}
    local ok=api.write(address,state.pending.after)
    if not ok or api.read(address,4)~=state.pending.after then
        -- A partially written float can contain neither complete value. We own
        -- this exact attempted write, and the entity/record must still match.
        state.pending.failed_write=true
        ok=M.restore(api,state.pending)
        if ok then state.pending=nil end
        return false,'reference_write_failed',false
    end
    -- The water update may already have counted the first prone frame. Clear
    -- only that startup debt, once, while the standing reference is above water.
    if s.drown_elapsed>0 and s.drown_elapsed<=0.05 and s.water_gate then
        local elapsed_address=s.water_address+16
        if not matches(api,s.identity) then return release('identity_changed') end
        if api.read(elapsed_address,4)~=s.elapsed_bytes then return release('water_changed') end
        local cleared=api.write(elapsed_address,packed(0)) and api.read(elapsed_address,4)==packed(0)
        if not cleared then
            state.pending.elapsed_recovery={address=elapsed_address,before=s.elapsed_bytes,after=packed(0)}
            release('startup_write_failed')
            return false,'startup_write_failed',false
        end
        state.startup_clears=state.startup_clears+1
    elseif s.drown_elapsed>0 then
        return release('existing_submersion')
    end
    state.protected=state.protected+1
    return true,'airborne_reference',true
end

return M
