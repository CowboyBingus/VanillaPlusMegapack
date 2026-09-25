local ffi, bit = require('ffi'), require('bit')
local patch = {}
local unavailable = {}
local function u32(bytes, offset)
    local a,b,c,d = bytes:byte(offset+1, offset+4)
    assert(d, 'Truncated data')
    return a + 256*b + 65536*c + 16777216*d
end
local function vector(bytes, offset)
    local value = ffi.new('float[3]')
    ffi.copy(value, bytes:sub(offset+1, offset+12), 12)
    for i=0,2 do
        if value[i] ~= value[i] or math.abs(value[i]) > 100000 then return nil end
    end
    return {tonumber(value[0]), tonumber(value[1]), tonumber(value[2])}
end
local function float(bytes, offset)
    local value = ffi.new('float[1]')
    ffi.copy(value, bytes:sub(offset+1, offset+4), 4)
    return tonumber(value[0])
end
local function xy_bytes(v)
    return ffi.string(ffi.new('float[2]', {v[1], v[2]}), 8)
end
local function same_xy(a,b)
    return a and b and math.abs(a[1]-b[1]) < 0.05 and math.abs(a[2]-b[2]) < 0.05
end
local function first_unused(beacons,mask)
    local first,count=nil,0
    for _,beacon in ipairs(beacons or {}) do
        if bit.band(beacon.used,mask)==0 then
            first=first or beacon
            count=count+1
        end
    end
    return first,count
end

-- Each address below comes from the build-locked read-only native/data trace.
-- Pointer following is read-only. The only write site is player_manager+0x10C.
local function snapshot(api, game, exe)
    local stage='player_manager'
    local function wait_for_data()
        error({kind=unavailable,status='waiting_for_game_data:'..stage},0)
    end
    local function read(address, size)
        local bytes=api.read(address,size)
        if not bytes then wait_for_data() end
        assert(#bytes==size,'Truncated spawn data: '..stage)
        return bytes
    end
    local function data_pointer(bytes,offset)
        offset=offset or 0
        if bytes:sub(offset+1,offset+8)==string.rep('\0',8) then wait_for_data() end
        local value=api.pointer(bytes,offset)
        assert(value,'Invalid spawn data pointer: '..stage)
        return value
    end
    local function pointer(address) return data_pointer(read(address,8)) end
    local function global(rva,name)
        stage=name
        return pointer(game+rva)
    end
    local function lookup(header, key)
        local capacity, empty, multiplier = u32(header,8), u32(header,12), u32(header,16)
        if capacity == 0 then return nil end
        assert(capacity <= 1048576 and bit.band(capacity,capacity-1)==0, 'Invalid lookup capacity')
        local table_address = data_pointer(header)
        -- Exact low-word multiplication: Lua doubles cannot multiply two arbitrary uint32s exactly.
        local product = bit.tobit(tonumber(ffi.cast('uint32_t', ffi.new('uint64_t',key)*multiplier)))
        for probe=0,math.min(capacity,128)-1 do
            local slot = bit.band(product+probe,capacity-1)
            local row = read(table_address+8*slot,8)
            if u32(row,0)==key then
                local index=u32(row,4)
                if index~=0xffffffff then return index end
                return nil
            end
            if u32(row,0)==empty then return nil end
        end
        return nil
    end
    local pm = global(0x3326468,'player_manager')
    local players = read(pm,0x440)
    local count, available = u32(players,0x84),u32(players,0x88)
    assert(count<=4 and available<=4, 'Unsupported player layout')
    local mode = read(global(0x33266a0,'mission_mode'),0x44)
    local snapshot = {identity=tostring(pm), address=pm+0x10C, count=count,
                      mode=u32(mode,8)>0 and u32(mode,0x40) or 0, beacons={}, automatic={}}
    -- Native player logic accepts gameplay modes 1..7, including defense (2).
    if count==0 or available==0 or snapshot.mode<1 or snapshot.mode>7 then return snapshot end
    stage='local_player'
    local entity_pointer=data_pointer(players,0xE8)
    local entity=read(entity_pointer,24)
    snapshot.id, snapshot.owned = u32(entity,8),bit.band(entity:byte(21),1)==1
    snapshot.state, snapshot.use_bit = u32(players,0x2E0),u32(players,0x3B4)
    snapshot.position=vector(players,0x10C)
    snapshot.original=players:sub(0x10D,0x114)
    snapshot.countdown=float(players,0x12C)
    snapshot.unit_ref=u32(players,0x3A8)
    assert(snapshot.use_bit<32, 'Unsupported player-use bit')
    if not snapshot.owned then return snapshot end
    local rm, posm = global(0x33269c0,'reinforcement_manager'),global(0x3326b20,'position_manager')
    local reinforcement, positions = read(rm,0x58),read(posm,0x60)
    local active=u32(reinforcement,12)
    assert(active<=128 and active<=u32(reinforcement,8), 'Unsupported reinforcement layout')
    local function position(id)
        local index=lookup(positions:sub(0x29,0x3C),id)
        if not index then return nil end
        assert(index<u32(positions,8), 'Position index outside live data')
        return vector(read(data_pointer(positions,0x50)+index*12,12),0)
    end
    if active>0 then
        stage='reinforcement_records'
        local entities,used=data_pointer(reinforcement,0x38),data_pointer(reinforcement,0x48)
        for i=0,active-1 do
            local e=read(pointer(entities+8*i),24)
            local id=u32(e,8)
            snapshot.beacons[#snapshot.beacons+1]={id=id, owned=bit.band(e:byte(21),1)==1, position=position(id),
                used=u32(read(used+4*i,4),0)}
        end
    end
    if count~=1 then return snapshot end
    local sm=global(0x33266b0,'automatic_anchor_manager')
    local stratagems=read(sm,0x80)
    local n=u32(stratagems,0x34)
    assert(n<=512, 'Unsupported active stratagem count')
    if n>0 then
        local data=data_pointer(stratagems,0x78)
        local rows=read(data,n*64)
        for i=0,n-1 do
            local base=i*64
            -- Current automatic-reinforcement producer ACCC96 / ACCEC5.
            if u32(rows,base+12)==0x7C then
                local v=vector(rows,base+16)
                if v then snapshot.automatic[#snapshot.automatic+1]={
                    key=rows:sub(base+17,base+28),position=v} end
            end
        end
    end
    -- Reproduce AC5BB0's unit-world-position read, without calling native code.
    local em=global(0x346bf98,'source_entity_manager')
    local index=snapshot.unit_ref~=0x7fff and lookup(read(em+15871688,20),snapshot.unit_ref) or nil
    if index then
        assert(index<262144, 'Entity index outside supported bound')
        local e=read(em+15937304+24*index,24)
        local engine_ref=u32(e,12)
        stage='source_unit_registry'
        local registry=pointer(exe+0x1a100f0)
        local header=read(registry,0xA8)
        local slot,generation=bit.band(engine_ref,0x3fffff),bit.rshift(engine_ref,22)
        assert(slot<u32(header,0x98), 'Unit slot outside registry')
        local generations=data_pointer(header,0xA0)
        assert(read(generations+slot,1):byte()==generation, 'Unit generation changed')
        local objects=data_pointer(header,0x88)
        local object=pointer(objects+8*slot)
        local vtable=pointer(object)
        assert(api.distance(pointer(vtable+0xE8),exe)==0x2bd870, 'Unsupported unit scene-graph layout')
        snapshot.source=vector(read(pointer(object+0x88)+0x30,12),0)
    else
        snapshot.source=vector(read(global(0x346d560,'fallback_position')+0x3C,12),0)
    end
    return snapshot
end

function patch.snapshot(api,game,exe)
    local ok,result=pcall(snapshot,api,game,exe)
    if ok then return result end
    if type(result)=='table' and result.kind==unavailable then return nil,result.status end
    error(result,0)
end

-- Pure event tracking; never adjusts a live pod, timers, use bits or network state.
function patch.plan(current, state)
    local previous=state.previous
    state.previous=current
    if not previous or previous.identity~=current.identity or previous.id~=current.id
        or previous.count~=current.count or previous.mode~=current.mode
        or current.mode<1 or current.mode>7 or not current.owned then
        state.anchor,state.pending=nil,nil
        return nil,'waiting_for_reinforcement'
    end
    if current.state==3 or current.state==0 then
        state.anchor,state.pending=nil,nil
        return nil,'waiting_for_reinforcement'
    end
    -- Automatic dummy type 0x7C exists before its reinforcement component.
    -- Freeze the source once, so a moving corpse/camera cannot move the target later.
    if current.count==1 and (current.state==1 or current.state==2) and not state.anchor then
        for _,auto in ipairs(current.automatic) do
            local was_present=false
            for _,old in ipairs(previous.automatic or {}) do
                if old.key==auto.key then was_present=true end
            end
            if not was_present and current.source then
                state.anchor={key=auto.key, position=auto.position, source=current.source}
                break
            end
        end
    end
    if current.state~=2 then return nil,'waiting_for_reinforcement' end
    if previous.state~=2 and previous.state~=1 and previous.state~=3 then
        return nil,'initial_deployment_unchanged'
    end
    if state.pending then return nil,'reinforcement_already_centered' end
    if not current.position or not current.countdown or current.countdown~=current.countdown
        or current.countdown<=0.1 or current.countdown>5.1 then
        return nil,'spawn_window_unavailable'
    end
    local mask=bit.lshift(1,current.use_bit)
    local selected={}
    for _,beacon in ipairs(current.beacons) do
        if bit.band(beacon.used,mask)~=0 and beacon.position then
            local old_used=false
            for _,old in ipairs(previous.beacons or {}) do
                if old.id==beacon.id and bit.band(old.used,mask)~=0 then old_used=true end
            end
            if not old_used then selected[#selected+1]=beacon end
        end
    end
    local beacon,association=selected[1],'used'
    if #selected==0 and current.count>1 and previous.state==1 then
        -- AC7280 chooses the first unused record. AC83F0 marks it only when
        -- the beacon is locally owned, so a teammate's beacon can stay unused
        -- through the local queue commit. Preserve that observed selection.
        local old=first_unused(previous.beacons,mask)
        local candidate,unused_count=first_unused(current.beacons,mask)
        if candidate and candidate.owned==false and candidate.position
            and ((old and old.owned==false and old.id==candidate.id and same_xy(old.position,candidate.position))
                 or (not old and unused_count==1)) then
            beacon,association=candidate,'unmarked_remote'
        end
    end
    if #selected>1 or not beacon then return nil,'beacon_association_unavailable' end
    local target,kind=beacon.position,'beacon'
    if current.count==1 then
        if not state.anchor or not same_xy(state.anchor.position,beacon.position) then
            return nil,'solo_anchor_unavailable'
        end
        target,kind=state.anchor.source,'solo'
    end
    local dx,dy=target[1]-current.position[1],target[2]-current.position[2]
    if dx*dx+dy*dy>512*512 then return nil,'placement_outside_supported_range' end
    return {bytes=xy_bytes(target),target={target[1],target[2]},kind=kind,beacon=beacon.id,
            association=association,beacon_position=beacon.position},'ready'
end

function patch.apply(api,game,exe,state)
    local current,waiting=patch.snapshot(api,game,exe)
    if not current then
        state.previous,state.anchor,state.pending=nil,nil,nil
        return true,waiting,false
    end
    local plan,reason=patch.plan(current,state)
    if not plan then return true,reason,false end
    -- Re-read every identity and association immediately before the single write.
    local fresh,waiting=patch.snapshot(api,game,exe)
    if not fresh then
        state.previous,state.anchor,state.pending=nil,nil,nil
        return true,waiting,false
    end
    if fresh.identity~=current.identity or fresh.id~=current.id or fresh.unit_ref~=current.unit_ref
        or fresh.use_bit~=current.use_bit
        or fresh.count~=current.count or fresh.mode~=current.mode or not fresh.owned or fresh.state~=2
        or fresh.countdown~=fresh.countdown or fresh.countdown<=0.1 or fresh.countdown>5.1
        or fresh.original~=current.original then
        return true,'spawn_changed_before_write',false
    end
    local found=false
    local mask=bit.lshift(1,fresh.use_bit)
    local first=first_unused(fresh.beacons,mask)
    for _,b in ipairs(fresh.beacons) do
        if b.id==plan.beacon and same_xy(b.position,plan.beacon_position) then
            if plan.association=='unmarked_remote' then
                found=b.owned==false and first and first.id==b.id and bit.band(b.used,mask)==0
            else
                found=bit.band(b.used,mask)~=0
            end
        end
    end
    if not found then return true,'beacon_changed_before_write',false end
    assert(api.writable_data(fresh.address,8),'Target is not existing private writable data')
    local written=api.write(fresh.address,plan.bytes)
    local actual=api.read(fresh.address,8)
    if not written or actual~=plan.bytes then
        -- Same field, while the original spawn record is still pending.
        if api.read(fresh.address-0x10C+0x2E0,4)==string.char(2,0,0,0) then
            api.write(fresh.address,fresh.original)
        end
        error('Spawn data write failed; correction stopped')
    end
    state.pending=plan
    state.corrections=(state.corrections or 0)+1
    state.last={kind=plan.kind,beacon=plan.beacon,association=plan.association,from=current.position,to=plan.target}
    return true,plan.kind..'_spawn_centered',true
end
return patch
