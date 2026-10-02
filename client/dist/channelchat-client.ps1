<#
  ChannelChat (codename "Anansi") — STANDALONE PowerShell client (GENERATED).

  DO NOT EDIT BY HAND. Regenerate with:
    node client/build/build-client.mjs --endpoint <url>

  Self-contained: embeds the dictionary + public configuration and imports no
  project-local modules at runtime. Built-in .NET only. Targets Windows PowerShell 5.1
  and PowerShell 7+.

  Embedded dictionaryId : sha256:c086524028b0dd375fb50622076755b293a478009a3c99cc44003b79f1781425
  Default endpoint      : http://127.0.0.1:8080/api/v1/exchange
  Generated (UTC)       : 2026-10-02T06:20:36.457Z

  The embedded package is DATA (dictionary + public config). It is NOT encryption and
  contains no credentials and no executable code.

  Usage (dot-source to get the functions):
    . .\channelchat-client.ps1
    Send-ChannelMessage -Text 'hello' -Endpoint 'http://host/api/v1/exchange'

  Usage (one-shot):
    .\channelchat-client.ps1 -Endpoint 'http://host/api/v1/exchange' -SendText 'hello'
    .\channelchat-client.ps1 -Endpoint 'http://host/api/v1/exchange' -HealthCheck
#>
param(
    [string]$Endpoint,
    [string]$SendText,
    [switch]$HealthCheck,
    [switch]$NoAutoLoad
)

# ========================================================================================
# BEGIN ChannelChat.Core.ps1 (inlined)
# ========================================================================================
# ChannelChat (codename "Anansi") — PowerShell client core.
#
# Dependency-free. Targets Windows PowerShell 5.1 (.NET Framework) and also runs on
# PowerShell 7 / .NET 5+. Uses ONLY built-in .NET APIs. No third-party modules, no NuGet,
# no downloaded assemblies, no runtime compilation, no Add-Type of custom code.
#
# This file contains DATA handling only. It never executes received content:
# no Invoke-Expression, no dynamic evaluation, no assembly loading from bytes.
#
# Avoids PowerShell 7-only syntax (no ternary, ?., ??, -Parallel) so it is valid on 5.1.
#
# Error codes match the JavaScript server (see src/errors.js). Each terminating error
# carries $_.Exception.Data['ChannelCode'] and a matching FullyQualifiedErrorId.

Set-StrictMode -Version 2.0

# --- default public limits (mirror src/limits.js client-relevant values) --------------
$script:ChannelDefaultLimits = @{
    maxResponseBodyBytes         = 4194304
    maxBase64Chars               = 1500000
    maxCompressedBytes           = 1048576
    maxDecompressedBytes         = 8388608
    maxPackageCompressedBytes    = 524288
    maxPackageDecompressedBytes  = 4194304
    maxDictionaryEntryBytes      = 256
    dictionaryEntryCount         = 256
    maxTokenCount                = 2000000
    maxReconstructedBytes        = 8388608
    clientTimeoutMs              = 30000
}

function Get-ChannelDefaultLimits {
    # Return a fresh clone so callers cannot mutate the shared defaults.
    $clone = @{}
    foreach ($k in $script:ChannelDefaultLimits.Keys) { $clone[$k] = $script:ChannelDefaultLimits[$k] }
    return $clone
}

function New-ChannelError {
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message)
    $ex = New-Object System.Exception ("[$Code] $Message")
    $ex.Data['ChannelCode'] = $Code
    return (New-Object System.Management.Automation.ErrorRecord($ex, $Code, [System.Management.Automation.ErrorCategory]::InvalidData, $null))
}

# Safe property read that works under StrictMode for PSCustomObject and hashtable alike.
# Returns $null when the property/key is absent (does not throw).
function Get-ChannelProp {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null }
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value } else { return $null }
}

# --- UTF-8 (strict) --------------------------------------------------------------------
function Get-ChannelStrictUtf8 {
    # throwOnInvalidBytes=$true => exception on malformed UTF-8 (decode) and on
    # unpaired surrogates (encode). encoderShouldEmitUTF8Identifier=$false => no BOM.
    return (New-Object System.Text.UTF8Encoding($false, $true))
}

function ConvertTo-ChannelUtf8Bytes {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $enc = Get-ChannelStrictUtf8
    try { return , $enc.GetBytes($Text) }
    catch { throw (New-ChannelError 'CODEC_LONE_SURROGATE' 'text contains an unpaired UTF-16 surrogate') }
}

function ConvertFrom-ChannelUtf8Bytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $enc = Get-ChannelStrictUtf8
    try { return $enc.GetString($Bytes) }
    catch { throw (New-ChannelError 'CODEC_INVALID_UTF8' 'bytes are not valid UTF-8') }
}

# --- dictionary fingerprint (identical algorithm to src/dictionary.js) -----------------
function Get-ChannelDictionaryId {
    param([Parameter(Mandatory)][string[]]$Entries)
    $enc = Get-ChannelStrictUtf8
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $ms = New-Object System.IO.MemoryStream
    try {
        $prefix = $enc.GetBytes('ChannelChat.Dictionary.v1')
        $ms.Write($prefix, 0, $prefix.Length)
        $ms.WriteByte(0)
        foreach ($e in $Entries) {
            $b = $enc.GetBytes($e)
            $len = [System.BitConverter]::GetBytes([uint32]$b.Length)
            if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($len) }
            $ms.Write($len, 0, 4)
            $ms.Write($b, 0, $b.Length)
        }
        $hash = $sha.ComputeHash($ms.ToArray())
        $sb = New-Object System.Text.StringBuilder
        foreach ($byte in $hash) { [void]$sb.Append($byte.ToString('x2')) }
        return 'sha256:' + $sb.ToString()
    }
    finally { $sha.Dispose(); $ms.Dispose() }
}

# --- dictionary validation / construction ---------------------------------------------
function New-ChannelDictionary {
    param(
        [Parameter(Mandatory)][object]$Document,
        [hashtable]$Limits = $null
    )
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($null -eq $Document) { throw (New-ChannelError 'DICT_SCHEMA_INVALID' 'dictionary document is null') }
    if ((Get-ChannelProp $Document 'schemaVersion') -ne 1) { throw (New-ChannelError 'DICT_SCHEMA_INVALID' 'dictionary.schemaVersion must be 1') }

    $entriesRaw = Get-ChannelProp $Document 'entries'
    if ($null -eq $entriesRaw -or -not ($entriesRaw -is [System.Collections.IEnumerable]) -or ($entriesRaw -is [string])) {
        throw (New-ChannelError 'DICT_SCHEMA_INVALID' 'dictionary.entries must be an array')
    }
    $entries = @($entriesRaw)
    if ($entries.Count -ne $Limits['dictionaryEntryCount']) {
        throw (New-ChannelError 'DICT_ENTRY_COUNT' ("dictionary.entries must have exactly {0} entries, got {1}" -f $Limits['dictionaryEntryCount'], $entries.Count))
    }

    $enc = Get-ChannelStrictUtf8
    $map = New-Object 'System.Collections.Generic.Dictionary[string,byte]' ([System.StringComparer]::Ordinal)
    $typed = New-Object 'string[]' $entries.Count
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        if ($null -eq $e -or -not ($e -is [string])) { throw (New-ChannelError 'DICT_ENTRY_TYPE' "dictionary entry at index $i is not a string") }
        try { $bytes = $enc.GetBytes($e) }
        catch { throw (New-ChannelError 'DICT_ENTRY_INVALID_UNICODE' "dictionary entry at index $i contains an unpaired surrogate") }
        if ($bytes.Length -gt $Limits['maxDictionaryEntryBytes']) {
            throw (New-ChannelError 'DICT_ENTRY_TOO_LONG' "dictionary entry at index $i exceeds max length")
        }
        if ($map.ContainsKey($e)) { throw (New-ChannelError 'DICT_DUPLICATE_ENTRY' "dictionary entry at index $i is duplicated") }
        $map[$e] = [byte]$i
        $typed[$i] = $e
    }

    $id = Get-ChannelDictionaryId -Entries $typed
    return [PSCustomObject]@{
        SchemaVersion = 1
        Entries       = $typed
        ByteOf        = $map
        Id            = $id
    }
}

# --- base64 (strict, canonical) --------------------------------------------------------
function ConvertFrom-ChannelBase64 {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if (($Text.Length % 4) -ne 0 -or ($Text -notmatch '\A[A-Za-z0-9+/]*={0,2}\z')) {
        throw (New-ChannelError 'PAYLOAD_BASE64_INVALID' 'value is not valid canonical base64')
    }
    try { $bytes = [System.Convert]::FromBase64String($Text) }
    catch { throw (New-ChannelError 'PAYLOAD_BASE64_INVALID' 'value is not valid base64') }
    if ([System.Convert]::ToBase64String($bytes) -ne $Text) {
        throw (New-ChannelError 'PAYLOAD_BASE64_INVALID' 'base64 is not canonical')
    }
    return , $bytes
}

function ConvertTo-ChannelBase64 {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    return [System.Convert]::ToBase64String($Bytes)
}

# --- gzip (bounded) --------------------------------------------------------------------
function Compress-ChannelGzip {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Data)
    $out = New-Object System.IO.MemoryStream
    $gz = New-Object System.IO.Compression.GZipStream($out, [System.IO.Compression.CompressionMode]::Compress, $true)
    try { $gz.Write($Data, 0, $Data.Length) }
    finally { $gz.Dispose() }
    $bytes = $out.ToArray()
    $out.Dispose()
    return , $bytes
}

function Expand-ChannelGzip {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Compressed,
        [Parameter(Mandatory)][int]$MaxBytes,
        [string]$TooLargeCode = 'PAYLOAD_DECOMPRESSED_TOO_LARGE'
    )
    $in = New-Object System.IO.MemoryStream (, $Compressed)
    $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $out = New-Object System.IO.MemoryStream
    try {
        $buf = New-Object 'byte[]' 8192
        $total = 0
        while ($true) {
            try { $read = $gz.Read($buf, 0, $buf.Length) }
            catch { throw (New-ChannelError 'PAYLOAD_GZIP_INVALID' 'input is not valid gzip') }
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $MaxBytes) { throw (New-ChannelError $TooLargeCode 'decompressed size exceeds limit') }
            $out.Write($buf, 0, $read)
        }
        return , $out.ToArray()
    }
    finally { $gz.Dispose(); $in.Dispose(); $out.Dispose() }
}

# --- token-array JSON (strict, no datetime coercion) -----------------------------------
# We hand-roll this because Windows PowerShell 5.1 ConvertFrom-Json coerces date-like
# quoted strings to [datetime], which would corrupt tokens. This parser preserves strings
# exactly and only accepts a flat array of JSON strings.

function ConvertTo-ChannelJsonStringLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($code -eq 8) { [void]$sb.Append('\b') }
        elseif ($code -eq 12) { [void]$sb.Append('\f') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9) { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append('\u'); [void]$sb.Append($code.ToString('x4')) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-ChannelTokenJson {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('[')
    for ($i = 0; $i -lt $Tokens.Length; $i++) {
        if ($i -gt 0) { [void]$sb.Append(',') }
        [void]$sb.Append((ConvertTo-ChannelJsonStringLiteral -Value $Tokens[$i]))
    }
    [void]$sb.Append(']')
    return $sb.ToString()
}

function ConvertFrom-ChannelTokenJson {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
    $s = $Json
    $n = $s.Length
    $i = 0
    $result = New-Object System.Collections.Generic.List[string]
    $fail = { param($m) throw (New-ChannelError 'PAYLOAD_JSON_INVALID' $m) }

    function Skip-Ws([string]$str, [int]$idx, [int]$len) {
        while ($idx -lt $len) {
            $c = $str[$idx]
            if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`n" -or $c -eq "`r") { $idx++ } else { break }
        }
        return $idx
    }

    $i = Skip-Ws $s $i $n
    if ($i -ge $n -or $s[$i] -ne '[') { & $fail 'token JSON must be an array' }
    $i++
    $i = Skip-Ws $s $i $n
    if ($i -lt $n -and $s[$i] -eq ']') {
        $i++
        $i = Skip-Ws $s $i $n
        if ($i -ne $n) { & $fail 'trailing content after array' }
        return , ([string[]]$result.ToArray())
    }

    while ($true) {
        $i = Skip-Ws $s $i $n
        if ($i -ge $n -or $s[$i] -ne '"') { & $fail 'expected a JSON string' }
        $i++
        $sb = New-Object System.Text.StringBuilder
        $closed = $false
        while ($i -lt $n) {
            $c = $s[$i]
            if ($c -eq '"') { $i++; $closed = $true; break }
            elseif ($c -eq '\') {
                $i++
                if ($i -ge $n) { & $fail 'dangling escape' }
                $esc = $s[$i]
                if ($esc -eq '"') { [void]$sb.Append('"') }
                elseif ($esc -eq '\') { [void]$sb.Append('\') }
                elseif ($esc -eq '/') { [void]$sb.Append('/') }
                elseif ($esc -eq 'b') { [void]$sb.Append([char]8) }
                elseif ($esc -eq 'f') { [void]$sb.Append([char]12) }
                elseif ($esc -eq 'n') { [void]$sb.Append([char]10) }
                elseif ($esc -eq 'r') { [void]$sb.Append([char]13) }
                elseif ($esc -eq 't') { [void]$sb.Append([char]9) }
                elseif ($esc -eq 'u') {
                    if ($i + 4 -ge $n) { & $fail 'short \u escape' }
                    $hex = $s.Substring($i + 1, 4)
                    if ($hex -notmatch '\A[0-9a-fA-F]{4}\z') { & $fail 'bad \u escape' }
                    [void]$sb.Append([char][System.Convert]::ToInt32($hex, 16))
                    $i += 4
                }
                else { & $fail 'invalid escape' }
                $i++
            }
            elseif ([int]$c -lt 32) { & $fail 'unescaped control character' }
            else { [void]$sb.Append($c); $i++ }
        }
        if (-not $closed) { & $fail 'unterminated string' }
        $result.Add($sb.ToString())
        $i = Skip-Ws $s $i $n
        if ($i -ge $n) { & $fail 'unterminated array' }
        if ($s[$i] -eq ',') { $i++; continue }
        elseif ($s[$i] -eq ']') { $i++; break }
        else { & $fail 'expected , or ]' }
    }
    $i = Skip-Ws $s $i $n
    if ($i -ne $n) { & $fail 'trailing content after array' }
    return , ([string[]]$result.ToArray())
}

# --- byte <-> token --------------------------------------------------------------------
function ConvertTo-ChannelTokenArray {
    param(
        [Parameter(Mandatory)]$Dictionary,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [hashtable]$Limits = $null
    )
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($Bytes.Length -gt $Limits['maxReconstructedBytes']) { throw (New-ChannelError 'CODEC_RECONSTRUCTED_TOO_LARGE' 'input exceeds max bytes') }
    if ($Bytes.Length -gt $Limits['maxTokenCount']) { throw (New-ChannelError 'CODEC_TOO_MANY_TOKENS' 'input exceeds max tokens') }
    $entries = $Dictionary.Entries
    $tokens = New-Object 'string[]' $Bytes.Length
    for ($i = 0; $i -lt $Bytes.Length; $i++) { $tokens[$i] = $entries[$Bytes[$i]] }
    return , $tokens
}

function ConvertFrom-ChannelTokenArray {
    param(
        [Parameter(Mandatory)]$Dictionary,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens,
        [hashtable]$Limits = $null
    )
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($Tokens.Length -gt $Limits['maxTokenCount']) { throw (New-ChannelError 'CODEC_TOO_MANY_TOKENS' 'token count exceeds max') }
    if ($Tokens.Length -gt $Limits['maxReconstructedBytes']) { throw (New-ChannelError 'CODEC_RECONSTRUCTED_TOO_LARGE' 'reconstructed size exceeds max') }
    $map = $Dictionary.ByteOf
    $out = New-Object 'byte[]' $Tokens.Length
    $b = [byte]0
    for ($i = 0; $i -lt $Tokens.Length; $i++) {
        $t = $Tokens[$i]
        if (-not $map.TryGetValue($t, [ref]$b)) { throw (New-ChannelError 'CODEC_UNKNOWN_TOKEN' "unknown token at index $i") }
        $out[$i] = $b
    }
    return , $out
}

# --- payload pack/unpack: tokens <-> base64(gzip(json)) --------------------------------
function ConvertTo-ChannelPayload {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens, [hashtable]$Limits = $null)
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    $enc = Get-ChannelStrictUtf8
    $json = $enc.GetBytes((ConvertTo-ChannelTokenJson -Tokens $Tokens))
    if ($json.Length -gt $Limits['maxDecompressedBytes']) { throw (New-ChannelError 'PAYLOAD_DECOMPRESSED_TOO_LARGE' 'token JSON exceeds limit') }
    $gz = Compress-ChannelGzip -Data $json
    if ($gz.Length -gt $Limits['maxCompressedBytes']) { throw (New-ChannelError 'PAYLOAD_COMPRESSED_TOO_LARGE' 'compressed payload exceeds limit') }
    $b64 = ConvertTo-ChannelBase64 -Bytes $gz
    if ($b64.Length -gt $Limits['maxBase64Chars']) { throw (New-ChannelError 'PAYLOAD_BASE64_TOO_LONG' 'base64 payload exceeds limit') }
    return $b64
}

function ConvertFrom-ChannelPayload {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Base64, [hashtable]$Limits = $null)
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($Base64.Length -gt $Limits['maxBase64Chars']) { throw (New-ChannelError 'PAYLOAD_BASE64_TOO_LONG' 'base64 payload exceeds limit') }
    $gz = ConvertFrom-ChannelBase64 -Text $Base64
    if ($gz.Length -gt $Limits['maxCompressedBytes']) { throw (New-ChannelError 'PAYLOAD_COMPRESSED_TOO_LARGE' 'compressed payload exceeds limit') }
    $json = Expand-ChannelGzip -Compressed $gz -MaxBytes $Limits['maxDecompressedBytes'] -TooLargeCode 'PAYLOAD_DECOMPRESSED_TOO_LARGE'
    $text = ConvertFrom-ChannelUtf8Bytes -Bytes $json
    $tokens = ConvertFrom-ChannelTokenJson -Json $text
    return , $tokens
}

# ========================================================================================
# BEGIN ChannelChat.Client.ps1 (inlined)
# ========================================================================================
# ChannelChat (codename "Anansi") — PowerShell client transport + public API.
#
# Requires the functions in ChannelChat.Core.ps1 to be loaded first (the dev module and the
# standalone build both arrange that). Dependency-free; built-in .NET only.
#
# Public functions:
#   ConvertTo-ChannelTokens     text/bytes  -> token array
#   ConvertFrom-ChannelTokens   token array -> text/bytes
#   Send-ChannelMessage         full HTTP(S) exchange with correlation checks
#   Test-ChannelEndpoint        GET /healthz liveness probe
#
# Transport rules: the URL scheme (http/https) alone selects transport; redirects are
# rejected; HTTPS keeps normal certificate validation (no bypass is ever installed).

$script:ChannelProtocolVersion = 1
$script:ChannelPayloadEncoding = 'dictionary-json+gzip+base64'
$script:ChannelSupportedKinds = @('text', 'bytes')

# Populated by Import-ChannelPackage (standalone) or Import-ChannelDictionaryFile (dev).
$script:ChannelDictionary = $null
$script:ChannelDefaultEndpoint = $null

function Resolve-ChannelDictionary {
    param($Dictionary)
    if ($null -ne $Dictionary) { return $Dictionary }
    if ($null -ne $script:ChannelDictionary) { return $script:ChannelDictionary }
    throw (New-ChannelError 'DICT_SCHEMA_INVALID' 'no dictionary loaded; pass -Dictionary or import a package')
}

function Resolve-ChannelEndpoint {
    param([string]$Endpoint)
    if (-not [string]::IsNullOrEmpty($Endpoint)) { return $Endpoint }
    if (-not [string]::IsNullOrEmpty($script:ChannelDefaultEndpoint)) { return $script:ChannelDefaultEndpoint }
    throw (New-ChannelError 'PROTO_FIELD_MISSING' 'no endpoint provided and no packaged default is set')
}

# --- embedded package decode (bounded, in memory; never written to a temp file) --------
function Import-ChannelPackage {
    param(
        [Parameter(Mandatory)][string]$Base64,
        [hashtable]$Limits = $null,
        [switch]$SetAsDefault
    )
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($Base64.Length -gt ($Limits['maxPackageCompressedBytes'] * 2)) {
        throw (New-ChannelError 'PACKAGE_COMPRESSED_TOO_LARGE' 'embedded package base64 too large')
    }
    $compressed = ConvertFrom-ChannelBase64 -Text $Base64
    if ($compressed.Length -gt $Limits['maxPackageCompressedBytes']) {
        throw (New-ChannelError 'PACKAGE_COMPRESSED_TOO_LARGE' 'embedded package compressed size exceeds limit')
    }
    $jsonBytes = Expand-ChannelGzip -Compressed $compressed -MaxBytes $Limits['maxPackageDecompressedBytes'] -TooLargeCode 'PACKAGE_DECOMPRESSED_TOO_LARGE'
    $jsonText = ConvertFrom-ChannelUtf8Bytes -Bytes $jsonBytes

    # Envelope has no date-like fields, so ConvertFrom-Json is safe for the package shell.
    try { $pkg = ConvertFrom-Json $jsonText } catch { throw (New-ChannelError 'PACKAGE_SCHEMA_INVALID' 'package JSON is invalid') }

    if ((Get-ChannelProp $pkg 'schemaVersion') -ne 1) { throw (New-ChannelError 'PACKAGE_SCHEMA_INVALID' 'package.schemaVersion must be 1') }
    $dictDoc = Get-ChannelProp $pkg 'dictionary'
    if ($null -eq $dictDoc) { throw (New-ChannelError 'PACKAGE_SCHEMA_INVALID' 'package.dictionary is missing') }

    $dict = New-ChannelDictionary -Document $dictDoc -Limits $Limits

    $declaredId = [string](Get-ChannelProp $pkg 'dictionaryId')
    if ([string]::IsNullOrEmpty($declaredId)) { throw (New-ChannelError 'PACKAGE_SCHEMA_INVALID' 'package.dictionaryId is missing') }
    if ($declaredId -cne $dict.Id) {
        throw (New-ChannelError 'DICT_ID_MISMATCH' 'package dictionaryId does not match computed fingerprint')
    }

    $config = Get-ChannelProp $pkg 'config'
    $defaultEndpoint = $null
    if ($null -ne $config) { $defaultEndpoint = [string](Get-ChannelProp $config 'defaultEndpoint') }

    if ($SetAsDefault) {
        $script:ChannelDictionary = $dict
        $script:ChannelDefaultEndpoint = $defaultEndpoint
    }
    return [PSCustomObject]@{
        Dictionary      = $dict
        DictionaryId    = $dict.Id
        DefaultEndpoint = $defaultEndpoint
        Config          = $config
    }
}

# --- HTTP transport (HttpWebRequest; no redirects; normal TLS validation) --------------
function Read-ChannelStreamBounded {
    param([Parameter(Mandatory)][System.IO.Stream]$Stream, [Parameter(Mandatory)][int]$MaxBytes)
    $out = New-Object System.IO.MemoryStream
    try {
        $buf = New-Object 'byte[]' 8192
        $total = 0
        while ($true) {
            $read = $Stream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }
            $total += $read
            if ($total -gt $MaxBytes) { throw (New-ChannelError 'CLIENT_RESPONSE_TOO_LARGE' 'response body exceeds limit') }
            $out.Write($buf, 0, $read)
        }
        return , $out.ToArray()
    }
    finally { $out.Dispose() }
}

function Invoke-ChannelHttp {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [byte[]]$Body = $null,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$MaxResponseBytes
    )
    $uri = $null
    try { $uri = [System.Uri]$Url } catch { throw (New-ChannelError 'PROTO_FIELD_TYPE' "invalid endpoint URL: $Url") }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        throw (New-ChannelError 'PROTO_FIELD_TYPE' "endpoint scheme must be http or https, got '$($uri.Scheme)'")
    }
    if ($uri.Scheme -eq 'https') {
        # Enable modern TLS without ever weakening certificate validation.
        $want = [System.Net.SecurityProtocolType]::Tls12
        try { $want = $want -bor [System.Net.SecurityProtocolType]::Tls13 } catch { }
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor $want
    }

    $req = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($uri)
    $req.Method = $Method
    $req.AllowAutoRedirect = $false
    # Connect directly. The MVP client does not route through an ambient system proxy, which
    # could silently redirect the request to a different destination.
    $req.Proxy = $null
    $req.KeepAlive = $false
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Accept = 'application/json'
    $req.UserAgent = 'ChannelChat-Anansi/1'

    if ($Method -eq 'POST') {
        $req.ContentType = 'application/json; charset=utf-8'
        $req.ContentLength = $Body.Length
        $rs = $null
        try { $rs = $req.GetRequestStream(); $rs.Write($Body, 0, $Body.Length) }
        finally { if ($null -ne $rs) { $rs.Dispose() } }
    }

    $resp = $null
    try {
        $resp = [System.Net.HttpWebResponse]$req.GetResponse()
    }
    catch [System.Net.WebException] {
        $we = $_.Exception
        if ($null -ne $we.Response) {
            $httpResp = [System.Net.HttpWebResponse]$we.Response
            $status = [int]$httpResp.StatusCode
            if ($status -ge 300 -and $status -lt 400) {
                $loc = $httpResp.Headers['Location']
                $httpResp.Dispose()
                throw (New-ChannelError 'CLIENT_REDIRECT_REJECTED' "redirect ($status) rejected; Location='$loc'")
            }
            $errStream = $httpResp.GetResponseStream()
            $bytes = $null
            try { $bytes = Read-ChannelStreamBounded -Stream $errStream -MaxBytes $MaxResponseBytes }
            finally { $errStream.Dispose(); $httpResp.Dispose() }
            return [PSCustomObject]@{ StatusCode = $status; Body = (ConvertFrom-ChannelUtf8Bytes -Bytes $bytes) }
        }
        if ($we.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
            throw (New-ChannelError 'CLIENT_TIMEOUT' 'request timed out')
        }
        # TLS/connection failures (e.g. TrustFailure, SecureChannelFailure) surface here.
        throw (New-ChannelError 'CLIENT_TIMEOUT' ("transport failure: {0}" -f $we.Status))
    }

    try {
        $status = [int]$resp.StatusCode
        if ($status -ge 300 -and $status -lt 400) {
            throw (New-ChannelError 'CLIENT_REDIRECT_REJECTED' "redirect ($status) rejected")
        }
        $stream = $resp.GetResponseStream()
        $bytes = Read-ChannelStreamBounded -Stream $stream -MaxBytes $MaxResponseBytes
        return [PSCustomObject]@{ StatusCode = $status; Body = (ConvertFrom-ChannelUtf8Bytes -Bytes $bytes) }
    }
    finally { $resp.Dispose() }
}

# --- public: codec ---------------------------------------------------------------------
# Resolve a Text/Bytes choice from bound parameters. Supports intentional empty inputs
# (empty string, empty byte array) and avoids the empty-string parameter-set pitfall.
function Resolve-ChannelInputBytes {
    param([bool]$HasText, [AllowEmptyString()][AllowNull()][string]$Text, [bool]$HasBytes, [AllowEmptyCollection()][AllowNull()][byte[]]$Bytes)
    if ($HasText -and $HasBytes) { throw (New-ChannelError 'PROTO_FIELD_TYPE' 'specify exactly one of -Text or -Bytes') }
    if (-not $HasText -and -not $HasBytes) { throw (New-ChannelError 'PROTO_FIELD_MISSING' 'specify one of -Text or -Bytes') }
    if ($HasText) {
        return @{ Kind = 'text'; Bytes = (ConvertTo-ChannelUtf8Bytes -Text $Text) }
    }
    $b = $Bytes
    if ($null -eq $b) { $b = New-Object 'byte[]' 0 }
    return @{ Kind = 'bytes'; Bytes = $b }
}

function ConvertTo-ChannelTokens {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyCollection()][AllowNull()][byte[]]$Bytes,
        [object]$Dictionary = $null,
        [hashtable]$Limits = $null
    )
    $dict = Resolve-ChannelDictionary $Dictionary
    $sel = Resolve-ChannelInputBytes `
        -HasText $PSBoundParameters.ContainsKey('Text') -Text $Text `
        -HasBytes $PSBoundParameters.ContainsKey('Bytes') -Bytes $Bytes
    $tokens = ConvertTo-ChannelTokenArray -Dictionary $dict -Bytes $sel.Bytes -Limits $Limits
    return , $tokens
}

function ConvertFrom-ChannelTokens {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tokens,
        [switch]$AsByteArray,
        [object]$Dictionary = $null,
        [hashtable]$Limits = $null
    )
    $dict = Resolve-ChannelDictionary $Dictionary
    $bytes = ConvertFrom-ChannelTokenArray -Dictionary $dict -Tokens $Tokens -Limits $Limits
    if ($AsByteArray) { return , $bytes }
    return (ConvertFrom-ChannelUtf8Bytes -Bytes $bytes)
}

# --- public: exchange ------------------------------------------------------------------
function Send-ChannelMessage {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyCollection()][AllowNull()][byte[]]$Bytes,
        [string]$Endpoint = $null,
        [object]$Dictionary = $null,
        [switch]$AsByteArray,
        [int]$TimeoutMs = 0,
        [hashtable]$Limits = $null
    )
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($TimeoutMs -le 0) { $TimeoutMs = $Limits['clientTimeoutMs'] }
    $dict = Resolve-ChannelDictionary $Dictionary
    $url = Resolve-ChannelEndpoint $Endpoint

    $sel = Resolve-ChannelInputBytes `
        -HasText $PSBoundParameters.ContainsKey('Text') -Text $Text `
        -HasBytes $PSBoundParameters.ContainsKey('Bytes') -Bytes $Bytes
    $kind = $sel.Kind
    $data = $sel.Bytes

    $tokens = ConvertTo-ChannelTokenArray -Dictionary $dict -Bytes $data -Limits $Limits
    $payload = ConvertTo-ChannelPayload -Tokens $tokens -Limits $Limits
    $requestId = [guid]::NewGuid().ToString()

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{"protocolVersion":')
    [void]$sb.Append($script:ChannelProtocolVersion)
    [void]$sb.Append(',"dictionaryId":'); [void]$sb.Append((ConvertTo-ChannelJsonStringLiteral $dict.Id))
    [void]$sb.Append(',"messageId":'); [void]$sb.Append((ConvertTo-ChannelJsonStringLiteral $requestId))
    [void]$sb.Append(',"kind":'); [void]$sb.Append((ConvertTo-ChannelJsonStringLiteral $kind))
    [void]$sb.Append(',"payloadEncoding":'); [void]$sb.Append((ConvertTo-ChannelJsonStringLiteral $script:ChannelPayloadEncoding))
    [void]$sb.Append(',"payload":'); [void]$sb.Append((ConvertTo-ChannelJsonStringLiteral $payload))
    [void]$sb.Append('}')
    $bodyBytes = (Get-ChannelStrictUtf8).GetBytes($sb.ToString())

    $http = Invoke-ChannelHttp -Url $url -Method 'POST' -Body $bodyBytes -TimeoutMs $TimeoutMs -MaxResponseBytes $Limits['maxResponseBodyBytes']

    if ($http.StatusCode -ne 200) {
        $code = 'SERVER_INTERNAL'
        $msg = "server returned HTTP $($http.StatusCode)"
        try {
            $errObj = ConvertFrom-Json $http.Body
            $errNode = Get-ChannelProp $errObj 'error'
            if ($null -ne $errNode) {
                $c = [string](Get-ChannelProp $errNode 'code'); if (-not [string]::IsNullOrEmpty($c)) { $code = $c }
                $m = [string](Get-ChannelProp $errNode 'message'); if (-not [string]::IsNullOrEmpty($m)) { $msg = $m }
            }
        }
        catch { }
        throw (New-ChannelError $code "exchange failed (HTTP $($http.StatusCode)): $msg")
    }

    $resp = $null
    try { $resp = ConvertFrom-Json $http.Body } catch { throw (New-ChannelError 'PROTO_BODY_INVALID_JSON' 'response is not valid JSON') }

    if ((Get-ChannelProp $resp 'protocolVersion') -ne $script:ChannelProtocolVersion) { throw (New-ChannelError 'PROTO_VERSION_UNSUPPORTED' 'response protocolVersion unsupported') }
    $respDictId = [string](Get-ChannelProp $resp 'dictionaryId')
    if ($respDictId -cne $dict.Id) { throw (New-ChannelError 'PROTO_DICTIONARY_MISMATCH' 'response dictionaryId mismatch') }
    $inReplyTo = [string](Get-ChannelProp $resp 'inReplyTo')
    if ($inReplyTo -cne $requestId) { throw (New-ChannelError 'CLIENT_CORRELATION_MISMATCH' 'response inReplyTo does not match request messageId') }
    $respKind = [string](Get-ChannelProp $resp 'kind')
    if ($respKind -cne $kind) { throw (New-ChannelError 'PROTO_KIND_UNSUPPORTED' 'response kind differs from request') }
    if (([string](Get-ChannelProp $resp 'payloadEncoding')) -cne $script:ChannelPayloadEncoding) { throw (New-ChannelError 'PROTO_ENCODING_UNSUPPORTED' 'response payloadEncoding unsupported') }
    $respMessageId = [string](Get-ChannelProp $resp 'messageId')
    $respPayload = [string](Get-ChannelProp $resp 'payload')

    $respTokens = ConvertFrom-ChannelPayload -Base64 $respPayload -Limits $Limits
    $respBytes = ConvertFrom-ChannelTokenArray -Dictionary $dict -Tokens $respTokens -Limits $Limits

    $text = $null
    if ($respKind -eq 'text') { $text = ConvertFrom-ChannelUtf8Bytes -Bytes $respBytes }

    return [PSCustomObject]@{
        Ok                = $true
        Endpoint          = $url
        Kind              = $respKind
        DictionaryId      = $respDictId
        RequestMessageId  = $requestId
        ResponseMessageId = $respMessageId
        InReplyTo         = $inReplyTo
        HttpStatus        = $http.StatusCode
        Text              = $text
        Bytes             = $respBytes
    }
}

function Test-ChannelEndpoint {
    [CmdletBinding()]
    param(
        [string]$Endpoint = $null,
        [int]$TimeoutMs = 0,
        [hashtable]$Limits = $null
    )
    if ($null -eq $Limits) { $Limits = Get-ChannelDefaultLimits }
    if ($TimeoutMs -le 0) { $TimeoutMs = $Limits['clientTimeoutMs'] }
    $url = Resolve-ChannelEndpoint $Endpoint
    $uri = [System.Uri]$url
    $healthUri = (New-Object System.UriBuilder($uri.Scheme, $uri.Host, $uri.Port, '/healthz')).Uri.AbsoluteUri

    $http = Invoke-ChannelHttp -Url $healthUri -Method 'GET' -TimeoutMs $TimeoutMs -MaxResponseBytes $Limits['maxResponseBodyBytes']
    $dictId = $null
    $proto = $null
    $statusText = $null
    if ($http.StatusCode -eq 200) {
        try {
            $obj = ConvertFrom-Json $http.Body
            $dictId = [string](Get-ChannelProp $obj 'dictionaryId')
            $proto = Get-ChannelProp $obj 'protocolVersion'
            $statusText = [string](Get-ChannelProp $obj 'status')
        }
        catch { }
    }
    return [PSCustomObject]@{
        Ok              = ($http.StatusCode -eq 200)
        Endpoint        = $url
        HealthUrl       = $healthUri
        HttpStatus      = $http.StatusCode
        Status          = $statusText
        ProtocolVersion = $proto
        DictionaryId    = $dictId
    }
}

# ----------------------------------------------------------------------------------------
# Embedded package (gzip+base64 of the dictionary + public configuration). DATA ONLY.
# ----------------------------------------------------------------------------------------
$ChannelEmbeddedPackage = 'H4sIAAAAAAAAA3VWTZMbuQ39L7yu7Gn16Gt0ix0fckhVasvZw27lgGajuzkiCRokpWlt7X/fAqhJOYlzaooEgYeHB1C/G0txcrM5/25GnKD68iWOiVws5myWUtL56WnbHz92H7uP2/OpO3VPkNzTdfuEb3aBOKPZGO+CK1l8WO8wlq8uINXy92zOz13XdRszOlscReD1Syy8fqYqAfr9YWMCvH2CjIfd5wU4m/N237U7Ad4+U0iMOeP4aS0oh93utD+2W39F+9/Hp+fT6dCd2vF/hnxYvIf8B9gLzPg/Afb9rj+dvjf5QZjd9mX33O3U6me0FHPhassPYfyMOVHM+InG9QfXv9IF4zsdmnj3x8YkWD3B+CVaGl2czfk7Aj+8Zoo/zXeXfhqUN7MxiamQJf8LcnYUzXn7x/ecS2UwFnYS/TcDfgKzMQPDlczG2AXYO6njiL7ICdpFDiZ6K0zFbMxMfjIbs1BBbzbGxdGJ3Wv1DuX84jw1Hch2cBfxFumKYUA2G0PZgnwTJDH4VnFAazaGKaBczA6Z5aRAnGWjRjcRB7MxV2cLyd3b4vIFV7MxbwzyWSFeUALdq6+SB7uQKYo7C+wVGDwAzORHAYhBDbwLcpG8u8oXAzKowSuMslEQJE+7gljDvbLsWhrAl0f+CvPqqMUJMGNU7gIwaQx3JRaYCYHFWfZQ8EG3JfWPA8VVHaekMAemeEclxF91J3koLlZhgusgxhlSWpwCKpTgLnkkdUelNC8wzrpYkBXKBN7qgnJipTAAF1Qm1vgmV1xjLhBlBQnsBhJWb+C5ZonbOCG2kuZIPi1OrkTg26JHqU6TbjFc1XmAOamwcgJmugkUF+0iblktmAa9kW9uKg9cunHBXFjFtgCza0WEGJVtW9njTdmhRlOOLiluHFVoAZJHzYtbOOe9xoecNDD4US8y3bTGC9w12msVT6zF16ZX9Fytzjlo3gZE/aIP6lLWBBcB5CJqlko/ea9CVaxlcbkoKPuOekEoy6PwYC8KbEJuhdDQ3tlFtyOWdpkRR63GqKP3jmlZGzktYUZsCvpWwXvVckiYlVyKuWlzZHe/q332qJQu4MR4YlJTqEzakJZCEzgW1DaMOFTfmhhya+rq24J4cEXHh3cpN3TRFWEHEr6pl6xOIa6Kg13LItcQ9OoVvFeB6ijqBdErsbYuzA07I8osgkKa3liVcYLshLBS46jAE4PjJj64QoyyN3uwTUqW8QpZMQZiaFWTXkOo2kFZVfitAhfpsJkhOm3fAXIbAgF4eFAIBRWql2dTO9yLGOY1Ze3ctHK7LEWK8O9RIpeisxdV3t1F2xKYc+vN4gpEpx7swhTa0ruyPDaBhzbvqp9qK47+hnht1SRWehcIoaW9uKzBgvBclNayoBa8jYzZhXZQmG5qmlObiQw5NZJiEzGEpCNQWYRbmwCtu7NlN7Q54h/tNEsEHcFXdVsYG30FowoLfKHGb5Yv2QLX5mLEqO2XKYLO2KnOVed2qQ0axVHfn5Wd1TSpzawrcm5NM0mRlZqyYNA43oMIa1lDbGRSY+YxMcBr5SGKN216aEN0ftco17ENkQDaNBfUzAYdNLm0Rl7akFiqqjW3NmM3z/Kuy+sQI6hqhkprG3cDca8PHrAo/RVL0YekSXcke2nSXPXpag+cdbFhkVGr4vPuUfS8vK9mj6ASqrm9FAyjg0ZuuTnv5qVoS2XxMMJNJ09ru0w+F6em+K26SK2f2YkHoZq4aI9byPbxihIzxsfAfqxwHFfzL1HIggH+z/+Vv43mbPIC/f5wtt3psO93XX8aunF8Pu6nYd8d+r47Ho77/dC/PMPueOq6F3i2Ly/W7nZd9zwcX6bt8bTd9XtJGyMyFBz/Uv5ZrDmbvusPH7bdh67/2h3OfXd+Pnzc7Y+/mh/g+hM/y6vuIgsAAA=='

if (-not $NoAutoLoad) {
    $null = Import-ChannelPackage -Base64 $ChannelEmbeddedPackage -SetAsDefault
    if (-not [string]::IsNullOrEmpty($Endpoint)) { $script:ChannelDefaultEndpoint = $Endpoint }

    if ($HealthCheck) {
        Test-ChannelEndpoint -Endpoint $Endpoint
    }
    elseif ($PSBoundParameters.ContainsKey('SendText')) {
        Send-ChannelMessage -Text $SendText -Endpoint $Endpoint
    }
}
