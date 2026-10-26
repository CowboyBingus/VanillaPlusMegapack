# Runs HellForge's C lint (rules C1-C15; KB hellforge-c-lint) over the pack with its own config and baseline
# (lint/lint-config.json, lint/lint-baseline.json). The lint lives in a HellForge-Open checkout's scripts/lint
# (-Lint, HELLFORGE_C_LINT, else c-lint/HellForge-Open/scripts/lint/lint.py in the HellForge folder above this
# repository or its worktree); the SDK header it reads, in sdk-dev/HellForge-Open (-HellForge, HELLFORGE_OPEN).
# Usage: scripts/lint.ps1 [check | scan | update] [extra lint.py arguments, e.g. --list, --allow-increase, --tests]
param([string]$Command='check',[string]$Lint=$env:HELLFORGE_C_LINT,[string]$HellForge=$env:HELLFORGE_OPEN,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$workspace=Split-Path -Parent $root
foreach($up in 1..3){if(Test-Path -LiteralPath (Join-Path $workspace 'c-lint/HellForge-Open')){break};$workspace=Split-Path -Parent $workspace}
if(-not $Lint){$Lint=Join-Path $workspace 'c-lint/HellForge-Open/scripts/lint/lint.py'}
if(-not $HellForge){$HellForge=Join-Path $workspace 'sdk-dev/HellForge-Open'}
if(-not(Test-Path -LiteralPath $Lint)){throw "No C lint at $Lint (pass -Lint, or set HELLFORGE_C_LINT)."}
$header=Join-Path $HellForge 'native/mod-sdk/hellforge_mod.h'
if(-not(Test-Path -LiteralPath $header)){throw "No SDK header at $header (pass -HellForge, or set HELLFORGE_OPEN)."}
# The config with the SDK header's absolute path, so the same file works from every worktree.
$config=Get-Content -Raw -LiteralPath (Join-Path $root 'lint/lint-config.json')|ConvertFrom-Json
$config.sdk_header=[IO.Path]::GetFullPath($header)
$build=New-Item -ItemType Directory -Force (Join-Path $root 'build')
$resolved=Join-Path $build 'lint-config.json'
[IO.File]::WriteAllText($resolved,($config|ConvertTo-Json -Depth 8))
$python=if(Get-Command py -ErrorAction SilentlyContinue){@('py','-3')}else{@('python')}
& $python[0] @($python|Select-Object -Skip 1) $Lint $Command --config $resolved --baseline (Join-Path $root 'lint/lint-baseline.json') --root $root @Rest
exit $LASTEXITCODE
