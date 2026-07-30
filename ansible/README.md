## Ansible bootstrap (minimal) for Banking Demo

This directory contains a **minimal bootstrap** playbook intended to make the demo
repeatable across environments similar to the current topology:

- `acm` (hub): GitOps root app, Conjur/ESO hub, Kiali MC, promxy
- `east` / `west` (managed clusters): operators, ESO, mesh, apps

### Requirements
- `ansible-core` 2.15+
- `oc` CLI logged in to all clusters and contexts configured (`acm`, `east`, `west`)
- `jq`, `curl`, `openssl`

### Run

```bash
cd ansible
ansible-playbook -i inventory.example.yml playbooks/install.yml
```

### What it does
- Applies the hub root GitOps app (`gitops/bootstrap/acm-root.yaml` template).
- Labels ManagedClusters and applies Placement/ApplicationSets (`gitops/acm`).
- Syncs Conjur ESO creds + CA from hub to managed clusters.
- Installs shared mesh `cacerts` and exchanges mesh remote secrets.
- Creates hub Kiali remote kubeconfig secrets and stores promxy upstream tokens in Conjur.
- Publishes a credentials dashboard on the hub (`namespace/dashboard`).

### Credentials dashboard only

```bash
cd ansible
ansible-playbook -i inventory.example.yml playbooks/dashboard.yml
```

