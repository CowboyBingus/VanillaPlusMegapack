-- Synthetic relocation of the build-24826606 Impaler recording, for regression
-- testing only. Original bytes are preserved in stuck_impaler.lua. Native RVAs
-- were checked independently on build 25327279; this is not a new live capture.
return function(f)
    local ffi=require('ffi')
    local game={ [0x276c3d0]=0x33266a0,[0x276c648]=0x3326920,[0x276c670]=0x3326948 }
    local exe={ [0x1a140f0]=0x1a100f0,[0x27c9928]=0x27c5b40 }
    local ranges={{0x27be808,704,-0x3f60},{0x236db80,2560,-0x4080}}
    for _,b in ipairs(f.blocks)do
        local mapped=game[b[1]-f.game]
        if mapped then b[1]=f.game+mapped else
            local rva=b[1]-f.exe
            mapped=exe[rva]
            if mapped then b[1]=f.exe+mapped else
                for _,r in ipairs(ranges)do
                    if rva>=r[1] and rva<r[1]+r[2]then b[1]=b[1]+r[3];break end
                end
            end
        end
        for offset=0,#b[2]-8,8 do
            local value=ffi.new('uint64_t[1]');ffi.copy(value,b[2]:sub(offset+1,offset+8),8)
            if tonumber(value[0])==f.exe+0xd11660 then
                b[2]=b[2]:sub(1,offset)..ffi.string(ffi.new('uint64_t[1]',f.exe+0xd0cfa0),8)..b[2]:sub(offset+9)
            end
        end
    end
    return f
end
