// Shared per-app CI. APP_NAME is set by the Jenkins job (banking-service | api-gateway).
// Flow: git change → OpenShift image build/push → GitOps newTag commit → Argo refresh.

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 45, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  parameters {
    booleanParam(name: 'FORCE_BUILD', defaultValue: true, description: 'Build even without path changes (default true for manual runs)')
    string(name: 'GIT_BRANCH', defaultValue: 'main', description: 'Branch for GitOps commits')
  }

  environment {
    APP = "${env.APP_NAME}"
    APPS_NS = 'banking-apps'
    GITOPS_NS = 'openshift-gitops'
    IMAGE_TAG = "${env.BUILD_NUMBER}"
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
          mkdir -p "${WORKSPACE}/.tools"
          if [ ! -x "${WORKSPACE}/.tools/oc" ]; then
            curl -fsSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" \
              | tar -xz -C "${WORKSPACE}/.tools" oc
          fi
          "${WORKSPACE}/.tools/oc" version --client
        '''
      }
    }

    stage('CI') {
      when {
        anyOf {
          expression { return params.FORCE_BUILD }
          changeset "apps/${env.APP_NAME}/**"
          changeset "ci/Jenkinsfile.app"
          changeset "ci/Jenkinsfile.${env.APP_NAME}"
        }
      }
      stages {
        stage('Build & push image') {
          steps {
            sh '''
              set -euo pipefail
              export PATH="${WORKSPACE}/.tools:${PATH}"
              oc whoami
              oc project "${APPS_NS}"
              oc start-build "${APP}" --from-dir="apps/${APP}" --follow --wait -n "${APPS_NS}"
              oc tag "${APPS_NS}/${APP}:latest" "${APPS_NS}/${APP}:${IMAGE_TAG}" -n "${APPS_NS}"
              oc get istag "${APP}:${IMAGE_TAG}" -n "${APPS_NS}"
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
                OVERLAY="gitops/components/${APP}/overlays/east/kustomization.yaml"
                test -f "${OVERLAY}"
                sed -i.bak -E "s/newTag:.*/newTag: ${IMAGE_TAG}/" "${OVERLAY}"
                rm -f "${OVERLAY}.bak"

                git config user.email "jenkins@banking-demo.local"
                git config user.name "Jenkins CI"
                git add "${OVERLAY}"
                if git diff --staged --quiet; then
                  echo "No GitOps changes to commit"
                  exit 0
                fi
                git commit -m "ci(${APP}): promote image to ${IMAGE_TAG} (${GIT_COMMIT_SHORT})"
                AUTH_URL="https://${GIT_USERNAME}:${GIT_PASSWORD}@github.com/panchoraposo/demo-spring.git"
                git push "${AUTH_URL}" "HEAD:${GIT_BRANCH}"
              '''
            }
          }
        }

        stage('GitOps refresh') {
          steps {
            sh '''
              set -euo pipefail
              export PATH="${WORKSPACE}/.tools:${PATH}"
              oc -n "${GITOPS_NS}" annotate application "${APP}" \
                argocd.argoproj.io/refresh=hard --overwrite || true
              echo "OpenShift GitOps will deploy ${APP}:${IMAGE_TAG} from Git."
            '''
          }
        }
      }
    }
  }

  post {
    success {
      echo "CI OK for ${env.APP}: image tag=${env.IMAGE_TAG}. Deployment is GitOps-owned."
    }
    unsuccessful {
      echo "CI finished with status ${currentBuild.currentResult} for ${env.APP}."
    }
  }
}
