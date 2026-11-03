$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$solution = Join-Path (Split-Path -Parent $PSScriptRoot) 'd365fo-cli.slnx'
if (-not (Test-Path -LiteralPath $solution -PathType Leaf)) {
    throw 'NINJA_CLEAN_SOLUTION_MISSING'
}

dotnet restore $solution --nologo
if ($LASTEXITCODE -ne 0) { throw 'NINJA_CLEAN_RESTORE_FAILED' }

dotnet build $solution --no-restore --configuration Release --nologo
if ($LASTEXITCODE -ne 0) { throw 'NINJA_CLEAN_BUILD_FAILED' }

dotnet test $solution --no-build --configuration Release --logger trx --nologo
if ($LASTEXITCODE -ne 0) { throw 'NINJA_CLEAN_TESTS_FAILED' }
