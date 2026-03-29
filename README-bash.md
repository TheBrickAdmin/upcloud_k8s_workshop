# Workshop Setup — Shared UpCloud Cluster (Bash)

> This guide uses **bash** and the `.sh` scripts.
> For PowerShell (Windows), see [README-pwsh.md](README-pwsh.md).

Participants each get their own namespace on a shared Kubernetes cluster.
They deploy the cat vs dog voting app and access it via a shared load balancer
using a hostname unique to them.

Participants receive:
- Their own namespace: `workshop-<name>`
- A kubeconfig scoped to that namespace
- Pre-configured voting app manifests ready to apply

---

## Workspace layout

```
upcloud_k8s_workshop/
├── admin/
│   └── <cluster-name>_kubeconfig.yaml   # Admin kubeconfig — gitignored, download from UpCloud after apply
├── deploy/
│   └── voting_app/                      # Source voting app manifests (input for distribute script)
├── participants/
│   └── <name>/                          # Generated — gitignored, hand out directly
│       ├── kubeconfig.yaml
│       ├── README.md
│       └── voting_app/
├── scripts/
│   ├── distribute-voting-app.ps1        # PowerShell: copies voting app files to participant folders
│   ├── distribute-voting-app.sh         # Bash: copies voting app files to participant folders
│   ├── participants.txt                 # One participant name per line
│   ├── provision-workshop-access.ps1    # PowerShell: creates namespaces, RBAC, kubeconfigs
│   └── provision-workshop-access.sh     # Bash: creates namespaces, RBAC, kubeconfigs
├── terraform/
│   ├── cluster.tf                       # Network, cluster, node group
│   ├── provider.tf
│   ├── terraform.tfvars                 # Your values — gitignored, copy from .example
│   ├── terraform.tfvars.example         # Template — fill in and save as terraform.tfvars
│   └── variables.tf
├── .gitignore
├── README-bash.md
├── README-pwsh.md
└── README.md
```

---

## Step 0: Ensure location

Ensure you are at the root of the `upcloud_k8s_workshop` directory.

---

## Step 1: Add participants

Edit `scripts/participants.txt` — one name per line, `#` for comments:

```
alice
bob
```

---

## Step 2: Create the cluster

### Authenticate with UpCloud

The Terraform provider reads credentials from environment variables.
Create an API token in the [UpCloud control panel](https://hub.upcloud.com) under
**Profile → Account → API tokens**, then set it in your shell:

```bash
export UPCLOUD_TOKEN="your-api-token"
```

### Deploy

Copy the tfvars example and fill in your values:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Then deploy:

```bash
cd terraform
terraform init
terraform plan
terraform apply
cd ..
```

The deployment may take about 10 minutes to complete.

After apply, download the admin kubeconfig from the UpCloud console and place it at
`admin/workshop-kub_kubeconfig.yaml` (or whatever you named your cluster).

Then set it as the active kubeconfig in your shell:

```bash
export KUBECONFIG="$(pwd)/admin/workshop-kub_kubeconfig.yaml"
```

---

## Step 3: Deploy the nginx ingress controller

Apply once after the cluster is ready. This creates a LoadBalancer service that UpCloud provisions with a public IP:

```bash
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml"
```

Wait for the LoadBalancer IP to be assigned (this can take a minute):

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller -w
```

The `EXTERNAL-IP` column should show the load balancer IP. This is the value
participants need to add to their hosts file.

---

## Step 4: Provision participant access

Creates namespaces, RBAC, and kubeconfigs for all participants in `scripts/participants.txt`.
Also scales the cluster node count to match the participant list before provisioning:

```bash
./scripts/provision-workshop-access.sh
```

**Node scaling:** The script sets `node_count` to `max(2, number_of_participants)` via
`terraform apply` — one node per participant so everyone has headroom to experiment beyond
just the voting app. Run it again whenever you add or remove participants.

To skip scaling (e.g. cluster is already correctly sized):

```bash
./scripts/provision-workshop-access.sh --skip-scale
```

Each participant gets:
- Namespace: `workshop-<name>`
- ServiceAccount + Role + RoleBinding (scoped to their namespace)
- `participants/<name>/kubeconfig.yaml` with a short-lived token
- `participants/<name>/README.md` with the correct load balancer IP already filled in

> **Note:** Run this step only after the ingress controller has an external IP (Step 3).
> If you ran it too early and the READMEs contain a placeholder, re-run this script to update them.
>
> **Terraform credentials:** The scaling step requires `UPCLOUD_TOKEN` to be set in your shell
> (same as Step 2).

---

## Step 5: Distribute the voting app

Copies and configures the voting app manifests for each participant:

```bash
./scripts/distribute-voting-app.sh
```

This populates `participants/<name>/voting_app/` with pre-wired deployments, services,
and Ingress resources for both the vote UI and result UI.

---

## Step 6: Hand out participant files

Give each participant only their own folder — never share across participants:

```
participants/<name>/kubeconfig.yaml
participants/<name>/README.md
participants/<name>/voting_app/
```

---

## Organizer checks

Verify namespaces exist:

```bash
kubectl get ns | grep workshop-
```

Verify a participant's permissions (substitute with your provisioned participant names):

```bash
export KUBECONFIG="$(pwd)/participants/rein/kubeconfig.yaml"
kubectl auth can-i create deployment -n workshop-rein   # should be yes
kubectl auth can-i create deployment -n workshop-henk   # should be no
kubectl get pods -A                                      # should be forbidden
```
