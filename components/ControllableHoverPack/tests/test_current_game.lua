local source=assert(arg[1]);local tests=source..'/../tests/'
local api,game=assert(loadfile(tests..'captured_game.lua'))()(tests..'current_game_25327279.lua')
local s=assert(assert(loadfile(source..'/hover_data.lua'))().snapshot(api,game))
assert(s.active and s.flight and not s.down,'Current-build airborne Hover Pack must be recognized')
print('PASS: actual Steam 25327279 airborne Hover Pack snapshot; no game writes/native calls')
