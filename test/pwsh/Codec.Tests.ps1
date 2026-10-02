# Test cases for the dependency-free PowerShell harness (run-tests.ps1).
# Each function is discovered and run by name (ChannelTest_*). They use the Assert-* helpers
# and $script:Dict / $script:Fixture / $script:Vectors provided by the harness.

function ChannelTest_FingerprintMatchesFixture {
    Assert-Equal $script:Dict.Id $script:Fixture.dictionaryId "dictionary fingerprint matches shared fixture"
    Assert-Equal $script:Dict.Entries.Length 256 "dictionary has 256 entries"
}

function ChannelTest_RoundTripAll256Bytes {
    $all = New-Object 'byte[]' 256
    for ($i = 0; $i -lt 256; $i++) { $all[$i] = [byte]$i }
    $tokens = ConvertTo-ChannelTokens -Bytes $all -Dictionary $script:Dict
    $back = ConvertFrom-ChannelTokens -Tokens $tokens -AsByteArray -Dictionary $script:Dict
    $ok = $true
    for ($i = 0; $i -lt 256; $i++) { if ($back[$i] -ne $all[$i]) { $ok = $false; break } }
    Assert-True $ok "all 256 byte values round-trip"
}

function ChannelTest_EmptyInputsStayArrays {
    $et = ConvertTo-ChannelTokens -Text '' -Dictionary $script:Dict
    Assert-True ($et -is [array]) "empty text yields an array"
    Assert-Equal $et.Length 0 "empty text yields zero tokens"
    $eb = ConvertTo-ChannelTokens -Bytes ([byte[]]@()) -Dictionary $script:Dict
    Assert-True ($eb -is [array]) "empty bytes yields an array"
    Assert-Equal $eb.Length 0 "empty bytes yields zero tokens"
    $backText = ConvertFrom-ChannelTokens -Tokens $et -Dictionary $script:Dict
    Assert-Equal $backText '' "empty tokens decode to empty string"
}

function ChannelTest_SingleElementStaysArray {
    $t = ConvertTo-ChannelTokens -Bytes ([byte[]]@(65)) -Dictionary $script:Dict
    Assert-True ($t -is [array]) "single-byte input yields an array"
    Assert-Equal $t.Length 1 "single-byte input yields one token"
    $b = ConvertFrom-ChannelTokens -Tokens $t -AsByteArray -Dictionary $script:Dict
    Assert-True ($b -is [array]) "single token decodes to a byte array"
    Assert-Equal $b[0] 65 "single token decodes to byte 65"
}

function ChannelTest_UnicodeAndCombiningPreserved {
    foreach ($s in @("café", "é ñ", "omega", "")) {
        # (literal strings; the real combining chars are exercised by the golden vectors)
        $t = ConvertTo-ChannelTokens -Text $s -Dictionary $script:Dict
        $back = ConvertFrom-ChannelTokens -Tokens $t -Dictionary $script:Dict
        Assert-Equal $back $s ("text round-trips exactly: '" + $s + "'")
    }
}

function ChannelTest_InputEqualToTokenTreatedAsBytes {
    $s = 'alfa'
    $t = ConvertTo-ChannelTokens -Text $s -Dictionary $script:Dict
    Assert-Equal $t.Length 4 "'alfa' encodes to 4 tokens (one per byte), not matched as a word"
    $back = ConvertFrom-ChannelTokens -Tokens $t -Dictionary $script:Dict
    Assert-Equal $back $s "'alfa' round-trips"
}

function ChannelTest_LoneSurrogateRejected {
    Assert-Code 'CODEC_LONE_SURROGATE' { ConvertTo-ChannelTokens -Text ([string][char]0xD800) -Dictionary $script:Dict } "lone surrogate rejected"
}

function ChannelTest_UnknownTokenRejected {
    Assert-Code 'CODEC_UNKNOWN_TOKEN' { ConvertFrom-ChannelTokens -Tokens @('definitely-not-a-token') -Dictionary $script:Dict } "unknown token rejected"
}

function ChannelTest_Base64StrictRejected {
    Assert-Code 'PAYLOAD_BASE64_INVALID' { ConvertFrom-ChannelBase64 -Text 'AAA' } "wrong-length base64 rejected"
    Assert-Code 'PAYLOAD_BASE64_INVALID' { ConvertFrom-ChannelBase64 -Text 'A A=' } "whitespace base64 rejected"
}

function ChannelTest_GzipCorruptRejected {
    $b64 = [System.Convert]::ToBase64String([byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
    Assert-Code 'PAYLOAD_GZIP_INVALID' { ConvertFrom-ChannelPayload -Base64 $b64 } "corrupt gzip rejected"
}

function ChannelTest_TokenJsonNotArrayRejected {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"not":"array"}')
    $b64 = [System.Convert]::ToBase64String((Compress-ChannelGzip -Data $bytes))
    Assert-Code 'PAYLOAD_JSON_INVALID' { ConvertFrom-ChannelPayload -Base64 $b64 } "non-array token JSON rejected"
}

function ChannelTest_AdversarialTokens {
    $entries = New-Object 'string[]' 256
    for ($i = 0; $i -lt 256; $i++) { $entries[$i] = "t$i" }
    $entries[0] = '__proto__'; $entries[1] = 'constructor'
    $entries[2] = 'quo"te'; $entries[3] = 'back\slash'; $entries[4] = [char]0x2605 + 'uni'
    $d = New-ChannelDictionary -Document ([PSCustomObject]@{ schemaVersion = 1; entries = $entries })
    $bytes = [byte[]]@(0, 1, 2, 3, 4, 250)
    $tokens = ConvertTo-ChannelTokens -Bytes $bytes -Dictionary $d
    $payload = ConvertTo-ChannelPayload -Tokens $tokens
    $tk2 = ConvertFrom-ChannelPayload -Base64 $payload
    $back = ConvertFrom-ChannelTokens -Tokens $tk2 -AsByteArray -Dictionary $d
    $ok = $true
    for ($i = 0; $i -lt $bytes.Length; $i++) { if ($back[$i] -ne $bytes[$i]) { $ok = $false; break } }
    Assert-True $ok "adversarial tokens (__proto__, constructor, quotes, backslash, unicode) round-trip"
}

function ChannelTest_GoldenVectors {
    foreach ($v in $script:Vectors.vectors) {
        $bytes = [System.Convert]::FromBase64String($v.inputBase64)
        $tokens = ConvertTo-ChannelTokenArray -Dictionary $script:Dict -Bytes $bytes
        $expected = [string[]]@($v.tokens)
        Assert-True (Compare-StringArray $tokens $expected) ("golden vector tokens match: " + $v.name)
        $roundBytes = ConvertFrom-ChannelTokenArray -Dictionary $script:Dict -Tokens $expected
        Assert-Equal ([System.Convert]::ToBase64String($roundBytes)) $v.inputBase64 ("golden vector bytes match: " + $v.name)
    }
}
