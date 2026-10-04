-- Replays bytes captured from Steam 25327279. Never calls game functions.
-- Memory is a stack of regions: the captured blocks, then whatever a test maps
-- or pokes on top (a later region wins where they overlap).
--   read(p, n) returns a string; every byte must be covered.
--   read(address, n, into, offset) copies into a caller buffer {data, address,
--   size} like the platform api: covered bytes from their region, zeros in
--   between (a larger read than the capture made), nil when no byte is
--   covered. It allocates nothing, so garbage checks measure the mod only.
local ffi=require('ffi')
-- Copies between number addresses create no cdata. Private names (__asm__
-- labels), as in src/read_api.lua, leave the real names undeclared.
ffi.cdef[[
    void hd2apc_test_move(uint64_t destination, uint64_t source, size_t length) __asm__("RtlMoveMemory");
    void hd2apc_test_zero(uint64_t destination, size_t length) __asm__("RtlZeroMemory");
]]
local kernel=ffi.load('kernel32')
local move,zero=kernel.hd2apc_test_move,kernel.hd2apc_test_zero
return function(filename)
 local fixture=dofile(filename);local regions,used={},{}
 local function address(p)return type(p)=='number' and p or tonumber(ffi.cast('uintptr_t',p))end
 -- A region backed by bytes at real address at (keep holds the allocation).
 local function add(a,size,at,keep,captured)
  regions[#regions+1]={address=a,size=size,at=at,keep=keep,captured=captured}
 end
 local function copy(a,bytes,captured)
  local data=ffi.new('uint8_t[?]',#bytes);ffi.copy(data,bytes,#bytes)
  add(a,#bytes,tonumber(ffi.cast('uintptr_t',data)),data,captured)
 end
 for _,b in ipairs(fixture.blocks)do
  copy(b.address,b.hex:gsub('..',function(h)return string.char(tonumber(h,16))end),true)
 end
 local memory={}
 -- A test buffer (a writable copy of a native object) seen at address a.
 function memory.map(a,pointer,size)add(address(a),size,address(pointer),pointer)end
 function memory.poke(a,bytes)copy(address(a),bytes)end
 local game,exe=ffi.cast('uint8_t *',fixture.game),ffi.cast('uint8_t *',fixture.exe)
 local api={module=function(n)return n=='game.dll' and game or exe end,address=address,
  distance=function(a,b)return address(a)-address(b)end}
 -- Copies the covered bytes of [a, a+n) to real address to; true when any
 -- byte is covered. memory.record (fixture export) also notes captured bytes.
 local function compose(a,n,to)
  local covered=false
  zero(to,n)
  for i=1,#regions do
   local r=regions[i]
   local from,upto=math.max(a,r.address),math.min(a+n,r.address+r.size)
   if from<upto then
    move(to+(from-a),r.at+(from-r.address),upto-from);covered=true
    if memory.record and r.captured then
     used[string.format('%.0f',from)..':'..(upto-from)]={address=from,
      bytes=ffi.string(ffi.cast('uint8_t *',r.at+(from-r.address)),upto-from)}
    end
   end
  end
  return covered
 end
 local scratch=ffi.new('uint8_t[32768]');local scratch_at=tonumber(ffi.cast('uintptr_t',scratch))
 function api.read(p,n,into,offset)
  if into then
   offset=offset or 0
   if type(p)~='number' or n<=0 or offset<0 or offset+n>into.size then return nil end
   return compose(p,n,into.address+offset) or nil
  end
  local a=address(p)
  assert(n>0 and n<=32768,'Replay read size')
  -- As the original replay: every byte must be captured (or mapped).
  local mask=ffi.new('uint8_t[?]',n)
  for _,r in ipairs(regions)do
   for i=math.max(a,r.address),math.min(a+n,r.address+r.size)-1 do mask[i-a]=1 end
  end
  for i=0,n-1 do if mask[i]==0 then error(string.format('Uncaptured current-build UI read %x:%d',a,n))end end
  compose(a,n,scratch_at)
  local bytes=ffi.string(scratch,n)
  for _,r in ipairs(regions)do
   if r.captured and a>=r.address and a+n<=r.address+r.size then
    used[string.format('%.0f',a)..':'..n]={address=a,bytes=bytes};break
   end
  end
  return bytes
 end
 function api.pointer(b,o)
  o=o or 0;if not b or o+8>#b then return nil end
  local p=ffi.new('uint64_t[1]');ffi.copy(p,b:sub(o+1,o+8),8)
  if p[0]<0x10000 or p[0]>=0x800000000000ULL then return nil end
  return ffi.cast('uint8_t *',p[0])
 end
 api.write=function()error('Capture replay cannot write')end
 local function export(path)
  local rows={};for _,b in pairs(used)do rows[#rows+1]=b end
  table.sort(rows,function(a,b)return a.address<b.address end)
  local out=assert(io.open(path,'wb'))
  out:write('-- Actual UI read ranges from Steam 25327279; no game writes or native calls.\nreturn {game=',string.format('%.0f',fixture.game),',exe=',string.format('%.0f',fixture.exe),',blocks={\n')
  for _,b in ipairs(rows)do
   out:write('{address=',string.format('%.0f',b.address),",hex='",(b.bytes:gsub('.',function(c)return string.format('%02x',c:byte())end)),"'},\n")
  end
  out:write('}}\n');out:close()
 end
 return api,game,exe,export,memory
end
