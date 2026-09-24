"""Compose the same named Lua resource for standalone and megapack builds."""
def component(path):
    return '(function()\n' + path.read_text(encoding='utf-8') + '\nend)()'

def wrapper(root,game_sha,exe_sha):
    source='local base='+component(root/'src/read_api.lua')+'\n'
    for name in ('platform','dependencies','native','policy','profile','signatures','image_native','images','image_signatures','install'):
        source+='local '+name+'='+component(root/'src'/(name+'.lua'))+'\n'
    source+="install(function()return platform(base)end,native,policy,profile,signatures,{revision='v22',game_sha256='%s',exe_sha256='%s'},image_native,images,image_signatures,dependencies)\n"%(game_sha,exe_sha)
    return source
