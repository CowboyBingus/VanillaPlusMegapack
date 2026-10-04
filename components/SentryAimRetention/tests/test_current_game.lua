-- Replays game memory captured read-only from one Gatling sentry on Steam build
-- 25327279 (tests/current_game_25327279.lua) through the current snapshot. The
-- port to build 25480438 changed no offset the snapshot reads (only the module
-- hashes), so this checks the current registry, map, component, weapon and
-- clock decoding on real bytes. It cannot show that build 25480438 keeps every
-- layout. No game write, native call or bind happens: the replay api raises on
-- a write and on any read outside the captured ranges.
-- usage: test_current_game.lua <src>
local source=assert(arg[1]);local tests=arg[0]:gsub('[%w_]+%.lua$','')
local ffi=require('ffi')
local api,game=assert(loadfile(tests..'captured_game.lua'))()(tests..'current_game_25327279.lua')
local M=assert(loadfile(source..'/aim_data.lua'))()
local reads=0
local function counted(read)return function(p,n)reads=reads+1;return read(p,n)end end
api.read=counted(api.read)
local rows,reason=M.snapshot(api,game)
assert(#rows==1 and rows[1].profile=='Gatling' and rows[1].id==707 and rows[1].node==2)
assert(rows[1].fire and rows[1].fire.node,'Current weapon fire-node layout must resolve')
local s=rows[1]
local function float(b,o)local c=ffi.new('float[1]');ffi.copy(c,b:sub(o+1,o+4),4);return c[0] end
local function ticks(b)local c=ffi.new('uint64_t[1]');ffi.copy(c,b,8);return tonumber(c[0])end
-- The decoded fields of the captured sentry: scanning on behavior node 2 with an
-- explicit point and no target, normal fire mode on fire node 15, trigger up.
-- Locating the sentry the first time: 59 reads (the layout, then its live fields).
assert(reason=='observing' and reads==59,reason..', '..reads..' reads')
assert(s.target==0 and s.runtime_target==0 and s.flags==0 and s.enabled and s.has and s.source_flags==32)
assert(math.abs(float(s.raw,0)-67.4295)<1e-3 and math.abs(float(s.raw,4)-55.9898)<1e-3
    and math.abs(float(s.raw,8)-4.6311)<1e-3 and s.computed==s.raw and s.point==s.raw)
assert(float(s.horizontal,0)==80 and float(s.vertical,0)==50,'turret speeds')
assert(#s.guards==18 and #s.transition_guards==4)
assert(s.fire.mode==1 and s.fire.node==15 and s.fire.trigger==false and s.fire.unit==8392104)
assert(s.fire.pause==16 and s.fire.resume==4 and s.fire.target_unit==nil and #s.fire.guards==10)
assert(s.selection.now==1279614354 and ticks(s.selection.deadline)==1280273460 and #s.selection.guards==1)
-- The same bytes through a kept layout: the same row, verified with 26 reads.
local function fields(r)
    return table.concat({r.id,r.node,r.target,r.runtime_target,r.flags,r.source_flags,tostring(r.has),
        tostring(r.enabled),r.raw,r.computed,r.point,r.horizontal,r.vertical,r.fire.mode,r.fire.node,
        tostring(r.fire.trigger),r.selection.now,r.selection.deadline},'|')
end
local cache=M.new_cache()
assert(#M.snapshot(api,game,cache)==1)
reads=0
local kept=M.snapshot(api,game,cache)
assert(#kept==1 and fields(kept[1])==fields(s) and reads==26,reads..' reads')
-- The weapon and trigger headers are read whole; the capture read their fields
-- one by one. The bytes between those fields are never decoded: another fill
-- gives the same row, and they are exactly these 40 bytes.
api.gap_fill=0
local filled=M.snapshot(api,game)
assert(#filled==1 and fields(filled[1])==fields(s))
api.gap_fill=0xee
local cm=api.address(api.pointer(api.read(game+0x3326660,8)))
local wm=api.address(s.fire.manager)
local expected={}
for _,range in ipairs({{wm+68,4},{wm+80,8},{cm+60,28}}) do
    for i=0,range[2]-1 do expected[string.format('%.0f',range[1]+i)]=true end
end
local gaps=0
for k in pairs(api.gaps) do assert(expected[k],'uncaptured byte '..k);gaps=gaps+1 end
assert(gaps==40,gaps..' uncaptured bytes')
-- The gates on the same real bytes: another resource, lost authority, an
-- unexpected behavior component and an empty registry root.
local read=api.read
local function patched(address,bytes)
    local at=api.address(address)
    api.read=function(p,n)
        local b=read(p,n);local a=api.address(p)
        if at>=a and at+#bytes<=a+n then b=b:sub(1,at-a)..bytes..b:sub(at-a+#bytes+1)end
        return b
    end
end
patched(s.entity,string.rep('\0',8));assert(#M.snapshot(api,game)==0,'another resource is not a sentry')
patched(s.entity+20,'\0');assert(#M.snapshot(api,game)==0,'a sentry this machine does not control')
patched(s.behavior_address,'\0\0\0\0')
local ok,why=pcall(M.snapshot,api,game);assert(not ok and tostring(why):find('Unsupported sentry behavior',1,true))
patched(game+0x3326d30,string.rep('\0',8))
local none,waiting=M.snapshot(api,game);assert(#none==0 and waiting=='waiting_for_sentries')
api.read=read
assert(#M.snapshot(api,game)==1)
-- A kept layout meets the same gates: lost authority drops it, an unexpected
-- behavior component raises, and the restored bytes locate it again.
cache=M.new_cache();assert(#M.snapshot(api,game,cache)==1)
patched(s.entity+20,'\0');assert(#M.snapshot(api,game,cache)==0,'kept: authority')
api.read=read;assert(#M.snapshot(api,game,cache)==0,'not classified again before a rescan')
cache=M.new_cache();assert(#M.snapshot(api,game,cache)==1)
patched(s.behavior_address,'\0\0\0\0')
ok,why=pcall(M.snapshot,api,game,cache);assert(not ok and tostring(why):find('Unsupported sentry behavior',1,true))
api.read=read;assert(#M.snapshot(api,game,cache)==1)
print('PASS: actual Steam 25327279 Gatling behavior/weapon snapshot; no game writes/native calls')
print('PASS: the captured sentry decodes exactly (59 reads to locate, 26 through its kept layout) and its resource, authority, behavior and root gates reject changed bytes')
