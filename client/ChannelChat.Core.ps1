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
