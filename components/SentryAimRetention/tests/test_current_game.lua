local source=assert(arg[1]);local tests=source..'/../tests/'
local api,game=assert(loadfile(tests..'captured_game.lua'))()(tests..'current_game_25327279.lua')
local rows=assert(loadfile(source..'/aim_data.lua'))().snapshot(api,game)
assert(#rows==1 and rows[1].profile=='Gatling' and rows[1].id==707 and rows[1].node==2)
assert(rows[1].fire and rows[1].fire.node,'Current weapon fire-node layout must resolve')
print('PASS: actual Steam 25327279 Gatling behavior/weapon snapshot; no game writes/native calls')
