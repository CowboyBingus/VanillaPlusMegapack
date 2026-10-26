# Builds the Vanilla Plus Megapack's DLL (vanilla_plus_megapack.dll, beside hellforge-mod.json) and, with -Test, builds
# and runs its tests (tests/core_test.c, tests/components/<id>_test.c). Uses HellForge's pinned Zig and the mod SDK of a
# HellForge-Open checkout, with the flags HellForge builds every mod with (src/HellForge.Core/ModKit.cs Flags), plus
# the build's identity (VPM_PACK_VERSION, VPM_COMMIT, VPM_BUILD_DATE). Beside the stripped DLL it builds the same code
# with line tables, build/symbols/vanilla_plus_megapack-<commit>.dll and .pdb, for scripts/symbolize.py, and records
# both in build/identity.json.
# Usage: scripts/build.ps1 [-Test] [-Only <component id>] [-HellForge <HellForge-Open checkout>] [-Zig <zig.exe>]
# Defaults: HELLFORGE_OPEN, else ../sdk-dev/HellForge-Open beside this repository; HELLFORGE_ZIG, else that checkout's
# tools/zig/zig.exe, else ../HellForge-Open/tools/zig/zig.exe.
param([switch]$Test,[string]$Only,[string]$HellForge=$env:HELLFORGE_OPEN,[string]$Zig=$env:HELLFORGE_ZIG,[switch]$NoDll)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
# The HellForge folder holding sdk-dev/ and HellForge-Open/: this repository's parent, or a parent of a worktree of it.
$workspace=Split-Path -Parent $root
foreach($up in 1..3){if(Test-Path -LiteralPath (Join-Path $workspace 'sdk-dev/HellForge-Open')){break};$workspace=Split-Path -Parent $workspace}
if(-not $HellForge){$HellForge=Join-Path $workspace 'sdk-dev/HellForge-Open'}
$sdk=Join-Path $HellForge 'native/mod-sdk'
if(-not(Test-Path -LiteralPath (Join-Path $sdk 'hellforge_mod.h'))){throw "No HellForge mod SDK at $sdk (pass -HellForge <HellForge-Open checkout>)."}
if(-not $Zig){
    foreach($candidate in @((Join-Path $HellForge 'tools/zig/zig.exe'),(Join-Path $workspace 'HellForge-Open/tools/zig/zig.exe'))){
        if(Test-Path -LiteralPath $candidate){$Zig=$candidate;break}
    }
}
if(-not $Zig -or -not(Test-Path -LiteralPath $Zig)){throw 'No zig.exe found (pass -Zig, or set HELLFORGE_ZIG).'}
$build=Join-Path $root 'build'
New-Item -ItemType Directory -Force $build|Out-Null
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $build 'zig-cache'
$env:ZIG_LOCAL_CACHE_DIR=Join-Path $build 'zig-cache'
# The compiler's temporary files stay in build/ too.
$env:TMP=$env:TEMP=New-Item -ItemType Directory -Force (Join-Path $build 'tmp')|ForEach-Object FullName
$failed=0
# The build's identity, compiled into the DLL (the core logs it at start-up): the manifest's version, the commit (with
# -dirty when the tree has changes; left out, so the core's fallback applies, when there is no git), the UTC date.
function Get-BuildIdentity{
    $version=(Get-Content -Raw -LiteralPath (Join-Path $root 'hellforge-mod.json')|ConvertFrom-Json).version
    $commit=$null
    $head=@()
    if(Get-Command git -ErrorAction SilentlyContinue){$head=@(git -C $root rev-parse --short HEAD 2>$null);if($LASTEXITCODE){$head=@()}}
    if($head.Count -eq 1){
        $commit=$head[0].Trim()
        $changes=@(git -C $root status --porcelain 2>$null)
        if($LASTEXITCODE){throw 'git status failed: cannot tell whether the tree has changes.'}
        if($changes.Count){$commit+='-dirty'}
    }else{Write-Warning 'No git commit found: the DLL carries no commit, and its symbols are named "unknown".'}
    [pscustomobject]@{version=$version;commit=$commit;date=(Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')}
}
if(-not $NoDll){
    $identity=Get-BuildIdentity
    $defines=@(('-DVPM_PACK_VERSION="{0}"' -f $identity.version),('-DVPM_BUILD_DATE="{0}"' -f $identity.date))
    if($identity.commit){$defines+=('-DVPM_COMMIT="{0}"' -f $identity.commit)}
    $sources=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.c'|Sort-Object FullName|ForEach-Object FullName)
    $flags=@('-std=c11','-target','x86_64-windows-gnu','-shared','-O2','-Wall','-Werror','-Wno-unused-parameter')+$defines+@('-I',$sdk)
    $dll=Join-Path $root 'vanilla_plus_megapack.dll'
    & $Zig cc @flags -s @sources -o $dll
    if($LASTEXITCODE){throw 'The DLL did not compile.'}
    Get-ChildItem -LiteralPath $root -File|Where-Object {$_.Extension -in @('.lib','.pdb')}|Remove-Item
    Write-Output ('Built {0} ({1:N0} KB)' -f $dll,((Get-Item -LiteralPath $dll).Length/1KB))
    # The same DLL unstripped, for scripts/symbolize.py: a PDB beside it (Zig's lld-link writes CodeView, not DWARF).
    # -gline-tables-only, not -g: full debug info changes clang's code in places, line tables do not, so the pack's
    # functions sit at the same offsets as in the shipped DLL. symbolize.py --check verifies that.
    $symbolsDir=Join-Path $build 'symbols'
    New-Item -ItemType Directory -Force $symbolsDir|Out-Null
    $symbols=Join-Path $symbolsDir ('vanilla_plus_megapack-{0}.dll' -f $(if($identity.commit){$identity.commit}else{'unknown'}))
    & $Zig cc @flags -gline-tables-only @sources -o $symbols
    if($LASTEXITCODE){throw 'The symbols DLL did not compile.'}
    Get-ChildItem -LiteralPath $symbolsDir -File -Filter '*.lib'|Remove-Item
    $python=Get-Command python -ErrorAction SilentlyContinue
    if($python){
        & $python.Source (Join-Path $PSScriptRoot 'symbolize.py') --check $dll --symbols $symbols
        if($LASTEXITCODE){throw ('{0} does not match the shipped DLL''s code: its offsets would mislead.' -f $symbols)}
    }else{Write-Warning ('No python: {0} was not checked against the shipped DLL.' -f $symbols)}
    $identity|Add-Member -NotePropertyName symbols -NotePropertyValue $symbols
    [IO.File]::WriteAllText((Join-Path $build 'identity.json'),($identity|ConvertTo-Json)+"`n")
    Write-Output ('Built {0} with its .pdb (commit {1})' -f $symbols,$identity.commit)
}
if($Test){
    $out=Join-Path $build 'tests'
    New-Item -ItemType Directory -Force $out|Out-Null
    $core=@(Get-ChildItem -LiteralPath (Join-Path $root 'src/core') -File -Filter '*.c'|Sort-Object FullName|ForEach-Object FullName)
    $harness=@(Get-ChildItem -LiteralPath (Join-Path $root 'tests/harness') -File -Filter '*.c'|ForEach-Object FullName)
    $cases=@()
    if(-not $Only -or $Only -eq 'core'){$cases+=,@('core',(Join-Path $root 'tests/core_test.c'),@())}
    foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'tests/components') -File -Filter '*_test.c' -ErrorAction SilentlyContinue)){
        $id=$file.BaseName -replace '_test$',''
        if($Only -and $Only -ne $id){continue}
        $own=@(Get-ChildItem -LiteralPath (Join-Path $root ('src/components/'+$id)) -Recurse -File -Filter '*.c'|ForEach-Object FullName)
        $cases+=,@($id,$file.FullName,$own)
    }
    foreach($case in $cases){
        $exe=Join-Path $out ($case[0]+'_test.exe')
        & $Zig cc -std=c11 -target x86_64-windows-gnu -O2 -g -Wall -Werror -Wno-unused-parameter -DVPM_TEST -I $sdk -I (Join-Path $root 'src') -I (Join-Path $root 'tests') `
            $case[1] @core @($case[2]) @harness -o $exe
        if($LASTEXITCODE){Write-Output ('{0}: did not compile' -f $case[0]);$failed++;continue}
        Push-Location $out
        try{& $exe|ForEach-Object {"  $_"};$code=$LASTEXITCODE}finally{Pop-Location}
        Write-Output ('{0}: {1}' -f $case[0],$(if($code){'FAILED'}else{'passed'}))
        if($code){$failed++}
    }
    # Know Your Constellation's Lua part (tests/lua): its test on LuaJIT's ffi against a probe DLL built from the
    # component's kyc_lua.c and kyc_gui.c (tests/lua/kyc_lua_probe.c). HellForge-Open's tools/ has no Lua interpreter, so
    # it runs with HD2_LUAJIT, else the workspace's LuaJIT (tools/src/LuaJIT/src/luajit.exe beside the HellForge folder),
    # and is skipped, saying so, without one.
    if(-not $Only -or $Only -eq 'know_your_constellation'){
        $luajit=$env:HD2_LUAJIT
        if(-not $luajit){$luajit=Join-Path (Split-Path -Parent $workspace) 'tools/src/LuaJIT/src/luajit.exe'}
        if(Test-Path -LiteralPath $luajit){
            $kyc=Join-Path $root 'src/components/know_your_constellation'
            $probe=Join-Path $out 'kyc_lua_probe.dll'
            & $Zig cc -std=c11 -target x86_64-windows-gnu -shared -O2 -Wall -Werror -Wno-unused-parameter -I $sdk -I (Join-Path $root 'src') `
                (Join-Path $root 'tests/lua/kyc_lua_probe.c') (Join-Path $kyc 'kyc_lua.c') (Join-Path $kyc 'kyc_gui.c') -o $probe
            if($LASTEXITCODE){Write-Output 'know_your_constellation (Lua part): the probe did not compile';$failed++}
            else{
                Get-ChildItem -LiteralPath $out -File -Filter 'kyc_lua_probe.lib'|Remove-Item
                & $luajit (Join-Path $root 'tests/lua/know_your_constellation_test.lua') $root $probe|ForEach-Object {"  $_"};$code=$LASTEXITCODE
                Write-Output ('know_your_constellation (Lua part): {0}' -f $(if($code){'FAILED'}else{'passed'}))
                if($code){$failed++}
            }
        }else{Write-Output 'know_your_constellation (Lua part): skipped, no LuaJIT (set HD2_LUAJIT to a luajit.exe)'}
    }
    if($failed){throw ('{0} test file(s) failed.' -f $failed)}
}
