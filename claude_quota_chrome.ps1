<# 
  Test Claude Code Chrome integration by extracting quota data from claude.ai.
  Requires: Claude Code CLI + Claude in Chrome extension + active login session.
#>
[CmdletBinding()]
param(
    [string]$Url = "https://claude.ai/settings/usage",
    [string]$ClaudeCmd = "claude",
    [string]$Model = "",
    [string]$OutputFile = "",
    [switch]$Raw
)

$schema = @'
{
  "type": "object",
  "properties": {
    "source_url": { "type": "string" },
    "current_session": {
      "type": "object",
      "properties": {
        "percent_used": { "type": "number" },
        "resets_in": { "type": "string" }
      },
      "required": ["percent_used", "resets_in"]
    },
    "weekly_limits": {
      "type": "object",
      "properties": {
        "percent_used": { "type": "number" },
        "resets": { "type": "string" }
      },
      "required": ["percent_used", "resets"]
    }
  },
  "required": ["source_url", "current_session", "weekly_limits"]
}
'@

$prompt = @"
Open $Url in the connected Chrome or Edge session.
If a login screen or CAPTCHA appears, pause and ask me to handle it.
After the page fully loads, read the DOM text (not a screenshot) and extract:
- current_session.percent_used (number)
- current_session.resets_in (string)
- weekly_limits.percent_used (number)
- weekly_limits.resets (string)
Also include source_url as the current page URL.
Return only JSON that matches the provided schema.
"@

Write-Host "Running Claude Code with Chrome integration..." -ForegroundColor Cyan
Write-Host "Target URL: $Url"

$args = @(
    "--chrome",
    "-p",
    "--output-format", "json",
    "--json-schema", $schema,
    $prompt
)
if ($Model) {
    $args = @("--model", $Model) + $args
}

try {
    # Reverted behavior: execute in the current shell session.
    # Stderr stays on console (can be noisy), stdout is captured for JSON parsing.
    $rawLines = & $ClaudeCmd @args
    $exit = $LASTEXITCODE
} catch {
    Write-Error "Failed to run Claude CLI command '$ClaudeCmd': $_"
    exit 1
}

if ($null -eq $exit) {
    $exit = if ($?) { 0 } else { 1 }
}

$cliOutput = ($rawLines | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
        $_.ToString()
    } else {
        [string]$_
    }
}) -join [Environment]::NewLine
$cliOutput = $cliOutput.Trim()

if ($exit -ne 0) {
    Write-Error "Claude CLI failed with exit code $exit."
    if ($cliOutput) {
        Write-Host $cliOutput
    }
    exit $exit
}

if ($Raw) {
    if ($cliOutput) {
        Write-Host $cliOutput
    }
    exit 0
}

try {
    $data = $cliOutput | ConvertFrom-Json -ErrorAction Stop
} catch {
    $match = [regex]::Match($cliOutput, "\{.*\}", "Singleline")
    if ($match.Success) {
        try {
            $data = $match.Value | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Failed to parse JSON output. Re-run with -Raw to inspect."
            if ($cliOutput) {
                Write-Host $cliOutput
            }
            exit 1
        }
    } else {
        Write-Warning "Failed to parse JSON output. Re-run with -Raw to inspect."
        if ($cliOutput) {
            Write-Host $cliOutput
        }
        exit 1
    }
}

$payload = if ($data.PSObject.Properties.Name -contains "structured_output") {
    $data.structured_output
} else {
    $data
}

$json = $payload | ConvertTo-Json -Depth 6
if ($OutputFile) {
    $json | Set-Content -Path $OutputFile -Encoding UTF8
}
Write-Host $json
