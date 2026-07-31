# Gitea (acm)

Hosts the demo mono-repo `banking/demo-spring` (Spring apps under `apps/`, GitOps, CI).

| Item | Value |
| --- | --- |
| Namespace | `banking-git` |
| Chart | `https://dl.gitea.com/charts/` `gitea` 12.7.0 |
| Public UI / git | OpenShift Route `gitea` → `https://gitea.<apps-domain>/` |
| Dev Spaces raw host | Route `gitea-raw` (`raw.<gitea-host>`) via `scripts/bootstrap-devspaces-gitea-raw.sh` |
| In-cluster clone | `http://gitea-http.banking-git.svc:3000/banking/demo-spring.git` |
| CI user / PAT | Created by `gitea-bootstrap` → Conjur `banking/github-ci/*` |

## Route

[`route.yaml`](route.yaml) exposes Gitea on the cluster apps domain (edge TLS).  
`scripts/bootstrap-gitea.sh install` applies the Route, then sets `ROOT_URL` / `DOMAIN` to `https://<route-host>/` so the UI and clone links work in the browser.

```bash
oc --context acm -n banking-git get route gitea \
  -o jsonpath='https://{.spec.host}{"\n"}'
```
