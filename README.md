# Conditional-Access---Baseline

Review each JSON file and update the include and exclude user/group IDs to match your tenant (GUIDs in these sample files are placeholders). Replace namedLocation values and country lists with the set relevant to your business.

Use the Azure AD PowerShell (MSGraph) or Microsoft Graph API to create policies. Example: New-MgConditionalAccessPolicy -BodyParameter (Get-Content -Raw ./policies/01-require-mfa-all-users.json | ConvertFrom-Json)

Start in Report-only mode for high-impact policies before enforcing.

Monitor sign-ins and Conditional Access insights in Azure AD portal and tune policies.