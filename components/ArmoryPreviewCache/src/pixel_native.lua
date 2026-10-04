-- Build-locked asynchronous readback and native pixel-texture construction.
-- The upload producer follows 0x31DD0B (the engine's own RGBA producer).
-- Uploaded payloads use that producer's allocator; never free them from Lua.
-- Conservative lifetime cap counts all submitted payloads until process exit.
local ffi=require('ffi')
local M={}
function M.new(api,game,exe,signatures,test_calls)
    local function read(p,n)local value=assert(api.read(p,n),'Pixel memory unavailable');return value end
    local function ptr(p)local value=assert(api.pointer(read(p,8)),'Pixel pointer unavailable');return value end
    for _,s in ipairs(signatures)do
        local bytes=s.hex:gsub('..',function(v)return string.char(tonumber(v,16))end)
        assert(read(exe+s.rva,#bytes)==bytes,'Pixel instruction mismatch')
    end
    local root=ptr(game+0x3326308);assert(root==exe+0x27c8d80,'Pixel API root mismatch')
    local app=ptr(root+16)
    for offset,rva in pairs({[432]=0x31b500,[456]=0x31ba70,[472]=0x31bab0,[480]=0x31bb20})do
        assert(ptr(app+offset)==exe+rva,'Pixel application API mismatch')
    end
    local calls=test_calls or {}
    local request=calls.request or ffi.cast('uint32_t (*)(void *,uint16_t)',exe+0x31b500)
    local done=calls.done or ffi.cast('uint8_t (*)(uint32_t)',exe+0x31ba70)
    local take=calls.take or ffi.cast('void *(*)(void *,uint32_t)',exe+0x31bab0)
    local free=calls.free or ffi.cast('void (*)(void *)',exe+0x31bb20)
    local create=calls.create or ffi.cast('void *(*)(int,int,int,void *)',exe+0x31e740)
    local allocate=calls.allocate or ffi.cast('void *(*)(void *,void *,uint64_t,uint64_t)',exe+0x5c2e10)
    local release=calls.release or ffi.cast('void (*)(void *,void *,uint64_t)',exe+0x5c2ed0)
    local self={submitted_bytes=0,submitted_count=0}
    function self:request(t)
        assert(read(t.handle,8)==t.id,'Readback texture identity changed')
        local id=tonumber(request(t.handle,0));assert(id>0 and id<65536,'Invalid pixel readback job')
        t.pins=(t.pins or 0)+1
        return {id=id,texture=t}
    end
    function self:poll(job)
        if done(job.id)==0 then return end
        local data=ffi.new('uint64_t[3]');take(data,job.id);job.id=nil
        local d=ffi.cast('uint32_t *',data)
        local w,h,format=tonumber(d[0]),tonumber(d[1]),tonumber(d[2])
        local pixels=ffi.cast('uint8_t *',data[2])
        if w~=job.texture.width or h~=job.texture.height or format~=0 or pixels==nil then
            free(data);job.texture.pins=job.texture.pins-1;error('Unexpected pixel readback result')
        end
        return {data=data,pixels=pixels,size=w*h*4,texture=job.texture}
    end
    function self:free(result)
        if not result.freed then free(result.data);result.freed=true;result.texture.pins=result.texture.pins-1 end
    end
    function self:allocate(size)
        assert(size>0 and size<=16*1024*1024 and self.submitted_bytes+size<=128*1024*1024
            and self.submitted_count<8,'Pixel upload lifetime budget full')
        local a=ptr(exe+0x1a10200);local v=ptr(a)
        assert(ptr(v+48)==exe+0x5c2e10 and ptr(v+64)==exe+0x5c2ed0,'Pixel allocator mismatch')
        local out=ffi.new('void *[3]');allocate(a,out,size,8);assert(out[0]~=nil,'Pixel allocation failed')
        return {pixels=ffi.cast('uint8_t *',out[0]),allocator=a,size=size}
    end
    function self:discard(buffer)
        if buffer.pixels and not buffer.submitted then release(buffer.allocator,buffer.pixels,0);buffer.pixels=nil end
    end
    function self:upload(buffer,width,height)
        assert(not buffer.submitted and buffer.size==width*height*4)
        local handle=create(width,height,0,buffer.pixels)
        -- Ownership crosses this call even if a later descriptor check fails.
        buffer.submitted=true;self.submitted_bytes=self.submitted_bytes+buffer.size;self.submitted_count=self.submitted_count+1
        assert(handle~=nil,'Pixel texture creation failed');handle=ffi.cast('uint8_t *',handle)
        return {handle=handle,id=read(handle,8),bytes=buffer.size,width=width,height=height,disk=true}
    end
    return self
end
return M
