-- Production adapter, simulated read-only native bindings. Mutation closures
-- are created but NEVER invoked at these synthetic module addresses.
local source,fixtures=assert(arg[1]),assert(arg[2])
local ffi=require('ffi')
local evidence=dofile(fixtures..'/stop_native.lua')
local completion=dofile(fixtures..'/completion_native.lua')
local api=dofile(source..'/windows_api.lua')()
for _,address in ipairs({0x10000,0x20dfcaad9c0,0x7ff7856173f8,0x7ffffffffffe}) do
    assert(api.address(ffi.cast('uint8_t *',address))==address)
    assert(api.address(ffi.cast('uint8_t *',address+1))==address+1)
end
assert(not pcall(api.address,ffi.cast('uint8_t *',0)))
assert(not pcall(api.address,ffi.cast('uint8_t *',0x800000000000)))
local game,exe=ffi.cast('uint8_t *',0x10000000),ffi.cast('uint8_t *',0x20000000)
local memory={}
local function key(address)return tonumber(ffi.cast('uintptr_t',address)) end
local function put(address,data)memory[key(address)]=data end
local function pointer(address,value)
    local b=ffi.new('uintptr_t[1]',ffi.cast('uintptr_t',value));put(address,ffi.string(b,8))
end
local table_address=exe+0x27cd910
pointer(game+0x3326338,table_address)
for _,entry in ipairs({{8,0x77f4f0},{0x60,0x799880},{0x68,0x799ba0}}) do
    pointer(table_address+entry[1],exe+entry[2])
end
put(exe+0x799880,'\x48\x89\x5c\x24\x08\x48\x89\x6c')
put(exe+0x799ba0,'\x48\x89\x5c\x24\x08\x48\x89\x6c')
assert(evidence.rva==0x7abd00 and #evidence.bytes==152)
put(game+evidence.rva,evidence.bytes)
assert(completion.rva==0x13c02c0 and #completion.bytes==422)
put(game+completion.rva,completion.bytes)
api.read=function(address,size)
    local b=memory[key(address)];return b and #b>=size and b:sub(1,size) or nil
end
local native=api.bind(game,exe)
assert(type(native.stop_sync)=='function' and type(native.pose)=='function' and type(native.disable)=='function')
assert(type(native.request_completion)=='function')
local request_code=completion.bytes
put(game+completion.rva,request_code:sub(1,400)..string.char((request_code:byte(401)+1)%256)..request_code:sub(402))
assert(not pcall(api.bind,game,exe),'Completion branch beyond primary unwind fragment must match')
put(game+completion.rva,request_code)
-- A changed final store is rejected even with an unchanged entry prologue.
local code=evidence.bytes
assert(code:byte(141)==0)
put(game+evidence.rva,code:sub(1,140)..'\1'..code:sub(142))
assert(not pcall(api.bind,game,exe),'Entire stop routine must match the captured code')
put(game+evidence.rva,code)
pointer(table_address+8,exe+0x7846f1)
assert(not pcall(api.bind,game,exe),'Changed native binding rejected')
print('PASS: production native adapter accepts captured stop routine and rejects changed body/bindings; no mutation closure invoked')
