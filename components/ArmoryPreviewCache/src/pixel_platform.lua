-- Bounded archive metadata invalidation and streaming SHA256, Windows only.
return function(api)
    local ffi=require('ffi');local kernel=ffi.load('kernel32');local bcrypt=ffi.load('bcrypt')
    -- Private names with __asm__ labels; the hashing and module-name functions
    -- are the private declarations made by read_api.lua.
    ffi.cdef[[
      void *hd2apc_FindFirstFileW(const uint16_t *,void *) __asm__("FindFirstFileW");
      int hd2apc_FindNextFileW(void *,void *) __asm__("FindNextFileW");
      int hd2apc_FindClose(void *) __asm__("FindClose");
      uint32_t hd2apc_GetLastError(void) __asm__("GetLastError");
    ]]
    local algorithm=ffi.new('void *[1]')
    local name=ffi.new('uint16_t[7]',{83,72,65,50,53,54,0})
    assert(bcrypt.hd2apc_BCryptOpenAlgorithmProvider(algorithm,name,nil,0)==0,'Pixel SHA256 unavailable')
    local provider=ffi.gc(algorithm,function(p)if p[0]~=nil then bcrypt.hd2apc_BCryptCloseAlgorithmProvider(p[0],0)end end)
    function api.hasher()
        local handle=ffi.new('void *[1]');assert(bcrypt.hd2apc_BCryptCreateHash(provider[0],handle,nil,0,nil,0,0)==0)
        local self={}
        function self:close()if handle[0]~=nil then bcrypt.hd2apc_BCryptDestroyHash(handle[0]);handle[0]=nil end end
        ffi.gc(handle,function()self:close()end)
        function self:update(data,size)
            assert(handle[0]~=nil and bcrypt.hd2apc_BCryptHashData(handle[0],data,size or #data,0)==0,'Pixel hash failed')
        end
        function self:finish()
            local digest=ffi.new('uint8_t[32]')
            assert(handle[0]~=nil and bcrypt.hd2apc_BCryptFinishHash(handle[0],digest,32,0)==0,'Pixel hash finish failed')
            self:close();return ffi.string(digest,32)
        end
        return self
    end
    function api.archive_fingerprint()
        local path=ffi.new('uint16_t[32768]');local length=kernel.hd2apc_GetModuleFileNameW(nil,path,32768)
        assert(length>0 and length<32750,'Cannot resolve game data directory')
        local slash={};for i=0,length-1 do if path[i]==92 or path[i]==47 then slash[#slash+1]=i end end
        assert(#slash>=2);local stop=slash[#slash-1]+1
        local suffix='data\\*';for i=1,#suffix do path[stop+i-1]=suffix:byte(i)end;path[stop+#suffix]=0
        local found=ffi.new('uint8_t[592]') -- WIN32_FIND_DATAW, names at +44.
        local handle=kernel.hd2apc_FindFirstFileW(path,found)
        assert(handle~=ffi.cast('void *',-1),'Cannot enumerate deployed archives')
        local ok,result=pcall(function()
            local rows={};local count=0
            repeat
                count=count+1;assert(count<=8192,'Archive manifest enumeration cap')
                local p=ffi.cast('uint16_t *',found+44);local chars={};local ascii=true
                for i=0,259 do if p[i]==0 then break end;if p[i]>127 then ascii=false;break end;chars[#chars+1]=string.char(p[i])end
                local filename=table.concat(chars):lower()
                local stem,tail=filename:match('^([0-9a-f]+)(.*)$')
                if ascii and stem and #stem==16 and (tail=='' or tail=='.stream' or tail=='.gpu_resources'
                    or tail:match('^%.patch_%d+') or tail:match('^%.patch_%d+%.'))then
                    -- Last-write FILETIME and 64-bit length, no content scan of multi-GB archives.
                    rows[#rows+1]=filename..'\0'..ffi.string(found+20,16)
                end
            until kernel.hd2apc_FindNextFileW(handle,found)==0
            assert(kernel.hd2apc_GetLastError()==18 and #rows>0,'Incomplete archive manifest')
            table.sort(rows);local h=api.hasher();for _,row in ipairs(rows)do h:update(row)end
            return h:finish()
        end)
        kernel.hd2apc_FindClose(handle);if not ok then error(result)end;return result
    end
    return api
end
