#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
#
# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=codementality/ddev-floci-az

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"

  mkdir -p "${TESTDIR}/web"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site \
    --project-type=php --docroot=web
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # The emulator answers on both of its health endpoints.
  run ddev exec curl -sf http://floci-az:4577/health
  assert_success
  assert_output --partial '"status":"UP"'
  run ddev exec curl -sf http://floci-az:4577/_floci/health
  assert_success

  # The web container is pointed at it without any application change.
  run ddev exec printenv AZURE_STORAGE_CONNECTION_STRING
  assert_success
  assert_output --partial "BlobEndpoint=http://floci-az:4577/devstoreaccount1;"
  assert_output --partial "QueueEndpoint=http://floci-az:4577/devstoreaccount1-queue;"

  # Blob round-trips through the bundled Azure CLI.
  run ddev floci-az az storage container create --name health-check -o tsv
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  assert_output --partial "health-check"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "Blob, Queue and Table all answer on the one port" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  # Three services, three path prefixes, one port. Getting the -queue and
  # -table suffixes wrong in the connection string is the classic way to have
  # Blob work and everything else 404.
  run ddev floci-az az storage container create --name uploads -o tsv
  assert_success
  run ddev floci-az az storage blob upload --container-name uploads --name a.txt --file /etc/hostname
  assert_success
  run ddev floci-az az storage blob list --container-name uploads -o tsv
  assert_success
  assert_output --partial "a.txt"

  run ddev floci-az az storage queue create --name jobs -o tsv
  assert_success
  run ddev floci-az az storage queue list -o tsv
  assert_success
  assert_output --partial "jobs"

  run ddev floci-az az storage table create --name sessions -o tsv
  assert_success
  run ddev floci-az az storage table list -o tsv
  assert_success
  assert_output --partial "sessions"
}

@test "the web container reaches the emulator with no explicit endpoint" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  run ddev floci-az az storage container create --name from-web -o tsv
  assert_success

  # The point of the web override file: the endpoints in the environment are
  # reachable from the web container, with no endpoint in application code.
  run ddev exec sh -c 'curl -sf "${AZURE_STORAGE_BLOB_ENDPOINT}?comp=list"'
  assert_success
  assert_output --partial "from-web"

  run ddev exec printenv AZURE_STORAGE_ACCOUNT
  assert_success
  assert_output "devstoreaccount1"
}

@test "the two default containers are created" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  # Created by a DDEV post-start hook, not by an emulator init hook — floci-az
  # has no /etc/floci-az/init mechanism at all.
  run ddev floci-az az storage container list -o tsv
  assert_success
  assert_output --partial "public"
  assert_output --partial "private"

  run ddev exec printenv AZURE_PUBLIC_CONTAINER
  assert_success
  assert_output "public"
  run ddev exec printenv AZURE_PRIVATE_CONTAINER
  assert_success
  assert_output "private"

  # Idempotent: the hook runs again on every start.
  run ddev restart -y
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  assert_output --partial "public"
}

@test "container permissions are advisory only, and listing survives a restart" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  run ddev floci-az az storage blob upload --container-name private --name a.txt --file /etc/hostname
  assert_success

  # Documented upstream limitation: floci-az enforces nothing, so an unsigned
  # read of the PRIVATE container succeeds. Asserted so that if upstream starts
  # enforcing, this test tells us and the README needs updating.
  run ddev exec sh -c 'curl -s -o /dev/null -w "%{http_code}" "http://floci-az:4577/devstoreaccount1/private/a.txt"'
  assert_success
  assert_output "200"

  # Unlike floci-gcp, container and blob listing here does survive a restart.
  sleep 8
  run ddev restart -y
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  assert_output --partial "private"
  run ddev floci-az az storage blob list --container-name private --query '[].name' -o tsv
  assert_success
  assert_output --partial "a.txt"
}

@test "Entra issues a usable token and Key Vault accepts it" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  # Key Vault requires a bearer token even in dev auth mode — this is the one
  # service where "no credentials needed" is not true — so the emulator's own
  # Entra has to be reachable from the web container and its tokens have to be
  # accepted. This exercises the whole AZURE_AUTHORITY_HOST/TENANT/CLIENT chain
  # the web override file sets up.
  cat > "${TESTDIR}/web/kv.sh" <<'SH'
#!/bin/sh
set -eu
TOKEN=$(curl -s -X POST \
  -d "grant_type=client_credentials&client_id=${AZURE_CLIENT_ID}&client_secret=${AZURE_CLIENT_SECRET}&scope=https://vault.azure.net/.default" \
  "${AZURE_AUTHORITY_HOST}${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "no token"; exit 1; }
curl -sf -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"s3cret"}' "${AZURE_KEY_VAULT_ENDPOINT}/secrets/api-key?api-version=7.4" >/dev/null
curl -sf -H "Authorization: Bearer $TOKEN" \
  "${AZURE_KEY_VAULT_ENDPOINT}/secrets/api-key?api-version=7.4"
SH
  run ddev exec sh /var/www/html/web/kv.sh
  assert_success
  assert_output --partial "s3cret"
}

@test "App Configuration answers over plain HTTP" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  # AZURE_APP_CONFIGURATION_ENDPOINT is deliberately an https:// URL because the
  # SDK rejects anything else, but the emulator itself only speaks http on 4577.
  # That is why the README's ForceHttp transport is needed — assert the http
  # form works so the advice stays honest.
  run ddev exec sh -c 'curl -sf -X PUT -H "Content-Type: application/vnd.microsoft.appconfig.kv+json" \
    -d "{\"value\":\"blue\"}" "${FLOCI_AZ_ENDPOINT}/${AZURE_STORAGE_ACCOUNT}-appconfig/kv/theme?api-version=1.0"'
  assert_success
  assert_output --partial '"key":"theme"'
}

@test "'ddev floci-az url' and 'connstring' report the right endpoints" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  run ddev floci-az url --internal
  assert_success
  assert_output "http://floci-az:4577"

  # The in-project connection string is the one that goes in application config.
  run ddev floci-az connstring
  assert_success
  assert_output --partial "BlobEndpoint=http://floci-az:4577/devstoreaccount1;"

  # The host one goes through ddev-router — no published port, plain HTTP so the
  # connection string never fights certificate validation, and stable across
  # restarts because the router routes by hostname rather than owning a port.
  run ddev floci-az url --host
  assert_success
  assert_output "http://${PROJNAME}.ddev.site:4577"
  run ddev floci-az connstring --host
  assert_success
  assert_output --partial "BlobEndpoint=http://${PROJNAME}.ddev.site:4577/devstoreaccount1;"

  run curl -sf "http://${PROJNAME}.ddev.site:4577/health"
  assert_success
  run curl -sfk "https://${PROJNAME}.ddev.site:4579/health"
  assert_success

  # Stable across a restart, unlike an ephemeral port.
  before="$(ddev floci-az url --host)"
  run ddev restart -y
  assert_success
  assert_equal "$(ddev floci-az url --host)" "${before}"

  run ddev floci-az env
  assert_success
  assert_output --partial "export AZURE_STORAGE_ALLOW_HTTP="
  assert_output --partial "${PROJNAME}.ddev.site:4577"

  run ddev floci-az health
  assert_success
  run ddev floci-az accounts
  assert_success
}

@test "state survives a restart, 'flush' clears it in place, 'reset' clears the volume" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  run ddev floci-az az storage container create --name persisted -o tsv
  assert_success

  # hybrid storage flushes asynchronously every five seconds; give it a moment
  # before cycling the container.
  sleep 8
  run ddev restart -y
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  assert_output --partial "persisted"

  # `flush` wipes state without a restart.
  run ddev floci-az flush
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  refute_output --partial "persisted"

  # …and `reset` takes the volume with it, so a restart cannot bring it back.
  run ddev floci-az reset -y
  assert_success
  run ddev restart -y
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  refute_output --partial "persisted"
}

@test "memory storage mode starts clean every time" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  ddev dotenv set .ddev/.env.floci-az --floci-az-storage-mode=memory
  run ddev restart -y
  assert_success

  run ddev floci-az az storage container create --name ephemeral -o tsv
  assert_success
  run ddev restart -y
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  refute_output --partial "ephemeral"
}

@test "a different account name flows through to the connection string" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  ddev dotenv set .ddev/.env.floci-az --floci-az-account-name=myaccount
  run ddev restart -y
  assert_success

  run ddev exec printenv AZURE_STORAGE_CONNECTION_STRING
  assert_success
  assert_output --partial "AccountName=myaccount;"
  assert_output --partial "TableEndpoint=http://floci-az:4577/myaccount-table;"

  # Accounts are created on demand, so the new name just works.
  run ddev floci-az az storage container create --name mine -o tsv
  assert_success
  run ddev floci-az az storage container list -o tsv
  assert_success
  assert_output --partial "mine"
}

@test "the add-on works without the Docker socket mount" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  rm "${TESTDIR}/.ddev/docker-compose.floci-az-docker.yaml"
  run ddev restart -y
  assert_success

  # Everything in-process must still be fine; only Functions, SQL, the Cosmos
  # engines, Redis, ACR and AKS are lost.
  run ddev floci-az az storage container create --name no-socket -o tsv
  assert_success
  run ddev floci-az az storage table list -o tsv
  assert_success
}

@test "nothing claims a fixed host port" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  # The whole point: no published host port means nothing for a second project
  # to collide with. If a fixed binding ever comes back, this catches it.
  run docker port "ddev-${PROJNAME}-floci-az"
  assert_output ""

  # And everything host-side still works, through the router.
  run ddev floci-az health
  assert_success
  run ddev floci-az accounts
  assert_success
  run ddev floci-az flush
  assert_success
  run curl -sf "http://${PROJNAME}.ddev.site:4577/health"
  assert_success
}

@test "add-on removes cleanly" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  run ddev add-on remove floci-az
  assert_success
  assert_file_not_exist "${TESTDIR}/.ddev/docker-compose.floci-az.yaml"
  assert_file_not_exist "${TESTDIR}/.ddev/docker-compose.floci-az-web.yaml"
  assert_file_not_exist "${TESTDIR}/.ddev/commands/host/floci-az"
  run ddev restart -y
  assert_success
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}
