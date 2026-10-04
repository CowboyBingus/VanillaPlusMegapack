-- Fixed-size, data-only cache records. Never execute data loaded from disk.
local ffi=require('ffi')
local M={max_bytes=16*1024*1024,key_size=116,entry_size=140}
local ints=ffi.new('uint32_t[4]');local floats=ffi.new('float[6]')
local function number(s,o)ffi.copy(ints,s:sub(o+1,o+4),4);return tonumber(ints[0])end
local function finite(n)return n==n and math.abs(n)<1000000 end
function M.header(width,height,count)
    assert(width%1==0 and height%1==0 and count%1==0)
    assert(width>=64 and width<=4096 and height>=64 and height<=16384 and count>=1 and count<=90)
    assert(width*height*4<=M.max_bytes)
    ints[0],ints[1],ints[2],ints[3]=width,height,count,width*height*4
    return ffi.string(ints,16)
end
function M.parse_header(s)
    assert(type(s)=='string' and #s==16,'Truncated pixel header')
    local w,h,n,size=number(s,0),number(s,4),number(s,8),number(s,12)
    assert(M.header(w,h,n)==s and size==w*h*4,'Invalid pixel header')
    return w,h,n,size
end
function M.encode(entries)
    local keys={};for key in pairs(entries)do keys[#keys+1]=key end;table.sort(keys)
    assert(#keys>=1 and #keys<=90)
    local out={}
    for _,key in ipairs(keys)do
        local e=entries[key];assert(#key==M.key_size and #e.uv==16)
        floats[0],floats[1]=e.width,e.height
        out[#out+1]=key..e.uv..ffi.string(floats,8)
    end
    return table.concat(out),#keys
end
function M.decode(s,n,layout,width,height)
    assert(#s==n*M.entry_size and #layout==52,'Invalid image index')
    local entries={}
    for i=0,n-1 do
        local at=i*M.entry_size;local key=s:sub(at+1,at+M.key_size)
        assert(key:sub(1,52)==layout and not entries[key],'Stale or duplicate image key')
        ffi.copy(floats,s:sub(at+117,at+140),24)
        for j=0,5 do assert(finite(tonumber(floats[j])),'Invalid image dimensions')end
        local x,y,r,b,w,h=tonumber(floats[0]),tonumber(floats[1]),tonumber(floats[2]),tonumber(floats[3]),tonumber(floats[4]),tonumber(floats[5])
        assert(x>=0 and y>=0 and r>x and b>y and r<=1.001 and b<=1.001 and w>0 and h>0)
        assert(math.abs(w-(r-x)*width)<.1 and math.abs(h-(b-y)*height)<.1,'Invalid image crop')
        entries[key]={uv=s:sub(at+117,at+132),width=w,height=h}
    end
    return entries
end
return M
