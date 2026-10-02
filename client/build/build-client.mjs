#!/usr/bin/env node
// Generates the standalone, self-contained PowerShell client:
//   client/dist/channelchat-client.ps1
//
// The output embeds the dictionary + public config as a gzip+base64 package (DATA only)
// and inlines the reviewable client code so it imports no project-local modules at runtime.
//
// Usage:
//   node client/build/build-client.mjs [--endpoint <url>] [--out <path>] [--dictionary <path>]

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { buildPackage } from "../../tools/build-package.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "..", "..");

function argValue(flag, fallback) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}

const endpoint = argValue("--endpoint", "http://127.0.0.1:8080/api/v1/exchange");
const dictionaryPath = argValue("--dictionary", join(repoRoot, "data", "dictionary.v1.json"));
const outPath = argValue("--out", join(repoRoot, "client", "dist", "channelchat-client.ps1"));

const core = readFileSync(join(repoRoot, "client", "ChannelChat.Core.ps1"), "utf8");
const client = readFileSync(join(repoRoot, "client", "ChannelChat.Client.ps1"), "utf8");

const built = buildPackage({ dictionaryPath, defaultEndpoint: endpoint });

// Sanity: base64 must be plain base64 so it embeds safely in a single-quoted PS string.
if (!/^[A-Za-z0-9+/]*={0,2}$/.test(built.base64)) {
  throw new Error("package base64 contains unexpected characters");
}

const header = `<#
  ChannelChat (codename "Anansi") — STANDALONE PowerShell client (GENERATED).

  DO NOT EDIT BY HAND. Regenerate with:
    node client/build/build-client.mjs --endpoint <url>

  Self-contained: embeds the dictionary + public configuration and imports no
  project-local modules at runtime. Built-in .NET only. Targets Windows PowerShell 5.1
  and PowerShell 7+.

  Embedded dictionaryId : ${built.dictionaryId}
  Default endpoint      : ${endpoint}
  Generated (UTC)       : ${built.package.generatedAtUtc}

  The embedded package is DATA (dictionary + public config). It is NOT encryption and
  contains no credentials and no executable code.

  Usage (dot-source to get the functions):
    . .\\channelchat-client.ps1
    Send-ChannelMessage -Text 'hello' -Endpoint 'http://host/api/v1/exchange'

  Usage (one-shot):
    .\\channelchat-client.ps1 -Endpoint 'http://host/api/v1/exchange' -SendText 'hello'
    .\\channelchat-client.ps1 -Endpoint 'http://host/api/v1/exchange' -HealthCheck
#>
param(
    [string]$Endpoint,
    [string]$SendText,
    [switch]$HealthCheck,
    [switch]$NoAutoLoad
)
`;

const bootstrap = `
# ----------------------------------------------------------------------------------------
# Embedded package (gzip+base64 of the dictionary + public configuration). DATA ONLY.
# ----------------------------------------------------------------------------------------
$ChannelEmbeddedPackage = '${built.base64}'

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
`;

const banner = (name) =>
  `\n# ========================================================================================\n# ${name}\n# ========================================================================================\n`;

const out =
  header +
  banner("BEGIN ChannelChat.Core.ps1 (inlined)") +
  core +
  banner("BEGIN ChannelChat.Client.ps1 (inlined)") +
  client +
  bootstrap;

mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, out, "utf8");
process.stdout.write(
  JSON.stringify(
    {
      event: "built",
      out: outPath,
      dictionaryId: built.dictionaryId,
      endpoint,
      compressedBytes: built.compressedBytes,
      base64Chars: built.base64.length,
      bytes: Buffer.byteLength(out, "utf8"),
    },
    null,
    2,
  ) + "\n",
);
