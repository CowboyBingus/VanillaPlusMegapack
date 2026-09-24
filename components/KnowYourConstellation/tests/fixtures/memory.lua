-- Synthetic memory fixtures. Addresses and packets are fictional, not captures.
local ffi = require('ffi')
local M = {}
local function scalar(ctype, value, size)
    return ffi.string(ffi.new(ctype..'[1]', value), size)
end
local function word(n) return scalar('uint32_t',n,4) end
local function half(n) return scalar('uint16_t',n,2) end
local function qword(n) return scalar('uint64_t',n,8) end
local function float(n) return scalar('float',n,4) end
local function record(size, fields)
    local result = string.rep('\0',size)
    for offset,bytes in pairs(fields) do
        assert(offset>=0 and offset+#bytes<=size)
        result=result:sub(1,offset)..bytes..result:sub(offset+#bytes+1)
    end
    return result
end
local function memory()
    local blocks={}
    local function put(address,bytes) blocks[#blocks+1]={address=address,bytes=bytes} end
    return blocks,put
end

function M.mission(kind)
    local game,root,board,controller=0x10000000,0x20000000,0x30000000,0x40000000
    local screen,defs,level,config=0x50000000,0x60000000,0x70000000,0x80000000
    local globals,session,remote,fallback=0x90000000,0xa0000000,0xb0000000,0xc0000000
    local blocks,put=memory()
    local joined=kind~='host'
    local planet=kind=='other' and 268 or 76
    local faction=kind=='join' and 4 or 2
    local planet_hash=planet==76 and 910588397 or 1653510998
    local tag=kind=='join' and 29 or 7
    local campaign=board+1053752
    put(game+0x347ce28,qword(screen))
    put(screen+0x429c,record(24,{[0]=word(15),[20]=word(1)}))
    put(game+0x3326340,qword(root))
    put(root+0xae288,qword(controller))
    put(game+0x347cee8,qword(board))
    put(board+1548960,word(joined and 0xffffffff or 0))
    put(board+1012352,record(92,{[16]=half(76),[24]=string.char(1),[28]=word(1),[52]=string.char(1)}))
    local descriptor=record(200,{[0]=word(12345),[4]=word(54321),[8]=string.char(faction,10),
        [12]=word(planet_hash),[26]=half(84)})
    put(board+0x4168d0,descriptor)
    put(controller+8,descriptor)
    put(controller,qword(0))
    put(board+1548952,word(76))
    put(campaign+495200,word(76))
    put(board+1197132,word(275))
    for _,p in ipairs({76,268}) do
        put(campaign+280*p,record(280,{[24]=word(p==76 and 910588397 or 1653510998)}))
        put(campaign+304*p+286752,record(304,{[36]=word(faction),[64]=word(1)}))
        put(campaign+304*p+286952,string.rep('\0',132))
    end
    put(game+0x347cef0,qword(session))
    put(session+92102,string.char(0))
    put(root+4205,string.char(0))
    put(root+4217,string.char(0))
    put(game+0x347cd98,qword(defs))
    put(defs+53248,word(1))
    put(defs,record(52,{[0]=word(101),[4]=word(40),[8]=word(424242),[24]=word(13),[28]=word(0x9fd5943a)}))
    local hashes={}
    for i=0,31 do hashes[#hashes+1]=word(i==12 and 0x9fd5943a or 1000+i) end
    put(game+0x21e1920,table.concat(hashes))
    put(campaign+494868,word(0))
    put(campaign+490072,word(0))
    put(campaign+155672,word(0))
    put(game+0x32e98e0+168+9,string.char(0))
    put(game+0x346d518,qword(globals))
    put(globals,string.rep('\0',32*356))
    put(controller+648,qword(level))
    put(level+9160276,string.rep('\0',16))
    local candidate=faction==4 and 468 or 276
    put(game+0x328d2a0+9*816,record(816,{[272]=word(1),[candidate]=word(tag+1),[candidate+4]=float(1)}))
    put(game+0x347cdf8,qword(config))
    put(config+73848,string.rep('\0',24))
    put(config+49232,string.rep('\0',24))
    put(game+0x3773420+896*84,string.rep('\0',896))
    if joined then
        put(board+1548956,word(planet))
        put(board+2064401,string.char(1))
        put(board+1548964,word(0xffffffff)..word(0))
        put(game+0x3326aa0,qword(fallback))
        put(fallback+5633600,word(428)..word(0)..word(10))
        put(board+2053224,word(1))
        put(board+2044424,word(3)..word(0)..word(10)..word(428)..word(0))
        put(game+0x347ce80,qword(remote))
        put(remote+1487456,word(1))
        put(remote+1409456+1456,string.char(1))
        local token='synthetic-public-test-mission'
        local packet=token..string.rep('\0',512-#token)
        put(remote+1409456+944,packet)
        put(root+713400,packet)
        put(board+4286668,word(0))
    end
    return {game=game,screen='map',blocks=blocks,tags={tag},complete=true,
        key=table.concat({12345,54321,faction,10,planet_hash,84},':')}
end

function M.widget(x,y,width,height,alpha)
    return record(164,{[0]=word(0xc0085011),[36]=float(width),[40]=float(height),
        [84]=float(alpha or 1),[100]=float(4/3),[140]=float(4/3),[148]=float(x),[156]=float(y)})
end

function M.presentation(kind)
    local game,screen,manager,owner,material=0x10000000,0x50000000,0xd0000000,0xe0000000,0xf0000000
    local blocks,put=memory()
    local briefing=kind=='briefing' or kind=='loadout'
    put(game+0x347ce28,qword(screen))
    put(screen+0x429c,record(24,{[0]=word(briefing and 14 or 15),[20]=word(1)}))
    put(game+0x3326e68,qword(manager))
    put(manager+25224,word(1)..word(0)..qword(owner)..word(226)..word(0))
    put(manager+25272,word(1)..word(0)..qword(owner)..word(229)..word(0))
    put(owner+8,word(kind=='loadout' and 1 or 0))
    put(owner+31232,M.widget(512,894.1667,533,360))
    put(owner+349072,string.rep('\0',164))
    put(owner+280528,M.widget(512,696.6667,533,425.5))
    put(owner+526048,M.widget(1900,300,443,400,kind=='hidden' and 0 or 1))
    put(game+0x3772268,word(0xc5d17df2)..word(0xb56d2aba))
    put(game+0x37c5478,qword(material))
    put(material+24,word(0x3ff20cbb)..word(0x9f85b87d))
    put(game+0x3772ee8,word(0xc79f934b)..word(0xd1ebb991))
    return {game=game,blocks=blocks}
end

function M.transitions()
    return {map=M.widget(512,768.8333,533,371.375),entry={
        {tab=2,flags=0xc0085011,alpha=0},{tab=0,flags=0xc0085011,alpha=.009},
        {tab=0,flags=0xc0085011,alpha=.503},{tab=0,flags=0xc0085011,alpha=1}}}
end

function M.positions()
    return {M.widget(1900,300,443,400),M.widget(2000,200,443,650)}
end
return M
