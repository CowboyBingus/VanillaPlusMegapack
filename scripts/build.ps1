# Builds the Vanilla Plus Megapack's DLL (vanilla_plus_megapack.dll, beside hellforge-mod.json) and, with -Test, builds
# and runs its tests (tests/core_test.c, tests/components/<id>_test.c). Uses HellForge's pinned Zig and the mod SDK of a
# HellForge-Open checkout, with the flags HellForge builds every mod with (src/HellForge.Core/ModKit.cs Flags).
# Usage: scripts/build.ps1 [-Test] [-Only <component id>] [-HellForge <HellForge-Open checkout>] [-Zig <zig.exe>]
# Defaults: HELLFORGE_OPEN, else ../sdk-dev/HellForge-Open beside this repository; HELLFORGE_ZIG, else that checkout's
# tools/zig/zig.exe, else ../HellForge-Open/tools/zig/zig.exe.
param([switch]$Test,[string]$Only,[string]$HellForge=$env:HELLFORGE_OPEN,[string]$Zig=$env:HELLFORGE_ZIG,[switch]$NoDll)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
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
if(-not $NoDll){
    $sources=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.c'|Sort-Object FullName|ForEach-Object FullName)
    $dll=Join-Path $root 'vanilla_plus_megapack.dll'
    & $Zig cc -std=c11 -target x86_64-windows-gnu -shared -O2 -Wall -Werror -Wno-unused-parameter -s -I $sdk @sources -o $dll
    if($LASTEXITCODE){throw 'The DLL did not compile.'}
    Get-ChildItem -LiteralPath $root -File|Where-Object {$_.Extension -in @('.lib','.pdb')}|Remove-Item
    Write-Output ('Built {0} ({1:N0} KB)' -f $dll,((Get-Item -LiteralPath $dll).Length/1KB))
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
        & $Zig cc -std=c11 -target x86_64-windows-gnu -O1 -g -Wall -Werror -Wno-unused-parameter -DVPM_TEST -I $sdk -I (Join-Path $root 'src') -I (Join-Path $root 'tests') `
            $case[1] @core @($case[2]) @harness -o $exe
        if($LASTEXITCODE){Write-Output ('{0}: did not compile' -f $case[0]);$failed++;continue}
        Push-Location $out
        try{& $exe|ForEach-Object {"  $_"};$code=$LASTEXITCODE}finally{Pop-Location}
        Write-Output ('{0}: {1}' -f $case[0],$(if($code){'FAILED'}else{'passed'}))
        if($code){$failed++}
    }
    if($failed){throw ('{0} test file(s) failed.' -f $failed)}
}
