#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ──────────────────────────────────────────────────────────────────
participants_file="$SCRIPT_DIR/participants.txt"
admin_kubeconfig="$SCRIPT_DIR/../admin/workshop-kub_kubeconfig.yaml"
participants_dir="$SCRIPT_DIR/../participants"
names=()
token_duration_hours=24
load_balancer_ip=""
lb_namespace="ingress-nginx"
terraform_dir="$SCRIPT_DIR/../terraform"
skip_scale=false

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --participants-file)    participants_file="$2";        shift 2 ;;
    --admin-kubeconfig)     admin_kubeconfig="$2";         shift 2 ;;
    --participants-dir)     participants_dir="$2";         shift 2 ;;
    --names)                IFS=',' read -ra names <<< "$2"; shift 2 ;;
    --token-duration-hours) token_duration_hours="$2";    shift 2 ;;
    --load-balancer-ip)     load_balancer_ip="$2";        shift 2 ;;
    --lb-namespace)         lb_namespace="$2";            shift 2 ;;
    --terraform-dir)        terraform_dir="$2";           shift 2 ;;
    --skip-scale)           skip_scale=true;              shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ── helpers ───────────────────────────────────────────────────────────────────
get_safe_name() {
  echo "$1" \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/^-*//;s/-*$//'
}

get_names_from_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "Could not find participants file at '$path'." >&2
    exit 1
  fi
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    echo "$line"
  done < "$path"
}

# ── resolve participants ───────────────────────────────────────────────────────
raw_names=()
if [[ ${#names[@]} -gt 0 ]]; then
  raw_names=("${names[@]}")
else
  while IFS= read -r name; do
    raw_names+=("$name")
  done < <(get_names_from_file "$participants_file")
fi

normalized=()
for name in "${raw_names[@]}"; do
  safe="$(get_safe_name "$name")"
  [[ -n "$safe" ]] && normalized+=("$safe")
done

# Deduplicate and sort
IFS=$'\n' normalized=($(printf '%s\n' "${normalized[@]}" | sort -u))
unset IFS

if [[ ${#normalized[@]} -eq 0 ]]; then
  echo "No valid participant names were found." >&2
  exit 1
fi

# ── scale cluster ─────────────────────────────────────────────────────────────
if [[ "$skip_scale" == true ]]; then
  echo "Skipping cluster scaling (--skip-scale specified)."
else
  count=${#normalized[@]}
  required_nodes=$(( count > 2 ? count : 2 ))
  echo "Participants: $count — target node count: $required_nodes"

  tf_dir="$(cd "$terraform_dir" && pwd)"
  if [[ ! -d "$tf_dir/.terraform" ]]; then
    echo "Terraform is not initialised in '$tf_dir'. Run 'terraform init' first." >&2
    exit 1
  fi

  if ! command -v terraform &>/dev/null; then
    echo "terraform is not installed or not in PATH." >&2
    exit 1
  fi

  echo "Running terraform apply to set node_count=$required_nodes ..."
  terraform -chdir="$tf_dir" apply -var "node_count=$required_nodes" -auto-approve

  echo "Waiting for all nodes to be Ready (timeout 10m)..."
  if ! kubectl --kubeconfig "$admin_kubeconfig" wait node --all --for=condition=Ready --timeout=10m; then
    echo "Warning: Not all nodes became Ready within the timeout. Proceeding anyway."
  fi
fi

# ── validate prerequisites ────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
  echo "kubectl is not installed or not in PATH." >&2
  exit 1
fi

if [[ ! -f "$admin_kubeconfig" ]]; then
  echo "Admin kubeconfig not found at '$admin_kubeconfig'." >&2
  exit 1
fi

# ── read cluster info ─────────────────────────────────────────────────────────
cluster_name="$(kubectl --kubeconfig "$admin_kubeconfig" config view --raw -o jsonpath='{.clusters[0].name}')"
api_server="$(kubectl --kubeconfig "$admin_kubeconfig" config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
ca_data="$(kubectl --kubeconfig "$admin_kubeconfig" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

if [[ -z "$cluster_name" || -z "$api_server" || -z "$ca_data" ]]; then
  echo "Could not read cluster information from admin kubeconfig '$admin_kubeconfig'." >&2
  exit 1
fi

# ── resolve LoadBalancer IP ───────────────────────────────────────────────────
if [[ -z "$load_balancer_ip" ]]; then
  echo "Attempting to retrieve LoadBalancer IP from $lb_namespace namespace..."

  lb_ip="$(kubectl --kubeconfig "$admin_kubeconfig" -n "$lb_namespace" get svc \
    -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

  if [[ -z "$lb_ip" ]]; then
    lb_hostname="$(kubectl --kubeconfig "$admin_kubeconfig" -n "$lb_namespace" get svc \
      -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [[ -n "$lb_hostname" ]]; then
      echo "Load balancer returned a hostname ($lb_hostname), resolving to IP..."
      lb_ip="$(dig +short "$lb_hostname" A 2>/dev/null | grep -E '^[0-9]+\.' | head -1 || true)"
      if [[ -n "$lb_ip" ]]; then
        echo "Resolved to IP: $lb_ip"
      else
        echo "Warning: Could not resolve '$lb_hostname' to an IP. README will contain a placeholder."
      fi
    fi
  fi

  if [[ -z "$lb_ip" ]]; then
    echo "Warning: Could not find LoadBalancer IP. README will contain a placeholder."
    load_balancer_ip="<LoadBalancer-IP>"
  else
    load_balancer_ip="$lb_ip"
  fi
fi

# ── provision each participant ────────────────────────────────────────────────
for name in "${normalized[@]}"; do
  namespace="workshop-$name"
  service_account="participant-$name"
  role_name="participant-$name-role"
  legacy_rb="participant-$name-admin"
  legacy_edit_rb="participant-$name-edit"
  role_binding="participant-$name-access"

  echo "Configuring namespace and RBAC for $name ..."

  manifest="apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $service_account
  namespace: $namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $role_name
  namespace: $namespace
rules:
- apiGroups: [\"\"]
  resources: [\"pods\", \"pods/log\", \"services\", \"configmaps\", \"secrets\", \"events\", \"persistentvolumeclaims\"]
  verbs: [\"get\", \"list\", \"watch\", \"create\", \"update\", \"patch\", \"delete\"]
- apiGroups: [\"apps\"]
  resources: [\"deployments\", \"replicasets\", \"statefulsets\", \"daemonsets\"]
  verbs: [\"get\", \"list\", \"watch\", \"create\", \"update\", \"patch\", \"delete\"]
- apiGroups: [\"batch\"]
  resources: [\"jobs\", \"cronjobs\"]
  verbs: [\"get\", \"list\", \"watch\", \"create\", \"update\", \"patch\", \"delete\"]
- apiGroups: [\"networking.k8s.io\"]
  resources: [\"ingresses\", \"networkpolicies\"]
  verbs: [\"get\", \"list\", \"watch\", \"create\", \"update\", \"patch\", \"delete\"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: $role_binding
  namespace: $namespace
subjects:
- kind: ServiceAccount
  name: $service_account
  namespace: $namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: $role_name"

  kubectl --kubeconfig "$admin_kubeconfig" -n "$namespace" \
    delete rolebinding "$legacy_rb" --ignore-not-found > /dev/null
  kubectl --kubeconfig "$admin_kubeconfig" -n "$namespace" \
    delete rolebinding "$legacy_edit_rb" --ignore-not-found > /dev/null
  echo "$manifest" | kubectl --kubeconfig "$admin_kubeconfig" apply -f - > /dev/null

  token="$(kubectl --kubeconfig "$admin_kubeconfig" -n "$namespace" \
    create token "$service_account" --duration="${token_duration_hours}h")"

  if [[ -z "$token" ]]; then
    echo "Failed to create token for participant '$name'." >&2
    exit 1
  fi

  participant_dir="$participants_dir/$name"
  mkdir -p "$participant_dir"

  # Write kubeconfig
  cat > "$participant_dir/kubeconfig.yaml" << KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: $cluster_name
  cluster:
    certificate-authority-data: $ca_data
    server: $api_server
users:
- name: $service_account
  user:
    token: $token
contexts:
- name: $service_account@$cluster_name
  context:
    cluster: $cluster_name
    user: $service_account
    namespace: $namespace
current-context: $service_account@$cluster_name
KUBECONFIG
  echo "Created participant kubeconfig: $participant_dir/kubeconfig.yaml"

  vote_host="$name.workshop.local"
  result_host="$name-result.workshop.local"

  # Write README
  cat > "$participant_dir/README.md" << README
# Workshop: Cat vs Dog Voting App — $name

## Step 1: Add hosts file entries

Add **both** lines below to your hosts file so your browser can reach the app.

**Windows** — open Notepad **as Administrator**, open
\`C:\Windows\System32\drivers\etc\hosts\`, and append:

\`\`\`
$load_balancer_ip  $vote_host
$load_balancer_ip  $result_host
\`\`\`

**Linux / macOS** — run:

\`\`\`bash
echo "$load_balancer_ip  $vote_host"   | sudo tee -a /etc/hosts
echo "$load_balancer_ip  $result_host" | sudo tee -a /etc/hosts
\`\`\`

## Step 2: Set your kubeconfig

**Windows PowerShell:**
\`\`\`powershell
\$env:KUBECONFIG = "\$(Get-Location)\kubeconfig.yaml"
\`\`\`

**macOS / Linux:**
\`\`\`bash
export KUBECONFIG="\$(pwd)/kubeconfig.yaml"
\`\`\`

## Step 3: Deploy the voting app

\`\`\`bash
kubectl apply -f voting_app/
\`\`\`

Wait about 30 seconds for the pods to start.

## Step 4: Open the apps

| What        | URL                          |
|-------------|------------------------------|
| Cast a vote | http://$vote_host   |
| See results | http://$result_host |

## Troubleshooting

\`\`\`bash
kubectl get pods
\`\`\`

All pods should show \`Running\`. If something is stuck, run:

\`\`\`bash
kubectl describe pod <pod-name>
\`\`\`
README
  echo "Created participant README: $participant_dir/README.md"
done

echo ""
echo "Done. Participant access has been provisioned on the shared workshop cluster."
echo "Run distribute-voting-app.sh next to copy the voting app files to each participant directory."
