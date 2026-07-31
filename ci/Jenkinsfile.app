// Template for per-app CI: OpenShift Build → Quay SBOM/attest/sign (RHTAS) → GitOps.
// Concrete jobs: Jenkinsfile.banking-service / Jenkinsfile.api-gateway

pipeline {
  agent any

  options {
    disableConcurrentBuilds()
    timeout(time: 60, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    booleanParam(name: 'FORCE_BUILD', defaultValue: true, description: 'Build even without path changes (default true for manual runs)')
    string(name: 'GITOPS_BRANCH', defaultValue: 'main', description: 'Branch for GitOps commits')
  }

  environment {
    APP = "${env.APP_NAME}"
    APPS_NS = 'banking-apps'
    GITOPS_NS = 'openshift-gitops'
    IMAGE_TAG = "${env.BUILD_NUMBER}"
    QUAY_ORG = 'banking'
    TOOLS_DIR = "${env.WORKSPACE}/.tools"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        sh 'git rev-parse --short HEAD > .gitcommit'
        script { env.GIT_COMMIT_SHORT = readFile('.gitcommit').trim() }
      }
    }

    stage('Install oc') {
      steps {
        sh '''
          set -euo pipefail
          mkdir -p "${TOOLS_DIR}"
          if [ ! -x "${TOOLS_DIR}/oc" ]; then
            curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" \
              | tar -xz -C "${TOOLS_DIR}" oc
          fi
          "${TOOLS_DIR}/oc" version --client
        '''
      }
    }

    stage('CI') {
      when {
        expression { return params.FORCE_BUILD || env.APP_NAME }
      }
      stages {
        stage('Build & push image') {
          steps {
            sh '''
              set -euo pipefail
              export PATH="${TOOLS_DIR}:${PATH}"
              oc whoami
              # Prefer -n over `oc project` — Jenkins home kubeconfig can be corrupt/incomplete.
              oc start-build "${APP}" --from-dir="apps/${APP}" --follow --wait -n "${APPS_NS}"
              oc tag "${APPS_NS}/${APP}:latest" "${APPS_NS}/${APP}:${IMAGE_TAG}" -n "${APPS_NS}"
              oc get istag "${APP}:${IMAGE_TAG}" -n "${APPS_NS}"
            '''
          }
        }

        stage('SBOM, attest & sign') {
          steps {
            sh '''
              set -euo pipefail
              export PATH="${TOOLS_DIR}:${PATH}"
              if [ -z "${QUAY_HOST:-}" ]; then
                QUAY_HOST="$(oc -n quay-enterprise get route -l quay-component=quay -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
              fi
              if [ -z "${QUAY_HOST:-}" ]; then
                echo "WARN: Quay not ready; skip sign/attest"
                exit 0
              fi
              export QUAY_HOST
              chmod +x ci/scripts/sign-and-attest.sh
              APP="${APP}" IMAGE_TAG="${IMAGE_TAG}" APPS_NS="${APPS_NS}" \
                QUAY_HOST="${QUAY_HOST}" QUAY_ORG="${QUAY_ORG}" TOOLS_DIR="${TOOLS_DIR}" \
                ci/scripts/sign-and-attest.sh
            '''
          }
        }

        stage('GitOps update') {
          steps {
            withCredentials([usernamePassword(
              credentialsId: 'github-ci',
              usernameVariable: 'GIT_USERNAME',
              passwordVariable: 'GIT_PASSWORD'
            )]) {
              sh '''
                set -euo pipefail
                OVERLAY_EAST="gitops/components/${APP}/overlays/east/kustomization.yaml"
                OVERLAY_WEST="gitops/components/${APP}/overlays/west/kustomization.yaml"
                test -f "${OVERLAY_EAST}"
                test -f "${OVERLAY_WEST}"
                # Quote tag: YAML would parse bare numbers as int and break kustomize/Argo.
                sed -i.bak -E "s/newTag:.*/newTag: \"${IMAGE_TAG}\"/" "${OVERLAY_EAST}" "${OVERLAY_WEST}"
                rm -f "${OVERLAY_EAST}.bak" "${OVERLAY_WEST}.bak"

                if [ "${GIT_PASSWORD}" = "replace-me" ] || [ -z "${GIT_PASSWORD}" ]; then
                  echo "WARN: github-ci token not configured; skipping git push of newTag=${IMAGE_TAG}."
                  echo "SKIP_GIT_PUSH=1" > .ci-gitops-status
                  exit 0
                fi

                git config user.email "jenkins@banking-demo.local"
                git config user.name "Jenkins CI"
                git add "${OVERLAY_EAST}" "${OVERLAY_WEST}"
                if git diff --staged --quiet; then
                  echo "SKIP_GIT_PUSH=0" > .ci-gitops-status
                  exit 0
                fi
                git commit -m "ci(${APP}): promote signed image ${IMAGE_TAG} on east+west (${GIT_COMMIT_SHORT})"
                AUTH_URL="https://${GIT_USERNAME}:${GIT_PASSWORD}@github.com/panchoraposo/demo-spring.git"
                if git push "${AUTH_URL}" "HEAD:${GITOPS_BRANCH}"; then
                  echo "SKIP_GIT_PUSH=0" > .ci-gitops-status
                else
                  echo "SKIP_GIT_PUSH=1" > .ci-gitops-status
                fi
              '''
            }
          }
        }

        stage('GitOps refresh') {
          steps {
            sh '''
              set -euo pipefail
              export PATH="${TOOLS_DIR}:${PATH}"
              # GitOps roots live on hub ArgoCD (ApplicationSet banking-spoke-roots).
              for app in "banking-east-root" "banking-west-root"; do
                oc -n "${GITOPS_NS}" annotate applications.argoproj.io "${app}" \
                  argocd.argoproj.io/refresh=hard --overwrite || true
              done
            '''
          }
        }
      }
    }
  }
}
