-- The mod's Windows adapter. Memory access and the clock come from Bingus
-- Shared Runtime (bingus_memory.lua with bingus_write.lua, passed in): reads into reused buffers; writes only into committed
-- private read-write memory, checked right before the write with one
-- VirtualQuery per region; module hashes read once per session for every mod;
-- all Windows functions under private, versioned names. This file adds the clock
-- and the build-locked native bindings.
return function(runtime, memory)
    local ffi = require('ffi')
    assert(ffi.abi('64bit'), 'Windows x64 is required')
    assert(type(memory) == 'table' and type(memory.time) == 'function', 'Bingus Shared Runtime memory api required')
    -- api.time is the runtime's: seconds from the performance counter, without
    -- boxing a 64-bit count (it was GetTickCount64 / 1000 here). Only time
    -- differences are used.
    local api = memory
    local native_cache
    function api.native(game,exe)
        if native_cache then return native_cache end
        local function pointer_at(address)
            return assert(api.pointer(api.read(address,8)), 'Native binding unavailable')
        end
        local bindings={
            {0x3326338,0x27cd910,{{0x18,0x7972f0},{0x38,0x7993d0},{0xa8,0x799540}}},
            {0x3326388,0x27cdc30,{{0,0x7ce220},{0x28,0x7cf050},{0x68,0x7cfe10}}},
            {0x3326328,0x27cdb40,{{0,0x79f860},{0x68,0x77dec0},{0x80,0x7f9070}}},
        }
        for _,binding in ipairs(bindings) do
            local table_address=pointer_at(game+binding[1])
            assert(api.distance(table_address,exe)==binding[2], 'Unsupported native table')
            for _,entry in ipairs(binding[3]) do
                assert(api.distance(pointer_at(table_address+entry[1]),exe)==entry[2], 'Unsupported native function')
            end
        end
        assert(api.read(game+0xa9d560,12)=='\072\139\196\072\137\088\008\072\137\104\032\086',
            'Native exit validator changed')
        assert(api.read(game+0xa9a0c0,16)=='\064\085\083\086\087\065\084\065\086\065\087\072\141\108\036\208',
            'Native vault driver changed')
        if native_cache then return native_cache end
        local valid=ffi.cast('uint64_t (*)(uint32_t)',exe+0x7972f0)
        local flags=ffi.cast('uint32_t (*)(uint32_t)',exe+0x7993d0)
        local motion=ffi.cast('void (*)(uint32_t,float *,float *)',exe+0x799540)
        local mover=ffi.cast('uint32_t (*)(uint32_t,uint32_t)',exe+0x7ce220)
        local dimensions=ffi.cast('void *(*)(uint32_t)',exe+0x7cfe10)
        local position=ffi.cast('void (*)(uint32_t,float *)',exe+0x7cf050)
        local basis=ffi.cast('void *(*)(void *,const float *,const float *)',game+0x173f150)
        local rotation=ffi.cast('void (*)(float *,const void *)',game+0x173a750)
        -- RCX is unused in this build; RDX is the validated avatar entity.
        local classify=ffi.cast('int32_t (*)(void *,const void *,const float *,const float *)',game+0xa9d560)
        local world_id=ffi.cast('uint32_t (*)(const void *)',exe+0x79f860)
        local query=ffi.cast('uint32_t (*)(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,const void *,void *,uint32_t)',exe+0x7f9070)
        local drive=ffi.cast('void (*)(void *,float)',game+0xa9a0c0)
        local detect=ffi.cast('uint32_t (*)(void *,float)',game+0xa9c3e0)
        assert(api.read(game+0xa9dd90,16)=='\072\139\196\072\137\088\008\085\086\087\065\084\065\085\065\086',
            'Native approach geometry routine changed')
        -- RCX is unused. The remaining arguments and all outputs are private.
        local approach=ffi.cast('uint8_t (*)(void *,const void *,float *,float *,float *,float *)',game+0xa9dd90)
        local override=ffi.cast('void (*)(void *,const void *,const void *)',game+0x83c420)
        local function aligned(size)
            local storage=ffi.new('uint8_t[?]',size+15)
            local address=tonumber(ffi.cast('uintptr_t',storage))
            return storage,storage+(16-address%16)%16
        end
        local native={}
        function native.ensure_override(manager,entity)
            assert(api.read(game+0x83c420,16)=='\072\137\092\036\008\072\137\108\036\016\072\137\116\036\024\087',
                'Native avatar override routine changed')
            -- 510370 reads start/count at +4/+8. An empty modifier leaves all
            -- fields unchanged; 832d40 creates the entity-owned record if absent.
            local empty=ffi.new('uint32_t[3]')
            override(manager,entity,empty)
        end
        local function f32(n) return tonumber(ffi.new('float[1]',n)[0]) end
        function native.actor(id)
            if id==0xffffffff or valid(id)==0 then return {valid=false} end
            local first,second=ffi.new('float[3]'),ffi.new('float[3]')
            local bits=tonumber(flags(id))
            motion(id,first,second)
            if valid(id)==0 then return nil end
            local x,y,z=tonumber(first[0]),tonumber(first[1]),tonumber(first[2])
            return {valid=true,flags=bits,motion_squared=f32(f32(f32(y*y)+f32(x*x))+f32(z*z))}
        end
        -- The mover's dimensions only need to be readable: read into one
        -- reused buffer, without a string per check.
        local probe=ffi.new('uint8_t[20]')
        function native.mover_position(unit,name)
            local id=mover(unit,name)
            local data=dimensions(id)
            assert(data~=nil and api.read_into(data,20,probe),'Local mover unavailable')
            local out=ffi.new('float[3]')
            position(id,out)
            return {tonumber(out[0]),tonumber(out[1]),tonumber(out[2])}
        end
        function native.exit(entity,target,direction)
            local matrix_owner,matrix=aligned(64)
            local rotation_owner,quat=aligned(16)
            local forward=ffi.new('float[3]',direction)
            local up=ffi.new('float[3]',{0,0,1})
            local point=ffi.new('float[3]',target)
            basis(matrix,forward,up)
            rotation(ffi.cast('float *',quat),matrix)
            local result=tonumber(classify(nil,entity,point,ffi.cast('float *',quat)))
            -- Keep the backing allocations rooted until all native reads finish.
            assert(matrix_owner~=nil and rotation_owner~=nil)
            return result
        end
        function native.context_matches(controller_bytes)
            assert(#controller_bytes==0x2b0,'Invalid local controller copy')
            local owner,copy=aligned(0x2b0)
            ffi.copy(copy,controller_bytes,0x2b0)
            ffi.cast('uint32_t *',copy+4)[0]=0
            -- Stage zero only performs the original approach search and writes
            -- its new geometry into this private copy; it cannot start a vault.
            local result=tonumber(detect(copy,0))
            if ffi.cast('uint32_t *',copy+4)[0]~=1 then return false,'native_approach_blocked',nil,result end
            for offset=0x1e8,0x210,4 do
                local previous=ffi.new('float[1]')
                ffi.copy(previous,controller_bytes:sub(offset+1,offset+4),4)
                local current=tonumber(ffi.cast('float *',copy+offset)[0])
                local delta=math.abs(current-tonumber(previous[0]))
                if delta~=delta or delta>0.02 then
                    local fresh=ffi.string(copy,0x2b0)
                    assert(owner~=nil)
                    return false,'native_approach_geometry_changed',fresh
                end
            end
            local fresh=ffi.string(copy,0x2b0)
            assert(owner~=nil)
            return true,nil,fresh
        end
        function native.raised_approach(controller_bytes,unit,name,direction,reach)
            -- Reuse the native five-slice ledge search at the existing 2.5
            -- allowance, without temporarily changing real avatar settings.
            if #controller_bytes~=0x2b0 or type(reach)~='number' or reach~=reach
                or reach<=0 or reach>1.5 then return nil,'unsupported_raised_reach' end
            local norm=0
            for i=1,3 do
                local v=direction[i]
                if type(v)~='number' or v~=v or math.abs(v)>1.001 then return nil,'unsupported_raised_direction' end
                norm=norm+v*v
            end
            if math.abs(norm-1)>0.001 or math.abs(direction[3])>0.001 then return nil,'unsupported_raised_direction' end
            local id=mover(unit,name)
            local data=dimensions(id)
            local shape=data~=nil and api.read(data,20)
            if not shape then return nil,'raised_mover_unavailable' end
            local dims=ffi.new('float[5]');ffi.copy(dims,shape,20)
            local radius,minimum=tonumber(dims[3]),tonumber(dims[4])
            if radius~=radius or minimum~=minimum or radius<=0 or radius>0.5
                or minimum<0 or minimum>=2.5 then return nil,'unsupported_raised_mover' end
            local root=ffi.new('float[3]');position(id,root)
            for i=0,2 do
                if root[i]~=root[i] or math.abs(root[i])>=100000 then return nil,'raised_mover_unavailable' end
            end
            local args=ffi.new('uint8_t[52]')
            ffi.cast('uint32_t *',args)[0]=unit
            ffi.copy(args+4,root,12)
            ffi.copy(args+16,shape:sub(13,16),4)
            ffi.copy(args+20,shape:sub(9,12),4)
            ffi.copy(args+24,ffi.new('float[3]',direction),12)
            ffi.copy(args+36,ffi.new('float[3]',{minimum,2.5,reach}),12)
            local out=ffi.new('float[8]')
            if approach(nil,args,out,out+3,out+6,out+7)==0 then return nil,'raised_approach_no_ledge' end
            local owner,copy=aligned(0x2b0)
            ffi.copy(copy,controller_bytes,0x2b0)
            ffi.cast('uint32_t *',copy+4)[0]=1
            ffi.copy(copy+488,out,32)
            ffi.copy(copy+520,args+24,12)
            local fresh=ffi.string(copy,0x2b0)
            assert(owner~=nil)
            return fresh
        end
        function native.query_basis(direction)
            local owner,matrix=aligned(64)
            local forward=ffi.new('float[3]',direction)
            local up=ffi.new('float[3]',{0,0,1})
            basis(matrix,forward,up)
            local bytes=ffi.string(matrix,64)
            assert(owner~=nil)
            return bytes
        end
        function native.refresh_query(record,world)
            assert(#record==128,'Invalid query descriptor')
            -- Match the existing worker's 56-byte descriptor, using private
            -- copies and output storage. No scheduler records are modified.
            local record_owner,copy=aligned(128)
            local output_owner,out=aligned(48)
            ffi.copy(copy,record,128)
            local descriptor=ffi.new('uint64_t[7]')
            descriptor[2]=ffi.cast('uintptr_t',copy+16)
            descriptor[3]=ffi.cast('uintptr_t',copy+80)
            descriptor[4]=ffi.cast('uintptr_t',copy+92)
            descriptor[5]=ffi.cast('uint64_t *',copy+8)[0]
            local tail=ffi.cast('uint32_t *',descriptor)
            tail[12]=ffi.cast('uint32_t *',copy+112)[0]
            tail[13]=ffi.cast('uint32_t *',copy+108)[0]
            local count=tonumber(query(world_id(world),2,1,5,0x05a5271a,descriptor,out,1))
            local bytes=ffi.string(out,44)
            assert(record_owner~=nil and output_owner~=nil)
            return bytes,math.min(count,1)
        end
        function native.retry(controller)
            -- This is the game's original eligibility/check/start routine.
            -- Zero dt avoids advancing movement timers a second time.
            drive(controller,0)
        end
        native_cache=native
        return native
    end
    return api
end
