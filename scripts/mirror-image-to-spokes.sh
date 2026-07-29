#!/usr/bin/env bash
# Mirror an ImageStream tag from acm banking-apps to east/west.
# Usage: scripts/mirror-image-to-spokes.sh <app> <tag>
set -euo pipefail

APP="${1:?app name required}"
TAG="${2:?tag required}"
HUB_CONTEXT="${HUB_CONTEXT:-acm}"
SPOKE_CONTEXTS="${SPOKE_CONTEXTS:-east west}"
NS="${NS:-banking-apps}"

if ! command -v skopeo >/dev/null 2>&1; then
  echo "skopeo is required to copy between cluster registries." >&2
  exit 1
fi

HUB_REG="$(oc --context "${HUB_CONTEXT}" get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "${HUB_REG}" ]]; then
  echo "Expose the acm image registry Route first (oc patch configs.imageregistry...)." >&2
  exit 1
fi

SRC="docker://${HUB_REG}/${NS}/${APP}:${TAG}"
for ctx in ${SPOKE_CONTEXTS}; do
  SPOKE_REG="$(oc --context "${ctx}" get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "${SPOKE_REG}" ]]; then
    echo "WARN: no registry route on ${ctx}; skip"
    continue
  fi
  echo "==> ${SRC} -> docker://${SPOKE_REG}/${NS}/${APP}:${TAG}"
  skopeo copy --all "${SRC}" "docker://${SPOKE_REG}/${NS}/${APP}:${TAG}"
  oc --context "${ctx}" -n "${NS}" tag "${APP}:${TAG}" "${APP}:latest" || true
done
