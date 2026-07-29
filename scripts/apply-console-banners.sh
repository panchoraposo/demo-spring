#!/usr/bin/env bash
set -euo pipefail
apply_banner() {
  local ctx="$1" text="$2" bg="$3"
  oc --context "${ctx}" apply -f - <<YAML
apiVersion: console.openshift.io/v1
kind: ConsoleNotification
metadata:
  name: cluster-banner
spec:
  text: "${text}"
  location: BannerTop
  color: '#fff'
  backgroundColor: '${bg}'
YAML
}
apply_banner acm "Hub Cluster" "#6A00FF"
apply_banner east "East Cluster" "#0088CE"
apply_banner west "West Cluster" "#3E8635"
echo "Console banners applied on acm, east, west."
