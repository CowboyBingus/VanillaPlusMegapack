-- At most one transfer and one 256 KiB disk/hash step per update. Saved pixels
-- are published only after checksum validation AND a GPU readback round trip.
local ffi=require('ffi')
local M={}
function M.new(api,native,adapter,codec,path,namespace,fs)
    fs=fs or {open=io.open,remove=os.remove,rename=os.rename}
    local prefix='APCPIX1\n'..namespace
    assert(#namespace==32)
    local self={status='waiting_for_pixel_world',loaded=0,saved=0,rejected=0,errors=0,
        read_bytes=0,written_bytes=0,verified_bytes=0,enabled=true,queue={},used={},slot=1}
    local active
    local function filename(slot)return path..'.pixels'..slot end
    local function close(a)
        if a.file then pcall(a.file.close,a.file);a.file=nil end
        if a.hash then pcall(a.hash.close,a.hash);a.hash=nil end
    end
    local function dispose(a)
        close(a)
        if a.buffer then native:discard(a.buffer);a.buffer=nil end
        if a.result then native:free(a.result);a.result=nil end
        if a.texture and a.mode=='load' then adapter:destroy(a.texture);a.texture=nil end
        if a.temporary then fs.remove(a.temporary)end
    end
    local function stop(a)
        if a.job and a.job.id then
            a.cancelled=true;close(a)
            if a.buffer then native:discard(a.buffer);a.buffer=nil end
            return -- Never free a texture while a GPU readback still references it.
        end
        dispose(a);active=nil
    end
    function self:cancel()
        self.queue={}
        if active then stop(active)end
    end
    function self:offer(texture,candidate)
        if self.enabled and #self.queue<8 then
            self.queue[#self.queue+1]={texture=texture,candidate=candidate}
        end
    end
    local function begin_load(s,slot)
        local f=fs.open(filename(slot),'rb');if not f then return end
        local a={mode='load',phase='read',file=f,slot=slot,context=s.context,offset=0};active=a
        local header=assert(f:read(108),'Missing pixel header')
        assert(#header==108 and header:sub(1,40)==prefix,'Stale pixel cache')
        local layout=header:sub(41,92);assert(layout==s.layout,'Pixel layout differs')
        local w,h,n,size=codec.parse_header(header:sub(93,108))
        assert(w==s.width and h==s.height,'Pixel dimensions differ')
        local index=assert(f:read(n*codec.entry_size),'Missing image index')
        a.entries=codec.decode(index,n,layout,w,h)
        local expected=108+#index+size+32
        local position=f:seek();assert(f:seek('end')==expected,'Truncated or oversized pixel cache');assert(f:seek('set',position))
        a.width,a.height,a.size=w,h,size;a.metadata=header..index
        a.hash=api.hasher();a.hash:update(a.metadata);a.buffer=native:allocate(size)
    end
    local function begin_save(s,offer,slot)
        local t,p=offer.texture,offer.candidate
        if t.retired or t.destroyed then return end
        local index,count=codec.encode(p.entries)
        -- Decode our own metadata before requesting any GPU work.
        codec.decode(index,count,p.layout,t.width,t.height)
        local a={mode='save',phase='wait',texture=t,slot=slot,context=s.context,offset=0,size=t.bytes,
            metadata=prefix..p.layout..codec.header(t.width,t.height,count)..index}
        active=a;a.job=native:request(t)
    end
    local function step(s,cache,pressure)
        if active then
            local a=active
            if a.context~=s.context or pressure or not self.enabled then a.cancelled=true end
            if a.phase=='wait' then
                local result=native:poll(a.job)
                if not result then self.status=a.cancelled and 'draining_pixel_readback' or 'waiting_for_pixel_readback';return end
                a.result=result;a.job=nil
                if a.cancelled then stop(a);return end
                a.hash=api.hasher();a.hash:update(a.metadata);a.offset=0
                if a.mode=='save' then
                    a.temporary=filename(a.slot)..'.tmp';a.file=assert(fs.open(a.temporary,'wb'),'Cannot write pixel cache')
                    assert(a.file:write(a.metadata));a.phase='write'
                else a.phase='verify'end
                return
            end
            if a.cancelled then stop(a);return end
            local n=math.min(256*1024,a.size-a.offset)
            if a.phase=='read' then
                local chunk=assert(a.file:read(n),'Truncated pixel payload');assert(#chunk==n,'Short pixel payload')
                ffi.copy(a.buffer.pixels+a.offset,chunk,n);a.hash:update(chunk)
                a.offset=a.offset+n;self.read_bytes=self.read_bytes+n;self.status='reading_saved_pixels'
                if a.offset==a.size then
                    a.digest=a.hash:finish();a.hash=nil
                    assert(a.file:read(32)==a.digest and a.file:read(1)==nil,'Pixel checksum mismatch')
                    close(a);a.phase='upload'
                end
            elseif a.phase=='upload' then
                a.texture=native:upload(a.buffer,a.width,a.height);a.buffer=nil
                a.job=native:request(a.texture);a.phase='wait';self.status='verifying_restored_texture'
            elseif a.phase=='write' or a.phase=='verify' then
                local chunk=ffi.string(a.result.pixels+a.offset,n);a.hash:update(chunk)
                if a.phase=='write' then assert(a.file:write(chunk));self.written_bytes=self.written_bytes+n
                else self.verified_bytes=self.verified_bytes+n end
                a.offset=a.offset+n;self.status=a.phase=='write' and 'saving_pixels' or 'verifying_restored_texture'
                if a.offset==a.size then
                    local digest=a.hash:finish();a.hash=nil
                    if a.mode=='save' then
                        assert(a.file:write(digest));local file=a.file;a.file=nil;assert(file:close(),'Pixel file flush failed')
                        local dest=filename(a.slot);fs.remove(dest..'.bak');fs.rename(dest,dest..'.bak')
                        local ok=fs.rename(a.temporary,dest)
                        if not ok then fs.rename(dest..'.bak',dest);error('Pixel cache replacement failed')end
                        a.temporary=nil;fs.remove(dest..'.bak');self.saved=self.saved+1;self.used[a.slot]=true
                    else
                        assert(digest==a.digest,'GPU pixel round trip differs')
                        if cache:import(a.texture,a.entries)then
                            a.texture=nil;self.loaded=self.loaded+1;self.used[a.slot]=true
                        end
                    end
                    dispose(a);active=nil;self.status='pixel_cache_ready'
                end
            end
            return
        end
        if pressure or not self.enabled or not s.context or not s.layout then return end
        if self.slot<=8 then
            local slot=self.slot;self.slot=slot+1;begin_load(s,slot);return
        end
        while #self.queue>0 do
            local offer=table.remove(self.queue,1)
            if not offer.texture.retired and not offer.texture.destroyed then
                local slot;for i=1,8 do if not self.used[i]then slot=i;break end end
                if not slot then self.status='pixel_disk_budget_full';self.queue={};return end
                begin_save(s,offer,slot);return
            end
        end
        self.status='pixel_cache_ready'
    end
    function self:tick(s,cache,pressure)
        local ok,why=pcall(step,s,cache,pressure)
        if not ok then
            self.last_error=tostring(why);self.errors=self.errors+1
            if active and active.mode=='load' then self.rejected=self.rejected+1
            else self.enabled=false end
            if active then stop(active)end
            self.status='pixel_cache_fallback'
        end
        self.pending=active and 1 or 0
        self.submitted_bytes=native.submitted_bytes;self.submitted_count=native.submitted_count
    end
    return self
end
return M
