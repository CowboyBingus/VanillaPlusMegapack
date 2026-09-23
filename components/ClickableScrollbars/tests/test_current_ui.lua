local root=assert(arg[1]);local source=arg[2] or root..'/src/clickable_scrollbars.lua'
local api,game,exe,export=dofile(root..'/tests/captured_ui.lua')(arg[3] or root..'/tests/fixtures/ui_armory_25327279.lua')
rawset(_G,'__CLICKABLE_SCROLLBARS_TEST',true)
local module=dofile(source)
local bridge,why=module.native_locate(api);assert(bridge,why)
local s=assert(module.native_state(bridge))
assert(bridge.route=='grid' and s.items==55 and s.columns==3 and s.rows==5)
assert(s.kind==4 and math.abs(s.value-.1232919246)<.000001 and s.span==3220)
assert(math.abs(s.geometry.left-1528)<.01 and math.abs(s.geometry.thumb-183.4745)<.01)
if arg[4]then export(arg[4])end
print('PASS: actual build 25327279 Armory controller, grid and scrollbar geometry')
