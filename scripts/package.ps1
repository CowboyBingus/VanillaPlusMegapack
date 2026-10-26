# Packs the Vanilla Plus Megapack for players: build/release/Vanilla-Plus-Megapack-HellForge-<version>.zip, the manifest at
# its root. By default a source mod, as HellForge's own "Zip to share" packs one (docs/modding/tools.md "Releasing a
# mod"): the manifest, icon, README, LICENSE and src/, and every player's HellForge builds the DLL. With -Prebuilt it
# ships the DLL instead, its manifest marked "prebuilt": true for game build 25480438. Builds and tests first.
# Usage: scripts/package.ps1 [-Prebuilt] [-HellForge <HellForge-Open checkout>]
param([switch]$Prebuilt,[string]$HellForge=$env:HELLFORGE_OPEN)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$buildArgs=@('-Test')
if($HellForge){$buildArgs+=@('-HellForge',$HellForge)}
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
[IO.File]::WriteAllText((Join-Path $staging 'hellforge-mod.json'),($manifest|ConvertTo-Json -Depth 8).Replace("`r`n","`n")+"`n")
$zip=Join-Path $root ('build/release/Vanilla-Plus-Megapack-HellForge-{0}{1}.zip' -f $manifest.version,$(if($Prebuilt){'-prebuilt'}else{''}))
if(Test-Path -LiteralPath $zip){Remove-Item -Force -LiteralPath $zip}
Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zip
Write-Output ('Packed {0} ({1:N0} KB)' -f $zip,((Get-Item -LiteralPath $zip).Length/1KB))
