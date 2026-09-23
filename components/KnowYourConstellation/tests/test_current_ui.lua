local source=assert(arg[1]);local root=source..'/..'
for _,screen in ipairs({'map','briefing'})do
 local path=arg[2] and arg[2]..'/'..(screen=='map' and 'map-recorded.lua' or 'briefing-fixed-recorded.lua')
  or root..'/tests/fixtures/ui_'..screen..'_25327279.lua'
 local api,game,exe,export=dofile(root..'/tests/captured_ui.lua')(path)
 local reader=dofile(source..'/mission.lua').new(api,game,dofile(source..'/resolve.lua'))
 assert(reader:screen()==screen,'Current screen stack/enum must resolve')
 local box=assert(dofile(source..'/presentation.lua').new(api,game):sample(screen),'Current native panel must resolve')
 assert(box.x==512 and math.abs(box.w-710.6667)<.01 and math.abs(box.scale-4/3)<.001)
 assert(math.abs(box.y-(screen=='map' and 715.5 or 824.833374))<.01)
 assert(box.font=='b56d2abac5d17df2' and box.material=='9f85b87d3ff20cbb' and box.atlas=='d1ebb991c79f934b')
 if arg[3]then export(root..'/tests/fixtures/ui_'..screen..'_25327279.lua')end
end
print('PASS: actual build 25327279 map and briefing screen stacks, registries and panel geometry')
