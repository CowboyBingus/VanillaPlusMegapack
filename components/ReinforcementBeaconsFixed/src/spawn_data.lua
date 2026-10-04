local ffi, bit = require('ffi'), require('bit')
local band, rshift, ldexp, abs = bit.band, bit.rshift, math.ldexp, math.abs
local patch = {}
local unavailable = {}
-- The player manager global, and the spawn state of a pending reinforcement.
local PLAYER_MANAGER, PENDING = 0x3326468, string.char(2, 0, 0, 0)

-- Read buffers kept for the session: every read goes into one of these
-- (api.read_into, no string per read) and is decoded in place. Each holds one
-- kind of data, so nothing a snapshot still decodes is overwritten by another
-- read; a second snapshot in the same frame overwrites them only after the
-- first has copied out everything it keeps.
local function buffer(size) return ffi.new('uint8_t[?]', size) end
local MODE, PLAYERS, ENTITY = buffer(0x44), buffer(0x440), buffer(24)
local REINFORCEMENT, POSITIONS = buffer(0x58), buffer(0x60)
local ENTITIES, USED = buffer(128*8), buffer(128*4)
local POINTER, ROW, COORDINATES, BYTE = buffer(8), buffer(8), buffer(12), buffer(1)
local STRATAGEMS, SOURCE_LOOKUP, REGISTRY = buffer(0x80), buffer(20), buffer(0xA8)
-- The stratagem rows grow to the largest count seen (at most 512 x 64 B).
local rows, rows_size = nil, 0

local function u32(b, offset)
    return b[offset] + 256*b[offset+1] + 65536*b[offset+2] + 16777216*b[offset+3]
end
-- A float decoded from its bits: nil for NaN or infinity. Loading the value
-- through a float cdata instead can turn a NaN into a value that is not a Lua
-- number in this NaN-tagged LuaJIT, where math.abs or a comparison would raise.
local function float(b, offset)
    local bits = u32(b, offset)
    local exponent = band(rshift(bits, 23), 0xff)
    if exponent == 255 then return nil end
    local mantissa = band(bits, 0x7fffff)
    local value = exponent == 0 and ldexp(mantissa, -149) or ldexp(mantissa + 0x800000, exponent - 150)
    if bits >= 0x80000000 then return -value end
    return value
end
local function vector(b, offset)
    local x, y, z = float(b, offset), float(b, offset+4), float(b, offset+8)
    if not (x and y and z) or abs(x) > 100000 or abs(y) > 100000 or abs(z) > 100000 then return nil end
    return {x, y, z}
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
-- The correction's write. api.write checks memory protection itself, once,
-- right before the store: existing private read-write data only. Only a
-- refused write queries again, to keep the status for non-writable data.
local function write_xy(api,address,bytes)
    if api.write(address,bytes) then return true end
    assert(api.writable_data(address,#bytes),'Target is not existing private writable data')
    return false
end

-- Each address below comes from the build-locked read-only native/data trace.
-- Pointer following is read-only. The only write site is player_manager+0x10C.
--
-- A snapshot reads through one reader: {api, game, exe, stage}. stage names
-- the data being read: missing data raises "waiting for game data" at that
-- stage (retried on the next check), malformed data an assertion naming it.
local function wait_for_data(reader)
    error({kind=unavailable,status='waiting_for_game_data:'..reader.stage},0)
end
-- All size bytes into buffer, or "waiting for game data": api.read_into never
-- returns part of a range.
local function read(reader, address, size, into)
    if not reader.api.read_into(address,size,into) then wait_for_data(reader) end
    return into
end
local function data_pointer(reader,b,offset)
    offset=offset or 0
    if u32(b,offset)==0 and u32(b,offset+4)==0 then wait_for_data(reader) end
    local value=reader.api.pointer_at(b,offset)
    if not value then error('Invalid spawn data pointer: '..reader.stage) end
    return value
end
local function pointer(reader,address) return data_pointer(reader,read(reader,address,8,POINTER)) end
local function global(reader,rva,name)
    reader.stage=name
    return pointer(reader,reader.game+rva)
end
-- The table index of key in the lookup whose header starts at header+offset,
-- or nil.
local function lookup(reader, header, offset, key)
    local capacity, empty, multiplier = u32(header,offset+8), u32(header,offset+12), u32(header,offset+16)
    if capacity == 0 then return nil end
    assert(capacity <= 1048576 and bit.band(capacity,capacity-1)==0, 'Invalid lookup capacity')
    local table_address = data_pointer(reader,header,offset)
    -- Exact low word of key x multiplier: Lua doubles cannot multiply two
    -- arbitrary uint32s exactly, so the multiplier goes in 16-bit halves; each
    -- partial product stays below 2^49, where tobit wraps exactly.
    local low = multiplier % 65536
    local product = bit.tobit(key*low + (key*((multiplier-low)/65536)) % 65536 * 65536)
    for probe=0,math.min(capacity,128)-1 do
        local slot = bit.band(product+probe,capacity-1)
        read(reader,table_address+8*slot,8,ROW)
        if u32(ROW,0)==key then
            local index=u32(ROW,4)
            if index~=0xffffffff then return index end
            return nil
        end
        if u32(ROW,0)==empty then return nil end
    end
    return nil
end

-- The mission mode, then (in gameplay modes 1..7 only) the player manager and
-- its player block: a new snapshot with the mode and, in a mission, the
-- identity, the pending spawn's address and the player count; also the
-- available-player count. Aboard the ship (mode 0) this is the whole check.
local function session(reader)
    read(reader,global(reader,0x33266a0,'mission_mode'),0x44,MODE)
    local mode=u32(MODE,8)>0 and u32(MODE,0x40) or 0
    -- Outside gameplay the plan only resets, reading nothing else.
    if mode<1 or mode>7 then return {mode=mode},0 end
    local pm = global(reader,PLAYER_MANAGER,'player_manager')
    read(reader,pm,0x440,PLAYERS)
    local count, available = u32(PLAYERS,0x84),u32(PLAYERS,0x88)
    assert(count<=4 and available<=4, 'Unsupported player layout')
    -- The identity is the player manager pointer itself: == and ~= compare two
    -- pointers by address, allocating nothing. The game replaces tostring, which
    -- prints every cdata as '[cdata (deleted)]', so a string identity never changed.
    return {identity=pm, address=pm+0x10C, count=count, mode=mode, beacons={}, automatic={}},available
end

-- The local player's identity, spawn state, use bit and pending spawn, from
-- the player block session read. True when this machine owns the local player.
local function local_player(reader,snapshot)
    reader.stage='local_player'
    read(reader,data_pointer(reader,PLAYERS,0xE8),24,ENTITY)
    snapshot.id, snapshot.owned = u32(ENTITY,8),bit.band(ENTITY[20],1)==1
    snapshot.state, snapshot.use_bit = u32(PLAYERS,0x2E0),u32(PLAYERS,0x3B4)
    snapshot.position=vector(PLAYERS,0x10C)
    -- The pending XY as the write and restore need it: compared and written
    -- only while a spawn is pending (state 2), so only then kept as a string.
    if snapshot.state==2 then snapshot.original=ffi.string(PLAYERS+0x10C,8) end
    snapshot.countdown=float(PLAYERS,0x12C)
    snapshot.unit_ref=u32(PLAYERS,0x3A8)
    assert(snapshot.use_bit<32, 'Unsupported player-use bit')
    return snapshot.owned
end

-- The reinforcement manager's records and the count of active records; with
-- positioned, also the position manager's block. A beacon position is only
-- compared while a reinforcement is queued or pending (states 1 and 2).
local function beacon_managers(reader,positioned)
    read(reader,global(reader,0x33269c0,'reinforcement_manager'),0x58,REINFORCEMENT)
    local active=u32(REINFORCEMENT,12)
    assert(active<=128 and active<=u32(REINFORCEMENT,8), 'Unsupported reinforcement layout')
    if positioned and active>0 then read(reader,global(reader,0x3326b20,'position_manager'),0x60,POSITIONS) end
    return active
end

-- A beacon's position through the position manager's lookup, or nil.
local function beacon_position(reader,id)
    local index=lookup(reader,POSITIONS,0x28,id)
    if not index then return nil end
    assert(index<u32(POSITIONS,8), 'Position index outside live data')
    return vector(read(reader,data_pointer(reader,POSITIONS,0x50)+index*12,12,COORDINATES),0)
end

-- Every active reinforcement record: id, ownership, position (in states 1
-- and 2, through the position manager's lookup, or nil) and use bits. The
-- entity pointers and use bits are read once for all records.
local function beacon_records(reader,snapshot)
    local positioned=snapshot.state==1 or snapshot.state==2
    local active=beacon_managers(reader,positioned)
    if active>0 then
        reader.stage='reinforcement_records'
        read(reader,data_pointer(reader,REINFORCEMENT,0x38),8*active,ENTITIES)
        read(reader,data_pointer(reader,REINFORCEMENT,0x48),4*active,USED)
        for i=0,active-1 do
            read(reader,data_pointer(reader,ENTITIES,8*i),24,ENTITY)
            local id=u32(ENTITY,8)
            snapshot.beacons[#snapshot.beacons+1]={id=id, owned=bit.band(ENTITY[20],1)==1,
                position=positioned and beacon_position(reader,id) or nil, used=u32(USED,4*i)}
        end
    end
end

-- Solo: the active stratagem rows, read at once, and their count.
local function stratagem_rows(reader)
    read(reader,global(reader,0x33266b0,'automatic_anchor_manager'),0x80,STRATAGEMS)
    local n=u32(STRATAGEMS,0x34)
    assert(n<=512, 'Unsupported active stratagem count')
    if n==0 then return 0 end
    if n*64>rows_size then rows,rows_size=buffer(n*64),n*64 end
    read(reader,data_pointer(reader,STRATAGEMS,0x78),n*64,rows)
    return n
end

-- Solo: every automatic-reinforcement dummy with a usable position.
local function automatic_anchors(reader,snapshot)
    local n=stratagem_rows(reader)
    for i=0,n-1 do
        local base=i*64
        -- Current automatic-reinforcement producer ACCC96 / ACCEC5.
        if u32(rows,base+12)==0x7C then
            local v=vector(rows,base+16)
            if v then snapshot.automatic[#snapshot.automatic+1]={
                key=ffi.string(rows+base+16,12),position=v} end
        end
    end
end

-- The source unit's world position through the unit registry: entity index,
-- engine reference, registry slot and generation, scene-graph object.
local function unit_position(reader,em,index)
    assert(index<262144, 'Entity index outside supported bound')
    local engine_ref=u32(read(reader,em+15937304+24*index,24,ENTITY),12)
    reader.stage='source_unit_registry'
    read(reader,pointer(reader,reader.exe+0x1a100f0),0xA8,REGISTRY)
    local slot,generation=bit.band(engine_ref,0x3fffff),bit.rshift(engine_ref,22)
    assert(slot<u32(REGISTRY,0x98), 'Unit slot outside registry')
    local generations=data_pointer(reader,REGISTRY,0xA0)
    assert(read(reader,generations+slot,1,BYTE)[0]==generation, 'Unit generation changed')
    local objects=data_pointer(reader,REGISTRY,0x88)
    local object=pointer(reader,objects+8*slot)
    local vtable=pointer(reader,object)
    assert(reader.api.distance(pointer(reader,vtable+0xE8),reader.exe)==0x2bd870, 'Unsupported unit scene-graph layout')
    return vector(read(reader,pointer(reader,object+0x88)+0x30,12,COORDINATES),0)
end

-- Solo: the position a death anchor freezes. Reproduces AC5BB0's
-- unit-world-position read, without calling native code; the fallback
-- position when the local player has no source unit.
local function source_position(reader,unit_ref)
    local em=global(reader,0x346bf98,'source_entity_manager')
    local index=unit_ref~=0x7fff and lookup(reader,read(reader,em+15871688,20,SOURCE_LOOKUP),0,unit_ref) or nil
    if index then return unit_position(reader,em,index) end
    return vector(read(reader,global(reader,0x346d560,'fallback_position')+0x3C,12,COORDINATES),0)
end

local function snapshot(api, game, exe)
    local reader={api=api,game=game,exe=exe,stage='mission_mode'}
    local snapshot,available=session(reader)
    -- Native player logic accepts gameplay modes 1..7, including defense (2).
    if snapshot.mode<1 or snapshot.mode>7 or snapshot.count==0 or available==0 then return snapshot end
    if not local_player(reader,snapshot) then return snapshot end
    beacon_records(reader,snapshot)
    if snapshot.count~=1 then return snapshot end
    automatic_anchors(reader,snapshot)
    -- The source position is read only when an anchor is captured (see
    -- patch.source): solo frames that capture nothing skip its ~12 reads.
    snapshot.reader=reader
    return snapshot
end

-- Converts "waiting for game data" into nil and its status; any other error
-- (an unsupported layout) is raised again.
local function settle(ok,result)
    if ok then return result end
    if type(result)=='table' and result.kind==unavailable then return nil,result.status end
    error(result,0)
end

function patch.snapshot(api,game,exe)
    return settle(pcall(snapshot,api,game,exe))
end

-- Solo: the source position of this snapshot's local player, read now, or
-- nil; nil and the waiting status when its game data is unavailable. A
-- snapshot that already carries a source (generated tests) keeps it.
function patch.source(current)
    if current.source~=nil or not current.reader then return current.source end
    local source,waiting=settle(pcall(source_position,current.reader,current.unit_ref))
    current.source=source
    return source,waiting
end

-- Pure event tracking; never adjusts a live pod, timers, use bits or network state.

-- Whether an automatic dummy with this key was in the previous snapshot.
local function was_present(automatic, key)
    local present=false
    for _,old in ipairs(automatic or {}) do
        if old.key==key then present=true end
    end
    return present
end

-- Automatic dummy type 0x7C exists before its reinforcement component.
-- Freeze the source once, so a moving corpse/camera cannot move the target later.
-- The source is read here, for the first new dummy only: no source (nil)
-- captures nothing, as before. Returns the waiting status when the source's
-- game data is unavailable, or nil.
local function capture_anchor(previous, current, state)
    if not (current.count==1 and (current.state==1 or current.state==2) and not state.anchor) then return nil end
    for _,auto in ipairs(current.automatic) do
        if not was_present(previous.automatic,auto.key) then
            local source,waiting=patch.source(current)
            if source then state.anchor={key=auto.key, position=auto.position, source=source} end
            return waiting
        end
    end
    return nil
end

-- Why this check cannot correct the spawn, before any beacon is considered;
-- nil when it may.
local function spawn_blocked(previous, current, state)
    if current.state~=2 then return 'waiting_for_reinforcement' end
    if previous.state~=2 and previous.state~=1 and previous.state~=3 then
        return 'initial_deployment_unchanged'
    end
    if state.pending then return 'reinforcement_already_centered' end
    if not current.position or not current.countdown or current.countdown~=current.countdown
        or current.countdown<=0.1 or current.countdown>5.1 then
        return 'spawn_window_unavailable'
    end
    return nil
end

-- Whether the beacon with this id already had the local use bit set.
local function used_before(beacons, id, mask)
    local used=false
    for _,old in ipairs(beacons or {}) do
        if old.id==id and bit.band(old.used,mask)~=0 then used=true end
    end
    return used
end

-- The beacons with a position whose local use bit was set since the previous snapshot.
local function newly_used(previous, current, mask)
    local selected={}
    for _,beacon in ipairs(current.beacons) do
        if bit.band(beacon.used,mask)~=0 and beacon.position and not used_before(previous.beacons,beacon.id,mask) then
            selected[#selected+1]=beacon
        end
    end
    return selected
end

-- AC7280 chooses the first unused record. AC83F0 marks it only when the
-- beacon is locally owned, so a teammate's beacon can stay unused through the
-- local queue commit. Preserve that observed selection: the candidate, or nil.
local function unmarked_remote(previous, current, mask)
    local old=first_unused(previous.beacons,mask)
    local candidate,unused_count=first_unused(current.beacons,mask)
    if candidate and candidate.owned==false and candidate.position
        and ((old and old.owned==false and old.id==candidate.id and same_xy(old.position,candidate.position))
             or (not old and unused_count==1)) then
        return candidate
    end
    return nil
end

-- The one beacon this spawn belongs to and how it was associated, or nil.
local function associated_beacon(previous, current, mask)
    local selected=newly_used(previous,current,mask)
    local beacon,association=selected[1],'used'
    if #selected==0 and current.count>1 and previous.state==1 then
        local candidate=unmarked_remote(previous,current,mask)
        if candidate then beacon,association=candidate,'unmarked_remote' end
    end
    if #selected>1 or not beacon then return nil end
    return beacon,association
end

-- The correction's target, the beacon's position or solo the frozen source
-- of its anchor, within the supported range of the pending spawn.
local function placement(current, state, beacon, association)
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

-- Forgets every association, as when game data becomes unavailable (a fresh start).
local function forget(state)
    state.previous,state.anchor,state.pending=nil,nil,nil
end

function patch.plan(current, state)
    local previous=state.previous
    state.previous=current
    -- Another player manager, local player, player count or mode, a mode
    -- outside gameplay, not owned here, or no reinforcement under way.
    if not previous or previous.identity~=current.identity or previous.id~=current.id
        or previous.count~=current.count or previous.mode~=current.mode
        or current.mode<1 or current.mode>7 or not current.owned
        or current.state==3 or current.state==0 then
        state.anchor,state.pending=nil,nil
        return nil,'waiting_for_reinforcement'
    end
    local waiting=capture_anchor(previous,current,state)
    -- Unavailable source data forgets every association, as an unavailable
    -- snapshot does (the source used to be part of every solo snapshot).
    if waiting then forget(state);return nil,waiting end
    local blocked=spawn_blocked(previous,current,state)
    if blocked then return nil,blocked end
    local beacon,association=associated_beacon(previous,current,bit.lshift(1,current.use_bit))
    if not beacon then return nil,'beacon_association_unavailable' end
    return placement(current,state,beacon,association)
end

-- Whether the re-read changed the pending spawn the plan was made for.
local function spawn_changed(current, fresh)
    return fresh.identity~=current.identity or fresh.id~=current.id or fresh.unit_ref~=current.unit_ref
        or fresh.use_bit~=current.use_bit
        or fresh.count~=current.count or fresh.mode~=current.mode or not fresh.owned or fresh.state~=2
        or not fresh.countdown or fresh.countdown<=0.1 or fresh.countdown>5.1
        or fresh.original~=current.original
end

-- Whether the re-read still associates the planned beacon with this spawn.
local function beacon_kept(fresh, plan)
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
    return found
end

-- The single write and its read-back. A refused or partial write puts the
-- original XY back while the spawn is still pending, and stops the correction.
local function write_correction(api, fresh, plan)
    local written=write_xy(api,fresh.address,plan.bytes)
    local actual=api.read(fresh.address,8)
    if not written or actual~=plan.bytes then
        -- Same field, while the original spawn record is still pending.
        if api.read(fresh.address-0x10C+0x2E0,4)==PENDING then
            api.write(fresh.address,fresh.original)
        end
        error('Spawn data write failed; correction stopped')
    end
end

-- Keeps what the write replaced, so patch.restore can put it back, and the
-- correction for the log.
local function record_correction(state, current, fresh, plan)
    plan.address,plan.original=fresh.address,fresh.original
    state.pending=plan
    state.corrections=(state.corrections or 0)+1
    state.last={kind=plan.kind,beacon=plan.beacon,association=plan.association,from=current.position,to=plan.target}
end

function patch.apply(api,game,exe,state)
    local current,waiting=patch.snapshot(api,game,exe)
    if not current then forget(state);return true,waiting,false end
    local plan,reason=patch.plan(current,state)
    if not plan then return true,reason,false end
    -- Re-read every identity and association immediately before the single write.
    local fresh,waiting=patch.snapshot(api,game,exe)
    if not fresh then forget(state);return true,waiting,false end
    if spawn_changed(current,fresh) then return true,'spawn_changed_before_write',false end
    if not beacon_kept(fresh,plan) then return true,'beacon_changed_before_write',false end
    write_correction(api,fresh,plan)
    record_correction(state,current,fresh,plan)
    return true,plan.kind..'_spawn_centered',true
end

-- Puts back the original XY of this mod's correction, only while the same
-- player manager's spawn is still pending and its XY still holds exactly the
-- bytes this mod wrote; anything else is left alone. Then forgets every
-- association, as when game data becomes unavailable (a fresh start).
-- Returns ok (false: the write failed) and the outcome.
function patch.restore(api,game,state)
    local pending=state.pending
    state.previous,state.anchor,state.pending=nil,nil,nil
    if not (pending and pending.address and pending.original) then return true,'nothing_to_restore' end
    local pm=api.pointer(api.read(game+PLAYER_MANAGER,8))
    if not pm or pm+0x10C~=pending.address or api.read(pm+0x2E0,4)~=PENDING
        or api.read(pending.address,8)~=pending.bytes then
        return true,'correction_left_unchanged'
    end
    if not api.write(pending.address,pending.original) or api.read(pending.address,8)~=pending.original then
        return false,'correction_restore_failed'
    end
    return true,'correction_restored'
end

-- Machine code: as before these functions were split, or less. The snapshot
-- created its read helpers as closures on every call, which LuaJIT 2.1.0-alpha
-- does not compile, so its straight-line steps, patch.snapshot and patch.apply
-- never compiled, and the plan only its first check. The read helpers, the two
-- record loops and that check still compile; the steps below stay
-- interpreted. As the first call of beacon_records and automatic_anchors, the
-- manager steps keep a trace from starting at those functions' entries while
-- their loops compile. The solo source position compiled only inside a trace
-- after the anchor loop; its few steps now run interpreted around compiled
-- reads, no slower in the game's lua51.dll (offline); it now runs only when
-- an anchor is captured, through patch.source, also interpreted. The byte
-- decoders (u32, float, vector) replace the float cdata loads and string
-- slices they decoded from; they compile into the same reader traces. Nothing
-- is flushed.
if jit and jit.off then
    for _,fn in ipairs({session,local_player,beacon_managers,stratagem_rows,unit_position,source_position,snapshot,
        settle,patch.snapshot,patch.source,was_present,capture_anchor,spawn_blocked,used_before,newly_used,unmarked_remote,
        associated_beacon,placement,forget,spawn_changed,beacon_kept,write_correction,record_correction,patch.apply}) do
        jit.off(fn)
    end
end
return patch
