-- Corpse collision repair and renewed-motion containment. The resource -- lint-ok: R15 the scan steps share one poll's upvalues; splitting the file changes the chunk interface of every test and the Megapack component: follow-up
-- allowlist is generated data in src/corpse_profiles.lua (from
-- profiles/catalog.json); the module wrapper passes it in as this chunk's
-- argument.
local profiles=...
assert(type(profiles)=='table','Corpse profiles unavailable')
for _,p in pairs(profiles) do
    p.main_names={};for _,name in ipairs(p.main) do p.main_names[name]=true end
end
local claws = {[0x92d0871f]=true,[0x6635646b]=true,[0x50b19c0a]=true}
-- The 8-byte resource keys by their two little-endian words, so an entity
-- header seen through a view finds its profile without making a string.
local resource_words={}
for key in pairs(profiles) do
    local b1,b2,b3,b4,b5,b6,b7,b8=key:byte(1,8)
    local low=b1+b2*256+b3*65536+b4*16777216
    resource_words[low]=resource_words[low] or {}
    resource_words[low][b5+b6*256+b7*65536+b8*16777216]=key
end

local ffi,bit=require('ffi'),require('bit')
-- interval: seconds of frame time between polls. It was 1/30 s on
-- GetTickCount64, which advances in 15.625 ms steps, so polls came every
-- third step: 46.9 ms (21 Hz) at 60 FPS and above, every other frame (15 Hz)
-- at 30 FPS. The frame time now drives the poll (archive_loader.lua) at that
-- same measured period, so the poll rate does not rise.
local M={profiles=profiles,interval=3/64,max_entities=128,max_units=4,budget_seconds=.001}
M.completion_grace=1
-- Corpse re-check backoff. A corpse's collision is repaired at conversion
-- (about 0.2 s after); recordings show no collider of a settled corpse moving
-- again, and every gap under 2.5 cm from 1 s after conversion (KB
-- corpse-recheck-backoff-2026-10-17). So a corpse that needed no command on
-- every inspection for corpse_settle_polls polls is inspected again after
-- 2, 4, 8 ... polls, at most corpse_recheck_polls (about 3-4 s); one that
-- needs a command starts over. 0 turns the backoff off.
M.corpse_settle_polls=24
M.corpse_recheck_polls=64
local ZERO8=string.rep('\0',8)
local byte,ldexp,floor=string.byte,math.ldexp,math.floor
-- Little-endian decode from the copied bytes. Unlike an FFI cast, this makes
-- no cdata object when the interpreter, not a compiled trace, runs it.
local function u32(b,o)
    o=o or 0
    assert(o>=0 and o+4<=#b,'Scalar outside copied data')
    local b1,b2,b3,b4=byte(b,o+1,o+4)
    return b1+b2*256+b3*65536+b4*16777216
end
-- The same word in a scratch view (api.view's buffer) at a fixed offset the
-- caller has bounded: no Lua string is made for it.
local function view_u32(v,o) return v[o]+v[o+1]*256+v[o+2]*65536+v[o+3]*16777216 end
-- One IEEE single from copied bytes, by arithmetic. A NaN loaded through an FFI
-- float can reach Lua as a value that is not a number in this NaN-tagged
-- LuaJIT; here every NaN is Lua's own 0/0, which finite() rejects.
local function float_at(b,o)
    local b1,b2,b3,b4=byte(b,o+1,o+4)
    local exponent,mantissa=(b4%128)*2+floor(b3/128),(b3%128)*65536+b2*256+b1
    local value
    if exponent==255 then value=mantissa==0 and math.huge or 0/0
    elseif exponent==0 then value=ldexp(mantissa,-149)
    else value=ldexp(mantissa+8388608,exponent-150) end
    if b4>=128 then return -value end
    return value
end
local function floats(b,o,n)
    assert(o>=0 and n<=16 and o+n*4<=#b,'Matrix outside copied data')
    local out={};for i=1,n do out[i]=float_at(b,o+(i-1)*4) end;return out
end
M.floats=floats -- for tests: the decoder poses use
local function phase(api,name)
    if api.profiler then return api.profiler.phase(name) end
end
local function detail(api,name)
    if api.profiler then api.profiler.detail(name) end
end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<100000 end

-- Havok body translations and unit matrices use the same world-space node
-- origin. Shape-local geometry remains in the existing shape. Remove skeletal
-- scale from the orientation; do not resize or replace a collision shape.
local RIGID_FIELDS={1,2,3,5,6,7,9,10,11,13,14,15}
local function unit3(a,b,c)
    local n=math.sqrt(a*a+b*b+c*c);if not finite(n) or n<0.001 then return nil end
    return a/n,b/n,c/n
end
-- Numeric core of M.rigid: position XYZ then quaternion XYZW, or nil. It builds
-- no tables, so poses that turn out aligned cost no garbage. Same arithmetic,
-- in the same order, as the table form it replaced.
local function rigid_values(matrix)
    for i=1,12 do if not finite(matrix[RIGID_FIELDS[i]]) then return nil end end
    local x1,x2,x3=unit3(matrix[1],matrix[2],matrix[3]);if not x1 then return nil end
    local y1,y2,y3=unit3(matrix[5],matrix[6],matrix[7]);if not y1 then return nil end
    local z1,z2,z3=unit3(matrix[9],matrix[10],matrix[11]);if not z1 then return nil end
    if math.abs(x1*y1+x2*y2+x3*y3)>.025 or math.abs(x1*z1+x2*z2+x3*z3)>.025
        or math.abs(y1*z1+y2*z2+y3*z3)>.025 then return nil end
    local c1,c2,c3=x2*y3-x3*y2,x3*y1-x1*y3,x1*y2-x2*y1
    if c1*z1+c2*z2+c3*z3<.99 then return nil end
    -- Column-major matrix to XYZW quaternion.
    local trace=x1+y2+z3
    local s,a,b,c,d
    if trace>0 then
        s=math.sqrt(trace+1)*2;a,b,c,d=(y3-z2)/s,(z1-x3)/s,(x2-y1)/s,s/4
    elseif x1>y2 and x1>z3 then
        s=math.sqrt(1+x1-y2-z3)*2;a,b,c,d=s/4,(y1+x2)/s,(z1+x3)/s,(y3-z2)/s
    elseif y2>z3 then
        s=math.sqrt(1+y2-x1-z3)*2;a,b,c,d=(y1+x2)/s,s/4,(z2+y3)/s,(z1-x3)/s
    else
        s=math.sqrt(1+z3-x1-y2)*2;a,b,c,d=(z1+x3)/s,(z2+y3)/s,s/4,(x2-y1)/s
    end
    local length=math.sqrt(a^2+b^2+c^2+d^2)
    if not finite(length) or length<.001 then return nil end
    return matrix[13],matrix[14],matrix[15],a/length,b/length,c/length,d/length
end

-- M.rigid's numbers, for a pose that may not be a 16-number table.
local function rigid_pose(matrix)
    if type(matrix)~='table' or #matrix~=16 then return nil end
    return rigid_values(matrix)
end

function M.rigid(matrix)
    local px,py,pz,qx,qy,qz,qw=rigid_pose(matrix)
    if not px then return nil end
    return {px,py,pz},{qx,qy,qz,qw}
end

local function settled(unit)
    local profile=profiles[unit.resource]
    return profile and unit.settled and unit.main_enabled~=nil
        and unit.main_enabled+(unit.main_disabled or 0)==profile.bodies
        and unit.main_static==unit.main_enabled
end

local function command_guards(actor)
    -- Most inspected auxiliaries already align and never receive a command.
    -- Keep their copied guard bytes compact until a real action needs the
    -- usual fresh identity/motion checks. This never rereads stale addresses.
    local b=actor.guard_source
    if not actor.guards and b then
        -- b[6] is the whole 160-byte body copied this poll; slice its motion
        -- and identity words exactly as they were read.
        actor.guards={{address=b[1],bytes=b[2]},{address=b[3],bytes=b[4]},
            {address=b[5]+64,bytes=b[6]:sub(65,68)},{address=b[5]+144,bytes=b[6]:sub(145,152)}}
    end
end

function M.plan(unit)
    local profile=profiles[unit.resource]
    -- Recorded assault-walker Corpses retain a dynamic torso and rocket pods.
    -- They must not block auxiliary repair on the fixed base. This exception
    -- is Corpse-only; it never relaxes RagdollSync stopping/completion gates.
    local mixed=profile and profile.corpse_dynamic_main and unit.corpse and unit.settled
        and unit.main_enabled~=nil and unit.main_enabled+(unit.main_disabled or 0)==profile.bodies
        and unit.main_static>0 and unit.main_static+(unit.main_dynamic_allowed or 0)==unit.main_enabled
    if not settled(unit) and not mixed then return {} end
    local actions={}
    for _,a in ipairs(unit.actors) do
        if a.enabled and a.stable and not a.registered and profile.actors[a.name]==a.node_hash then
            if profile.name=='Impaler' and claws[a.name] then
                command_guards(a)
                actions[#actions+1]={kind='disable',actor=a}
            elseif a.motion==0 and a.pose~=a.node_pose then
                local px,py,pz,qx,qy,qz,qw=rigid_values(a.node_pose)
                local ox,oy,oz,rx,ry,rz,rw=rigid_values(a.pose)
                if px and ox then
                    local distance=math.sqrt((px-ox)^2+(py-oy)^2+(pz-oz)^2)
                    local rotation=math.abs(qx*rx+qy*ry+qz*rz+qw*rw)
                    -- 2.5 cm / half a degree avoid rewriting an already aligned
                    -- stationary corpse. There is no upper gap cutoff: the
                    -- recorded 27 m failure must remain repairable.
                    if distance>.025 or rotation<.9999904807207345 then
                        command_guards(a)
                        actions[#actions+1]={kind='pose',actor=a,position={px,py,pz},rotation={qx,qy,qz,qw},
                            gap=distance,degrees=math.deg(2*math.acos(math.min(1,rotation)))}
                    end
                end
            end
        end
    end
    return actions
end

-- Compares expected bytes with a copied block at offset without creating a
-- substring. Copied game data is unique per poll, so every :sub() allocated.
local function ranges_equal(a,a_offset,b,b_offset,n)
    if a_offset<0 or b_offset<0 or a_offset+n>#a or b_offset+n>#b then return false end
    for i=1,n do if byte(a,a_offset+i)~=byte(b,b_offset+i) then return false end end
    return true
end
local function matches(block,offset,expected) return ranges_equal(block,offset,expected,0,#expected) end
-- The same comparison against a scratch view of `size` copied bytes.
local function view_matches(view,size,offset,expected)
    local n=#expected
    if offset<0 or offset+n>size then return false end
    for i=1,n do if view[offset+i-1]~=byte(expected,i) then return false end end
    return true
end
-- One guard against fresh game bytes: through the view when the adapter has
-- one (no Lua string), otherwise through an ordinary read.
local function viewable(api) return api.view~=nil and api.view_read==api.read end
local function unchanged(api,g)
    local n=#g.bytes
    if viewable(api) then
        local view=api.view(g.address,n)
        return view~=nil and view_matches(view,n,0,g.bytes)
    end
    return api.read(g.address,n)==g.bytes
end
-- Copies size bytes at address with one view, so several guarded words that
-- lie close together cost one copy instead of one read each (the snapshot's
-- guard takes their bytes from it). Without the paired view, or if the copy
-- fails, the result is false or nil and each word is read on its own, exactly
-- as before.
local function capture(api,address,size) return viewable(api) and api.view(address,size) end

-- Sort order for compile: one comparator for every plan, not a new closure per
-- plan. sort_numbers is set only for the duration of the sort.
local sort_numbers
local function by_address(a,b) return sort_numbers[a]<sort_numbers[b] end
-- Grouping plan for one guard list, kept as parallel number arrays rather than
-- a table per guard. The list's entries and their address/bytes are recorded,
-- so any change to the list forces a fresh plan exactly as before.
local function compile(api,guards)
    local n=#guards
    local c={count=n,entries={},addresses={},bytes={},numbers={},order={},first={},last={},start={},size={}}
    local numbers,order=c.numbers,c.order
    for i=1,n do
        local g=guards[i]
        c.entries[i]=g;c.addresses[i]=g.address;c.bytes[i]=g.bytes
        numbers[i]=api.address(g.address);order[i]=i
    end
    sort_numbers=numbers;table.sort(order,by_address);sort_numbers=nil
    local groups=0
    for k=1,n do
        local i=order[k]
        local number,length=numbers[i],#guards[i].bytes
        if groups==0 or number>c.start[groups]+c.size[groups]+128 or number+length-c.start[groups]>4096 then
            groups=groups+1;c.first[groups]=k;c.start[groups]=number;c.size[groups]=length
        else c.size[groups]=math.max(c.size[groups],number+length-c.start[groups]) end
        c.last[groups]=k
    end
    c.groups=groups
    return c
end

local function current(compiled,guards)
    if not compiled or compiled.count~=#guards then return false end
    for i=1,compiled.count do
        local g=guards[i]
        if g~=compiled.entries[i] or g.address~=compiled.addresses[i] or g.bytes~=compiled.bytes[i] then return false end
    end
    return true
end

local function same(api,guards)
    local previous=phase(api,'validation')
    local result=true
    if not api.address or #guards<2 then
        for _,g in ipairs(guards) do if not unchanged(api,g) then result=false;break end end
        phase(api,previous);return result
    end
    local compiled=guards.compiled
    if not current(compiled,guards) then compiled=compile(api,guards);guards.compiled=compiled end
    local order,numbers=compiled.order,compiled.numbers
    for group=1,compiled.groups do
        local start,size=compiled.start[group],compiled.size[group]
        local address=guards[order[compiled.first[group]]].address
        local view=viewable(api) and api.view(address,size) or nil
        local block=not view and api.read(address,size)
        local whole=view~=nil or (block and #block==size)
        for k=compiled.first[group],compiled.last[group] do
            local check=guards[order[k]]
            local ok
            if view then ok=view_matches(view,size,numbers[order[k]]-start,check.bytes)
            elseif whole then ok=matches(block,numbers[order[k]]-start,check.bytes)
            else ok=unchanged(api,check) end
            if not ok then result=false;break end
        end
        if not result then break end
    end
    phase(api,previous);return result
end
M.same=same

-- Distance and degrees between a pose (position XYZ then rotation XYZW, seven
-- numbers) and a kept position and rotation.
local function separation(pose,old,oldq)
    local distance=math.sqrt((pose[1]-old[1])^2+(pose[2]-old[2])^2+(pose[3]-old[3])^2)
    local cosine=math.min(1,math.abs(pose[4]*oldq[1]+pose[5]*oldq[2]+pose[6]*oldq[3]+pose[7]*oldq[4]))
    return distance,math.deg(2*math.acos(cosine))
end

-- Motion sample scratch, refilled by every M.fling_action call and read only
-- within it, so a sample makes no table: the root body's pose, and each main
-- body's pose relative to it by the body's index in main_bodies (one table per
-- index, made up front for the largest profile), each as seven numbers.
-- History keeps copies (kept_pose, kept_limbs), made only when it starts or
-- restarts.
local root_pose,limb_poses,limb_capacity={0,0,0,0,0,0,0},{},0
local function limb_scratch(n)
    for i=limb_capacity+1,n do limb_poses[i]={0,0,0,0,0,0,0} end
    limb_capacity=math.max(limb_capacity,n)
end
do
    local most=0
    for _,p in pairs(profiles) do most=math.max(most,p.bodies) end
    limb_scratch(most)
end
-- Body id -> stamp of the last sample that had it: an id repeats within a
-- sample when it already has the current stamp. Nothing is emptied per sample
-- (an id an error left behind has an older stamp); the table is replaced once
-- it has gathered 1024 new ids (about 68 ragdolls of 15 bodies), which bounds
-- it below 2048 entries. Ragdolls sampled in turn reuse their ids.
local limb_seen,seen_ids,sample_stamp={},0,0

-- The root's pose into scratch; false when it is not rigid.
local function sample_root(matrix)
    local px,py,pz,qx,qy,qz,qw=rigid_pose(matrix)
    if not px then return false end
    local r=root_pose
    r[1],r[2],r[3],r[4],r[5],r[6],r[7]=px,py,pz,qx,qy,qz,qw
    return true
end

-- A body's pose relative to the root's, written into pose; false when the
-- body's pose is not rigid. Inverse root rotation applied to the displacement,
-- and conjugate(root) multiplied by body rotation. A coherent whole-corpse
-- turn is not flapping.
local function relative_pose(matrix,pose)
    local bx,by,bz,qx,qy,qz,qw=rigid_pose(matrix)
    if not bx then return false end
    local r=root_pose
    local x,y,z,w=-r[4],-r[5],-r[6],r[7]
    local dx,dy,dz=bx-r[1],by-r[2],bz-r[3]
    local tx,ty,tz=2*(y*dz-z*dy),2*(z*dx-x*dz),2*(x*dy-y*dx)
    pose[1],pose[2],pose[3],pose[4],pose[5],pose[6],pose[7]=
        dx+w*tx+y*tz-z*ty,dy+w*ty+z*tx-x*tz,dz+w*tz+x*ty-y*tx,
        w*qx+x*qw+y*qz-z*qy,w*qy-x*qz+y*qw+z*qx,w*qz+x*qy-y*qx+z*qw,w*qw-x*qx-y*qy-z*qz
    return true
end

-- Every main body's relative pose into scratch, in main_bodies order. Returns
-- how many bodies it sampled, or nil when a pose is not rigid, a body id
-- repeats or the root is not among them.
local function sample_limbs(bodies,root_id)
    -- ipairs visits at most #bodies entries.
    if #bodies>limb_capacity then limb_scratch(#bodies) end
    if seen_ids>=1024 then limb_seen,seen_ids={},0 end
    sample_stamp=sample_stamp+1
    local seen,stamp,sampled=limb_seen,sample_stamp,0
    for i,body in ipairs(bodies) do
        local id=body.id
        local mark=seen[id]
        if mark==stamp or not relative_pose(body.pose,limb_poses[i]) then return nil end
        if mark==nil then seen_ids=seen_ids+1 end
        seen[id]=stamp;sampled=i
    end
    if seen[root_id]~=stamp then return nil end
    return sampled
end

-- History's own copies of a scratch pose (position, rotation) and of each
-- body's relative pose by body id: history never holds a scratch table.
local function kept_pose(pose)
    return {pose[1],pose[2],pose[3]},{pose[4],pose[5],pose[6],pose[7]}
end
local function kept_limbs(bodies,sampled)
    local limbs={}
    for i=1,sampled do
        local position,rotation=kept_pose(limb_poses[i])
        limbs[bodies[i].id]={position=position,rotation=rotation}
    end
    return limbs
end

-- An armed sample's limbs: a main body other than the root that stays more
-- than 0.5 m or 15 degrees from its kept relative pose for at least 100 ms.
-- Returns its id, distance and degrees; nil when there is none; false when
-- history lacks one of the bodies.
local function limb_excursion(bodies,root_id,previous,now)
    local excursions=previous.excursions or {}
    previous.excursions=excursions
    for i,body in ipairs(bodies) do
        local id=body.id
        local old=previous.limbs[id]
        if not old then return false end
        local ld,la=separation(limb_poses[i],old.position,old.rotation)
        if id~=root_id and (ld>.5 or la>15) then
            local started=excursions[id]
            if started and now-started>=.1 then return id,ld,la end
            excursions[id]=started or now
        else excursions[id]=nil end
    end
    return nil
end

-- Client-side containment of motion restarting after a fixed corpse has had
-- time to settle. History contains numeric identities and copied poses only.
-- A fixed flag alone is insufficient: the recording includes normal final
-- corrections after that transition, before the root becomes stationary.
function M.fling_action(unit,state,now)
    state.fling_history=state.fling_history or {}
    local history=state.fling_history
    local key=unit.unit
    local root=unit.root_body
    local profile=profiles[unit.resource]
    if not settled(unit) or unit.corpse or unit.owner~=false
        or unit.active~=true or unit.update_enabled~=true then
        if key then history[key]=nil end
        return nil
    end
    -- Tripod settings intentionally disable every main actor on landing.
    -- Once this completed fixed state persists, finish through the same native
    -- stop/owner route. Never read disabled Havok bodies or resurrect collision.
    if profile.finish_disabled and unit.main_enabled==0 then
        local previous=history[key]
        if not previous or not previous.disabled or previous.entity~=unit.id
            or previous.resource~=unit.resource or previous.members~=unit.main_signature
            or now<=previous.last or now-previous.last>1 then
            history[key]={disabled=true,entity=unit.id,resource=unit.resource,
                members=unit.main_signature,since=now,last=now,samples=1}
        else
            previous.last=now;previous.samples=previous.samples+1
            if previous.samples>=3 and now-previous.since>=1 then
                return {distance=0,degrees=0,actor=unit.root_id,cause='landed_disabled'}
            end
        end
        return nil
    end
    if not root or not sample_root(root.pose) then history[key]=nil;return nil end
    local bodies=unit.main_bodies
    if not bodies or #bodies~=unit.main_enabled then history[key]=nil;return nil end
    local sampled=sample_limbs(bodies,root.id)
    if not sampled then history[key]=nil;return nil end
    local previous=history[key]
    if not previous or previous.entity~=unit.id or previous.resource~=unit.resource
        or previous.actor~=root.id or previous.members~=unit.main_signature or previous.enabled~=unit.main_enabled
        or now<=previous.last or now-previous.last>1 then
        local position,rotation=kept_pose(root_pose)
        history[key]={entity=unit.id,resource=unit.resource,actor=root.id,members=unit.main_signature,
            enabled=unit.main_enabled,position=position,rotation=rotation,limbs=kept_limbs(bodies,sampled),
            since=now,last=now,samples=1,armed=false}
        return nil
    end
    previous.last=now;previous.samples=previous.samples+1
    local distance,degrees=separation(root_pose,previous.position,previous.rotation)
    if previous.armed then
        -- Experimental containment thresholds, not engine-defined limits.
        if distance>.75 or degrees>20 then
            return {distance=distance,degrees=degrees,actor=root.id,
                cause=distance>.75 and 'translation' or 'rotation'}
        end
        local actor,ld,la=limb_excursion(bodies,root.id,previous,now)
        if actor==false then history[key]=nil;return nil end
        if actor then
            return {distance=distance,degrees=degrees,actor=actor,limb_distance=ld,limb_degrees=la,
                cause=ld>.5 and 'limb_translation' or 'limb_rotation'}
        end
    elseif distance>.25 or degrees>10 then
        previous.position,previous.rotation=kept_pose(root_pose);previous.limbs=kept_limbs(bodies,sampled)
        previous.since=now;previous.samples=1
    elseif previous.samples>=3 and now-previous.since>=1 then
        previous.armed=true;state.fling_armed=(state.fling_armed or 0)+1
    end
    return nil
end

-- Module-relative addresses (a base plus a constant) are made once per pair of
-- module bases, which the loader passes in unchanged every poll, instead of as
-- new pointer objects every poll.
local based_game,based_exe,mode_slot,world_slots,manager_slots=nil,nil,nil,{},{}
local function rebase(game,exe)
    if rawequal(game,based_game) and rawequal(exe,based_exe) then return end
    based_game,based_exe,mode_slot=game,exe,game+0x33266a0
    manager_slots[false],manager_slots[true]=game+0x3326948,game+0x3326920
    for index=0,3 do world_slots[index]=exe+0x27ba8a8+176*index end
end
-- The getter's slot object is reused only while the vtable pointer read this
-- poll has the same value, so the address read is always this poll's.
local getter_vtable,getter_slot
local function checked_world(api,exe,index,read,state)
    local reference=read(world_slots[index] or exe+0x27ba8a8+176*index,8)
    if reference==ZERO8 then return nil end
    local world=assert(api.pointer(reference),'Physics world unavailable')
    local vt=assert(api.pointer(read(world,8)),'Physics vtable unavailable')
    if vt~=getter_vtable then getter_vtable,getter_slot=vt,vt+136 end
    local getter=assert(api.pointer(read(getter_slot,8)),'Physics getter unavailable')
    local offset=api.distance(getter,exe)
    if offset~=0xd0cfa0 then
        state.getter_failures=(state.getter_failures or 0)+1
        state.last_getter_failure=string.format(
            'Body getter changed: world_index=%d world=%.0f vtable=%.0f actual=%.0f expected=%.0f offset=%.0f',
            index,api.address(world),api.address(vt),api.address(getter),api.address(exe+0xd0cfa0),offset)
        error(state.last_getter_failure)
    end
    state.getter_checks=(state.getter_checks or 0)+1
    return world
end

-- M.snapshot's helpers are made once, not as new closures every poll.
-- begin_snapshot points them at the poll's api, state and exe and empties their
-- tables (keeping emptied ones for reuse), so nothing copied or decoded in one
-- poll is used in another: the same lifetime as when they were made per poll.
local read,fetch,cached,pointer,world_for,pool_for,guard,begin_snapshot,snapshot_totals
local body_arrays={}
do
    local api,state,exe,used,calls
    -- pool_tables keeps one table per pool index across polls so a poll
    -- refills it instead of making a new one; pools says which were filled in
    -- this poll, and only those are used.
    local cache,worlds,pools,pool_tables,spare={},{},{},{},{}
    function begin_snapshot(a,s,e)
        api,state,exe,used,calls=a,s,e,0,0
        for key,sizes in pairs(cache) do
            for size in pairs(sizes) do sizes[size]=nil end
            spare[#spare+1]=sizes;cache[key]=nil
        end
        for index in pairs(worlds) do worlds[index]=nil end
        for index in pairs(body_arrays) do body_arrays[index]=nil end
        for index in pairs(pools) do pools[index]=nil end
    end
    function snapshot_totals() return used,calls end
    function read(address,size)
        assert(size>0 and size<=32768,'Read size outside bounds')
        used=used+size;calls=calls+1
        assert(used<=4*1024*1024 and calls<=18000,'Snapshot budget exceeded')
        local b=assert(api.read(address,size),'Data unavailable');assert(#b==size,'Short read');return b
    end
    -- Like read, but through the scratch view while it stays paired with
    -- api.read: the bytes are then valid only until the next view and no Lua
    -- string is made. Counted against the same snapshot budget.
    function fetch(address,size)
        if not viewable(api) then return read(address,size) end
        assert(size>0 and size<=32768,'Read size outside bounds')
        used=used+size;calls=calls+1
        assert(used<=4*1024*1024 and calls<=18000,'Snapshot budget exceeded')
        return assert(api.view(address,size),'Data unavailable')
    end
    function cached(address,size,optional)
        local key=api.address(address)
        local sizes=cache[key]
        if not sizes then sizes=table.remove(spare) or {};cache[key]=sizes end
        if sizes[size]==nil then
            if optional then
                local ok,bytes=pcall(read,address,size);sizes[size]=ok and bytes or false
            else sizes[size]=read(address,size) end
        end
        return sizes[size] or nil
    end
    function pointer(b,o) return assert(api.pointer(b,o),'Pointer unavailable') end
    -- These decoded values share the existing copied-byte cache's lifetime:
    -- one snapshot/poll only. Actor/body identities and mutation guards remain
    -- fresh. No resolved address is retained in state or across polls.
    function world_for(index)
        local world=worlds[index]
        if world~=nil then
            if world then state.getter_checks=(state.getter_checks or 0)+1 end
            return world or nil
        end
        world=checked_world(api,exe,index,cached,state)
        worlds[index]=world or false
        state.world_metadata_decodes=(state.world_metadata_decodes or 0)+1
        return world
    end
    function pool_for(index)
        local pool=pools[index]
        if not pool then
            local b=cached(exe+0x2369b00+64*index,56)
            local layout=u32(b,28)
            pool=pool_tables[index] or {};pool_tables[index]=pool
            pool.base,pool.count,pool.mask,pool.generation=pointer(b),u32(b,36),u32(b,40),u32(b,52)
            pool.stride,pool.identity_offset,pool.data_offset=
                bit.band(layout,65535),bit.band(bit.rshift(layout,16),255),bit.rshift(layout,24)
            pools[index]=pool
            state.pool_metadata_decodes=(state.pool_metadata_decodes or 0)+1
        end
        return pool
    end
    -- With view (a capture() made just before, no other view in between) the
    -- guarded bytes are copied out of it at offset instead of read again.
    function guard(list,address,size,view,offset)
        local b=view and ffi.string(view+offset,size) or read(address,size);list[#list+1]={address=address,bytes=b};return b
    end
end
-- Like guard, but fills entry i in place (a new entry the first time): the
-- manager globals' list is kept across polls, so its two entries cost no table.
local function keep(list,i,address,size)
    local b,entry=read(address,size),list[i]
    if entry then entry.address,entry.bytes=address,b else list[i]={address=address,bytes=b} end
    return b
end
-- With consume, units are handed over one by one and never collected, so the
-- returned and selected lists stay empty and the globals' list is reused (its
-- grouping plan dropped, so every poll groups its guards afresh). Without
-- consume, the caller keeps the units: fresh lists, as before.
local EMPTY,RAGDOLL_FIRST,CORPSE_FIRST,manager_globals={},{false,true},{true,false},{[false]={},[true]={}}
local function no_units(consume) if consume then return EMPTY end;return {} end
local function manager_lists(corpse,consume)
    if not consume then return {},{} end
    local globals=manager_globals[corpse];globals.compiled=nil;return globals,EMPTY
end

-- M.snapshot in named steps. scan_poll points them at the poll (its api,
-- state, exe, consume and budget, then the mission mode it reads) and
-- scan_manager at the manager being scanned. Every value is set in the same
-- poll before a step reads it; nothing is used by a later poll.
local scan_poll,scan_steps
do
    local api,state,exe,consume,budget,preflight_due
    local mode_reference,mode,mode_bytes
    local corpse,manager_name,manager,active,entities,pointers,runtime,sync,sync_number,globals,selected
    -- The entity address of the entry being visited (the listing's number),
    -- recorded in its unit for the corpse re-check backoff.
    local visit_address
    -- sync_counts[k] is the count of entry sync_first+k, copied this poll
    -- after the last inspection; sync_first is nil when there is none.
    local manager_count,sync_first,sync_last,sync_counts=0,nil,nil,{}
    local SYNC_WINDOW,CLOCK_EVERY=16,8

    -- The unit's record and identity guards: its entity header, the mission
    -- mode and its manager entry.
    local function new_unit(index,entity,e)
        local u={resource=e:sub(1,8),id=u32(e,8),unit=u32(e,12),corpse=corpse,address=visit_address,
            owner=bit.band(u32(e,20),1)~=0,active=index<active,manager=manager,index=index,
            guards={},main={},main_bodies={},main_pose_guards={},registered={},actors={},
            main_enabled=0,main_static=0,main_disabled=0,main_dynamic_allowed=0}
        u.guards[#u.guards+1]={address=entity,bytes=e}
        u.guards[#u.guards+1]={address=mode_slot,bytes=mode_reference}
        u.guards[#u.guards+1]={address=mode+8,bytes=mode_bytes:sub(9,12)}
        u.guards[#u.guards+1]={address=entities+index*8,bytes=pointers:sub(index*8+1,index*8+8)}
        return u
    end
    -- A ragdoll's main-body members from its runtime record r, each guarded.
    local function main_members(u,profile,r)
        local b=read(r,profile.bodies*712)
        local members={}
        for i=0,profile.bodies-1 do
            local id=u32(b,i*712)
            assert(id~=0xffffffff and not u.main[id],'Invalid main actor membership')
            u.main[id]=profile.main[i+1];u.registered[id]=true
            members[#members+1]=tostring(id);if i==0 then u.root_id=id end
            u.guards[#u.guards+1]={address=r+i*712,bytes=b:sub(i*712+1,i*712+8)}
            local n=u32(b,i*712+12);assert(n<=9,'Sub-actor bounds changed')
            for j=0,n-1 do u.registered[u32(b,i*712+28+j*76)]=true end
        end
        u.main_signature=table.concat(members,':')
    end
    -- A ragdoll's runtime record and sync counts; false when they do not match
    -- the profile.
    local function ragdoll_runtime(u,profile,quick)
        local r=runtime+u.index*11192
        local meta=guard(u.guards,r+11160,32)
        if u32(meta,0)~=profile.bodies or meta:byte(13)>1 or meta:byte(14)~=0 or meta:sub(17,24)~=ZERO8 then return false end
        u.update_enabled=meta:byte(13)==1;u.update_address=r+11172
        local s=sync+u.index*432
        -- The eligibility check read the word at s for this entity this poll,
        -- and no native call runs in between: its bytes become the guard's
        -- instead of a second read. The guard is validated with the others,
        -- as before. The rotation count (+184) and flag (+428) lie within 245
        -- bytes: one copy, each still with its own guard.
        local pc=string.char(quick%256,floor(quick/256)%256,floor(quick/65536)%256,floor(quick/16777216))
        local sv=capture(api,s+184,245);u.guards[#u.guards+1]={address=s,bytes=pc}
        local rc,flag=guard(u.guards,s+184,4,sv,0),guard(u.guards,s+428,1,sv,244)
        if u32(pc)~=profile.bodies or u32(rc)~=profile.bodies or flag:byte()~=0 then return false end
        main_members(u,profile,r)
        return true
    end
    -- The unit object: generation, identity and skeleton size, then the
    -- skeleton's node matrices. Returns the unit's slot and nodes.
    local function skeleton(u,profile)
        local registry=pointer(guard(u.guards,exe+0x1a100f0,8))
        local uh=cached(registry,0xa8);local slot_index=u.unit%0x400000
        assert(slot_index<u32(uh,0x98),'Unit index changed')
        local gen_address=pointer(uh,0xa0)+slot_index
        assert(guard(u.guards,gen_address,1)==string.char(math.floor(u.unit/0x400000)),'Unit generation changed')
        local slot=pointer(uh,0x88)+slot_index*8
        -- The unit object's identity (+8), skeleton size (+0x70) and node
        -- pointer (+0x88) words lie within 136 bytes: one copy. Each keeps its
        -- own guard, checked in the same order.
        local object=pointer(guard(u.guards,slot,8));local v=capture(api,object+8,0x88)
        assert(u32(guard(u.guards,object+8,4,v,0))==u.unit,'Unit identity changed')
        local node_count=u32(guard(u.guards,object+0x70,4,v,0x68))
        assert(node_count==profile.nodes,'Skeleton changed')
        local node_pointer=pointer(guard(u.guards,object+0x88,8,v,0x80))
        return slot_index,read(node_pointer,node_count*64)
    end
    -- The unit's actor handles, inline or behind a pointer; nil for none.
    local function actor_handles(u,slot_index)
        local list=pointer(guard(u.guards,exe+0x27c5b40,8))+slot_index*24
        local ah=guard(u.guards,list,24);local flags=u32(ah,4)
        assert(bit.band(flags,0x40000000)~=0 and bit.band(u32(ah),0x3fffffff)==u.unit,'Actor list identity changed')
        local n=bit.band(flags,127)
        if n==0 then return nil end
        local actor_pointer=bit.band(flags,0x80000000)~=0 and list+8 or pointer(ah,8)
        return guard(u.guards,actor_pointer,n*4),n
    end
    -- The pool and index of the row actor_row decoded last (this actor's).
    local row_pool,row_ai
    -- An actor's pool row: its identity word and 40 data bytes, each as copied
    -- bytes and a zero-based offset into them. Rows copied together are
    -- decoded in place: a row's own bytes and addresses are made only when a
    -- guard or a command needs them.
    local function actor_row(id)
        local pool=pool_for(bit.band(bit.rshift(id,28),3)+10*bit.rshift(id,30))
        local ai=bit.band(id,pool.mask)
        assert(ai<pool.count and bit.band(id,pool.generation)~=0,'Expired actor')
        local stride=pool.stride
        local identity_offset,data_offset=pool.identity_offset,pool.data_offset
        row_pool,row_ai=pool,ai
        if stride<=256 and identity_offset+4<=stride and data_offset+40<=stride then
            local first=ai-ai%16
            local size=math.min(16,pool.count-first)*stride
            -- Actor rows may be copied together. Havok bodies must remain
            -- individual: disabled body slots are off-limits.
            local rows=cached(pool.base+first*stride,size,true)
            if rows then
                local base=(ai-first)*stride
                return rows,base+identity_offset,rows,base+data_offset
            end
        end
        local entry=pool.base+ai*stride
        return read(entry+identity_offset,4),0,read(entry+data_offset,40),0
    end
    -- The current row's identity and data addresses, made only when needed.
    local function row_addresses()
        local pool=row_pool
        local entry=pool.base+row_ai*pool.stride
        return entry+pool.identity_offset,entry+pool.data_offset
    end
    -- n bytes at zero-based offset o of copied bytes b, as their own string.
    local function slice(b,o,n)
        if o==0 and #b==n then return b end
        return b:sub(o+1,o+n)
    end
    -- An enabled actor's physics body, copied whole and checked against the
    -- actor. Returns its address, bytes (a scratch view when the adapter has
    -- one: valid only until the next view), motion word and collision filter.
    local function actor_body(u,id,ab,ao)
        local world_index=bit.rshift(id,30)
        local world=assert(world_for(world_index),'Physics world unavailable')
        local bi=bit.band(u32(ab,ao+20),0xffffff);assert(bi<262144,'Body index changed')
        local base=body_arrays[world_index]
        if not base then base=pointer(cached(world+24,8));body_arrays[world_index]=base end
        local body_address=base+160*bi
        local body=fetch(body_address,160)
        local word=type(body)=='string' and u32 or view_u32
        assert(word(body,144)==id and word(body,148)==u.unit,'Physics body identity changed')
        return body_address,body,word(body,64),bit.band(word(body,108),127)
    end
    -- The body's 160 bytes as a string: kept for guards, commands and poses.
    local function copied(body)
        if type(body)=='string' then return body end
        return ffi.string(body,160)
    end
    -- Whether the body's first 64 bytes equal the node matrix at offset.
    local function matrix_equal(nodes,offset,body)
        if type(body)=='string' then return ranges_equal(nodes,offset,body,0,64) end
        if offset<0 or offset+64>#nodes then return false end
        for i=0,63 do if byte(nodes,offset+i+1)~=body[i] then return false end end
        return true
    end
    -- An enabled main body: counted, its motion and identity guarded, its pose
    -- guarded and (ragdolls only) decoded.
    local function count_main_body(u,profile,id,name,body_address,body,motion)
        u.main_enabled=u.main_enabled+1
        u.main_static=u.main_static+(motion==0 and 1 or 0)
        if u.corpse and motion~=0 and profile.corpse_dynamic_main and profile.corpse_dynamic_main[name] then
            u.main_dynamic_allowed=u.main_dynamic_allowed+1
        end
        u.guards[#u.guards+1]={address=body_address+64,bytes=body:sub(65,68)}
        u.guards[#u.guards+1]={address=body_address+144,bytes=body:sub(145,152)}
        local pose_guard={address=body_address,bytes=body:sub(1,64)}
        u.main_pose_guards[#u.main_pose_guards+1]=pose_guard
        -- Corpse-phase planning uses primary identity/motion, not decoded
        -- primary transforms. Keep every guard.
        local main_body={id=id,pose=not u.corpse and floats(body,0,16) or nil,guards={pose_guard}}
        u.main_bodies[#u.main_bodies+1]=main_body
        -- The root's only guard is its pose guard, already in main_pose_guards.
        if id==u.root_id then u.root_body=main_body;u.root_in_pose_guards=true end
    end
    -- Whether M.plan could act on an auxiliary actor: the same authored
    -- mapping, registration, claw and static-body tests it applies. A static
    -- body whose bytes equal its node is already aligned (M.plan compares the
    -- identical table and skips it), so it needs no record.
    local function actionable(profile,ab,ao,registered,motion,body,nodes)
        local name,node=u32(ab,ao+24),u32(ab,ao+28)
        local claw=profile.name=='Impaler' and claws[name]
        return profile.actors[name] and node<#nodes/64 and not registered
            and profile.actors[name]==u32(ab,ao+32)
            and (claw or (motion==0 and not matrix_equal(nodes,node*64,body)))
    end
    -- An actor record's node pose (decoded once per node and unit) and pose.
    -- Copied matrices are immutable during the poll. Exact byte equality proves
    -- no pose repair is due; all nonidentical matrices retain the rigid checks.
    local function poses(nodes,node_matrices,node,body)
        local node_pose=node_matrices[node]
        if not node_pose then
            node_pose=floats(nodes,node*64,16);node_matrices[node]=node_pose
        end
        return node_pose,ranges_equal(nodes,node*64,body,0,64) and node_pose or floats(body,0,16)
    end
    -- One actor of the unit: its row; a main actor's guards and counts; an
    -- enabled actor's body; a record for an auxiliary actor M.plan could act on.
    -- A main actor's row guards: its data, then its identity.
    local function main_row(u,ib,io,ab,ao)
        local identity_address,address=row_addresses()
        u.guards[#u.guards+1]={address=address,bytes=slice(ab,ao,40)}
        u.guards[#u.guards+1]={address=identity_address,bytes=slice(ib,io,4)}
    end
    local function inspect_actor(u,profile,id,main_names,nodes,node_matrices)
        local ib,io,ab,ao=actor_row(id)
        assert(u32(ib,io)==id,'Actor generation changed')
        assert(u32(ab,ao+12)==u.unit,'Actor owner changed')
        local name,node=u32(ab,ao+24),u32(ab,ao+28)
        local enabled=bit.band(u32(ab,ao+16),1)~=0
        local is_main=u.corpse and profile.main_names[name] or u.main[id]
        if is_main then
            assert((u.corpse or name==u.main[id]) and not main_names[name], 'Main actor names changed')
            main_names[name]=true
            main_row(u,ib,io,ab,ao)
            if not enabled and profile.disabled_main[name] then u.main_disabled=u.main_disabled+1 end
        end
        -- Disabled tentacles can retain differently tagged body IDs. They are
        -- never repair targets. Skip their bodies entirely; undeclared disabled
        -- primaries still block settlement.
        if not enabled then return end
        detail(api,'bodies')
        local body_address,body,motion,filter=actor_body(u,id,ab,ao)
        -- Main bodies keep their bytes as guards: copy them out of the view
        -- before anything else takes one.
        if is_main then body=copied(body);count_main_body(u,profile,id,name,body_address,body,motion) end
        local registered=u.registered[id] or is_main or filter==52 or filter==48 or filter==83
        if not actionable(profile,ab,ao,registered,motion,body,nodes) then return end
        body=copied(body)
        local node_pose,pose=poses(nodes,node_matrices,node,body)
        -- The copied body block is kept whole; command_guards slices the same
        -- bytes only if a command needs them. Fresh identity and motion are
        -- validated again at command dispatch; aligned actors need no extra
        -- read pass.
        local identity_address,address=row_addresses()
        local a={id=id,name=name,node=node,node_hash=u32(ab,ao+32),enabled=enabled,motion=motion,
            registered=registered,pose=pose,node_pose=node_pose,
            guard_source={identity_address,slice(ib,io,4),address,slice(ab,ao,40),body_address,body}}
        a.stable=true;u.actors[#u.actors+1]=a
    end
    -- The unit's actors, in handle order; invalid handles are skipped.
    local function inspect_actors(u,profile,handles,n,nodes)
        local main_names,node_matrices={},{}
        for i=0,n-1 do
            detail(api,'actors')
            local id=u32(handles,i*4)
            if id~=0xffffffff then inspect_actor(u,profile,id,main_names,nodes,node_matrices) end
        end
    end
    -- One listed, eligible unit, read and checked in full. The caller runs it
    -- in pcall: a failed read or check skips the unit. nil when it does not
    -- qualify this poll.
    local function inspect(index,entity,e,profile,quick)
        local u=new_unit(index,entity,e)
        if not corpse and not ragdoll_runtime(u,profile,quick) then return nil end
        u.settled=true
        detail(api,'skeleton')
        local slot_index,nodes=skeleton(u,profile)
        detail(api,'actors')
        local handles,n=actor_handles(u,slot_index)
        if not handles then return nil end
        inspect_actors(u,profile,handles,n,nodes)
        if not same(api,u.guards) then return nil end
        return u
    end
    -- A unit inspected in full goes to consume once the manager's globals still
    -- hold, or without consume into the manager's selected list.
    local function hand_over(unit)
        if not consume then selected[#selected+1]=unit;return end
        if same(api,globals) then
            for _,g in ipairs(globals) do unit.guards[#unit.guards+1]=g end
            -- inspect verified the unit's own guards and the globals were just
            -- verified, with no native call since: consume need not compare
            -- them again before its first native call (verified is cleared by
            -- the first one).
            unit.verified=true
            consume(unit)
        else
            if state.fling_history then state.fling_history[unit.unit]=nil end
            state.skipped=(state.skipped or 0)+1
        end
    end
    -- Inspects a listed, eligible unit and records the outcome.
    -- The poll's first inspection sets its 1 ms deadline (one clock read) and
    -- runs the read-only preflight: the exact getter path the corpse reader
    -- uses, checked before any unit's bodies. World 2 hosts the captured enemy
    -- actors; absence during loading is normal.
    local function first_inspection()
        if budget and not budget.deadline and api.clock then budget.deadline=api.clock()+M.budget_seconds end
        if not preflight_due then return end
        preflight_due=false
        state.preflight_getter='checking'
        state.preflight_getter=world_for(2) and 'verified' or 'waiting_for_world'
    end
    local function inspect_listed(index,entity,e,profile,quick)
        first_inspection()
        if budget then budget.inspected=budget.inspected+1 end
        phase(api,'snapshot')
        detail(api,'metadata')
        local profile_start=api.profiler and api.clock()
        local profile_reads=api.profiler and api.profiler.reads
        local ok,unit=pcall(inspect,index,entity,e,profile,quick)
        -- The inspection took views and its commands may have changed the
        -- game: sync counts are copied afresh for the next listed entry.
        sync_first=nil
        if ok and unit then hand_over(unit)
        elseif not ok then state.skipped=(state.skipped or 0)+1;state.last_skip=tostring(unit) end
        if (not ok or not unit) and state.fling_history then state.fling_history[u32(e,12)]=nil end
        if api.profiler then api.profiler.unit(profile.name,profile_start,profile_reads,ok and unit or nil) end
    end
    -- One manager entry: its header and, for a listed resource, the cheap
    -- lifecycle check before counting against the expensive-unit limit or
    -- reading any skeleton. True once 32 units are selected.
    -- The ragdoll's sync count at index, or nil when unreadable. One view
    -- copies the counts of up to SYNC_WINDOW entries from index on (432-byte
    -- stride, only as many as this poll may still scan) into sync_counts, so
    -- the following listed entries cost no read of their own. Without the
    -- paired view, or if it fails, each count is read on its own as before.
    local function sync_count(index)
        if sync_first and index>=sync_first and index<=sync_last then return sync_counts[index-sync_first] end
        local n=math.min(manager_count-index,SYNC_WINDOW,budget and M.max_entities-budget.scanned+1 or SYNC_WINDOW)
        local view=n>1 and viewable(api) and api.view(sync_number+index*432,(n-1)*432+4)
        if not view then
            local b=api.read(sync_number+index*432,4)
            return b and #b==4 and u32(b) or nil
        end
        for k=0,n-1 do sync_counts[k]=view_u32(view,k*432) end
        sync_first,sync_last=index,index+n-1
        return sync_counts[0]
    end
    -- The entry's header (24 bytes) through the view when there is one: an
    -- unlisted resource then makes no string. Returns the header's bytes (a
    -- string, made only for a listed resource) and its profile, or nil.
    local function header(entity)
        if not viewable(api) then
            local e=api.read(entity,24)
            return e,e and profiles[e:sub(1,8)]
        end
        local v=api.view(entity,24)
        local keys=v and resource_words[view_u32(v,0)]
        local key=keys and keys[view_u32(v,4)]
        if not key then return nil end
        return ffi.string(v,24),profiles[key]
    end
    -- The listing: which entries of a manager hold a listed resource, kept
    -- across polls in state.listings so an idle poll reads no entry header.
    -- It is a hint for where to look, never data to act on: an entry it names
    -- has its header read afresh before inspection, and everything a command
    -- depends on is read and guarded in that poll, as before. Entities are
    -- classified by address (the header's resource words; the unit word is
    -- kept for clearing motion history). The whole pointer array is compared
    -- with the last poll's (an interned string: one comparison, no
    -- allocation); only a changed array is walked, and only addresses not
    -- seen before cost a header view. An entity can be freed and another
    -- allocated at the same address between two polls, leaving the array
    -- unchanged: a rolling verification re-reads ceil(count/16) headers of
    -- the manager scanned first in each poll (the managers alternate), so
    -- every entry is checked again within 32 polls (1.5-2 s).
    local SWEEP_POLLS=16
    local listing
    local function listing_of(is_corpse)
        local all=state.listings
        if not all then all={};state.listings=all end
        local l=all[is_corpse]
        if not l then l={known={},units={},stamps={},listed={},n=0,size=0,stamp=0,sweep=0};all[is_corpse]=l end
        return l
    end
    -- The entity address at entry index of the copied pointer array, as a
    -- number (no pointer object); 0 when it is not a user address.
    local function address_at(index)
        local b1,b2,b3,b4,b5,b6,b7,b8=byte(pointers,index*8+1,index*8+8)
        local value=b1+b2*256+b3*65536+b4*16777216+(b5+b6*256+b7*65536+b8*16777216)*4294967296
        if value<0x10000 or value>=0x800000000000 then return 0 end
        return value
    end
    -- The resource key (false when not listed) and unit word of the entity
    -- at address, from a fresh header; nil when the header is unreadable.
    local function classify(address)
        if viewable(api) then
            local v=api.view(address,24)
            if not v then return nil end
            local keys=resource_words[view_u32(v,0)]
            local key=keys and keys[view_u32(v,4)]
            if not key then return false end
            return key,view_u32(v,12)
        end
        local e=api.read(address,24)
        if not e or #e~=24 then return nil end
        local key=e:sub(1,8)
        if not profiles[key] then return false end
        return key,u32(e,12)
    end
    -- Forgets addresses the array no longer holds, once they outnumber it.
    local function prune(l,count)
        if l.size<=2*count+64 then return end
        local known,units,stamps,stamp,size=l.known,l.units,l.stamps,l.stamp,0
        for address,seen in pairs(stamps) do
            if seen~=stamp then stamps[address]=nil;known[address]=nil;units[address]=nil else size=size+1 end
        end
        l.size=size
    end
    -- Rebuilds the listed entry indices from this poll's pointer array. At
    -- most M.max_entities new addresses are classified per poll; the rest
    -- wait for the next (the listing stays incomplete and the poll counts as
    -- yielded).
    -- The listing's key for a valid address, classifying it while the poll
    -- may still (left > 0). Returns the key (nil: not classified) and left.
    -- An unreadable header counts as unlisted: the rolling verification
    -- reads it again within 32 polls, and the array's next change reclassifies
    -- nothing it already knows.
    local function key_of(l,address,left)
        local key=l.known[address]
        if key==nil and left>0 then
            left=left-1
            local unit
            key,unit=classify(address)
            if key==nil then key=false;state.listing_unreadable=(state.listing_unreadable or 0)+1 end
            l.known[address],l.units[address]=key,unit
            state.listing_classified=(state.listing_classified or 0)+1
        end
        if l.stamps[address]==nil then l.size=l.size+1 end
        l.stamps[address]=l.stamp
        return key,left
    end
    local function relist(l,count)
        l.stamp=l.stamp+1
        local listed,n,left,complete=l.listed,0,M.max_entities,true
        for index=0,count-1 do
            local address=address_at(index)
            local key
            if address~=0 then key,left=key_of(l,address,left) else key=false end
            if key==nil then complete=false elseif key then n=n+1;listed[n]=index end
        end
        for i=n+1,l.n do listed[i]=nil end
        l.n,l.count,l.complete,l.pointers=n,count,complete,complete and pointers or nil
        prune(l,count)
        if not complete and budget then budget.yielded=true end
    end
    -- Re-reads a few known entries' headers (the rolling verification); a
    -- changed one is reclassified and the listing rebuilt.
    local function verify(l,count)
        local known,units=l.known,l.units
        for _=1,math.ceil(count/SWEEP_POLLS) do
            local index=l.sweep%count;l.sweep=index+1
            local address=address_at(index)
            local key=known[address]
            if key~=nil then
                local fresh,unit=classify(address)
                if fresh~=nil and (fresh~=key or fresh and units[address]~=unit) then
                    known[address],units[address],l.pointers=fresh,unit,nil
                    state.listing_changes=(state.listing_changes or 0)+1
                end
            end
        end
    end
    -- Whether the corpse at address waits for its next re-check: its unit's
    -- backoff record (consume keeps it) names this address and is not due.
    -- Records are kept only by M.apply's polls.
    local function backed_off(address)
        local checks=state.corpse_checks
        local record=checks and checks[listing.units[address]]
        return record~=nil and record.address==address and state.fling_scan<record.due
    end
    -- A listed entry: the cheap lifecycle check (ragdolls: the sync count),
    -- then a fresh header for an eligible one. A header that no longer
    -- matches the listing is skipped this poll and classified afresh by the
    -- next poll's rebuild.
    local function visit(index)
        local address=address_at(index)
        local key=listing.known[address]
        local profile=key and profiles[key]
        if not profile then return false end
        if corpse and backed_off(address) then
            state.corpse_rechecks_deferred=(state.corpse_rechecks_deferred or 0)+1
            return false
        end
        local quick=not corpse and sync_count(index)
        if corpse or quick==profile.bodies then
            local entity=api.pointer(pointers,index*8)
            local e,fresh=header(entity)
            visit_address=address
            if fresh==profile then inspect_listed(index,entity,e,profile,quick)
            else
                listing.known[address],listing.pointers=nil,nil
                state.listing_changes=(state.listing_changes or 0)+1
            end
        elseif state.fling_history then state.fling_history[listing.units[address]]=nil end
        phase(api,'discovery')
        return #selected>=32
    end
    -- The clock is a system call: it is read every CLOCK_EVERY scanned listed
    -- entries and after every inspection (about a hundred reads), not before
    -- every entry, and only once the poll's first inspection has set the
    -- deadline (inspect_listed): a poll that inspects nothing reads no clock.
    -- The 1 ms deadline stays soft.
    local function exhausted()
        if not budget then return nil end
        -- A deadline seen by the first manager also ends the second's scan.
        if budget.yielded or budget.scanned>=M.max_entities or budget.inspected>=M.max_units then return true end
        if budget.scanned==0 or not api.clock or not budget.deadline then return false end
        if budget.scanned%CLOCK_EVERY~=0 and budget.inspected==budget.clocked then return false end
        budget.clocked=budget.inspected
        return api.clock()>=budget.deadline
    end
    -- The first listed position whose entry index is at or after cursor
    -- (wrapping to the first), by bisection of the ascending listed indices.
    local function listed_from(cursor)
        local listed,low,high=listing.listed,1,listing.n
        while low<high do
            local middle=floor((low+high)/2)
            if listed[middle]<cursor then low=middle+1 else high=middle end
        end
        if listed[low]<cursor then return 1 end
        return low
    end
    -- The manager's listed entries from its rotating cursor (an entry index),
    -- within the poll's budget. Unlisted entries cost nothing.
    local function scan_entities(count)
        local n=listing.n
        if n==0 then return end
        local listed=listing.listed
        local first=listed_from((state.cursors[manager_name] or 0)%count)
        for step=0,n-1 do
            if exhausted() then budget.yielded=true;break end
            local index=listed[(first-1+step)%n+1]
            state.cursors[manager_name]=(index+1)%count
            if budget then budget.scanned=budget.scanned+1 end
            if visit(index) then break end
        end
    end
    -- The manager's slot: the bytes copied with the mode slot this poll
    -- (in_mission), or its own read without the paired view.
    local slot_bytes={}
    local function manager_slot()
        local b=slot_bytes[corpse]
        if not b then return keep(globals,1,manager_slots[corpse],8) end
        local entry=globals[1]
        if entry then entry.address,entry.bytes=manager_slots[corpse],b
        else globals[1]={address=manager_slots[corpse],bytes=b} end
        return b
    end
    -- The manager's header, read through its kept globals, with its bounds
    -- checked. Returns the header bytes and the entry count.
    local function manager_header()
        manager=pointer(manager_slot())
        local h=keep(globals,2,manager,88)
        local capacity,count=u32(h,corpse and 16 or 4),u32(h,corpse and 24 or 12)
        active=u32(h,corpse and 28 or 16)
        state[manager_name..'_count']=count
        assert(active<=count and count<=capacity and capacity<=8192 and count<=(corpse and 512 or 2048),'Manager bounds changed')
        if not corpse then assert(u32(h,20)<=active,'Owner partition changed') end
        return h,count
    end
    -- Without consume, the manager's selected units are returned with its
    -- globals once those still hold. With consume, each streamed unit was
    -- checked against them just before its commands; no pointers or unfinished
    -- writes are retained.
    local function collect(result)
        if consume then return end
        if not same(api,globals) then
            state.skipped=(state.skipped or 0)+1
            for _,u in ipairs(selected) do if state.fling_history then state.fling_history[u.unit]=nil end end
            return
        end
        for _,u in ipairs(selected) do
            for _,g in ipairs(globals) do u.guards[#u.guards+1]=g end
            result[#result+1]=u
        end
    end
    local function scan_manager(is_corpse,result,first)
        phase(api,'discovery')
        corpse,manager_name=is_corpse,is_corpse and 'corpse' or 'ragdoll'
        globals,selected=manager_lists(corpse,consume)
        local h,count=manager_header()
        manager_count,sync_first=count,nil
        listing=listing_of(corpse)
        if count>0 then
            entities,runtime,sync=pointer(h,corpse and 64 or 56),pointer(h,72),pointer(h,80)
            pointers=read(entities,count*8)
            if first then verify(listing,count) end
            if pointers~=listing.pointers then relist(listing,count) end
            -- Sync count reads take a number address: no pointer object per entry.
            if listing.n>0 and not corpse then sync_number=api.address(sync) end
            scan_entities(count)
        end
        collect(result)
    end
    -- The mode slot and both manager slots lie within 0x2b0 bytes of
    -- game.dll's data: one view copies all three. A slot is compared as two
    -- words with last poll's (slot_low/slot_high by slot key: 0 for the mode,
    -- false and true for the managers); an unchanged one keeps last poll's
    -- bytes, so no string is made for it. The manager slots are taken from
    -- the view only in a mission, before any other view.
    local SLOT_SPAN=0x2b0
    local slot_low,slot_high,slot_view={},{},nil
    local function slot_from(offset,key,kept)
        local low,high=view_u32(slot_view,offset),view_u32(slot_view,offset+4)
        if kept and slot_low[key]==low and slot_high[key]==high then return kept end
        slot_low[key],slot_high[key]=low,high
        return ffi.string(slot_view+offset,8)
    end
    local function read_mode_slot()
        slot_view=viewable(api) and api.view(mode_slot,SLOT_SPAN) or nil
        if not slot_view then slot_low[0]=nil;return api.read(mode_slot,8) end
        return slot_from(0,0,mode_reference)
    end
    local function read_manager_slots()
        if not slot_view then slot_bytes[false],slot_bytes[true]=nil,nil;return end
        slot_bytes[false]=slot_from(0x2a8,false,slot_bytes[false])
        slot_bytes[true]=slot_from(0x280,true,slot_bytes[true])
    end
    -- The mission mode. The recorded client mission had +8=1 and +0x40=2.
    -- Back on the ship, +8 became zero while +0x40 stayed 2. Do not use that
    -- second field as a mission selector; entity/profile/lifecycle guards
    -- remain mandatory.
    local function in_mission()
        mode_reference=read_mode_slot()
        mode=api.pointer(mode_reference)
        state.mission_flag=0;state.mode_field_40=0
        if not mode then return false end
        -- A read, not a view: the slot view stays valid for the managers.
        mode_bytes=read(mode,0x44)
        state.mission_flag=u32(mode_bytes,8);state.mode_field_40=u32(mode_bytes,0x40)
        if state.mission_flag==0 then return false end
        read_manager_slots()
        return true
    end
    -- The mission check, then both managers. Returns nil outside a mission.
    function scan_poll(a,s,e,c,b)
        api,state,exe,consume,budget=a,s,e,c,b
        if not in_mission() then state.preflight_getter='waiting_for_mission';return nil end
        -- The physics getter preflight runs before the poll's first
        -- inspection (inspect_listed): a poll that inspects nothing makes none
        -- of its 3 reads.
        preflight_due=true
        if state.preflight_getter=='waiting_for_mission' or state.preflight_getter==nil then
            state.preflight_getter='waiting_for_unit'
        end
        local result=no_units(consume)
        state.cursors=state.cursors or {}
        -- Alternate first ownership of the shared budget so neither manager can
        -- starve the other. Cursors are indices only; pointers are always reread.
        state.manager_turn=not state.manager_turn
        for i,is_corpse in ipairs(state.manager_turn and RAGDOLL_FIRST or CORPSE_FIRST) do scan_manager(is_corpse,result,i==1) end
        return result
    end
    scan_steps={scan_poll,in_mission,scan_manager,collect,manager_header,scan_entities,exhausted,visit,inspect_listed,first_inspection,key_of,backed_off,
        relist,verify,classify,prune,listed_from,read_mode_slot,read_manager_slots,slot_from,manager_slot}
end

function M.snapshot(api,game,exe,state,consume,budget)
    phase(api,'discovery')
    begin_snapshot(api,state,exe);rebase(game,exe)
    local result=scan_poll(api,state,exe,consume,budget)
    if not result then return no_units(consume),'waiting_for_mission' end
    state.read_bytes,state.read_calls=snapshot_totals()
    return result,'ready'
end
-- Machine code: before the split, nothing outside the per-unit inspection
-- compiled in the game's LuaJIT (begin_snapshot's pairs() and the creation of
-- the inspection closure aborted every trace through M.snapshot), so these
-- steps stay interpreted. The inspection steps and hand_over compile as the
-- closure's body did.
if jit and jit.off then
    jit.off(M.snapshot)
    for _,fn in ipairs(scan_steps) do jit.off(fn) end
end
scan_steps=nil

-- A settled remote ragdoll still receiving network corrections nudges its
-- skeleton a few centimetres every tenth of a second, and each nudge
-- requalified the same auxiliary actor: one recorded Acid Charger received 389
-- realignments in 4.3 s. The first correction stays immediate. A small repeat
-- on the same actor, unit and entity waits out the rest of the cooldown; a
-- large repeat still applies at once.
M.repose_cooldown=1
M.repose_bypass_m=.1
M.repose_bypass_degrees=5
local function defer_repeats(state,u,actions,now)
    local recent,kept=state.reposed,nil
    for i,action in ipairs(actions) do
        local last=action.kind=='pose' and recent[action.actor.id]
        local hold=last and last.unit==u.unit and last.entity==u.id and now>=last.at
            and now-last.at<M.repose_cooldown and action.gap<=M.repose_bypass_m
            and (action.degrees or 0)<=M.repose_bypass_degrees
        if hold then
            state.reposes_deferred=(state.reposes_deferred or 0)+1
            if not kept then kept={};for j=1,i-1 do kept[j]=actions[j] end end
        elseif kept then kept[#kept+1]=action end
    end
    return kept or actions
end

-- Empties a table in place (or makes one), so a reset costs no new table.
local function emptied(t) if not t then return {} end;for key in pairs(t) do t[key]=nil end;return t end
-- A fresh start: no motion history, stop, scan position or cooldown survives
-- into the next poll. Leaving a mission does this, and so does the loader when
-- an update below the mod fails. The mod holds nothing in the game itself.
function M.reset(state)
    state.fling_history,state.fling_stopped=emptied(state.fling_history),emptied(state.fling_stopped)
    state.cursors,state.reposed=emptied(state.cursors),emptied(state.reposed)
    state.listings,state.corpse_checks=emptied(state.listings),emptied(state.corpse_checks)
end
-- consume is made once, not as a new closure every poll: begin_apply points it
-- at the poll's api, state and time before each snapshot.
local poll_budget,apply_consume,begin_apply={}
do
    local api,state,now
    -- n is nil when M.apply read no time: the first unit reads it.
    function begin_apply(a,s,n) api,state,now=a,s,n end
    -- Whether the unit's own and global guards still hold. A unit the snapshot
    -- just verified (see hand_over) holds until this unit's first native
    -- call, which clears verified; every later check compares afresh.
    local function holds(u) return u.verified or same(api,u.guards) end
    local function read_time()
        if now==nil then now=api.time and api.time() or 0 end
    end
    -- The corpse re-check backoff (M.corpse_settle_polls): a corpse that
    -- needed no command keeps a record by unit, with its entity address and
    -- identity; one that needs a command, or a new entity, starts over.
    local function note_corpse(u,actions,stopped)
        if not u.corpse then return end
        local clean=actions==0 and not stopped
        local checks=state.corpse_checks
        if not checks then checks={};state.corpse_checks=checks end
        if not clean or not u.address or M.corpse_recheck_polls<=0 then checks[u.unit]=nil;return end
        local scan,record=state.fling_scan,checks[u.unit]
        if not record or record.address~=u.address or record.entity~=u.id then
            record={address=u.address,entity=u.id,since=scan,wait=0,due=0};checks[u.unit]=record
        end
        record.seen=scan
        if scan-record.since<M.corpse_settle_polls then return end
        record.wait=math.min(math.max(record.wait*2,2),M.corpse_recheck_polls)
        record.due=scan+record.wait
    end
    local function consume(u)
        read_time()
        state.observed=state.observed+1
        state.accepted_units=(state.accepted_units or 0)+1
        phase(api,'planning')
        local actions=M.plan(u)
        if api.profiler then
            u.profile_lifecycle=u.corpse and (#actions>0 and 'corpse_repair' or settled(u) and 'corpse_aligned' or 'corpse_other')
                or (u.update_enabled==false and 'ragdoll_stopped' or settled(u) and 'ragdoll_settled' or 'ragdoll_dynamic')
        end
        local stopped=state.fling_stopped[u.unit]
        note_corpse(u,#actions,stopped)
        actions=defer_repeats(state,u,actions,now)
        if #actions==0 and not stopped and u.corpse then return end
        if stopped and stopped.requested and u.corpse and u.active
            and stopped.resource==u.resource and holds(u) then
            -- Conversion creates a new entity while retaining the unit handle.
            -- Observe the phase; a submitted request alone is not success.
            state.completion_corpse_observed=(state.completion_corpse_observed or 0)+1
            state.fling_stopped[u.unit]=nil;stopped=nil
        end
        if stopped and (stopped.entity~=u.id or stopped.resource~=u.resource
            or stopped.members~=u.main_signature or u.corpse or u.update_enabled) then
            state.fling_stopped[u.unit]=nil;stopped=nil
        end
        -- No actions means this outer identity pass is redundant. Motion samples
        -- still need identity AND pose validation below: they can arm a later
        -- stop even when this poll issues no command.
        local planned=#actions>0 or stopped~=nil
        if not planned then state.guard_passes_skipped=(state.guard_passes_skipped or 0)+1 end
        if not planned or holds(u) then
            for _,action in ipairs(actions) do
                if holds(u) and same(api,action.actor.guards) then
                    u.verified=nil
                    if action.kind=='disable' then
                        phase(api,'native');state.native.disable(action.actor.id)
                        state.claws_disabled=(state.claws_disabled or 0)+1
                    else
                        phase(api,'native');state.native.pose(action.actor.id,action.position,action.rotation)
                        state.realignments=(state.realignments or 0)+1
                        local entry=state.reposed[action.actor.id]
                        if entry then entry.unit,entry.entity,entry.at=u.unit,u.id,now
                        else state.reposed[action.actor.id]={unit=u.unit,entity=u.id,at=now} end
                        if u.corpse and u.main_static<u.main_enabled then
                            state.mixed_corpse_realignments=(state.mixed_corpse_realignments or 0)+1
                        end
                        state.max_gap=math.max(state.max_gap or 0,action.gap)
                        state.last_unit=u.unit;state.last_actor=action.actor.id
                    end
                else state.skipped=(state.skipped or 0)+1 end
            end
            local stop,finish_handoff,request_completion
            local validate_motion=planned or (not u.corpse and u.owner==false and u.active==true
                and u.update_enabled==true and settled(u))
            -- A snapshot unit's root guard is one of its main pose guards
            -- (root_in_pose_guards): comparing it again would repeat a view.
            if not validate_motion or (holds(u) and same(api,u.main_pose_guards or EMPTY)
                and (not u.root_body or u.root_in_pose_guards or same(api,u.root_body.guards or EMPTY))) then
                if stopped then
                    stopped.last_scan=state.fling_scan
                    finish_handoff=u.owner and u.active and settled(u)
                    request_completion=u.owner==false and u.active and settled(u) and not stopped.requested
                        and stopped.stopped_at and now-stopped.stopped_at>=M.completion_grace
                end
                phase(api,'motion')
                stop=M.fling_action(u,state,now)
            else state.fling_history[u.unit]=nil end
            if finish_handoff and holds(u) then
                -- The component's runtime is copied unchanged when ownership
                -- moves (native 0x7a4b30). Finish ONLY a stop we previously
                -- made, through the routine's normal owned-Corpse branch.
                -- It may transition the entity, so do not read old storage.
                phase(api,'native');state.native.stop_sync(u.manager,u.index)
                state.fling_handoffs=(state.fling_handoffs or 0)+1
                state.fling_stopped[u.unit]=nil
            elseif request_completion and holds(u) then
                -- A remote stop never requests Corpse conversion. Ask its
                -- owner through the existing engine path once, after a grace
                -- period. No ownership, timer, or replication storage edits.
                stopped.requested=true
                state.completion_requests=(state.completion_requests or 0)+1
                state.last_completion_unit=u.unit;state.last_completion_entity=u.id
                state.last_completion_uptime=now
                phase(api,'native');state.native.request_completion(u.id)
                -- Native completion may invalidate entity storage. Read none
                -- of this snapshot again after the request.
            elseif stop and holds(u) and same(api,u.main_pose_guards or EMPTY) then
                -- Run last: this routine changes update_enabled, invalidating
                -- this snapshot's guards. The remote-only gate avoids its
                -- locally-owned force-Corpse branch. No pose is rewound.
                phase(api,'native');state.native.stop_sync(u.manager,u.index)
                state.fling_stops=(state.fling_stops or 0)+1
                state.last_fling_unit=u.unit;state.last_fling_entity=u.id
                state.last_fling_type=profiles[u.resource].name;state.last_fling_reason=stop.cause
                state.last_fling_uptime=now
                state.last_fling_distance=stop.distance;state.last_fling_degrees=stop.degrees
                state.last_fling_actor=stop.actor
                state.last_fling_limb_distance=stop.limb_distance or 0
                state.last_fling_limb_degrees=stop.limb_degrees or 0
                if stop.limb_distance then state.fling_limb_stops=(state.fling_limb_stops or 0)+1 end
                if stop.cause=='landed_disabled' then state.landed_disabled_stops=(state.landed_disabled_stops or 0)+1 end
                state.max_fling_distance=math.max(state.max_fling_distance or 0,stop.distance)
                if api.read(u.update_address,1)=='\0' then
                    state.fling_stops_verified=(state.fling_stops_verified or 0)+1
                    state.fling_history[u.unit]=nil
                    state.fling_stopped[u.unit]={entity=u.id,resource=u.resource,members=u.main_signature,
                        last_scan=state.fling_scan,stopped_at=now}
                end
            elseif stop then
                -- A race at dispatch breaks the observation interval too.
                state.fling_history[u.unit]=nil
            end
        else
            state.fling_history[u.unit]=nil
        end
    end
    apply_consume=consume
end

-- Every 256 polls, forgets backoff records of corpses not inspected for 256
-- polls (a waiting corpse is inspected at least every corpse_recheck_polls):
-- the game disposed of them.
local function prune_corpse_checks(state)
    local checks=state.corpse_checks
    if not checks or state.fling_scan%256~=0 then return end
    for unit,record in pairs(checks) do
        if state.fling_scan-record.seen>256 then checks[unit]=nil end
    end
end
-- Expires repose cooldowns and motion histories older than now allows.
local function expire(state,now)
    for id,entry in pairs(state.reposed) do
        if now<entry.at or now-entry.at>=M.repose_cooldown then state.reposed[id]=nil end
    end
    for key,entry in pairs(state.fling_history) do
        if now<entry.last or now-entry.last>1 then
            state.max_revisit_seconds=math.max(state.max_revisit_seconds or 0,now-entry.last)
            state.history_expirations=(state.history_expirations or 0)+1
            state.fling_history[key]=nil
        end
    end
end

function M.apply(api,game,exe,state)
    phase(api,'maintenance')
    state.reposed=state.reposed or {}
    state.fling_history=state.fling_history or {}
    state.fling_stopped=state.fling_stopped or {}
    state.fling_scan=(state.fling_scan or 0)+1
    -- The time is a system call: read here only when a cooldown or history
    -- may expire, otherwise by the poll's first unit (consume). A poll that
    -- keeps neither and hands over no unit reads no clock.
    local now
    if next(state.reposed)~=nil or next(state.fling_history)~=nil then
        now=api.time and api.time() or 0
        expire(state,now)
    end
    prune_corpse_checks(state)
    for key,entry in pairs(state.fling_stopped) do
        -- Count successful scans rather than wall time: a paused application
        -- must not forget a stop immediately before an ownership handoff.
        if state.fling_scan-entry.last_scan>256 then state.fling_stopped[key]=nil end
    end
    state.observed=0
    begin_apply(api,state,now);local consume,budget=apply_consume,poll_budget
    -- The deadline is set by the poll's first inspection (inspect_listed).
    budget.scanned,budget.inspected,budget.yielded,budget.deadline=0,0,nil,nil
    budget.clocked=0
    local units,reason=M.snapshot(api,game,exe,state,consume,budget)
    -- Snapshot substitutes used by policy tests may return complete units.
    if state.observed==0 then for _,u in ipairs(units) do consume(u) end end
    phase(api,'maintenance')
    state.scan_entities=(state.scan_entities or 0)+budget.scanned
    state.deep_inspections=(state.deep_inspections or 0)+budget.inspected
    if budget.yielded then state.budget_yields=(state.budget_yields or 0)+1 end
    -- Off a mission the first poll forgets everything; later ones find it
    -- forgotten already and skip the reset.
    if reason=='ready' then state.forgotten=false
    elseif not state.forgotten then M.reset(state);state.forgotten=true end
    state.completion_pending=0
    for _,entry in pairs(state.fling_stopped) do
        if entry.requested then state.completion_pending=state.completion_pending+1 end
    end
    return true,reason,reason=='ready'
end
return M
