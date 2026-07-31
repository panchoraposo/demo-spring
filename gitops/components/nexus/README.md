# Nexus Repository Manager (acm)

Maven group **`maven-public`** proxies:

| Repo | Upstream |
| --- | --- |
| `maven-central` | https://repo1.maven.org/maven2/ |
| `maven-redhat` | https://maven.repository.redhat.com/ga/ |

## URLs

| Consumer | URL |
| --- | --- |
| In-cluster (BuildConfig, Dev Spaces) | `http://nexus.nexus.svc.cluster.local:8081/repository/maven-public/` |
| Laptop / browser | `https://$(oc --context acm -n nexus get route nexus -o jsonpath='{.spec.host}')/repository/maven-public/` |

## Bootstrap repos + CI user

```bash
./scripts/bootstrap-nexus.sh
```

Creates proxy/group repos (idempotent) and seeds Conjur `banking/nexus/*` when possible.
Default admin password is read from the Nexus data volume on first boot.
