param(
  [string]$ParticipantsFile      = (Join-Path $PSScriptRoot "participants.txt"),
  [string]$AdminKubeconfigPath   = (Join-Path $PSScriptRoot "../admin/workshop-kub_kubeconfig.yaml"),
  [string]$ParticipantsDir       = (Join-Path $PSScriptRoot "../participants"),
  [string[]]$Names,
  [int]$TokenDurationHours       = 24,
  [string]$LoadBalancerIP        = "",
  [string]$LoadBalancerNamespace = "ingress-nginx",
  [string]$TerraformDir          = (Join-Path $PSScriptRoot "../terraform"),
  [switch]$SkipScale
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SafeName {
  param([Parameter(Mandatory = $true)][string]$Name)

  $lower = $Name.Trim().ToLowerInvariant()
  $replaced = [System.Text.RegularExpressions.Regex]::Replace($lower, "[^a-z0-9-]", "-")
  return $replaced.Trim("-")
}

function Get-NamesFromFile {
  param([Parameter(Mandatory = $true)][string]$Path)

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

function New-ParticipantKubeconfig {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$ApiServer,
    [Parameter(Mandatory = $true)][string]$CaData,
    [Parameter(Mandatory = $true)][string]$UserName,
    [Parameter(Mandatory = $true)][string]$Namespace,
    [Parameter(Mandatory = $true)][string]$Token
  )

  $kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
- name: $ClusterName
  cluster:
    certificate-authority-data: $CaData
    server: $ApiServer
users:
- name: $UserName
  user:
    token: $Token
contexts:
- name: $UserName@$ClusterName
  context:
    cluster: $ClusterName
    user: $UserName
    namespace: $Namespace
current-context: $UserName@$ClusterName
"@

  Set-Content -LiteralPath $Path -Value $kubeconfig -NoNewline
}

function New-ParticipantReadme {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ParticipantName,
    [Parameter(Mandatory = $true)][string]$LoadBalancerIP
  )

  $voteHost   = "$ParticipantName.workshop.local"
  $resultHost = "$ParticipantName-result.workshop.local"
  $fence = '```'

  $readme = @"
# Workshop: Cat vs Dog Voting App — $ParticipantName

## Step 1: Add hosts file entries

Add **both** lines below to your hosts file so your browser can reach the app.

**Windows** — open Notepad **as Administrator**, open
``C:\Windows\System32\drivers\etc\hosts``, and append:

${fence}
$LoadBalancerIP  $voteHost
$LoadBalancerIP  $resultHost
${fence}

**Linux / macOS** — run:

${fence}bash
echo "$LoadBalancerIP  $voteHost"   | sudo tee -a /etc/hosts
echo "$LoadBalancerIP  $resultHost" | sudo tee -a /etc/hosts
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

  Set-Content -LiteralPath $Path -Value $readme -NoNewline
}


if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  throw "kubectl is not installed or not in PATH."
}

if (-not (Test-Path -LiteralPath $AdminKubeconfigPath)) {
  throw "Admin kubeconfig not found at '$AdminKubeconfigPath'."
}

$participantNames = @()
if ($Names -and $Names.Count -gt 0) {
  $participantNames = $Names
} else {
  $participantNames = Get-NamesFromFile -Path $ParticipantsFile
}

$normalized = @()
foreach ($participant in $participantNames) {
  $safeName = Get-SafeName -Name $participant
  if (-not [string]::IsNullOrWhiteSpace($safeName)) {
    $normalized += $safeName
  }
}

$normalized = $normalized | Sort-Object -Unique
if ($normalized.Count -eq 0) {
  throw "No valid participant names were found."
}

# Scale cluster nodes to match participant count.
# Formula: 1 node per participant, minimum 2.
# This gives each participant a full node's worth of headroom for experimentation.
if ($SkipScale) {
  Write-Host "Skipping cluster scaling (-SkipScale specified)."
} else {
  $requiredNodes = [Math]::Max(2, $normalized.Count)
  Write-Host "Participants: $($normalized.Count) — target node count: $requiredNodes"

  $tfDir = Resolve-Path $TerraformDir
  if (-not (Test-Path -LiteralPath (Join-Path $tfDir ".terraform"))) {
    throw "Terraform is not initialised in '$tfDir'. Run 'terraform init' first."
  }

  if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "terraform is not installed or not in PATH."
  }

  Write-Host "Running terraform apply to set node_count=$requiredNodes ..."
  & terraform "-chdir=$tfDir" apply -var "node_count=$requiredNodes" -auto-approve
  if ($LASTEXITCODE -ne 0) {
    throw "Terraform apply failed while scaling to $requiredNodes nodes."
  }

  Write-Host "Waiting for all nodes to be Ready (timeout 10m)..."
  & kubectl --kubeconfig $AdminKubeconfigPath wait node --all --for=condition=Ready --timeout=10m
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Warning: Not all nodes became Ready within the timeout. Proceeding anyway."
  }
}

$clusterName = (& kubectl --kubeconfig $AdminKubeconfigPath config view --raw -o jsonpath='{.clusters[0].name}')
$apiServer = (& kubectl --kubeconfig $AdminKubeconfigPath config view --raw -o jsonpath='{.clusters[0].cluster.server}')
$caData = (& kubectl --kubeconfig $AdminKubeconfigPath config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

if ([string]::IsNullOrWhiteSpace($clusterName) -or [string]::IsNullOrWhiteSpace($apiServer) -or [string]::IsNullOrWhiteSpace($caData)) {
  throw "Could not read cluster information from admin kubeconfig '$AdminKubeconfigPath'."
}

# Get LoadBalancer IP if not provided
if ([string]::IsNullOrWhiteSpace($LoadBalancerIP)) {
  Write-Host "Attempting to retrieve LoadBalancer IP from $LoadBalancerNamespace namespace..."

  $lbIP = (& kubectl --kubeconfig $AdminKubeconfigPath -n $LoadBalancerNamespace get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>$null)

  if ([string]::IsNullOrWhiteSpace($lbIP)) {
    $lbHostname = (& kubectl --kubeconfig $AdminKubeconfigPath -n $LoadBalancerNamespace get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>$null)

    if (-not [string]::IsNullOrWhiteSpace($lbHostname)) {
      Write-Host "Load balancer returned a hostname ($lbHostname), resolving to IP..."
      $resolved = [System.Net.Dns]::GetHostAddresses($lbHostname) |
                  Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                  Select-Object -First 1
      if ($resolved) {
        $lbIP = $resolved.IPAddressToString
        Write-Host "Resolved to IP: $lbIP"
      } else {
        Write-Host "Warning: Could not resolve '$lbHostname' to an IP. README will contain a placeholder."
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($lbIP)) {
    Write-Host "Warning: Could not find LoadBalancer IP. README will contain a placeholder."
    $LoadBalancerIP = "<LoadBalancer-IP>"
  } else {
    $LoadBalancerIP = $lbIP
  }
}


foreach ($name in $normalized) {
  $namespace = "workshop-$name"
  $serviceAccount = "participant-$name"
  $roleName = "participant-$name-role"
  $legacyRoleBinding = "participant-$name-admin"
  $legacyEditRoleBinding = "participant-$name-edit"
  $roleBinding = "participant-$name-access"

  Write-Host "Configuring namespace and RBAC for $name ..."

  $manifest = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $serviceAccount
  namespace: $namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $roleName
  namespace: $namespace
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services", "configmaps", "secrets", "events", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $roleBinding
  namespace: $namespace
subjects:
- kind: ServiceAccount
  name: $serviceAccount
  namespace: $namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $roleName
"@

  & kubectl --kubeconfig $AdminKubeconfigPath -n $namespace delete rolebinding $legacyRoleBinding --ignore-not-found | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed deleting legacy rolebinding '$legacyRoleBinding' for participant '$name'."
  }

  & kubectl --kubeconfig $AdminKubeconfigPath -n $namespace delete rolebinding $legacyEditRoleBinding --ignore-not-found | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed deleting legacy rolebinding '$legacyEditRoleBinding' for participant '$name'."
  }

  $manifest | kubectl --kubeconfig $AdminKubeconfigPath apply -f - | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed applying namespace/RBAC manifest for participant '$name'."
  }

  $token = (& kubectl --kubeconfig $AdminKubeconfigPath -n $namespace create token $serviceAccount --duration="$($TokenDurationHours)h")
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to create token for participant '$name'."
  }
  if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Failed to create token for participant '$name'."
  }

  $participantDir = Join-Path $ParticipantsDir $name
  New-Item -ItemType Directory -Path $participantDir -Force | Out-Null

  $kubeconfigPath = Join-Path $participantDir "kubeconfig.yaml"
  New-ParticipantKubeconfig -Path $kubeconfigPath -ClusterName $clusterName -ApiServer $apiServer -CaData $caData -UserName $serviceAccount -Namespace $namespace -Token $token
  Write-Host "Created participant kubeconfig: $kubeconfigPath"

  $readmePath = Join-Path $participantDir "README.md"
  New-ParticipantReadme -Path $readmePath -ParticipantName $name -LoadBalancerIP $LoadBalancerIP
  Write-Host "Created participant README: $readmePath"
}

Write-Host ""
Write-Host "Done. Participant access has been provisioned on the shared workshop cluster."
Write-Host "Run distribute-voting-app.ps1 next to copy the voting app files to each participant directory."
