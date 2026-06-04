# CLAUDE.md — RGS Carbide Enclave

This file gives Claude Code the context it needs to work effectively in this
repository. Read it fully before touching any file.

---

## Project overview

End-to-end **airgapped** deployment of the RGS Carbide suite (Harvester, RKE2,
Rancher Manager, Harbor, Keycloak) running in an enclave network with an NVIDIA
DGX Spark for AI workload serving. Everything must work with **zero internet
access** on the far side of the airgap boundary.

Companion documentation site lives in
`https://github.com/jradtke-rgs/docs.carbide-enclave.kubernerdes.com` (Docusaurus).

---

## Repository structure

```
infra/
  hauler/          # Hauler content manifests (.yaml) — one per product layer
  packer/          # VM image builds (SL-Micro + RKE2 baked in)
  terraform/       # Harvester VM provisioning via Harvester provider
  <hostname>/      # Per-host config backups (e.g. infra/nuc-00/)
                   # Directory tree mirrors the host filesystem (etc/, srv/, etc.)
                   # Populated by the host backup pull script
platform/
  rke2/            # RKE2 server/agent configs for the mgmt cluster
  rancher/         # Rancher Helm values (airgap-mode)
  cert-manager/    # ClusterIssuer / StepIssuer manifests
  step-ca/         # step-ca bootstrap (systemd unit or Kubernetes pod)
services/
  keycloak/        # Helm values, realm JSON export, OIDC client configs
  harbor/          # Helm values, airgap seeding procedure
  gpu-operator/    # NVIDIA GPU Operator for DGX Spark
  ai-serving/      # vLLM / Ollama deployment + model delivery manifests
scripts/
  env.d/           # Per-environment variables (sourced by all scripts)
  seed.sh          # End-to-end Hauler collect → tarball → load → push
  bootstrap.sh     # Bastion bootstrap (step-ca; HAProxy optional)
docs/              # Inline reference docs; prose lives in the Docusaurus repo
```

---

## Environment & network

| Variable | Value |
|---|---|
| `ENVIRONMENT` | `carbide-enclave` |
| `DOMAIN` | `carbide-enclave.kubernerdes.com` |
| `IP_PREFIX` | `10.0.0` |
| `GATEWAY` | `10.0.0.1` |
| `BASTION_IP` | `10.0.0.10` (nuc-00) |
| `NAS_IP` | `10.0.0.11` |
| `HARVESTER_VIP` | `10.0.0.100` (set when cluster forms) |
| `RANCHER_VIP` | `10.0.0.30` |
| `HARBOR_VIP` | `10.0.0.99` |
| `KEYCLOAK_VIP` | `10.0.0.98` |
| `DGX_IP` | `10.0.0.251` |
| `DHCP_RANGE` | `$IP_PREFIX.172-254` |

All environment-specific values live in `scripts/env.d/carbide-enclave.sh`.
Scripts **source** that file; never hardcode IPs or hostnames elsewhere.

### Hardware (carbide-enclave environment — Gen10 nodes)

| Host | Role | Model | CPU | RAM | NICs |
|---|---|---|---|---|---|
| nuc-00 | Bastion / admin | NUC13ANHi3 | i3-1315U | 32 GB | 1 |
| nuc-01 | Harvester node 1 | NUC10i7FNH | i7-10710U | TBD | 2 |
| nuc-02 | Harvester node 2 | NUC10i7FNH | i7-10710U | TBD | 2 |
| nuc-03 | Harvester node 3 | NUC10i7FNH| i7-10710U | TBD | 2 |
| spark | NVIDIA DGX Spark | GB10 | arm64 | 128 GB | 1 |
| nas | NAS / NFS | ASUS X99 | Xeon E5-2630 v3 | 94 GB | 1 |

**Critical:** The DGX Spark is **arm64 (aarch64)**. Any Hauler manifest, image
tarball, or Helm chart that ships binaries must include multi-arch entries.
Do not assume amd64-only.

---

## Component versions (update here first, scripts inherit)

These are the baseline versions. Pin everything — airgapped environments cannot
tolerate version drift between collect and install.

```bash
# Keep these in sync with scripts/env.d/enclave.sh
RKE2_VERSION="v1.30.13+rke2r1"         # last confirmed multi-arch stable
RANCHER_VERSION="v2.9.x"               # latest Rancher 2.9 at time of seed
HARVESTER_VERSION="v1.3.x"
CERT_MANAGER_VERSION="v1.14.x"
HARBOR_VERSION="2.11.x"
KEYCLOAK_VERSION="24.x"
HAULER_VERSION="v0.4.x"                # or latest from get.hauler.dev
GPU_OPERATOR_VERSION="v24.x"
STEP_CA_VERSION="v0.27.x"
```

---

## Airgap boundary rules

These are hard rules. Violating them produces a repo that works online but
silently breaks in the enclave.

1. **Every image, chart, and binary must flow through Hauler.** No `helm repo
   add` pointing at the internet. No `docker pull` from docker.io. If it isn't
   in the Hauler store, it doesn't exist in the enclave.

2. **Hauler manifests are the source of truth for what enters the enclave.**
   When adding a new component, add its Hauler manifest entry *first*, then
   write the install procedure.

3. **arm64 parity is required for every artifact used by or on the DGX Spark.**
   Add `linux/arm64` platform entries alongside `linux/amd64` in every image
   ref that touches the DGX or the GPU Operator.

4. **TLS everywhere, internal CA only.** step-ca is the root. cert-manager
   issues all certs. No self-signed certs generated ad hoc. No `--tls-skip-verify`
   flags in final configs (acceptable only during initial CA bootstrap).

5. **No hardcoded secrets.** Passwords, tokens, and keys go in
   `scripts/env.d/enclave.sh` (gitignored sensitive section) or in a Kubernetes
   Secret manifest that references an env var. Never commit a real secret.

---

## Bootstrap order (strict — dependencies flow downward)

```
1. Bastion setup
   ├── DNS + DHCP + NTP + Web + TFTP — nuc-00 (done)
   ├── step-ca — internal root CA, ACME server
   └── HAProxy + Keepalived — *(optional; Harvester built-in LB under evaluation)*
       *(RMT removed — Harvester is ISO-based, no external RPM repo needed)*

2. Hauler collect (bastion, while still connected or via sneakernet transfer)
   └── hauler store sync → hauler store save → tarball across airgap boundary

3. Hauler serve (airgap side, on bastion)
   └── hauler store serve registry  (port 5000, firewall already open)

4. Harvester bare-metal install (airgap ISO + config from Hauler fileserver / Apache)
   └── 3-node cluster, Longhorn storage, VM network VLAN

5. RKE2 management cluster (3 VMs provisioned by Terraform via Harvester API)
   ├── SL-Micro guest OS (image built by Packer, uploaded to Harvester)
   └── RKE2 airgap install (image tarballs from Hauler)

6. cert-manager + StepIssuer
   └── wildcard cert for *.enclave.kubernerdes.com

7. Harbor
   ├── Helm install (images from Hauler-served registry)
   ├── TLS cert from cert-manager
   └── Hauler push → Harbor (all images migrate from Hauler ephemeral
       registry to permanent Harbor registry)

8. Keycloak
   ├── Helm install
   ├── Realm import (enclave realm JSON in services/keycloak/)
   └── OIDC clients: rancher, harbor, spark-workloads

9. Rancher Manager
   ├── Helm install (system-default-registry = Harbor)
   ├── OIDC auth → Keycloak
   └── Carbide CSR + Stigatron

10. DGX Spark
    ├── RKE2 agent join (arm64 tarball from Hauler)
    ├── NVIDIA GPU Operator
    └── vLLM / Ollama + model delivery via Harbor OCI artifact

11. Day-2
    ├── Update workflow (re-run Hauler collect → push to Harbor)
    └── Stigatron STIG compliance reporting
```

---

## Coding conventions

### Shell scripts

- **Bash only.** Set `set -euo pipefail` at the top of every script.
- Source the environment file early: `source "$(dirname "$0")/env.d/enclave.sh"`
- Use functions for logical steps; keep `main()` readable as a sequence.
- Print progress with a consistent prefix: `echo "[enclave] step description"`
- Idempotent where possible — scripts should be safe to re-run.
- No `sudo` inside scripts; document the required privilege level in the
  script's header comment and run as root or with explicit sudo at call site.

### Kubernetes manifests / Helm values

- YAML only, no JSON manifests.
- Namespace every resource explicitly — no reliance on `default` namespace.
- Image refs must use the Harbor hostname, not upstream registries:
  `harbor.enclave.kubernerdes.com/library/...`
- Label every resource with at minimum:
  ```yaml
  labels:
    app.kubernetes.io/part-of: carbide-enclave
    app.kubernetes.io/managed-by: helm   # or: kustomize / manual
  ```

### Hauler manifests

- One manifest file per product layer (e.g. `infra/hauler/rke2.yaml`,
  `infra/hauler/rancher.yaml`, `services/hauler/harbor.yaml`).
- Always specify the exact version tag — no `latest`.
- Include both `linux/amd64` and `linux/arm64` platform entries for any image
  that runs on or is managed by the DGX Spark.
- Comment every entry with the consuming component:
  ```yaml
  # cert-manager controller — consumed by platform/cert-manager
  - name: quay.io/jetstack/cert-manager-controller:v1.14.5
  ```

### Terraform (Harvester provider)

- State stored locally in `infra/terraform/<component>/terraform.tfstate` —
  **gitignored**. Document state location in the relevant README.
- Variable defaults live in `terraform.tfvars.example`; actual `terraform.tfvars`
  is gitignored.
- Use `locals {}` to derive hostnames and IPs from the `ip_prefix` variable
  rather than hardcoding.

---

## Key decisions already made

| Decision | Choice | Rationale |
|---|---|---|
| Airgap transport tool | Hauler | RGS-native, OCI + helm + files in one store |
| Container registry | Harbor | Full OCI, OIDC auth, Helm proxy, airgap-friendly |
| Internal CA | step-ca (Smallstep) | ACME support, cert-manager integration, airgap-capable |
| OIDC provider | Keycloak | Self-hostable, covers Rancher + Harbor + DGX workloads |
| Harvester guest OS | SL-Micro | Consistent with Harvester base OS, transactional updates |
| RKE2 CNI | Canal (default) | Sufficient for enclave; Cilium if eBPF needed later |
| AI serving | vLLM (primary) | GPU-native inference server; Ollama as fallback |
| Model registry | Harbor OCI artifact | Keeps models inside the same trust boundary |
| Host config backup layout | `infra/<hostname>/` mirroring filesystem paths | Path = location on host; pull script needs no separate manifest |
| Docs site | Separate repo (Docusaurus) | Different toolchain, audience, and release cadence from infra |
| Docs dev workflow | Edit on MBP → git push → git pull on admin node → run script locally | Git is source of truth; admin node drives its own builds |

---

## Known gaps / open questions

Track these as GitHub Issues. Current list:

- [ ] **HAProxy + Keepalived vs Harvester LB** — Harvester has a built-in load balancer
      (via kube-vip or MetalLB); evaluate whether it can own the service VIPs (.30, .98,
      .99, .100) instead of a dedicated HAProxy VM. Decision gates the nuc-00-03 VM build.
- [ ] **SL-Micro Packer pipeline** — build SL-Micro VM image with RKE2 baked
      in and upload to Harvester. Ubuntu Packer approach (community) needs
      porting to SL-Micro.
- [x] **RMT** — not needed; Harvester ships as a self-contained ISO, and
      Hauler + Harbor is the artifact pipeline for everything else.
- [ ] **DGX Spark join method** — decision pending: managed RKE2 agent node
      (integrates with Rancher RBAC) vs standalone K3s (simpler bootstrap).
      Leaning toward RKE2 agent.
- [ ] **arm64 Hauler manifests** — GPU Operator, vLLM, and all DGX-side images
      need explicit arm64 platform entries. Not yet written.
- [ ] **Keycloak realm design** — groups/roles mapping to Rancher cluster roles
      not yet defined. Needs coordination with RBAC requirements.
- [ ] **Model airgap delivery** — LLM weights (potentially 4–70 GB per model)
      need a transfer plan. Hauler `FileContent` or OCI artifact push to Harbor.
      Logistics TBD.
- [ ] **Harvester VIP / network topology** — second NIC on each node is for VM
      traffic. VLAN config and Harvester network attachment not yet scripted.

---

## Useful references

| Resource | URL |
|---|---|
| Hauler docs | https://hauler.dev |
| RKE2 airgap install | https://docs.rke2.io/install/airgap |
| Harvester docs | https://docs.harvesterhci.io |
| Rancher airgap install | https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/other-installation-methods/air-gapped-helm-cli-install |
| step-ca docs | https://smallstep.com/docs/step-ca |
| Harbor airgap | https://goharbor.io/docs/latest/install-config/download-installer |
| RGS rancher-airgap repo | https://github.com/zackbradys/rancher-airgap |
| RGS airgap blog | https://ranchergovernment.com/blog/airgapping-made-easy-with-rke2-and-rancher |
| Hardware inventory | https://github.com/jradtke-rgs/homelab.kubernerdes.com/blob/main/Hardware.md |
| Docs repo | https://github.com/jradtke-rgs/docs.carbide-enclave.kubernerdes.com |

---

## What to do first

If you are starting with an empty repo, do these in order:

1. Create `scripts/env.d/enclave.sh` with all variables from the table above.
2. Create `infra/hauler/` and write the first Hauler manifest covering RKE2
   and cert-manager (the two earliest platform dependencies).
3. Create `scripts/bootstrap.sh` with the bastion setup sequence (step-ca, DNS,
   HAProxy, RMT).
4. Open a GitHub Issue for each item in the "Known gaps" section above.

Everything else flows from those three files.
