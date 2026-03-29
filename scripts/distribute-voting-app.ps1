param(
  [string]$ParticipantsFile = (Join-Path $PSScriptRoot "participants.txt"),
  [string]$VotingAppSource  = (Join-Path $PSScriptRoot "../deploy/voting_app"),
  [string]$ParticipantsDir  = (Join-Path $PSScriptRoot "../participants")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── helpers ──────────────────────────────────────────────────────────────────

function Get-SafeName {
  param([string]$Name)
  $lower    = $Name.Trim().ToLowerInvariant()
  $replaced = [System.Text.RegularExpressions.Regex]::Replace($lower, "[^a-z0-9-]", "-")
  return $replaced.Trim("-")
}

function Get-NamesFromFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Could not find participants file at '$Path'."
  }
  $result = @()
  foreach ($line in (Get-Content -LiteralPath $Path)) {
    $trimmed = $line.Trim()
    if ($trimmed -ne "" -and -not $trimmed.StartsWith("#")) {
      $result += $trimmed
    }
  }
  return $result
}

# Patch a service manifest: NodePort → ClusterIP, strip nodePort lines
function Convert-ServiceToClusterIP {
  param([string]$Content)
  $out = $Content -replace '(?m)^\s*type:\s*NodePort\s*$', '  type: ClusterIP'
  $out = $out -replace '(?m)^\s*nodePort:\s*\d+\s*(\r?\n)', ''
  return $out
}

# ── resolve paths ─────────────────────────────────────────────────────────────

$sourcePath = [System.IO.Path]::GetFullPath($VotingAppSource)
if (-not (Test-Path -LiteralPath $sourcePath)) {
  throw "Voting app source directory not found at '$sourcePath'."
}

$participantsPath = [System.IO.Path]::GetFullPath($ParticipantsDir)

# ── load participants ─────────────────────────────────────────────────────────

$rawNames   = Get-NamesFromFile -Path ([System.IO.Path]::GetFullPath($ParticipantsFile))
$normalized = ($rawNames | ForEach-Object { Get-SafeName $_ } | Where-Object { $_ -ne "" } | Sort-Object -Unique)

if ($normalized.Count -eq 0) {
  throw "No valid participant names found in '$TfvarsPath'."
}

Write-Host "Participants: $($normalized -join ', ')"
Write-Host "Source:       $sourcePath"
Write-Host "Output:       $participantsPath"
Write-Host ""

# ── process each participant ──────────────────────────────────────────────────

$sourceFiles = Get-ChildItem -LiteralPath $sourcePath -Filter "*.yaml" | Sort-Object Name

foreach ($name in $normalized) {
  $namespace   = "workshop-$name"
  $voteHost    = "$name.workshop.local"
  $resultHost  = "$name-result.workshop.local"
  $destDir     = Join-Path $participantsPath "$name/voting_app"

  New-Item -ItemType Directory -Path $destDir -Force | Out-Null
  Write-Host "[$name] Writing to $destDir"

  # Copy (and patch) every source file
  foreach ($file in $sourceFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw

    # Patch NodePort services to ClusterIP so ports don't collide across namespaces
    if ($file.Name -in @("vote-service.yaml", "result-service.yaml")) {
      $content = Convert-ServiceToClusterIP -Content $content
      Write-Host "  patched  $($file.Name)  (NodePort -> ClusterIP)"
    } else {
      Write-Host "  copied   $($file.Name)"
    }

    $destFile = Join-Path $destDir $file.Name
    Set-Content -LiteralPath $destFile -Value $content -NoNewline
  }

  # Remove legacy HTTPRoute file if present from a previous run
  $legacyRoutes = Join-Path $destDir "httproutes.yaml"
  if (Test-Path -LiteralPath $legacyRoutes) {
    Remove-Item -LiteralPath $legacyRoutes
    Write-Host "  removed  httproutes.yaml  (replaced by ingress.yaml)"
  }

  # Generate Ingress resources for vote and result frontends
  $ingress = @"
---
# Exposes the vote UI at http://$voteHost
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vote
  namespace: $namespace
spec:
  ingressClassName: nginx
  rules:
  - host: $voteHost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: vote
            port:
              number: 8080

---
# Exposes the result UI at http://$resultHost
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: result
  namespace: $namespace
spec:
  ingressClassName: nginx
  rules:
  - host: $resultHost
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: result
            port:
              number: 8081
"@

  $ingressFile = Join-Path $destDir "ingress.yaml"
  Set-Content -LiteralPath $ingressFile -Value $ingress -NoNewline
  Write-Host "  created  ingress.yaml  ($voteHost + $resultHost)"

  # Update the participant README — preserve the LB address if already set
  $lbPlaceholder = "<LoadBalancer-IP-or-Hostname>"
  $readmePath    = Join-Path $participantsPath "$name/README.md"
  if (Test-Path -LiteralPath $readmePath) {
    $existingReadme = Get-Content -LiteralPath $readmePath -Raw
    $lbMatch = [System.Text.RegularExpressions.Regex]::Match(
      $existingReadme, '(\S+)\s+' + [regex]::Escape($voteHost)
    )
    if ($lbMatch.Success) { $lbPlaceholder = $lbMatch.Groups[1].Value }
  }

  $fence = '```'
  $readme = @"
# Workshop: Cat vs Dog Voting App — $name

## Step 1: Add hosts file entries

Add **both** lines below to your hosts file so your browser can reach the app.

**Windows** — open Notepad **as Administrator**, open
``C:\Windows\System32\drivers\etc\hosts``, and append:

${fence}
$lbPlaceholder  $voteHost
$lbPlaceholder  $resultHost
${fence}

**Linux / macOS** — run:

${fence}bash
echo "$lbPlaceholder  $voteHost"   | sudo tee -a /etc/hosts
echo "$lbPlaceholder  $resultHost" | sudo tee -a /etc/hosts
${fence}

## Step 2: Set your kubeconfig

**Windows PowerShell:**
${fence}powershell
`$env:KUBECONFIG = "`$(Get-Location)\kubeconfig.yaml"
${fence}

**macOS / Linux:**
${fence}bash
export KUBECONFIG="`$(pwd)/kubeconfig.yaml"
${fence}

## Step 3: Deploy the voting app

${fence}bash
kubectl apply -f voting_app/
${fence}

Wait about 30 seconds for the pods to start.

## Step 4: Open the apps

| What        | URL                          |
|-------------|------------------------------|
| Cast a vote | http://$voteHost   |
| See results | http://$resultHost |

## Troubleshooting

${fence}bash
kubectl get pods
${fence}

All pods should show ``Running``. If something is stuck, run:

${fence}bash
kubectl describe pod <pod-name>
${fence}
"@

  Set-Content -LiteralPath $readmePath -Value $readme -NoNewline
  Write-Host "  updated  README.md"
  Write-Host ""
}

Write-Host "Done. Voting app files distributed to all participant directories."
