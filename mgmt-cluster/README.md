# NKP Management Cluster — Air-Gapped Deployment

End-to-end automation for deploying an NKP 2.17 management cluster on Nutanix AHV in air-gapped mode, including Kommander installation and Day 2 configuration (S3 storage, monitoring, Harbor, CNPG backups, RBAC, SSO).

## Prerequisites

- Jump host with Docker (or Podman), `jq`, `curl`, Python 3
- NKP CLI installed (`tools/install-all.sh` + `tools/0_get-nkp-cli`)
- NKP Rocky Linux/Ubuntu Pro image uploaded to Prism Central
- Private OCI registry (Harbor) with a project created (e.g. `/nkp`)
- Network: control plane VIP + MetalLB IPs free, PE/PC reachable from jump host

## Workflow

```
Phase 1 — Bootstrap
  0_push-airgap-bundle.sh    Push images to private registry
  1_preflight.sh             Validate everything before deploy

Phase 2 — Cluster
  2_deploy.sh                Create the NKP cluster (nkp create cluster nutanix)

Phase 3 — Platform
  3_mark-deployed-default-apps.sh Mark DefaultApps as deployed before applying license
  4_install-kommander.sh          Install Kommander
  5_healthcheck.sh                Validate cluster health

Phase 4 — Storage & Observability (day2/ manifests via kapply)
  day2/00-license.yaml             NKP license
  day2/01-objects-secrets.yaml     Loki + Velero S3 credentials
  day2/02-cosi-secret.yaml         COSI driver for Nutanix Objects
  day2/60-insights-storage.yaml    NKP Insights → Nutanix Objects (COSI)
  day2/61-thanos-objstore.yaml     Thanos → Nutanix Objects (S3)
  day2/62-harbor-s3-cnpg.yaml      Harbor → COSI + CNPG backups → S3
```

---

## Quick Start

```bash
cd mgmt-cluster

# 1. Generate config.json file
python3 configure.py 

# 2. Push & validate
./0_push-airgap-bundle.sh
./1_preflight.sh

# 3. Deploy cluster
./2_deploy.sh

# 4. Pre-install secrets (before Kommander)
source ../helpers.sh
kapply day2/01-objects-secrets.yaml OBJECTS_ACCESS_KEY="..." OBJECTS_SECRET_KEY="..."
kapply day2/02-cosi-secret.yaml PC_ENDPOINT="..." ...

# 5. Prepare kommander.yaml manually
cp kommander.yaml.example kommander.yaml
vi kommander.yaml                             # edit for your environment

# 6. Mark default apps + install Kommander
./3_mark-deployed-default-apps.sh             # prevents Rook Ceph zombie apps
./4_install-kommander.sh                      # run ONCE only

# 7. Post-install: license + Day 2 manifests
kapply day2/00-license.yaml NKP_LICENSE="..."
./5_healthcheck.sh
```
---

## Scripts

### Phase 1 : Bootstrap

### `configure.py` -> Interactive config wizard

Connects to Prism Central v4 API, lists PE clusters, subnets, images, storage containers and generates `config.json`.

```bash
python3 configure.py

# Non-interactive:
PC_URL=https://10.12.54.8:9440 PC_USER=admin PC_PASS=... python3 configure.py
```

If `config.json` already exists, previous values are used as defaults.

<details>
<summary>Example output</summary>

```
Connecting to Prism Central at https://10.12.54.8:9440 ...
  API version: v4.0.b2
  PE clusters found: 2
    1) Thor-PE       (extId: 000612f7-...)
    2) Lab-PE        (extId: 000583c1-...)
  Select PE cluster [1]: 1
  Subnets found on Thor-PE: 1
    1) VLAN54-Mgmt
  ...
config.json written successfully.
```

</details>

### `0_push-airgap-bundle.sh` —> Push air-gap bundles to registry

Reads `config.json`, validates registry connectivity, pushes all image bundles and loads the bootstrap image into local Docker.

```bash
./0_push-airgap-bundle.sh                    # uses default bundle dir
./0_push-airgap-bundle.sh /path/to/bundles   # custom bundle path
```

Pushes: `konvoy-image-bundle`, `kommander-image-bundle`, loads `konvoy-bootstrap-image` locally.

<details>
<summary>Example output</summary>

```
══════════════════════════════════════════════════════════
  Loading config
══════════════════════════════════════════════════════════
  [OK]   Deployment type: airgap
  [OK]   Registry URL: https://thor.itcs.local:5000/nkp
  [INFO]   Host: thor.itcs.local:5000  Path: /nkp  Scheme: https

══════════════════════════════════════════════════════════
  Registry connectivity
══════════════════════════════════════════════════════════
  [OK]   Registry reachable at https://thor.itcs.local:5000/v2/ (HTTP 401)
  [OK]   Registry authentication successful

══════════════════════════════════════════════════════════
  Locating bundles
══════════════════════════════════════════════════════════
  [INFO] Found versioned subdirectory: nkp-v2.17.0
  [OK]   Image bundle: konvoy-image-bundle-v2.17.0.tar (6.2G)
  [OK]   Image bundle: kommander-image-bundle-v2.17.0.tar (9.1G)
  [WARN] No chart bundles (*-charts-bundle*.tar.gz) found — skipping chart push

══════════════════════════════════════════════════════════
  1/3 — Pushing konvoy-image-bundle-v2.17.0.tar
══════════════════════════════════════════════════════════
  [INFO] This may take 10-30 minutes depending on bundle size...
  [OK]   konvoy-image-bundle-v2.17.0.tar pushed successfully

══════════════════════════════════════════════════════════
  Complete
══════════════════════════════════════════════════════════
  All bundles pushed to https://thor.itcs.local:5000/nkp
```

</details>

### `1_preflight.sh` —> Pre-flight validation

Validates tools, config values, network connectivity, Nutanix API (PE, subnet, image, storage), registry access, and proxy settings. Fix all `[FAIL]` before deploying.

```bash
./1_preflight.sh
```

Checks: Docker, nkp CLI, kubectl, jq, helm, config.json fields, PC/PE API, VIP availability, DNS, NTP, registry auth.

<details>
<summary>Example output</summary>

```
══════════════════════════════════════════════════════════
  1. Bootstrap Host Checks
══════════════════════════════════════════════════════════
  [PASS] docker: Docker version 27.5.1
  [PASS] nkp: v2.17.0
  [PASS] kubectl: v1.34.0
  [PASS] jq: jq-1.7
  [PASS] helm: v3.17.3

══════════════════════════════════════════════════════════
  2. Configuration Validation
══════════════════════════════════════════════════════════
  [PASS] Deployment type: airgap
  [PASS] Cluster name: lab-itcs-nkp-mgmt
  [PASS] Control plane count: 3 (odd)
  [PASS] Worker count: 4
  [PASS] Control plane VIP: 10.12.54.200
  [PASS] MetalLB IP range: 10.12.54.201-10.12.54.210

══════════════════════════════════════════════════════════
  4. Nutanix API Validation
══════════════════════════════════════════════════════════
  [PASS] Prism Central authentication successful
  [PASS] PE cluster 'Thor-PE' found (extId: 000612f7-...)
  [PASS] Subnet 'VLAN54-Mgmt' found (extId: ab3f1c5e-...)
  [PASS] CP image 'nkp-rocky-9.5-release-...' found
  [PASS] Storage container 'SelfServiceContainer' found

══════════════════════════════════════════════════════════
  Summary
══════════════════════════════════════════════════════════
  Passed: 22
  Warnings: 1
  Failed: 0

  All checks passed — ready to deploy!
```

</details>

### Phase 2 —> Cluster

### `2_deploy.sh` —> Deploy the NKP cluster

Reads `config.json` and runs `nkp create cluster nutanix` with all flags. Passwords are prompted at runtime or read from env vars.

```bash
./2_deploy.sh                # interactive
./2_deploy.sh --verbose      # show nkp output
```

Produces `${CLUSTER_NAME}.conf` kubeconfig on success.

<details>
<summary>Example output</summary>

```
══════════════════════════════════════════════════════════
  Auth pre-checks
══════════════════════════════════════════════════════════
  [OK]   Prism Central: admin@10.12.54.8 (HTTP 200)

══════════════════════════════════════════════════════════
  Deployment summary
══════════════════════════════════════════════════════════
  Cluster:      lab-itcs-nkp-mgmt
  Type:         airgap
  NKP version:  v2.17.0

  Nutanix:
    PC:         10.12.54.8:9440 (user: admin)
    PE:         Thor-PE
    Subnet:     VLAN54-Mgmt
    Storage:    SelfServiceContainer

  Nodes:
    CP:         3x (8 vCPU / 16 GB)
    Workers:    4x (16 vCPU / 32 GB)

  Deploy cluster? [Y/n]: Y

══════════════════════════════════════════════════════════
  Deploying lab-itcs-nkp-mgmt
══════════════════════════════════════════════════════════
  [INFO] Starting nkp create cluster nutanix...
  [INFO] This will take 20-45 minutes. Use tmux to avoid losing the session.
  ...
  [OK]   Cluster created successfully
  [OK]   Kubeconfig: lab-itcs-nkp-mgmt.conf
```

</details>

### Phase 3 —> Platform

### `kommander.yaml` —> Manual preparation

Generate `kommander.yaml` from the annotated template and edit for your environment. This is NOT automated — review every section.

```bash
cp kommander.yaml.example kommander.yaml
vi kommander.yaml
```

See `kommander.yaml.example` for full documentation of all fields (S3 endpoints, registry, disabled apps, etc.).

### `3_mark-deployed-default-apps.sh` — Mark DefaultApps as deployed

Annotates the KommanderCluster resource to prevent the License Controller from re-installing default apps (Rook Ceph) when the Ultimate license is applied. **Must run BEFORE applying the license.**

```bash
./3_mark-deployed-default-apps.sh
```
### `4_install-kommander.sh` —> Install Kommander

Uses the manually prepared `kommander.yaml` and installs Kommander.

```bash
./4_install-kommander.sh                    # interactive
./4_install-kommander.sh --skip-wait        # don't wait for HelmReleases
./4_install-kommander.sh -v                 # verbose
```

<details>
<summary>Example output</summary>

```
══════════════════════════════════════════════════════════
  Loading config
══════════════════════════════════════════════════════════
  [OK]   Config loaded: lab-itcs-nkp-mgmt (airgap)

══════════════════════════════════════════════════════════
  Kubeconfig
══════════════════════════════════════════════════════════
  [OK]   KUBECONFIG=lab-itcs-nkp-mgmt.conf
  [OK]   Cluster is reachable

══════════════════════════════════════════════════════════
  Locating air-gapped bundles
══════════════════════════════════════════════════════════
  [OK]   Applications repo: kommander-applications-v2.17.0.tar.gz

══════════════════════════════════════════════════════════
  Install summary
══════════════════════════════════════════════════════════
  Cluster:     lab-itcs-nkp-mgmt
  Type:        airgap
  Config:      kommander.yaml
  Apps repo:   kommander-applications-v2.17.0.tar.gz

  Install Kommander? [Y/n]: Y

══════════════════════════════════════════════════════════
  Installing Kommander
══════════════════════════════════════════════════════════
  [INFO] This will take 10-30 minutes. Use tmux to avoid losing the session.
  ...
  [OK]   nkp install kommander completed

══════════════════════════════════════════════════════════
  Kommander installed
══════════════════════════════════════════════════════════
  Dashboard: https://thor.itcs.local/dkp/kommander/dashboard
  Username:  goofy-dog
  Password:  ****
```

</details>

### `5_healthcheck.sh` —> Health check

Validates cluster health: nodes, pods, CAPI, CSI, networking, HelmReleases, certs, platform apps.

```bash
./5_healthcheck.sh                 # standard checks
./5_healthcheck.sh --full          # include pod-level detail
./5_healthcheck.sh --watch         # re-run every 30s
```

<details>
<summary>Example output</summary>

```
══════════════════════════════════════════════════════════
  2. Versions
══════════════════════════════════════════════════════════
  [INFO] Kubernetes server: v1.34.0
  [INFO] NKP CLI:           v2.17.0
  [INFO] CAPI:              v1.10.7
  [INFO] CAPX:              v1.8.3
  [INFO] Cilium:            v1.17.4
  [INFO] Nutanix CSI:       v3.6.0

══════════════════════════════════════════════════════════
  3. Node Status
══════════════════════════════════════════════════════════
  [OK]   All 7 nodes Ready
  [OK]   No resource pressure on any node

══════════════════════════════════════════════════════════
  9. HelmReleases
══════════════════════════════════════════════════════════
  [OK]   All 50 HelmReleases Ready

══════════════════════════════════════════════════════════
  Health Check Summary
══════════════════════════════════════════════════════════
  Cluster:   lab-itcs-nkp-mgmt (thor.itcs.local)
  K8s:       v1.34.0
  NKP:       v2.17.0
  Nodes:     7/7 Ready

  PASS: 28  WARN: 0  FAIL: 0

  Status: HEALTHY
```

</details>

### Helpers

| File | Description |
|------|-------------|
| `../helpers.sh` | Provides `kapply` function  `envsubst` + `kubectl apply` for templated YAML |
| `apply.sh` | Standalone version of `kapply` (same functionality) |
| `kommander.yaml.example` | Full annotated Installation CR template for air-gapped Ultimate on Nutanix. copy to `kommander.yaml` and edit |

---

## Day 2 Manifests

All declarative YAML in `day2/`, applied via `kapply` (source `helpers.sh` first).

| File | Purpose | Variables | Status |
|------|---------|-----------|--------|
| `00-license.yaml` | NKP Ultimate license | `NKP_LICENSE` | Done |
| `01-objects-secrets.yaml` | Loki + Velero S3 credentials | `OBJECTS_ACCESS_KEY`, `OBJECTS_SECRET_KEY` | Done |
| `02-cosi-secret.yaml` | COSI driver for Nutanix Objects | `PC_ENDPOINT`, `PC_PORT`, `PC_USER`, `PC_PASS`, `OBJECTS_ENDPOINT`, `OBJECTS_ACCESS_KEY`, `OBJECTS_SECRET_KEY` | Done |
| `10-gitlab-connector.yaml` | Dex GitLab OIDC connector | `GITLAB_APP_ID`, `GITLAB_CLIENT_SECRET` | TODO |
| `11-local-users.yaml` | Dex static local users | `ADMIN_BCRYPT_HASH`, `DEMO_BCRYPT_HASH` | TODO |
| `20-rbac.yaml` | ClusterRoleBindings | (none) | TODO |
| `60-insights-storage.yaml` | NKP Insights → Nutanix Objects (COSI) | `INSIGHTS_BUCKET` | Done |
| `61-thanos-objstore.yaml` | Thanos long-term metrics → S3 | `THANOS_BUCKET`, `OBJECTS_ACCESS_KEY`, `OBJECTS_SECRET_KEY` | Done |
| `62-harbor-s3-cnpg.yaml` | Harbor S3 via COSI + CNPG backups | `OBJECTS_ACCESS_KEY`, `OBJECTS_SECRET_KEY` | Done |

---

## S3 Storage Architecture

All persistent storage backends use **Nutanix Objects** (S3-compatible) instead of Rook Ceph.

```
Nutanix Objects (FS-OBJECT.itcs.local)
  ├── nkp-loki        ← Loki logs          (manual secret)
  ├── nkp-velero      ← Velero backups     (manual secret)
  ├── nkp-insight     ← NKP Insights       (COSI auto-managed)
  ├── nkp-thanos      ← Prometheus metrics  (manual secret)
  ├── nkp-harbor      ← Harbor registry    (COSI auto-provisioned)
  └── nkp-cnpg        ← CNPG DB backups    (manual secret)
```

COSI (Container Object Storage Interface) manages bucket provisioning and credentials for Insights and Harbor. Manual secrets are used where COSI is not supported (Loki, Velero, Thanos, CNPG).

---

## Findings & Gotchas

<details>
<summary>Expand all findings</summary>

| Finding | Detail |
|---------|--------|
| **Objects S3 style** | Virtual-hosted: `https://<bucket>.FS-OBJECT.itcs.local`. Base domain has NO HTTPS. |
| **Loki secret name** | MUST be `dkp-loki` NKP defaults hardcode `extraEnvFrom: dkp-loki` on all Loki components. |
| **Loki region** | Must set `region: us-east-1` explicitly SDK auto-detection causes `IllegalLocationConstraintException`. |
| **Rook Ceph "zombie app"** | `enabled: false` in kommander.yaml is NOT enough. License Controller re-installs default apps for Pro/Ultimate. Must annotate KommanderCluster + delete AppDeployments + remove CephCluster/CephObjectStore CRs + clear finalizers. |
| **COSI existing bucket** | COSI BucketAccess creates a new IAM user on Nutanix Objects and replaces the bucket's access policy, removing the original user. |
| **NKP Insights AppDeployment** | Auto-created by Kommander for Ultimate license. Only need the `nkp-insights-overrides` ConfigMap. |
| **CNPG minimal image** | NKP bundles `postgresql:17.5-minimal-bookworm` (no barman-cloud). Must push full `17.5-bookworm` to Harbor project for CNPG backups. |
| **CNPG chart v0.3.1** | Does NOT accept raw `barmanObjectStore` spec. Uses `backups.provider`/`backups.endpointURL`/`backups.destinationPath`. Encryption defaults AES256 — set to `""` for Nutanix Objects. |
| **cosi-bucket-kit chart** | When `cosiBucketKit.enabled: true`, MUST provide `bucketClaims` and `bucketAccesses` arrays. nil causes Go template panic. |

</details>

---

## Environment Variables

| Variable | Used by | Description |
|----------|---------|-------------|
| `PC_URL` | configure.py | Prism Central URL |
| `PC_USER` | configure.py | Prism Central username |
| `PC_PASS` | configure.py | Prism Central password |
| `NUTANIX_PASSWORD` | 1_preflight.sh, 2_deploy.sh | PC password |
| `REGISTRY_PASSWORD` | 0_push-airgap-bundle.sh, 1_preflight.sh | Registry password |
| `NKP_LICENSE` | 4_configure.sh | NKP license key |
| `OBJECTS_ACCESS_KEY` | day2/ manifests | Nutanix Objects S3 access key |
| `OBJECTS_SECRET_KEY` | day2/ manifests | Nutanix Objects S3 secret key |

See `.env.example` for the full list.

---