-- The package lease table is decoded in place (src/native.lua references):
-- one reused 16 KB buffer, identifiers turned into text once per session.
-- The v23 decoder (tests/reference/native_v23.lua) and the current one run on
-- the same synthetic lease table in the captured UI's memory, with stand-ins
-- for the two native lease functions: rows, counts, ownership checks, every
-- acquire/release outcome and the balance assertions must be equal. The
-- current decoder must allocate under 1 KB per decode (v23: over 32 KB).
local root=assert(arg[1]);local ffi=require('ffi')
local function num(x)return type(x)=='number' and x or tonumber(ffi.cast('uintptr_t',x))end
local function ptrs(v)return ffi.string(ffi.new('uint64_t[1]',v),8)end

local api,game,exe,_,memory=dofile(root..'/tests/captured_ui.lua')(root..'/tests/fixtures/ui_armory_25327279.lua')
-- The lease table: a 32-byte header, 1024 rows of 16 bytes, the allocator
-- pointer at +16416.
local block=ffi.new('uint8_t[16432]')
local base=num(block)
local header=ffi.cast('uint32_t *',block)
local rows=ffi.cast('uint32_t *',block+32)
memory.map(base,block,16432)
memory.poke(num(game)+0x347ceb0,ptrs(base))
local function reset()
    ffi.fill(block,16432)
    ffi.cast('uint64_t *',block)[0]=base+32
    header[2]=1024;header[6]=2
    ffi.cast('uint64_t *',block+16416)[0]=0x7f0000001000
end
-- Identifiers in rows: low and high words, with the high bit set in some.
local function put(index,low,high,count)
    rows[index*4],rows[index*4+1],rows[index*4+2],rows[index*4+3]=low,high,count,0
end
local function find(low,high)
    for i=0,1023 do if rows[i*4]==low and rows[i*4+1]==high then return i end end
end
-- The native lease functions: argument is the identifier (uint64_t[1]).
local balanced=true
local calls={}
function calls.acquire(_,argument)
    if not balanced then return end
    local words=ffi.cast('uint32_t *',argument)
    local i=find(words[0],words[1])
    if i then rows[i*4+2]=rows[i*4+2]+1;return end
    for j=0,1023 do if rows[j*4]==0 and rows[j*4+1]==0 then put(j,words[0],words[1],1);return end end
end
function calls.release(_,argument)
    if not balanced then return end
    local words=ffi.cast('uint32_t *',argument)
    local i=find(words[0],words[1])
    rows[i*4+2]=rows[i*4+2]-1
    if rows[i*4+2]==0 then put(i,0,0,0)end
end
-- v23 called the native functions directly: the same stand-ins replace its
-- casts (a copy whose two casts read calls.acquire/calls.release).
local v23_source=assert(io.open(root..'/tests/reference/native_v23.lua','rb')):read('*a')
v23_source=v23_source:gsub("local acquire=ffi%.cast%b()","local acquire=TEST_CALLS.acquire")
    :gsub("local release=ffi%.cast%b()","local release=TEST_CALLS.release")
local v23_chunk=assert(loadstring(v23_source,'native_v23'))
setfenv(v23_chunk,setmetatable({TEST_CALLS=calls},{__index=_G}))
local adapters={v23=v23_chunk().new(api,game,exe,{}),current=dofile(root..'/src/native.lua').new(api,game,exe,{},nil,calls)}

local function fill(seed,n)
    reset()
    local x=seed
    for k=1,n do
        x=(x*1103515245+12345)%2147483648
        local index=(x*7+k*13)%1024
        while rows[index*4]~=0 or rows[index*4+1]~=0 do index=(index+1)%1024 end
        put(index,(x*2654435761)%4294967296,(k%3==0) and 0x80000000+k or k,1+x%9)
    end
end
local function snapshot(adapter)
    local r,n,owner=adapter:references()
    local ids={}
    for id,count in pairs(r)do ids[#ids+1]=id..'='..count end
    table.sort(ids)
    return table.concat(ids,',')..' n='..n..' owner='..tostring(owner and #owner)
end
local function both(label,fn)
    local results={}
    for _,name in ipairs({'v23','current'})do
        local saved=ffi.new('uint8_t[16432]');ffi.copy(saved,block,16432)
        local ok,a,b=pcall(fn,adapters[name])
        local decoded,table_text=pcall(snapshot,adapters[name])
        results[name]=tostring(ok)..' '..tostring(a)..' '..tostring(b)..' | '..tostring(decoded)..' '..tostring(table_text)
        if name=='v23' then results.after_v23=ffi.string(block,16432);ffi.copy(block,saved,16432)end
    end
    assert(results.after_v23==ffi.string(block,16432),label..': the lease table ended differently')
    -- Error messages carry the source name: compare their text only.
    local function plain(s)return (s:gsub('%[string "native_v23"%]:%d+: ',''):gsub('%S*native%.lua:%d+: ',''))end
    assert(plain(results.v23)==plain(results.current),label..':\n  v23:     '..results.v23..'\n  current: '..results.current)
end

for _,count in ipairs({0,1,300,1007})do
    fill(count+7,count)
    both(count..' rows decode',function(a)local r,n=a:references();return n end)
    local _,_,owner=adapters.current:references()
    local some={}
    for id in pairs((adapters.v23:references()))do some[id]={};if #some>3 then break end end
    both(count..' rows: held leases valid',function(a)return a:valid_leases(some,owner)end)
    both(count..' rows: a missing lease',function(a)return a:valid_leases({['0123456789abcdef']={}},owner)end)
    both(count..' rows: another owner',function(a)return a:valid_leases(some,'other')end)
    both(count..' rows: acquire a new package',function(a)return a:acquire('00000001ffffffff',owner)end)
    both(count..' rows: acquire it again',function(a)return a:acquire('00000001ffffffff',owner)end)
    -- With 1007 rows the table now holds 1008: a new package is refused.
    both(count..' rows: another new package',function(a)return a:acquire('0000000300000003',owner)end)
    both(count..' rows: release it',function(a)return a:release('00000001ffffffff',owner)end)
    both(count..' rows: release it to zero',function(a)return a:release('00000001ffffffff',owner)end)
    both(count..' rows: release a package not held',function(a)return a:release('00000001ffffffff',owner)end)
    both(count..' rows: acquire for another owner',function(a)return a:acquire('8000000000000002',owner..'x')end)
    balanced=false
    both(count..' rows: an acquire that does not balance',function(a)return a:acquire('00000002fffffffe',owner)end)
    balanced=true
end
-- Malformed rows raise in both.
fill(3,20);rows[5*4+3]=1;put(5,9,9,1);rows[5*4+3]=1
both('a 64-bit count',function(a)return a:references()end)
fill(3,20);put(6,9,9,0)
both('a zero count',function(a)return a:references()end)

-- Allocation per decode, interpreted: the reused buffer and the identifier
-- texts made on the first decode.
fill(11,300)
local function garbage(adapter,n)
    jit.off()
    adapter:references()
    collectgarbage('collect');collectgarbage('stop')
    local before=collectgarbage('count')
    for _=1,n do adapter:references()end
    local bytes=(collectgarbage('count')-before)*1024/n
    collectgarbage('restart');jit.on()
    return bytes
end
local v23_bytes,current_bytes=garbage(adapters.v23,20),garbage(adapters.current,200)
assert(v23_bytes>32*1024,'v23 reference: '..v23_bytes..' bytes per decode')
assert(current_bytes<1024,'current: '..current_bytes..' bytes per decode')
print(string.format('PASS: in-place lease table decode equals v23 for 0, 1, 300 and 1007 rows: rows and counts, ownership checks, acquire/release outcomes, full table, unbalanced call and malformed rows; %.0f bytes allocated per decode (v23: %.0f)',
    current_bytes,v23_bytes))
