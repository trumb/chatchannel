# Dependency-free PowerShell test harness for the ChannelChat ("Anansi") client.
#
# No Pester, no third-party modules. Dot-sources the client core + client and the test
# cases, runs every function named ChannelTest_*, and exits non-zero on any failure.
#
# Run:
#   pwsh -NoProfile -File test/pwsh/run-tests.ps1           # PowerShell 7
#   powershell.exe -NoProfile -File test\pwsh\run-tests.ps1 # Windows PowerShell 5.1
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..'))
)
$ErrorActionPreference = 'Stop'

. (Join-Path $Root 'client/ChannelChat.Core.ps1')
. (Join-Path $Root 'client/ChannelChat.Client.ps1')

$script:Pass = 0
$script:Fail = 0

function Assert-True { param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Pass++ }
    else { $script:Fail++; Write-Host ("  FAIL: " + $Message) -ForegroundColor Red }
}
function Assert-Equal { param($Actual, $Expected, [string]$Message)
    Assert-True ($Actual -ceq $Expected) ("{0} (expected '{1}', got '{2}')" -f $Message, $Expected, $Actual)
}
function Assert-Code { param([string]$ExpectedCode, [scriptblock]$Action, [string]$Message)
    try { & $Action | Out-Null; Assert-True $false ("{0} (no error thrown)" -f $Message) }
    catch {
        $code = [string]$_.Exception.Data['ChannelCode']
        Assert-True ($code -eq $ExpectedCode) ("{0} (expected code {1}, got {2})" -f $Message, $ExpectedCode, $code)
    }
}
function Compare-StringArray { param([string[]]$A, [string[]]$B)
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -cne $B[$i]) { return $false } }
    return $true
}

# Shared state for test cases.
$script:Dict = New-ChannelDictionary -Document (ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $Root 'data/dictionary.v1.json'))))
$script:Fixture = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $Root 'shared/dictionary-fixture.json')))
$script:Vectors = ConvertFrom-Json ([System.IO.File]::ReadAllText((Join-Path $Root 'shared/vectors.json')))

. (Join-Path $PSScriptRoot 'Codec.Tests.ps1')

$tests = Get-Command -CommandType Function | Where-Object { $_.Name -like 'ChannelTest_*' } | Sort-Object Name
Write-Host ("ChannelChat PowerShell tests on PowerShell {0}" -f $PSVersionTable.PSVersion.ToString())
foreach ($t in $tests) {
    Write-Host ("RUN  " + $t.Name)
    & $t.Name
}
Write-Host ("`nRESULT: PASS={0} FAIL={1}" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
