<#
.SYNOPSIS
  Deploy Conditional Access JSON policies from ./policies into Microsoft Entra ID via Microsoft Graph.

.DESCRIPTION
  - Installs Microsoft.Graph if missing.
  - Connects to Graph with required scopes.
  - Loads each JSON file from a policies folder, prompts for placeholder replacements,
    validates the JSON and POSTs to /identity/conditionalAccess/policies.
  - Can also PATCH existing policies with the same displayName when -AllowUpdate is used.
  - Supports -WhatIf mode (no changes, only simulates).
  - Supports -NonInteractive for unattended runs (no prompts).

.NOTES
  - You must have permission to create/update Conditional Access policies.
  - Template placeholders (e.g. <BREAK_GLASS_USER_OBJECT_ID>) will be discovered and you will be asked to provide values.
  - Review policies before running; adjust 'state' values if you want enabled vs report-only.
#>

param(
    [switch] $WhatIf,
    [switch] $NonInteractive,
    [switch] $AllowUpdate,
    [string] $PoliciesPath
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
    # Scopes for managing CA policies
    $scopes = @(
        "Policy.ReadWrite.ConditionalAccess",
        "Policy.Read.All",
        "Directory.Read.All",
        "Application.Read.All",
        "User.Read.All"
    )

    try {
        Connect-MgGraph -Scopes $scopes -ErrorAction Stop
        $ctx = Get-MgContext
        Write-Host "Connected as:" $ctx.Account -ForegroundColor Green
    } catch {
        Write-Error "Failed to connect to Microsoft Graph. $_"
        Exit 1
    }
}

function PromptForPlaceholderReplacements {
    param(
        [string] $jsonText,
        [hashtable] $PlaceholderCache,
        [switch] $NonInteractive
    )

    if ($NonInteractive) {
        # Do not touch placeholders in non-interactive mode
        return $jsonText
    }

    # Find placeholders like <SOME_VALUE>
    $placeholders = ([regex]::Matches($jsonText,'\<[^<>]+\>') | ForEach-Object { $_.Value }) | Select-Object -Unique

    $replacements = @{}

    foreach ($ph in $placeholders) {
        if ($ph -match '^<\s*>$') { continue }

        if ($PlaceholderCache.ContainsKey($ph)) {
            $replacements[$ph] = $PlaceholderCache[$ph]
            continue
        }

        $prompt = "Enter value for placeholder $ph (enter to leave as-is)"
        $val = Read-Host $prompt

        if ($val -ne "") {
            $replacements[$ph] = $val
            $PlaceholderCache[$ph] = $val
        }
    }

    foreach ($k in $replacements.Keys) {
        # Simple literal replacement – no regex semantics
        $jsonText = $jsonText.Replace($k, $replacements[$k])
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
        [string]   $filename,
        [switch]   $WhatIf,
        [switch]   $AllowUpdate,
        [hashtable] $ExistingIndex
    )

    $body = ($policyObject | ConvertTo-Json -Depth 99)
    $displayName = $policyObject.displayName
    $existingId = $null

    if ($ExistingIndex -and $ExistingIndex.ContainsKey($displayName)) {
        $existingId = $ExistingIndex[$displayName]
    }

    if ($WhatIf) {
        if ($existingId -and $AllowUpdate) {
            Write-Host "[WhatIf] Would UPDATE existing policy '$displayName' ($existingId) from file: $filename" -ForegroundColor Yellow
            return @{
                status      = 'WhatIf-Update'
                filename    = $filename
                id          = $existingId
                displayName = $displayName
            }
        }
        elseif ($existingId) {
            Write-Host "[WhatIf] Would SKIP (policy exists) '$displayName' ($existingId) from file: $filename" -ForegroundColor Yellow
            return @{
                status      = 'WhatIf-ExistsSkipped'
                filename    = $filename
                id          = $existingId
                displayName = $displayName
            }
        }
        else {
            Write-Host "[WhatIf] Would CREATE policy from file: $filename" -ForegroundColor Yellow
            return @{
                status      = 'WhatIf-Create'
                filename    = $filename
                displayName = $displayName
            }
        }
    }

    try {
        if ($existingId -and $AllowUpdate) {
            Write-Host "Updating existing policy '$displayName' ($existingId) from file $filename..." -ForegroundColor Cyan
            $uri = "identity/conditionalAccess/policies/$existingId"
            $null = Invoke-MgGraphRequest -Method PATCH -Uri $uri -Body $body -ContentType 'application/json' -ErrorAction Stop
            Write-Host "Updated policy '$displayName' ($existingId)." -ForegroundColor Green
            return @{ status = 'Updated'; filename = $filename; id = $existingId; displayName = $displayName }
        }
        elseif ($existingId) {
            Write-Host "Policy '$displayName' already exists (id: $existingId). Skipping. Use -AllowUpdate to PATCH." -ForegroundColor Yellow
            return @{ status = 'ExistsSkipped'; filename = $filename; id = $existingId; displayName = $displayName }
        }
        else {
            Write-Host "Creating new policy '$displayName' from file $filename..." -ForegroundColor Cyan
            $response = Invoke-MgGraphRequest -Method POST -Uri 'identity/conditionalAccess/policies' -Body $body -ContentType 'application/json' -ErrorAction Stop
            Write-Host "Created policy '$($policyObject.displayName)' (id: $($response.id)) from file $filename" -ForegroundColor Green
            return @{ status = 'Created'; filename = $filename; id = $response.id; displayName = $policyObject.displayName }
        }
    } catch {
        Write-Error "Failed to create/update policy from $filename : $_"
        return @{ status = 'Failed'; filename = $filename; error = $_.Exception.Message; displayName = $displayName }
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

# Resolve policies folder
if ([string]::IsNullOrWhiteSpace($PoliciesPath)) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $policiesFolder = Join-Path $scriptDir 'policies'
} else {
    $policiesFolder = (Resolve-Path $PoliciesPath).Path
}

if (-not (Test-Path $policiesFolder)) {
    Write-Error "Policies folder not found: $policiesFolder. Create a 'policies' folder and put your JSON files there, or use -PoliciesPath."
    Exit 1
}

$policyFiles = Get-ChildItem -Path $policiesFolder -Filter *.json | Sort-Object Name
if ($policyFiles.Count -eq 0) {
    Write-Error "No JSON files found in $policiesFolder"
    Exit 1
}

# Get existing policies once and index by displayName
$existingIndex = @{}
try {
    Write-Host "Fetching existing Conditional Access policies..." -ForegroundColor Cyan
    $existing = Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop
    foreach ($p in $existing) {
        if (-not [string]::IsNullOrWhiteSpace($p.displayName)) {
            $existingIndex[$p.displayName] = $p.Id
        }
    }
    Write-Host "Found $($existingIndex.Count) existing policies." -ForegroundColor Green
} catch {
    Write-Warning "Could not fetch existing policies. Create operations will still work, but -AllowUpdate will be ineffective. $_"
}

$results = @()
$placeholderCache = @{}

foreach ($file
