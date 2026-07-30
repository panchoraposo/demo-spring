## Environment configuration (default)

This directory contains **non-secret**, environment-specific values used by Kustomize
`replacements` to avoid repo-wide placeholder scripts.

For a new install, copy `default/` to a new folder (e.g. `gitops/environments/env1/`)
and update the `*.env` files, then point the Argo root apps at that environment
(or keep `default` if you only maintain one environment per branch).

### Files
- `common.env`: Git repo URL and revision.
- `acm.env`: hub-specific endpoints.
- `east.env`: east spoke ingress domain and derived Keycloak issuer/host.
- `west.env`: west spoke ingress domain and derived Keycloak issuer/host.

