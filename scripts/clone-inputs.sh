#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="${ROOT}/apps"

EPHPM_REPO="${EPHPM_REPO:-https://github.com/ephpm/ephpm.git}"
EPHPM_COMMIT="${EPHPM_COMMIT:-469c51ec749678d73984fea8f788b6727eb29f30}"

KRAYIN_REPO="${KRAYIN_REPO:-https://github.com/krayin/laravel-crm.git}"
KRAYIN_COMMIT="${KRAYIN_COMMIT:-7d426f901b18f043eb91e425c7bdd3e9cba568ab}"

mkdir -p "${APPS_DIR}"

if [ ! -d "${APPS_DIR}/ephpm/.git" ]; then
  git clone "${EPHPM_REPO}" "${APPS_DIR}/ephpm"
fi
git -C "${APPS_DIR}/ephpm" fetch --tags --quiet
git -C "${APPS_DIR}/ephpm" checkout "${EPHPM_COMMIT}"
git -C "${APPS_DIR}/ephpm" reset --hard "${EPHPM_COMMIT}"
git -C "${APPS_DIR}/ephpm" clean -fd
git -C "${APPS_DIR}/ephpm" apply "${ROOT}/patches/ephpm-source-build.patch"

if [ ! -d "${APPS_DIR}/laravel-crm/.git" ]; then
  git clone "${KRAYIN_REPO}" "${APPS_DIR}/laravel-crm"
fi
git -C "${APPS_DIR}/laravel-crm" fetch --tags --quiet
git -C "${APPS_DIR}/laravel-crm" checkout "${KRAYIN_COMMIT}"
git -C "${APPS_DIR}/laravel-crm" reset --hard "${KRAYIN_COMMIT}"
git -C "${APPS_DIR}/laravel-crm" clean -fd

cat <<MSG
Prepared upstream inputs:
- apps/ephpm at ${EPHPM_COMMIT}, with patches/ephpm-source-build.patch applied
- apps/laravel-crm at ${KRAYIN_COMMIT}
MSG
