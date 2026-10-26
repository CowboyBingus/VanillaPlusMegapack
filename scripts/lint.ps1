# Runs HellForge's C lint (rules C1-C15; KB hellforge-c-lint) over the pack with its own config and baseline
# (lint/lint-config.json, lint/lint-baseline.json). The lint lives in a HellForge-Open checkout's scripts/lint
# (-Lint, HELLFORGE_C_LINT, else ../c-lint/HellForge-Open/scripts/lint/lint.py beside this repository).
# Usage: scripts/lint.ps1 [check | scan | update] [extra lint.py arguments, e.g. --list, --allow-increase, --tests]
param([string]$Command='check',[string]$Lint=$env:HELLFORGE_C_LINT,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not $Lint){$Lint=Join-Path (Split-Path -Parent $root) 'c-lint/HellForge-Open/scripts/lint/lint.py'}
if(-not(Test-Path -LiteralPath $Lint)){throw "No C lint at $Lint (pass -Lint, or set HELLFORGE_C_LINT)."}
$python=if(Get-Command py -ErrorAction SilentlyContinue){@('py','-3')}else{@('python')}
& $python[0] @($python|Select-Object -Skip 1) $Lint $Command --config (Join-Path $root 'lint/lint-config.json') `
    --baseline (Join-Path $root 'lint/lint-baseline.json') --root $root @Rest
exit $LASTEXITCODE
