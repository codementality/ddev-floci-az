#!/usr/bin/env bash
#ddev-generated
# Creates the project's two default Blob Storage containers.
#
#   public  — created with --public-access blob, which is how a real public
#             asset container is configured.
#   private — no public access; owner only.
#
# READ THE CAVEAT. floci-az accepts --public-access on create but does not
# store it, `set-permission` returns NotImplemented, and neither auth mode
# enforces anything: every request succeeds, signed or not, on both containers.
# The two exist so your application and IaC exercise the right shapes, not
# because one is actually protected. See "Container permissions are not
# enforced" in the add-on README.
#
# Unlike the AWS and GCP emulators, floci-az has no initialization-hook
# mechanism of its own — there is no /etc/floci-az/init to drop scripts into —
# so this runs from a DDEV post-start hook instead. That is what
# .ddev/config.floci-az.yaml wires up.
set -eu

CONTAINER="ddev-${DDEV_PROJECT}-floci-az"
ENV_FILE="${DDEV_APPROOT}/.ddev/.env.floci-az"

dotenv() {
  local value
  value="$(grep -sE "^${1}=" "${ENV_FILE}" | tail -n1 | cut -d= -f2- \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" || true)"
  echo "${value:-$2}"
}

# Nothing to do if the emulator is not running — `ddev start` with the add-on
# removed, for instance. Stay silent rather than failing the start.
docker inspect "${CONTAINER}" >/dev/null 2>&1 || exit 0

ACCOUNT="$(dotenv FLOCI_AZ_ACCOUNT_NAME devstoreaccount1)"
ACCOUNT_KEY="$(dotenv FLOCI_AZ_ACCOUNT_KEY 'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMh0==')"
PUBLIC="$(dotenv FLOCI_AZ_PUBLIC_CONTAINER public)"
PRIVATE="$(dotenv FLOCI_AZ_PRIVATE_CONTAINER private)"

CONN="DefaultEndpointsProtocol=http;AccountName=${ACCOUNT};AccountKey=${ACCOUNT_KEY};BlobEndpoint=http://localhost:4577/${ACCOUNT};QueueEndpoint=http://localhost:4577/${ACCOUNT}-queue;TableEndpoint=http://localhost:4577/${ACCOUNT}-table;"

az_in_container() {
  docker exec -i \
    -e AZURE_STORAGE_CONNECTION_STRING="${CONN}" \
    -e AZURE_STORAGE_ALLOW_HTTP=true \
    "${CONTAINER}" az "$@"
}

if ! docker exec "${CONTAINER}" sh -c 'command -v az >/dev/null 2>&1'; then
  echo "floci-az: the Azure CLI is not in this image, so the default containers were not created." >&2
  echo "floci-az: switch to floci/floci-az:latest-compat, or create them yourself." >&2
  exit 0
fi

# `az storage container create` is already idempotent — it reports created:false
# for one that exists — so this is safe to run on every start.
for spec in "${PUBLIC}:blob" "${PRIVATE}:off"; do
  name="${spec%%:*}"
  access="${spec##*:}"
  [ -n "${name}" ] || continue
  if [ "${access}" = "blob" ]; then
    az_in_container storage container create --name "${name}" --public-access blob -o none 2>/dev/null || true
    echo "floci-az: container '${name}' ready (public-access requested — not enforced by floci-az)"
  else
    az_in_container storage container create --name "${name}" -o none 2>/dev/null || true
    echo "floci-az: container '${name}' ready (private)"
  fi
done
