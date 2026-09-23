local root=assert(arg[1]);local source=arg[2] or root..'/src'
for _,screen in ipairs({'armory','loadout'})do
 local path=arg[3] and arg[3]..'/'..(screen=='armory' and 'ship-armory-fixed-recorded.lua' or 'loadout-replay-input.lua')
  or root..'/tests/fixtures/ui_'..screen..'_25327279.lua'
 local api,game,exe,export=dofile(root..'/tests/captured_ui.lua')(path)
 local native=dofile(source..'/native.lua').new(api,game,exe,dofile(source..'/signatures.lua'))
 local s=native:snapshot();local expected=screen=='armory' and 54 or 48
 assert(s.menu and not s.blocked and s.top==(screen=='armory' and 5 or 14) and #s.items==expected)
 local images=dofile(source..'/image_native.lua').new(api,game,exe,dofile(source..'/image_signatures.lua'))
 local i=images:snapshot()
 assert(i.complete and i.expected_count==expected and #i.items==expected and #i.widgets==15)
 assert(i.controller_kind==(screen=='armory' and 224 or 229))
 if arg[4]then export(root..'/tests/fixtures/ui_'..screen..'_25327279.lua')end
end
print('PASS: actual build 25327279 Armory/loadout worlds, controllers, asset queues and 15 visible thumbnails each')
