# Shared RHACS helpers for Jenkins (sourced by acs-image-*.sh).
# Expects: ACS_CENTRAL_URL, ACS_API_TOKEN, TOOLS_DIR
# Sets: ROX_ENDPOINT / ROX_API_TOKEN / installs roxctl into TOOLS_DIR

acs_warn_skip() {
  echo "WARN: $*"
  if [[ "${ACS_REQUIRED:-false}" == "true" ]]; then
    exit 1
  fi
  exit 0
}

acs_resolve_central() {
  if [[ -z "${ACS_CENTRAL_URL:-}" ]]; then
    ACS_CENTRAL_URL="$(oc -n stackrox get route central -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
  fi
  [[ -n "${ACS_CENTRAL_URL:-}" ]] || acs_warn_skip "ACS Central URL not found; run scripts/bootstrap-acs-ci.sh"
  [[ -n "${ACS_API_TOKEN:-}" ]] || acs_warn_skip "ACS_API_TOKEN empty; run scripts/bootstrap-acs-ci.sh"
}

acs_ensure_roxctl() {
  local os=Linux ver tmp
  case "$(uname -s)" in Darwin) os=Darwin ;; esac
  mkdir -p "${TOOLS_DIR}"

  if [[ -x "${TOOLS_DIR}/roxctl" ]]; then
    return 0
  fi

  # Parallel stages may race; write to a temp name then mv (atomic on same FS).
  echo "==> installing roxctl (${os})"
  ver="$(curl -sk -H "Authorization: Bearer ${ACS_API_TOKEN}" \
    "${ACS_CENTRAL_URL}/v1/metadata" 2>/dev/null \
    | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
  tmp="${TOOLS_DIR}/roxctl.$$.$RANDOM"
  if [[ -n "${ver}" ]]; then
    curl -fsSL -o "${tmp}" \
      "https://mirror.openshift.com/pub/rhacs/assets/${ver}/bin/${os}/roxctl" \
      || curl -fsSL -o "${tmp}" \
      "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${os}/roxctl"
  else
    curl -fsSL -o "${tmp}" \
      "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${os}/roxctl"
  fi
  chmod +x "${tmp}"
  mv -f "${tmp}" "${TOOLS_DIR}/roxctl"
}

acs_export_rox_env() {
  local hostport
  hostport="$(echo "${ACS_CENTRAL_URL}" | sed -E 's|^https?://||; s|/$||')"
  case "${hostport}" in
    *:*) ;;
    *) hostport="${hostport}:443" ;;
  esac
  export ROX_API_TOKEN="${ACS_API_TOKEN}"
  export ROX_ENDPOINT="${hostport}"
  export ROX_CENTRAL_ADDRESS="${hostport}"
  ACS_HOSTPORT="${hostport}"
}
