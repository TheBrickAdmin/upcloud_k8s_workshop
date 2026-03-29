#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── defaults ──────────────────────────────────────────────────────────────────
participants_file="$SCRIPT_DIR/participants.txt"
voting_app_source="$SCRIPT_DIR/../deploy/voting_app"
participants_dir="$SCRIPT_DIR/../participants"

# ── argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --participants-file)  participants_file="$2";  shift 2 ;;
    --voting-app-source)  voting_app_source="$2";  shift 2 ;;
    --participants-dir)   participants_dir="$2";   shift 2 ;;
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

# Patch a service manifest: NodePort -> ClusterIP, strip nodePort lines
convert_service_to_cluster_ip() {
  local content="$1"
  content="$(echo "$content" | sed -E 's/^([[:space:]]*)type:[[:space:]]*NodePort[[:space:]]*$/\1type: ClusterIP/')"
  content="$(echo "$content" | sed -E '/^[[:space:]]*nodePort:[[:space:]]*[0-9]+[[:space:]]*$/d')"
  echo "$content"
}

# ── resolve paths ─────────────────────────────────────────────────────────────
source_path="$(cd "$voting_app_source" && pwd)"
if [[ ! -d "$source_path" ]]; then
  echo "Voting app source directory not found at '$source_path'." >&2
  exit 1
fi

participants_path="$(mkdir -p "$participants_dir" && cd "$participants_dir" && pwd)"

# ── load participants ─────────────────────────────────────────────────────────
raw_names=()
while IFS= read -r name; do
  raw_names+=("$name")
done < <(get_names_from_file "$participants_file")

normalized=()
for name in "${raw_names[@]}"; do
  safe="$(get_safe_name "$name")"
  [[ -n "$safe" ]] && normalized+=("$safe")
done

IFS=$'\n' normalized=($(printf '%s\n' "${normalized[@]}" | sort -u))
unset IFS

if [[ ${#normalized[@]} -eq 0 ]]; then
  echo "No valid participant names found." >&2
  exit 1
fi

echo "Participants: $(IFS=', '; echo "${normalized[*]}")"
echo "Source:       $source_path"
echo "Output:       $participants_path"
echo ""

# ── process each participant ──────────────────────────────────────────────────
mapfile -t source_files < <(find "$source_path" -maxdepth 1 -name "*.yaml" | sort)

for name in "${normalized[@]}"; do
  namespace="workshop-$name"
  vote_host="$name.workshop.local"
  result_host="$name-result.workshop.local"
  dest_dir="$participants_path/$name/voting_app"

  mkdir -p "$dest_dir"
  echo "[$name] Writing to $dest_dir"

  # Copy (and patch) every source file
  for src_file in "${source_files[@]}"; do
    filename="$(basename "$src_file")"
    content="$(cat "$src_file")"

    if [[ "$filename" == "vote-service.yaml" || "$filename" == "result-service.yaml" ]]; then
      content="$(convert_service_to_cluster_ip "$content")"
      echo "  patched  $filename  (NodePort -> ClusterIP)"
    else
      echo "  copied   $filename"
    fi

    printf '%s' "$content" > "$dest_dir/$filename"
  done

  # Remove legacy HTTPRoute file if present from a previous run
  legacy_routes="$dest_dir/httproutes.yaml"
  if [[ -f "$legacy_routes" ]]; then
    rm "$legacy_routes"
    echo "  removed  httproutes.yaml  (replaced by ingress.yaml)"
  fi

  # Generate Ingress resources for vote and result frontends
  cat > "$dest_dir/ingress.yaml" << INGRESS
---
# Exposes the vote UI at http://$vote_host
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vote
  namespace: $namespace
spec:
  ingressClassName: nginx
  rules:
  - host: $vote_host
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
# Exposes the result UI at http://$result_host
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: result
  namespace: $namespace
spec:
  ingressClassName: nginx
  rules:
  - host: $result_host
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: result
            port:
              number: 8081
INGRESS
  echo "  created  ingress.yaml  ($vote_host + $result_host)"

  # Update the participant README — preserve the LB address if already set
  lb_placeholder="<LoadBalancer-IP-or-Hostname>"
  readme_path="$participants_path/$name/README.md"
  if [[ -f "$readme_path" ]]; then
    existing_lb="$(awk -v host="$vote_host" '$0 ~ host { print $1; exit }' "$readme_path" 2>/dev/null || true)"
    [[ -n "$existing_lb" ]] && lb_placeholder="$existing_lb"
  fi

  cat > "$readme_path" << README
# Workshop: Cat vs Dog Voting App — $name

## Step 1: Add hosts file entries

Add **both** lines below to your hosts file so your browser can reach the app.

**Windows** — open Notepad **as Administrator**, open
\`C:\Windows\System32\drivers\etc\hosts\`, and append:

\`\`\`
$lb_placeholder  $vote_host
$lb_placeholder  $result_host
\`\`\`

**Linux / macOS** — run:

\`\`\`bash
echo "$lb_placeholder  $vote_host"   | sudo tee -a /etc/hosts
echo "$lb_placeholder  $result_host" | sudo tee -a /etc/hosts
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
  echo "  updated  README.md"
  echo ""
done

echo "Done. Voting app files distributed to all participant directories."
