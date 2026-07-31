#!/usr/bin/env bash
# Official community-project logos for OpenShift ConsoleLink applicationMenu.imageURL.
# HTTPS URLs (required by the ConsoleLink API; rendered at 24x24).
# shellcheck shell=bash

# Gitea — https://github.com/go-gitea/gitea (assets/logo.svg)
console_link_icon_gitea() {
  printf '%s' 'https://raw.githubusercontent.com/go-gitea/gitea/main/assets/logo.svg'
}

# Jenkins — https://www.jenkins.io/artwork/
console_link_icon_jenkins() {
  printf '%s' 'https://www.jenkins.io/images/logos/jenkins/jenkins.svg'
}

# Project Quay — https://github.com/quay/quay (QE mark)
console_link_icon_quay() {
  printf '%s' 'https://raw.githubusercontent.com/quay/quay/master/static/img/QE-complex.svg'
}

# Rekor (Sigstore) — https://github.com/sigstore/community artwork
console_link_icon_rekor() {
  printf '%s' 'https://raw.githubusercontent.com/sigstore/community/main/artwork/rekor/icons/color/sigstore_rekor-icon-color.svg'
}

# Kiali — https://github.com/kiali/kiali
console_link_icon_kiali() {
  printf '%s' 'https://raw.githubusercontent.com/kiali/kiali/master/frontend/src/assets/img/kiali/icon-lightbkg.svg'
}

# Perses — https://github.com/perses/perses (project logo)
console_link_icon_perses() {
  printf '%s' 'https://raw.githubusercontent.com/perses/perses/main/docs/static/logo_perses_light_bg.svg'
}
