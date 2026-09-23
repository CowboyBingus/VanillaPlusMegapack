local source=assert(arg[1]);local tests=source..'/../tests/'
local api,game=assert(loadfile(tests..'captured_game.lua'))()(tests..'current_game_25327279.lua')
local s,why=assert(loadfile(source..'/dive_data.lua'))().snapshot(api,game)
assert(s,why);assert(math.abs(s.base+1.3)<0.00001 and s.stance==2)
assert(s.remaining==5 and not s.dive,'Recorded mission state must resolve through the actual Drownable table')
print('PASS: actual current-build Drownable table at F12E20 with 122 hash slots, resource 5 and native water/stance/motion state')
