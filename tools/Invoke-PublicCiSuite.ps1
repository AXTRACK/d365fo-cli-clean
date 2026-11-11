param([ValidateSet('Windows','Linux','Macos')][string]$Suite)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$expected = @{Windows='Windows';Linux='Unix';Macos='Unix'}[$Suite]
if ($Suite -eq 'Windows' -and -not $IsWindows) { throw 'NINJA_CI_WRONG_RUNNER_WINDOWS' }
if ($Suite -eq 'Linux' -and -not $IsLinux) { throw 'NINJA_CI_WRONG_RUNNER_LINUX' }
if ($Suite -eq 'Macos' -and -not $IsMacOS) { throw 'NINJA_CI_WRONG_RUNNER_MACOS' }
function Invoke-Checked {
    param([string]$Program,[string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "NINJA_CI_FAILED: $Program $($Arguments -join ' ') exit=$LASTEXITCODE" }
}
Invoke-Checked dotnet @('restore','d365fo-cli.slnx','--nologo')
Invoke-Checked dotnet @('build','d365fo-cli.slnx','--no-restore','-c','Release','-nologo')
Invoke-Checked dotnet @('test','d365fo-cli.slnx','--no-build','-c','Release','--logger','trx','--collect','XPlat Code Coverage')
if ($Suite -eq 'Macos') { Write-Host 'NINJA_CI_MACOS_PASS'; exit 0 }
$rid=if($Suite -eq 'Windows'){'win-x64'}else{'linux-x64'}
Invoke-Checked pwsh @('-NoProfile','-File','scripts/smoke-published-cli.ps1','-Rid',$rid)
if ($Suite -eq 'Windows') { Write-Host 'NINJA_CI_WINDOWS_PASS'; exit 0 }
Invoke-Checked pwsh @('-NoProfile','-File','scripts/check-build-warnings.ps1','-Baseline','101')
Invoke-Checked dotnet @('run','--project','src/D365FO.Cli','-c','Release','--','knowledge','audit','--verify','--output','json')
Invoke-Checked dotnet @('run','--project','src/D365FO.Cli','-c','Release','--','eval','run','--all','--output','json')
Invoke-Checked dotnet @('run','--project','src/D365FO.Cli','-c','Release','--no-build','--','eval','coverage','--check','--output','json')
Invoke-Checked dotnet @('run','--project','src/D365FO.Cli','-c','Release','--no-build','--','oracle','sweep','--dry','--output','json')
Invoke-Checked python @('-m','pip','install','pyyaml')
Invoke-Checked python @('scripts/test-emit-skills.py')
Invoke-Checked python @('scripts/emit-skills.py')
$drift=@(git status --porcelain -- skills/copilot skills/anthropic skills/d365fo-cli)
if ($drift.Count -gt 0) { throw "NINJA_CI_GENERATED_SKILLS_DRIFT: $($drift -join ';')" }
Invoke-Checked python @('scripts/check-skill-frontmatter.py')
Invoke-Checked dotnet @('build','src/D365FO.Cli','-c','Release','-nologo')
Invoke-Checked dotnet @('build','src/D365FO.Mcp','-c','Release','-nologo')
Invoke-Checked python @('scripts/emit-mcp-tools.py','--check')
Write-Host 'NINJA_CI_LINUX_PASS'