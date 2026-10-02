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
        # TLS/connection failures (e.g. TrustFailure, SecureChannelFailure, ConnectFailure)
        # surface here. Certificate validation is never bypassed, so an untrusted HTTPS
        # certificate fails as a transport error rather than succeeding.
        throw (New-ChannelError 'CLIENT_TRANSPORT' ("transport failure: {0}" -f $we.Status))
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
