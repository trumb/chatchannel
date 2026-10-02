# Interop helper invoked by test/interop.test.mjs. Emits a single compact JSON line.
#
# Commands:
#   fingerprint  -Root -DictPath
#   encode       -Root -DictPath -Kind -InputBase64     (-> { payload })
#   decode       -Root -DictPath -InputBase64           (-> { outBase64 })  (InputBase64 = payload)
#   e2e          -Standalone -Endpoint -Kind -InputBase64 (-> { ok, inReplyToMatches, newId, outBase64, kind })
param(
    [Parameter(Mandatory)][string]$Command,
    [string]$Root = '',
    [string]$DictPath = '',
    [string]$Kind = 'bytes',
    [string]$InputBase64 = '',
    [string]$Standalone = '',
    [string]$Endpoint = ''
)
$ErrorActionPreference = 'Stop'

function Emit($obj) { $obj | ConvertTo-Json -Compress -Depth 6 }

if ($Command -eq 'e2e') {
    # Save args in distinct locals: dot-sourcing the standalone runs its param() block and
    # would reset any same-named caller variable (notably $Endpoint) to its default.
    $epLocal = $Endpoint
    $kindLocal = $Kind
    $inLocal = $InputBase64
    . $Standalone   # loads functions + embedded package (no action params = no send)
    $bytes = [System.Convert]::FromBase64String($inLocal)
    if ($kindLocal -eq 'text') {
        $txt = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        $r = Send-ChannelMessage -Text $txt -Endpoint $epLocal
    }
    else {
        $r = Send-ChannelMessage -Bytes $bytes -Endpoint $epLocal -AsByteArray
    }
    Emit @{
        ok               = [bool]$r.Ok
        inReplyToMatches = ($r.InReplyTo -ceq $r.RequestMessageId)
        newId            = ($r.ResponseMessageId -ne $r.RequestMessageId)
        kind             = $r.Kind
        outBase64        = [System.Convert]::ToBase64String($r.Bytes)
    }
    return
}

if ($Command -eq 'sendcatch') {
    # Attempt a send and report the stable error code instead of throwing. Used to assert
    # redirect rejection, no HTTPS->HTTP fallback, and certificate rejection.
    $epLocal = $Endpoint
    . $Standalone
    try {
        $r = Send-ChannelMessage -Text 'probe' -Endpoint $epLocal
        Emit @{ ok = [bool]$r.Ok; code = 'NONE' }
    }
    catch {
        Emit @{ ok = $false; code = [string]$_.Exception.Data['ChannelCode'] }
    }
    return
}

. (Join-Path $Root 'client/ChannelChat.Core.ps1')
. (Join-Path $Root 'client/ChannelChat.Client.ps1')
$doc = ConvertFrom-Json ([System.IO.File]::ReadAllText($DictPath))
$dict = New-ChannelDictionary -Document $doc

switch ($Command) {
    'fingerprint' { Emit @{ dictionaryId = $dict.Id } }
    'encode' {
        $bytes = [System.Convert]::FromBase64String($InputBase64)
        $tokens = ConvertTo-ChannelTokenArray -Dictionary $dict -Bytes $bytes
        Emit @{ payload = (ConvertTo-ChannelPayload -Tokens $tokens) }
    }
    'decode' {
        $tokens = ConvertFrom-ChannelPayload -Base64 $InputBase64
        $bytes = ConvertFrom-ChannelTokenArray -Dictionary $dict -Tokens $tokens
        Emit @{ outBase64 = [System.Convert]::ToBase64String($bytes) }
    }
    default { throw "unknown command: $Command" }
}
