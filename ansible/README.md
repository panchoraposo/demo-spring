## Ansible bootstrap for Banking Demo

Repeatable post-join installer for the **acm / east / west** topology. It discovers
live cluster domains, rewrites GitOps env values, registers managed clusters in
hub Argo CD, syncs secrets, peers the mesh, and publishes a credentials dashboard.

### Requirements
- `ansible-core` 2.15+
- `oc` logged in with contexts `acm`, `east`, `west`
- `jq`, `curl`, `openssl`, `python3`, `istioctl`
- RHACM hub with ManagedClusters **east** / **west** already joined and Available
- A Git remote reachable by OpenShift GitOps (prefer a **per-environment branch or fork**)

### Run

```bash
cd ansible
cp inventory.example.yml inventory.yml   # edit git_repo_url / git_target_revision
ansible-playbook -i inventory.yml playbooks/install.yml
```

To commit+push the discovered env values automatically (required when Argo reads a remote that still has another sandbox’s hosts):

```bash
ansible-playbook -i inventory.yml playbooks/install.yml -e auto_push_env=true
```

### What it does (order)
1. **preflight** — CLIs, oc contexts, ManagedCluster Available, `istioctl`
2. **configure_environment** — discover apps domains / Conjur / Quay / Thanos; rewrite `*.env`, promxy, Jenkins/Gitea/Conjur hosts, ApplicationSet repo
3. **bootstrap_gitops_hub** — install GitOps if needed, scale hub workers (`hub_capacity`), apply `acm-root`
4. **wait_hub_ready** — Conjur creds + Keycloak Route
5. **label_managedclusters** — `banking-managed` + `banking-demo/role=managed`
6. **register_argocd_clusters** — hub Argo cluster Secrets for east/west
7. **apply_acm_gitops** — Placement + ApplicationSets
8. **wait_hub_ready** — managed-cluster GitOps servers
9. **sync_conjur_creds_to_spokes** — ESO creds + CA to east/west
10. **bootstrap_quay_ci** — org/robot + `banking-ci/quay-ci` when missing
11. **bootstrap_tpa_importers** — enable TPA `osv-github` / `cve` / `redhat-csaf` importers via API
12. **sync_quay_pull_secret** — `banking-apps/quay-pull` on managed clusters
13. **mesh_shared_ca** / **mesh_remote_secrets** / **kiali_remote_secrets**
14. **promxy_tokens** — Thanos reader tokens → Conjur → ESO
15. **postflight** — Kiali Prometheus + sample traffic
16. **dashboard** — credentials page on hub (`namespace/dashboard`)

### Credentials dashboard only

```bash
cd ansible
ansible-playbook -i inventory.example.yml playbooks/dashboard.yml
```

### Still manual / optional
- `scripts/bootstrap-gitea.sh` — Gitea seed (not in acm app-of-apps by default)
- `scripts/apply-console-banners.sh` / `scripts/apply-console-links.sh`
- First Jenkins builds (images) if Quay tags are not yet present
- GitHub/Gitea PAT in Conjur for Jenkins GitOps commits (`scripts/set-conjur-github-pat.sh`)
- Mesh failover: `scripts/demo-mesh-failover.sh` ([docs/mesh-failover.md](../docs/mesh-failover.md))
- Perses dashboards: `scripts/perses-url.sh` ([docs/observability-perses.md](../docs/observability-perses.md))
- SI failover: `scripts/demo-si-failover.sh` ([docs/service-interconnect-failover.md](../docs/service-interconnect-failover.md))
- Autoscaling: `scripts/demo-keda-scale.sh` ([docs/keda-autoscaling.md](../docs/keda-autoscaling.md))

See [docs/multi-cluster.md](../docs/multi-cluster.md).
