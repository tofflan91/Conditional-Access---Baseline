<#
.SYNOPSIS
  Deploy Conditional Access JSON policies from ./policies into Azure AD via Microsoft Graph.

.DESCRIPTION
  - Installs Microsoft.Graph if missing.
  - Connects to Graph with required scopes.
  - Loads each JSON file from ./policies, prompts for placeholder replacements,
    validates the JSON and POSTs to /identity/conditionalAccess/policies.
  - Supports -WhatIf mode (no changes, only simulates).

.NOTES
  - You must have permission to create Conditional Access policies.
  - Template placeholders (e.g. <BREAK_GLASS_USER_OBJECT_ID>) will be discovered and you will be asked to provide values.
  - Review policies in ./policies before running; adjust 'state' values if you want report-only vs enabled.
#>

param(
    [switch] $WhatIf
)

function Ensure-GraphModule {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
        Write-Host "Microsoft.Graph not found. Installing module from PSGallery..." -ForegroundColor Yellow
        Install-Module Microsoft.Graph -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Host "Microsoft.Graph module is available." -ForegroundColor Green
    }
}

function Connect-GraphInteractive {
    Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
    # Minimum scopes required to manage CA policies:
    $scopes = @(
        "Policy.ReadWrite.ConditionalAccess",
        "Directory.Read.All",
        "Application.ReadWrite.All",
        "User.Read.All"
    )

    # Use interactive login - user will consent.
    Try {
        Connect-MgGraph -Scopes $scopes -ErrorAction Stop
        $ctx = Get-MgContext
        Write-Host "Connected as:" $ctx.Account -ForegroundColor Green
    } Catch {
        Write-Error "Failed to connect to Microsoft Graph. $_"
        Exit 1
    }
}

function PromptForPlaceholderReplacements {
    param(
        [string] $jsonText
    )

    # Find placeholders like <SOME_VALUE>
    $placeholders = ([regex]::Matches($jsonText,'\<[^<>]+\>') | ForEach-Object { $_.Value }) | Select-Object -Unique

    $replacements = @{}
    foreach ($ph in $placeholders) {
        # skip obvious non-placeholder tokens (in case)
        if ($ph -match '^<\s*>$') { continue }

        # Ask the user for a replacement
        $prompt = "Enter value for placeholder $ph (enter to leave as-is)"
        $val = Read-Host $prompt
        if ($val -ne "") {
            $replacements[$ph] = $val
        }
    }

    foreach ($k in $replacements.Keys) {
        $jsonText = $jsonText -replace [regex]::Escape($k), [System.Text.RegularExpressions.Regex]::Escape($replacements[$k])
    }

    return $jsonText
}

function Validate-Json {
    param(
        [string] $text,
        [string] $filename
    )
    try {
        $obj = $text | ConvertFrom-Json -ErrorAction Stop
        return $obj
    } catch {
        Write-Error "JSON validation failed for $filename : $_"
        return $null
    }
}

function Deploy-Policy {
    param(
        [psobject] $policyObject,
        [string] $filename,
        [switch] $WhatIf
    )

    $body = ($policyObject | ConvertTo-Json -Depth 99)

    if ($WhatIf) {
        Write-Host "[WhatIf] Would create policy from file: $filename" -ForegroundColor Yellow
        return @{ status = 'WhatIf'; filename = $filename; bodyPreview = ($body.Substring(0,[Math]::Min(400,$body.Length))) }
    }

    try {
        # Use the beta or v1.0 endpoint for conditionalAccess policies
        # We'll POST to /identity/conditionalAccess/policies
        $response = Invoke-MgGraphRequest -Method POST -Uri 'identity/conditionalAccess/policies' -Body $body -ContentType 'application/json' -ErrorAction Stop
        Write-Host "Created policy '$($policyObject.displayName)' (id: $($response.id)) from file $filename" -ForegroundColor Green
        return @{ status = 'Created'; filename = $filename; id = $response.id; displayName = $policyObject.displayName }
    } catch {
        Write-Error "Failed to create policy from $filename : $_"
        return @{ status = 'Failed'; filename = $filename; error = $_.Exception.Message }
    }
}

# ==== Script start ====
Ensure-GraphModule

# Connect to Graph unless session exists
try {
    $ctx = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Connect-GraphInteractive
    } else {
        Write-Host "Re-using existing Microsoft Graph connection." -ForegroundColor Green
    }
} catch {
    Connect-GraphInteractive
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$policiesFolder = Join-Path $scriptDir 'policies'

if (-not (Test-Path $policiesFolder)) {
    Write-Error "Policies folder not found: $policiesFolder. Create a 'policies' folder and put your JSON files there."
    Exit 1
}

$policyFiles = Get-ChildItem -Path $policiesFolder -Filter *.json | Sort-Object Name
if ($policyFiles.Count -eq 0) {
    Write-Error "No JSON files found in $policiesFolder"
    Exit 1
}

$results = @()

foreach ($file in $policyFiles) {
    Write-Host "----" -ForegroundColor DarkCyan
    Write-Host "Processing file: $($file.Name)" -ForegroundColor Cyan

    $rawText = Get-Content -Raw -Path $file.FullName
    # Prompt user for values for placeholders
    $processedText = PromptForPlaceholderReplacements -jsonText $rawText

    # Validate
    $policyObj = Validate-Json -text $processedText -filename $file.Name
    if (-not $policyObj) {
        Write-Warning "Skipping $($file.Name) due to invalid JSON."
        $results += @{ status='InvalidJSON'; filename=$file.Name }
        continue
    }

    # Offer a summary of the policy before deploying
    $displayName = $policyObj.displayName
    $state = $policyObj.state
    $apps = $null
    if ($policyObj.conditions -and $policyObj.conditions.applications -and $policyObj.conditions.applications.includeApplications) {
        $apps = $policyObj.conditions.applications.includeApplications -join ', '
    } else {
        $apps = 'All or unspecified'
    }
    Write-Host "Policy summary:" -ForegroundColor Magenta
    Write-Host "  DisplayName: $displayName"
    Write-Host "  State: $state"
    Write-Host "  Apps: $apps"

    # Auto-confirm unless WhatIf
    if ($WhatIf) {
        $deployResult = Deploy-Policy -policyObject $policyObj -filename $file.Name -WhatIf
        $results += $deployResult
    } else {
        $ok = Read-Host "Create this policy now? (Y/N - default Y)"
        if ($ok -eq "" -or $ok -match '^[Yy]') {
            $deployResult = Deploy-Policy -policyObject $policyObj -filename $file.Name
            $results += $deployResult
        } else {
            Write-Host "Skipped creation of $($file.Name)" -ForegroundColor Yellow
            $results += @{ status='Skipped'; filename=$file.Name }
        }
    }
}

# Summary
Write-Host "----" -ForegroundColor DarkGreen
Write-Host "Deployment summary:" -ForegroundColor Green
$results | Format-Table -AutoSize

Write-Host "`nNotes:" -ForegroundColor Cyan
Write-Host "- Check Azure AD > Security > Conditional Access to review the newly created policies."
Write-Host "- Use report-only mode for high-impact policies until tuned."
Write-Host "- If you need automated mapping for role name -> role id or group name -> objectId, we can extend this script to resolve those via Graph."
