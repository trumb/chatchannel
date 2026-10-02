# ChannelChat (codename "Anansi") — DEVELOPMENT module.
#
# Dot-sources the dependency-free core + client for local development and testing.
# NOTE: this dev module uses project-local files. The STANDALONE client produced by
# client/build/build-client.mjs is fully self-contained and imports nothing at runtime.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ChannelChat.Core.ps1')
. (Join-Path $here 'ChannelChat.Client.ps1')

function Import-ChannelDictionaryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$SetAsDefault,
        [string]$DefaultEndpoint
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = (Get-ChannelStrictUtf8).GetString($bytes)
    $doc = ConvertFrom-Json $text
    $dict = New-ChannelDictionary -Document $doc
    if ($SetAsDefault) {
        $script:ChannelDictionary = $dict
        if (-not [string]::IsNullOrEmpty($DefaultEndpoint)) { $script:ChannelDefaultEndpoint = $DefaultEndpoint }
    }
    return $dict
}

Export-ModuleMember -Function `
    ConvertTo-ChannelTokens, ConvertFrom-ChannelTokens, Send-ChannelMessage, Test-ChannelEndpoint, `
    Import-ChannelDictionaryFile, Import-ChannelPackage, New-ChannelDictionary, Get-ChannelDictionaryId, `
    Get-ChannelDefaultLimits
