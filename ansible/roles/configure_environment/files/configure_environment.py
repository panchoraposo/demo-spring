#!/usr/bin/env python3
"""Discover live cluster domains/routes and rewrite GitOps env files for this environment."""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


def oc(*args: str, context: str) -> str:
    cmd = ["oc", "--context", context, *args]
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""


def apps_domain(context: str) -> str:
    console = oc("whoami", "--show-console", context=context)
    for prefix in (
        "https://console-openshift-console.",
        "http://console-openshift-console.",
    ):
        if console.startswith(prefix):
            return console[len(prefix) :]
    return ""


def route_host(context: str, namespace: str, name: str) -> str:
    return oc("-n", namespace, "get", "route", name, "-o", "jsonpath={.spec.host}", context=context)


def write_env(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")
    print(f"wrote {path}")


def sub_sandbox_domains(text: str, hub_apps: str) -> str:
    return re.sub(
        r"apps\.cluster-[a-z0-9]+\.[a-z0-9]+\.sandbox[0-9]+\.opentlc\.com",
        hub_apps,
        text,
    )


def main() -> int:
    acm = os.environ.get("ACM_CONTEXT", "acm")
    east = os.environ.get("EAST_CONTEXT", "east")
    west = os.environ.get("WEST_CONTEXT", "west")
    root = Path(os.environ["REPO_ROOT"])
    git_repo = os.environ.get("GIT_REPO_URL", "https://github.com/panchoraposo/demo-spring.git")
    git_rev = os.environ.get("GIT_TARGET_REVISION", "main")
    reset_tags = os.environ.get("RESET_IMAGE_TAGS", "false").lower() in ("1", "true", "yes")

    hub_apps = apps_domain(acm)
    if not hub_apps:
        print("ERROR: could not discover hub apps domain", file=sys.stderr)
        return 1
    east_apps = apps_domain(east)
    west_apps = apps_domain(west)

    conjur_host = route_host(acm, "banking-conjur", "conjur") or f"conjur-banking-conjur.{hub_apps}"
    conjur_url = f"https://{conjur_host}"
    keycloak_host = f"sso.{hub_apps}"
    keycloak_issuer = f"https://{keycloak_host}/realms/banking"
    tpa_domain = f".{hub_apps}"
    tpa_url = f"https://server{tpa_domain}"
    rhda_url = f"https://rhda-backend-trusted-profile-analyzer.{hub_apps}"
    jenkins_url = f"https://jenkins-banking-ci.{hub_apps}/"
    trustify_issuer = f"https://{keycloak_host}/realms/trustify"
    gitea_host = f"gitea-banking-git.{hub_apps}"

    quay_host = oc(
        "-n",
        "quay-enterprise",
        "get",
        "route",
        "-l",
        "quay-component=quay-app-route",
        "-o",
        "jsonpath={.items[0].spec.host}",
        context=acm,
    )
    if not quay_host:
        quay_host = route_host(acm, "quay-enterprise", "banking-quay-quay")
    if not quay_host:
        quay_host = f"banking-quay-quay-quay-enterprise.{hub_apps}"

    east_thanos = oc(
        "-n",
        "openshift-monitoring",
        "get",
        "route",
        "thanos-querier",
        "-o",
        "jsonpath={.spec.host}",
        context=east,
    )
    west_thanos = oc(
        "-n",
        "openshift-monitoring",
        "get",
        "route",
        "thanos-querier",
        "-o",
        "jsonpath={.spec.host}",
        context=west,
    )

    print(f"hub_apps={hub_apps}")
    print(f"east_apps={east_apps or 'unknown'} west_apps={west_apps or 'unknown'}")
    print(f"conjur={conjur_url}")
    print(f"keycloak={keycloak_host}")
    print(f"quay={quay_host}")
    print(f"thanos east={east_thanos or 'none'} west={west_thanos or 'none'}")

    for cluster in ("acm", "east", "west"):
        write_env(
            root / f"gitops/applications/{cluster}/env/common.env",
            [f"GIT_REPO_URL={git_repo}", f"GIT_TARGET_REVISION={git_rev}"],
        )

    write_env(root / "gitops/components/keycloak/overlays/acm/env/keycloak.env", [f"KEYCLOAK_HOST={keycloak_host}"])
    write_env(root / "gitops/components/trusted-profile-analyzer/env/tpa.env", [f"TPA_APP_DOMAIN={tpa_domain}"])
    write_env(
        root / "gitops/components/devspaces/overlays/acm/env/devspaces.env",
        [f"RHDA_BACKEND_URL={rhda_url}", f"TPA_URL={tpa_url}"],
    )
    for cluster in ("east", "west"):
        write_env(
            root / f"gitops/components/external-secrets/overlays/{cluster}/env/conjur.env",
            [f"CONJUR_URL_SPOKE={conjur_url}"],
        )
        jwk = f"{keycloak_issuer}/protocol/openid-connect/certs"
        write_env(
            root / f"gitops/components/banking-service/overlays/{cluster}/env/banking-service.env",
            [
                f"KEYCLOAK_ISSUER={keycloak_issuer}",
                f"OIDC_TRUSTED_ISSUERS={keycloak_issuer}",
                f"BANKING_CLUSTER={cluster}",
                f"KEYCLOAK_JWK_SET_URI={jwk}",
            ],
        )
        write_env(
            root / f"gitops/components/api-gateway/overlays/{cluster}/env/api-gateway.env",
            [f"KEYCLOAK_ISSUER={keycloak_issuer}", f"KEYCLOAK_JWK_SET_URI={jwk}"],
        )
        write_env(
            root / f"gitops/components/banking-si-service/overlays/{cluster}/env/banking-service.env",
            [
                f"KEYCLOAK_ISSUER={keycloak_issuer}",
                f"OIDC_TRUSTED_ISSUERS={keycloak_issuer}",
                f"BANKING_CLUSTER={cluster}",
                f"KEYCLOAK_JWK_SET_URI={jwk}",
            ],
        )
        write_env(
            root / f"gitops/components/banking-si-gateway/overlays/{cluster}/env/api-gateway.env",
            [f"KEYCLOAK_ISSUER={keycloak_issuer}", f"KEYCLOAK_JWK_SET_URI={jwk}"],
        )

    write_env(
        root / "gitops/environments/default/acm.env",
        [
            f"ACM_APPS_DOMAIN={hub_apps}",
            f"KEYCLOAK_HOST={keycloak_host}",
            f"KEYCLOAK_ISSUER={keycloak_issuer}",
            f"CONJUR_URL_SPOKE={conjur_url}",
        ],
    )
    if east_apps:
        write_env(
            root / "gitops/environments/default/east.env",
            [
                f"EAST_APPS_DOMAIN={east_apps}",
                f"EAST_KEYCLOAK_HOST={keycloak_host}",
                f"EAST_KEYCLOAK_ISSUER={keycloak_issuer}",
                f"OIDC_TRUSTED_ISSUERS={keycloak_issuer}",
            ],
        )
    if west_apps:
        write_env(
            root / "gitops/environments/default/west.env",
            [
                f"WEST_APPS_DOMAIN={west_apps}",
                f"WEST_KEYCLOAK_HOST={keycloak_host}",
                f"WEST_KEYCLOAK_ISSUER={keycloak_issuer}",
                f"OIDC_TRUSTED_ISSUERS={keycloak_issuer}",
            ],
        )

    if east_thanos and west_thanos:
        promxy = root / "gitops/components/promxy/promxy-config.yaml"
        promxy.write_text(
            f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: promxy-config
  namespace: acm-observability
  labels:
    app.kubernetes.io/part-of: banking-demo
data:
  config.yaml: |
    promxy:
      server_groups:
        - static_configs:
            - targets:
                - {east_thanos}:443
          labels:
            cluster: east
          ignore_error: true
          scheme: https
          http_client:
            tls_config:
              insecure_skip_verify: true
            bearer_token_file: /etc/promxy-tokens/east.token
        - static_configs:
            - targets:
                - {west_thanos}:443
          labels:
            cluster: west
          ignore_error: true
          scheme: https
          http_client:
            tls_config:
              insecure_skip_verify: true
            bearer_token_file: /etc/promxy-tokens/west.token
"""
        )
        print(f"wrote {promxy}")

    for cluster in ("east", "west"):
        for rel in (
            f"gitops/components/banking-service/overlays/{cluster}/kustomization.yaml",
            f"gitops/components/banking-si-service/overlays/{cluster}/kustomization.yaml",
        ):
            p = root / rel
            if not p.exists():
                continue
            text = p.read_text()
            text2 = re.sub(
                r"newName:\s*.*/banking/banking-service",
                f"newName: {quay_host}/banking/banking-service",
                text,
            )
            if reset_tags:
                text2 = re.sub(r'newTag:\s*["\']?[^"\'\n]+["\']?', 'newTag: "latest"', text2)
            if text2 != text:
                p.write_text(text2)
                print(f"patched {p}")

        # banking-si-gateway uses the local banking-apps ImageStream (not Quay).

    def patch_jenkins(text: str) -> str:
        text = sub_sandbox_domains(text, hub_apps)
        text = re.sub(r"jenkinsUrl:\s*.*", f"jenkinsUrl: {jenkins_url}", text)
        text = re.sub(
            r"(?m)(name:\s*TPA_URL\s*\n\s*value:\s*).*",
            rf"\1{tpa_url}",
            text,
        )
        text = re.sub(
            r"https://sso\.[^\s\"']+/realms/trustify",
            trustify_issuer,
            text,
        )
        return text

    def patch_gitea(text: str) -> str:
        text = sub_sandbox_domains(text, hub_apps)
        text = re.sub(r"(?m)(DOMAIN:\s*).*", rf"\1{gitea_host}", text)
        text = re.sub(r"(?m)(SSH_DOMAIN:\s*).*", rf"\1{gitea_host}", text)
        text = re.sub(r"(?m)(ROOT_URL:\s*).*", rf"\1https://{gitea_host}/", text)
        return text

    def patch_conjur(text: str) -> str:
        text = sub_sandbox_domains(text, hub_apps)
        return re.sub(r"- conjur-banking-conjur\.apps\.[^\n]+", f"- {conjur_host}", text)

    def patch_trustify(text: str) -> str:
        text = sub_sandbox_domains(text, hub_apps)
        return re.sub(r"https://server\.apps\.[^\s\"']+/\*", f"{tpa_url}/*", text)

    def patch_appset(text: str) -> str:
        text = re.sub(r"(?m)repoURL:\s*.*", f"repoURL: {git_repo}", text)
        text = re.sub(r"(?m)targetRevision:\s*.*", f"targetRevision: {git_rev}", text)
        return text

    for path, fn in (
        (root / "gitops/components/jenkins/helm-values.yaml", patch_jenkins),
        (root / "gitops/components/gitea/helm-values.yaml", patch_gitea),
        (root / "gitops/components/conjur/helm-values.yaml", patch_conjur),
        (root / "gitops/components/keycloak/base/trustify-realm-import.yaml", patch_trustify),
        (root / "gitops/acm/applicationsets/spoke-root.yaml", patch_appset),
    ):
        if not path.exists():
            continue
        orig = path.read_text()
        new = fn(orig)
        if new != orig:
            path.write_text(new)
            print(f"patched {path}")

    out = root / "ansible/playbooks/.generated"
    out.mkdir(parents=True, exist_ok=True)
    (out / "environment.env").write_text(
        "\n".join(
            [
                f"HUB_APPS_DOMAIN={hub_apps}",
                f"EAST_APPS_DOMAIN={east_apps}",
                f"WEST_APPS_DOMAIN={west_apps}",
                f"CONJUR_URL={conjur_url}",
                f"KEYCLOAK_HOST={keycloak_host}",
                f"KEYCLOAK_ISSUER={keycloak_issuer}",
                f"QUAY_HOST={quay_host}",
                f"TPA_URL={tpa_url}",
                f"RHDA_BACKEND_URL={rhda_url}",
                f"EAST_THANOS_HOST={east_thanos}",
                f"WEST_THANOS_HOST={west_thanos}",
                f"GIT_REPO_URL={git_repo}",
                f"GIT_TARGET_REVISION={git_rev}",
            ]
        )
        + "\n"
    )
    print(f"OK: environment configured for {hub_apps}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
