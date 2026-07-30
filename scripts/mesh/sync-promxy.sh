#!/usr/bin/env bash
# Deploy promxy on acm fanning out to east/west Thanos Querier routes for Kiali graphs.
set -euo pipefail

HUB_CONTEXT="${HUB_CONTEXT:-acm}"
SPOKE_CONTEXTS="${SPOKE_CONTEXTS:-east west}"
OBS_NS="${OBS_NS:-acm-observability}"
READER_SA="${READER_SA:-acm-thanos-reader}"

oc --context "${HUB_CONTEXT}" create namespace "${OBS_NS}" --dry-run=client -o yaml \
  | oc --context "${HUB_CONTEXT}" apply -f -

tokens_args=()
server_groups=""
for ctx in ${SPOKE_CONTEXTS}; do
  oc --context "${ctx}" -n istio-system create sa "${READER_SA}" --dry-run=client -o yaml \
    | oc --context "${ctx}" apply -f -
  oc --context "${ctx}" adm policy add-cluster-role-to-user cluster-monitoring-view \
    "system:serviceaccount:istio-system:${READER_SA}" >/dev/null
  host="$(oc --context "${ctx}" -n openshift-monitoring get route thanos-querier -o jsonpath='{.spec.host}')"
  token="$(oc --context "${ctx}" -n istio-system create token "${READER_SA}" --duration=8760h)"
  tokens_args+=(--from-literal="${ctx}.token=${token}")
  server_groups+="
        - static_configs:
            - targets:
                - ${host}:443
          ignore_error: true
          scheme: https
          http_client:
            tls_config:
              insecure_skip_verify: true
            bearer_token_file: /etc/promxy-tokens/${ctx}.token"
done

oc --context "${HUB_CONTEXT}" -n "${OBS_NS}" create secret generic promxy-upstream-tokens \
  "${tokens_args[@]}" --dry-run=client -o yaml | oc --context "${HUB_CONTEXT}" apply -f -

oc --context "${HUB_CONTEXT}" -n "${OBS_NS}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: promxy-config
  namespace: ${OBS_NS}
data:
  config.yaml: |
    promxy:
      server_groups:${server_groups}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: promxy
  namespace: ${OBS_NS}
  labels:
    app: promxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: promxy
  template:
    metadata:
      labels:
        app: promxy
    spec:
      containers:
        - name: promxy
          image: quay.io/jacksontj/promxy:v0.0.93
          args:
            - --config=/etc/promxy/config.yaml
            - --web.enable-lifecycle
          ports:
            - containerPort: 8082
              name: http
          volumeMounts:
            - name: config
              mountPath: /etc/promxy
            - name: tokens
              mountPath: /etc/promxy-tokens
              readOnly: true
          readinessProbe:
            httpGet:
              path: /
              port: http
          livenessProbe:
            httpGet:
              path: /
              port: http
      volumes:
        - name: config
          configMap:
            name: promxy-config
        - name: tokens
          secret:
            secretName: promxy-upstream-tokens
---
apiVersion: v1
kind: Service
metadata:
  name: promxy
  namespace: ${OBS_NS}
spec:
  selector:
    app: promxy
  ports:
    - name: http
      port: 8082
      targetPort: http
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: promxy
  namespace: ${OBS_NS}
spec:
  to:
    kind: Service
    name: promxy
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

oc --context "${HUB_CONTEXT}" -n "${OBS_NS}" rollout status deploy/promxy --timeout=180s
echo "Promxy ready. Point Kiali prometheus.url to http://promxy.${OBS_NS}.svc.cluster.local:8082"
