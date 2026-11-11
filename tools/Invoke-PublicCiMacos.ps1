$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Invoke-PublicCiSuite.ps1') -Suite Macos
if (-not $?) { throw 'NINJA_CI_SUITE_FAILED' }
