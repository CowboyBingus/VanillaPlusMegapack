# Packs the Vanilla Plus Megapack for players: build/release/Vanilla-Plus-Megapack-HellForge-<version>.zip, the manifest at
# its root. By default a source mod, as HellForge's own "Zip to share" packs one (docs/modding/tools.md "Releasing a
# mod"): the manifest, icon, README, LICENSE and src/, and every player's HellForge builds the DLL. With -Prebuilt it
# ships the DLL instead, its manifest marked "prebuilt": true for game build 25480438. Builds and tests first. Beside
# it, <zip name>-symbols-<commit>.zip holds the unstripped DLL and PDB of that build for scripts/symbolize.py: they
# match the prebuilt DLL; a player's own build of the source mod is a different build. Both forms carry data/, the game
# patch of Know Your Constellation's Lua part (scripts/lua_patch.py), which HellForge stages with the pack and Bingus
# Shared Loader starts: one mod, one download.
# Usage: scripts/package.ps1 [-Prebuilt] [-HellForge <HellForge-Open checkout>]
param([switch]$Prebuilt,[string]$HellForge=$env:HELLFORGE_OPEN)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
# A hashtable: an array would pass '-Test' as a positional string (it bound to -Only, and no test ran).
$buildArgs=@{Test=$true}
if($HellForge){$buildArgs.HellForge=$HellForge}
& (Join-Path $PSScriptRoot 'build.ps1') @buildArgs
if(-not $?){throw 'The build or its tests failed: nothing packed.'}
$manifest=Get-Content -Raw -LiteralPath (Join-Path $root 'hellforge-mod.json')|ConvertFrom-Json
$staging=Join-Path $root 'build/release/staging'
if(Test-Path -LiteralPath $staging){Remove-Item -Recurse -Force -LiteralPath $staging}
New-Item -ItemType Directory -Force $staging|Out-Null
foreach($name in @('icon.png','README.md','LICENSE')){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $staging}
if($Prebuilt){
    $manifest.code|Add-Member -NotePropertyName prebuilt -NotePropertyValue $true -Force
    $manifest.code|Add-Member -NotePropertyName game -NotePropertyValue '25480438' -Force
    Copy-Item -LiteralPath (Join-Path $root $manifest.code.dll) -Destination $staging
}else{
    # The tracked sources only, as committed (no local builds).
    foreach($file in @(git -C $root ls-files 'src')){
        $destination=Join-Path $staging $file
        New-Item -ItemType Directory -Force (Split-Path -Parent $destination)|Out-Null
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $destination
    }
}
# The Lua part's patch, built from its source and checked to hold exactly that source.
$python=Get-Command python -ErrorAction SilentlyContinue
if(-not $python){throw 'No python: the Lua part''s patch (scripts/lua_patch.py) cannot be built; nothing packed.'}
$lua=Join-Path $root 'src/components/know_your_constellation/lua/forecast_panel.lua'
& $python.Source (Join-Path $PSScriptRoot 'lua_patch.py') $lua $staging
if($LASTEXITCODE){throw 'The Lua part''s patch did not build: nothing packed.'}
& $python.Source (Join-Path $PSScriptRoot 'lua_patch.py') --check $lua (Join-Path $staging 'data/9ba626afa44a3aa3.patch_0')
if($LASTEXITCODE){throw 'The Lua part''s patch does not hold its source: nothing packed.'}
[IO.File]::WriteAllText((Join-Path $staging 'hellforge-mod.json'),($manifest|ConvertTo-Json -Depth 8).Replace("`r`n","`n")+"`n")
$zip=Join-Path $root ('build/release/Vanilla-Plus-Megapack-HellForge-{0}{1}.zip' -f $manifest.version,$(if($Prebuilt){'-prebuilt'}else{''}))
if(Test-Path -LiteralPath $zip){Remove-Item -Force -LiteralPath $zip}
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
Write-Output ('Packed {0} ({1:N0} KB)' -f $zip,((Get-Item -LiteralPath $zip).Length/1KB))
# The symbols of the DLL this build made, for scripts/symbolize.py; not for players. They hold the build machine's
# source paths.
$identity=Get-Content -Raw -LiteralPath (Join-Path $root 'build/identity.json')|ConvertFrom-Json
$symbolFiles=@($identity.symbols,[IO.Path]::ChangeExtension($identity.symbols,'.pdb'))
foreach($file in $symbolFiles){if(-not(Test-Path -LiteralPath $file)){throw "The build left no $file."}}
$symbolsZip=[IO.Path]::ChangeExtension($zip,$null).TrimEnd('.')+('-symbols-{0}.zip' -f $(if($identity.commit){$identity.commit}else{'unknown'}))
if(Test-Path -LiteralPath $symbolsZip){Remove-Item -Force -LiteralPath $symbolsZip}
Compress-Archive -LiteralPath $symbolFiles -DestinationPath $symbolsZip
Write-Output ('Packed {0} ({1:N0} KB)' -f $symbolsZip,((Get-Item -LiteralPath $symbolsZip).Length/1KB))
