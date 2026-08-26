# ddev-floci-az <!-- omit in toc -->

[![tests](https://github.com/codementality/ddev-floci-az/actions/workflows/tests.yml/badge.svg)](https://github.com/codementality/ddev-floci-az/actions/workflows/tests.yml)
[![last commit](https://img.shields.io/github/last-commit/codementality/ddev-floci-az)](https://github.com/codementality/ddev-floci-az/commits)
[![release](https://img.shields.io/github/v/release/codementality/ddev-floci-az)](https://github.com/codementality/ddev-floci-az/releases/latest)

A [DDEV](https://ddev.com) add-on that runs [floci-az](https://floci.io/az/) —
a free, open-source local Azure emulator — alongside your project, and points
your web container at it.

Your application talks to `http://floci-az:4577` instead of Azure. Blob
containers, Queues, Tables, Key Vault secrets, App Configuration keys, Cosmos DB
databases, Entra ID tokens and about twenty other services exist locally, with
no Azure subscription, no service principal, and no billing account.

- [Why this add-on](#why-this-add-on)
- [Running alongside the AWS and GCP emulators](#running-alongside-the-aws-and-gcp-emulators)
- [Installation](#installation)
- [Using it](#using-it)
- [One port, many paths](#one-port-many-paths)
- [The two default containers](#the-two-default-containers)
- [Key Vault, Entra ID and the auth story](#key-vault-entra-id-and-the-auth-story)
- [App Configuration needs an https endpoint](#app-configuration-needs-an-https-endpoint)
- [Reaching Floci from the host](#reaching-floci-from-the-host)
- [Persistence](#persistence)
- [Docker-backed services and the Docker socket](#docker-backed-services-and-the-docker-socket)
- [Azure SQL and the EULA](#azure-sql-and-the-eula)
- [Migrating from Azurite](#migrating-from-azurite)
- [Configuration](#configuration)
- [The `ddev floci-az` command](#the-ddev-floci-az-command)
- [Removing the add-on](#removing-the-add-on)
- [Credits](#credits)

## Why this add-on

Azurite, Microsoft's official local emulator, covers Blob, Queue and Table and
stops there — no Key Vault, no App Configuration, no Cosmos, no Entra, no ARM.
floci-az covers all of those in one ~78 MB container on one port, MIT licensed,
with no account and no feature gates. It is wire-compatible with Azurite, so the
connection string you already have keeps working.

Running it as a DDEV add-on rather than as a separate `docker compose` stack
buys you three things that are fiddly to arrange by hand:

- **The web container is configured for you.**
  `AZURE_STORAGE_CONNECTION_STRING` — the one variable every Azure Storage SDK
  and `az storage` reads on its own — is set in the web container's
  environment, with the endpoints already pointing at the container. So is a
  working Entra tenant, client id and secret.
- **Returned URLs resolve.** SAS URLs, operation locations, function invoke
  URLs and Entra token issuers name the `floci-az` container rather than
  `localhost`, which is what makes them usable from your PHP/Node/Python code.
  Upstream's default is `localhost`, and getting this wrong is the single most
  common way a local cloud emulator appears to work and then doesn't.
- **Docker-backed services land on DDEV's network.** Functions, SQL Server,
  Redis and the Cosmos engines that Floci starts join the project's own network
  instead of binding random ports straight onto the host, so your web container
  can actually reach them.

## Running alongside the AWS and GCP emulators

Everything this add-on installs is named for the cloud it emulates rather than
for Floci: the service and its hostname are `floci-az`, the container is
`ddev-<project>-floci-az`, the state volume is `floci-az`, and the command is
`ddev floci-az`. Nothing here claims the bare `floci` name, so the equivalent
AWS and GCP add-ons can be installed in the same project without overwriting
this one's files or shadowing its command.

Your application can then tell them apart by endpoint:
`http://floci-aws:4566`, `http://floci-az:4577`, `http://floci-gcp:4588`.

## Installation

```bash
ddev add-on get codementality/ddev-floci-az
ddev restart
```

Then check it:

```bash
ddev floci-az az storage container create --name uploads
ddev floci-az az storage container list -o table
```

## Using it

Nothing in your application needs to know it is talking to an emulator. The web
container already has the environment set:

| Variable | Value |
|---|---|
| `AZURE_STORAGE_CONNECTION_STRING` | The full Azurite-style string, endpoints on `floci-az:4577` |
| `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_KEY` | `devstoreaccount1` and the well-known dev key |
| `AZURE_STORAGE_ALLOW_HTTP` | `true` |
| `AZURE_STORAGE_BLOB_ENDPOINT`, `..._QUEUE_ENDPOINT`, `..._TABLE_ENDPOINT` | Per-service URLs |
| `AZURE_KEY_VAULT_ENDPOINT`, `AZURE_COSMOS_ENDPOINT`, `AZURE_APP_CONFIGURATION_ENDPOINT` | Per-service URLs |
| `AZURE_AUTHORITY_HOST`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` | The seeded Entra tenant and app registration |
| `FLOCI_AZ_ENDPOINT` | `http://floci-az:4577` — the bare root, for ARM calls |

Only the connection string is read automatically; the rest are endpoints for
your code to pass to a client constructor.

**PHP** (`microsoft/azure-storage-blob` or the newer `azure-sdk-for-php`):

```php
$client = MicrosoftAzure\Storage\Blob\BlobRestProxy::createBlobService(
  getenv('AZURE_STORAGE_CONNECTION_STRING')
);
$client->createContainer('uploads');
$client->createBlockBlob('uploads', 'a.txt', 'hi');
```

For Drupal with a `flysystem`-backed module, point the container at `uploads`
and hand it the same connection string.

**Python / Node / .NET / Java**: `BlobServiceClient.from_connection_string(...)`
and its equivalents all take `AZURE_STORAGE_CONNECTION_STRING` as-is.

## One port, many paths

Azure normally gives each service its own hostname. floci-az serves everything
on port 4577 and routes by path prefix instead, which is why the connection
string has three different endpoint URLs on the same host and port:

| Service | Path |
|---|---|
| Blob | `/devstoreaccount1` |
| Queue | `/devstoreaccount1-queue` |
| Table | `/devstoreaccount1-table` |
| Key Vault | `/devstoreaccount1-keyvault` |
| App Configuration | `/devstoreaccount1-appconfig` |
| Cosmos DB | `/devstoreaccount1-cosmos` |
| Functions | `/devstoreaccount1-functions` |
| ARM (SQL, AKS, Redis, ACR, VNet …) | `/subscriptions/...` |

Dropping the `-queue` or `-table` suffix is the classic way to have Blob work
and everything else return 404. The add-on builds all three correctly; if you
write a connection string by hand, keep the suffixes.

## The two default containers

Out of the box the add-on creates two Blob Storage containers on every start:

| Container | Default name | Intent |
|---|---|---|
| Public | `public` | Created with `--public-access blob` |
| Private | `private` | No public access — owner only |

The web container gets `AZURE_PUBLIC_CONTAINER`, `AZURE_PRIVATE_CONTAINER`,
`AZURE_STORAGE_CONTAINER` (the public one) and `AZURE_PUBLIC_CONTAINER_URL` —
the last being the router URL a browser can actually resolve, since a URL built
from `floci-az:4577` only works inside Docker.

Rename either, or set one to an empty string to skip it:

```bash
ddev dotenv set .ddev/.env.floci-az --floci-az-public-container=assets
ddev dotenv set .ddev/.env.floci-az --floci-az-private-container=""
ddev restart
```

### How they get created, since floci-az has no init hooks

The AWS and GCP emulators run initialization scripts from a directory inside the
container. floci-az has no such mechanism — there is no `/etc/floci-az/init` —
so this add-on creates the containers from a DDEV **post-start hook** instead,
wired up in `.ddev/config.floci-az.yaml` and running
`.ddev/floci-az/create-containers.sh`.

That is worth knowing if you want to add your own startup resources: put them in
that script, or add another `post-start` hook of your own. `az storage container
create` is already idempotent, so re-running on every start is safe.

### Container permissions are not enforced

**The two containers are equally open at runtime.**

- `az storage container create --public-access blob` is accepted, but the value
  is **not stored** — `container show --query properties.publicAccess` comes
  back empty for both.
- `az storage container set-permission` returns **`ErrorCode:NotImplemented`**.
- Unsigned reads succeed on **both** containers: `GET
  /devstoreaccount1/private/a.txt` returns 200 with no credentials.
- Setting `--floci-az-auth-mode=strict` does **not** change this. Strict mode
  validates HMAC signatures where one is presented, but an unsigned blob read
  still returns 200 on both containers.

So the split exists to make your application and IaC exercise the right shapes —
public assets in one container, private uploads in the other, with the right
`publicAccess` in your Bicep or Terraform — and so it is already in place if
upstream starts enforcing it. Treat *both* containers as world-readable locally,
and do not rely on the emulator to catch a permissions mistake; only real Azure
will.

Unlike GCS on floci-gcp, container and blob listing here does survive a restart
correctly.

> *Measured against `floci/floci-az:0.11.0` on 2026-08-26. Floci is under active development, so this may already be out of date. The add-on's test suite carries a canary — `container permissions are advisory only, and listing survives a restart` — that goes red when this changes, so a nightly CI failure there is good news, not a regression.*


## Key Vault, Entra ID and the auth story

Storage runs in `dev` auth mode, which accepts any credential and any signature
— that is what makes the emulator usable without real keys.

**Key Vault is the exception.** It requires a real bearer token even locally,
because that is how the Key Vault API works. floci-az ships a full local Entra
ID that issues genuine RS256-signed JWTs from a seeded tenant, so the fix is to
ask it for one — and the web container already has everything needed:

```sh
TOKEN=$(curl -s -X POST \
  -d "grant_type=client_credentials&client_id=${AZURE_CLIENT_ID}&client_secret=${AZURE_CLIENT_SECRET}&scope=https://vault.azure.net/.default" \
  "${AZURE_AUTHORITY_HOST}${AZURE_TENANT_ID}/oauth2/v2.0/token" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

curl -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"value":"s3cret"}' \
  "${AZURE_KEY_VAULT_ENDPOINT}/secrets/api-key?api-version=7.4"
```

In an SDK, `ClientSecretCredential` with those three variables does the same
thing, and `DefaultAzureCredential` picks them up from the environment
unassisted — `AZURE_AUTHORITY_HOST` is the variable that redirects it away from
`login.microsoftonline.com`. The seeded values are tenant
`00000000-0000-0000-0000-000000000002`, client
`11111111-1111-1111-1111-111111111111`, secret `floci-az-dev-secret`.

Set `--floci-az-auth-mode=strict` if you want storage signatures validated too.

## App Configuration needs an https endpoint

The App Configuration SDK refuses a plaintext endpoint outright, and floci-az
speaks http on 4577. So `AZURE_APP_CONFIGURATION_ENDPOINT` is deliberately set
to an `https://` URL, and the convention is a transport that rewrites the scheme
on the way out:

```python
from azure.appconfiguration import AzureAppConfigurationClient
from azure.core.pipeline.transport import RequestsTransport

class ForceHttpTransport(RequestsTransport):
    def send(self, request, **kwargs):
        request.url = request.url.replace("https://", "http://", 1)
        return super().send(request, **kwargs)

conn = f"Endpoint={os.environ['AZURE_APP_CONFIGURATION_ENDPOINT']};Id=devstoreaccount1;Secret=placeholder"
client = AzureAppConfigurationClient.from_connection_string(conn, transport=ForceHttpTransport())
```

Java takes the equivalent `HttpPipelinePolicy`. Plain HTTP calls to
`${FLOCI_AZ_ENDPOINT}/devstoreaccount1-appconfig/kv/...` need none of this.

## Reaching Floci from the host

Two endpoints, and neither needs a published host port:

```bash
ddev floci-az url
# From the project (web container, Functions, SQL): http://floci-az:4577
# From the host (az CLI, Terraform, your IDE):      http://<project>.ddev.site:4577
#                                            (TLS: https://<project>.ddev.site:4579)
```

The host endpoint is ddev-router, which routes by hostname — so ports 4577 and
4579 are *shared* between every project running this add-on rather than owned by
one of them, and each project's requests reach its own emulator.

The plain-HTTP port matters more than it looks. An Azure connection string
carries its own scheme, and the local-development convention every SDK and
tutorial uses is `DefaultEndpointsProtocol=http`. A stable http endpoint means
the connection string never has to fight certificate validation, and never has
to change:

```bash
eval "$(ddev floci-az env)"
az storage container list -o table
```

Everything floci-az serves on 4577 is REST, so the router carries all of it —
there is no direct host port to manage. (The GCP add-on does publish one,
because gRPC does not survive Traefik; Azure has no equivalent need.)

Or skip the question entirely with `ddev floci-az az ...`, which runs the CLI
inside the container.

### Running several projects at once

Two DDEV projects with this add-on installed start side by side with no
configuration — nothing claims a fixed host port, so there is nothing to
collide. State is per project: the `floci-az` volume is namespaced
`ddev-<project>_floci-az`, and `FLOCI_AZ_DOCKER_RESOURCE_NAMESPACE` scopes every
sidecar container Floci spawns — a SQL Server, a Redis cache — to its own
project. `ddev floci-az reset` or a full `ddev delete` in one leaves the other
untouched.

## Persistence

Upstream defaults to `memory`; this add-on defaults to `hybrid` — in-memory
speed with an asynchronous flush every five seconds, so your containers, queues
and secrets survive `ddev restart`. State lives in a Docker volume, not in your
project directory.

```bash
# Wipe everything in place, no restart — the one for between test runs.
ddev floci-az flush

# Delete the state volume and any containers Floci spawned.
ddev floci-az reset

# Or make every start clean.
ddev dotenv set .ddev/.env.floci-az --floci-az-storage-mode=memory
ddev restart
```

Other modes are `persistent` (flush on graceful shutdown) and `wal` (write-ahead
log, maximum durability). Individual services can override the global mode —
`--floci-az-storage-services-blob-mode=wal`, say. Use `memory` in CI.

## Docker-backed services and the Docker socket

floci-az backs **Azure Functions**, the **Cosmos DB engines** (MongoDB,
PostgreSQL, Cassandra), **Azure SQL**, **PostgreSQL** and **MySQL Flexible
Server**, **Cache for Redis**, **Container Registry** and **AKS** with real
containers rather than mocking their responses — a real SQL Server, a real
Valkey, a real k3s cluster, your actual function code executing. Doing so
requires the host's Docker socket, which `docker-compose.floci-az-docker.yaml`
mounts. The socket is also what powers Floci's embedded DNS.

Mounting the Docker socket into a container gives it control of the host's
Docker daemon, which is effectively root on the host. It is the same bargain
LocalStack and Testcontainers ask for, but it is worth making deliberately. If
this project only uses the in-process services — Blob, Queue and Table Storage,
Key Vault, App Configuration, Cosmos NoSQL, Entra ID, Managed Identity, Event
Grid, Monitor, APIM, Email, and the whole ARM management plane — you can decline
it:

```bash
rm .ddev/docker-compose.floci-az-docker.yaml
ddev restart
```

You can also keep the socket and stop one service from spawning anything, by
putting it in control-plane-only mock mode:

```bash
ddev dotenv set .ddev/.env.floci-az --floci-az-services-functions-mocked=true
```

Event Hubs, Service Bus and Virtual Machines ship mocked already — Event Hubs
because its AMQP data plane does not yet work with the Azure SDKs upstream — so
only the services listed above spawn containers out of the box.

One wrinkle worth knowing: containers Floci starts are its own, not DDEV's, so
`ddev stop` leaves them running. `ddev floci-az reset` removes the ones
belonging to this project along with the state.

## Azure SQL and the EULA

Microsoft's SQL Server image will not start until its licence is accepted, so
Azure SQL is ARM-state-only — you can create servers and databases, but nothing
speaks TDS — until you say yes:

```bash
ddev dotenv set .ddev/.env.floci-az --floci-az-services-sql-accept-eula=Y
ddev restart
```

Note that the value has to be a real `Y` or `N`. floci-az refuses to boot at all
if it is set to an empty string, which is why this add-on defaults it to `N`
rather than leaving it unset.

Once a server exists, its container binds a port chosen by the OS;
`GET /devstoreaccount1-sql/servers/<name>/connect` reports it. The same pattern
applies to the Cosmos engines and AKS — see the
[ports reference](https://floci.io/floci-az/configuration/ports/).

## Migrating from Azurite

floci-az is wire-compatible, so an existing setup mostly moves across unchanged:

- The connection string keeps the same shape — only the host, port and paths
  change, and this add-on sets them for you.
- The account name and key are the well-known development pair, as in Azurite.
- Blob, Queue and Table behave the same; everything Azurite never had (Key
  Vault, App Configuration, Cosmos, Entra, ARM) is simply also there.

The differences worth knowing: Azurite gives each service its own port
(10000/10001/10002), floci-az gives them one port and three paths; and Azurite
has no auth mode to speak of, where floci-az has `dev` and `strict`.

## Configuration

These are Floci's own variable names, not add-on-specific aliases, because
floci-az already namespaces everything under `FLOCI_AZ_*`. Anything in the
[upstream reference](https://floci.io/floci-az/configuration/docker-compose/)
works here verbatim — set it and restart:

```bash
ddev dotenv set .ddev/.env.floci-az --floci-az-services-cosmos-enabled=false
ddev restart
```

The ones this add-on gives a different default to, or invents:

| Variable | Default | Purpose |
|---|---|---|
| `FLOCI_AZ_IMAGE` | `floci/floci-az:latest-compat` | Image tag. `floci/floci-az:latest` is the lean ~78 MB native build **without** the Azure CLI |
| `FLOCI_AZ_HOSTNAME` | `floci-az` | Hostname on DDEV's network, and the host in returned URLs |
| `FLOCI_AZ_BASE_URL` | `http://floci-az:4577` | Base URL Floci embeds in API responses (upstream: `http://localhost:4577`) |
| `FLOCI_AZ_HTTP_PORT` | `4577` | ddev-router port (http), shared between projects |
| `FLOCI_AZ_HTTPS_PORT` | `4579` | ddev-router port (https), shared between projects |
| `FLOCI_AZ_ACCOUNT_NAME` | `devstoreaccount1` | Storage account in the connection string |
| `FLOCI_AZ_ACCOUNT_KEY` | the well-known dev key | Account key in the connection string |
| `FLOCI_AZ_PUBLIC_CONTAINER` | `public` | Blob container created on every start, public-access requested. Empty string to skip |
| `FLOCI_AZ_PRIVATE_CONTAINER` | `private` | Private blob container created on every start. Empty string to skip |
| `FLOCI_AZ_STORAGE_MODE` | `hybrid` | `memory`, `persistent`, `hybrid` or `wal` (upstream: `memory`) |
| `FLOCI_AZ_AUTH_MODE` | `dev` | `dev` accepts anything; `strict` validates HMAC-SHA256 |
| `FLOCI_AZ_SERVICES_DOCKER_NETWORK` | `ddev-<project>_default` | Network for containers Floci spawns |
| `FLOCI_AZ_DOCKER_RESOURCE_NAMESPACE` | `<project>` | Names and labels spawned containers and volumes |
| `FLOCI_AZ_SERVICES_SQL_ACCEPT_EULA` | `N` | `Y` to accept Microsoft's SQL Server licence |
| `FLOCI_AZ_DNS_CONTAINER_FALLBACK_ENABLED` | `true` | Public resolvers in spawned containers; set `false` on an offline network |

Anything else — `FLOCI_AZ_SERVICES_REDIS_DEFAULT_IMAGE`, say — can go straight
into `.ddev/.env.floci-az` and be added to the `environment:` block of
`.ddev/docker-compose.floci-az.yaml`, or set in a compose file of your own.

## The `ddev floci-az` command

| Command | Does |
|---|---|
| `ddev floci-az az <args>` | Runs the Azure CLI inside the container, connection string already injected |
| `ddev floci-az connstring [--host]` | Prints the connection string, in-project or host-side |
| `ddev floci-az env [--unset]` | Prints `export` lines for your shell; `eval "$(...)"` to apply |
| `ddev floci-az url` | Prints all three endpoints (`--internal` / `--host` / `--router` for one) |
| `ddev floci-az health` | Hits `/health` |
| `ddev floci-az accounts` | Lists the storage accounts that exist |
| `ddev floci-az logs [-f]` | Container logs |
| `ddev floci-az shell` | A shell in the container |
| `ddev floci-az flush` | Wipes all emulated state in place, no restart |
| `ddev floci-az reset` | Deletes the state volume, and any containers Floci spawned for this project |

`ddev floci-az az` needs the Azure CLI, which only the `-compat` image ships.
If you switch `FLOCI_AZ_IMAGE` to `floci/floci-az:latest` for the smaller image,
use your own `az` after `eval "$(ddev floci-az env)"` instead.

The connection string is injected here rather than through `azfloci`, the
wrapper the compat image ships. azfloci does the same job, but it also exports
`REQUESTS_CA_BUNDLE=""`, which current Azure CLI versions reject outright, so
every command through it fails.

## Removing the add-on

Clean up first, remove second. `ddev add-on remove` deletes the `ddev floci-az`
command along with everything else, so `reset` is no longer available once the
add-on is gone:

```bash
ddev floci-az reset          # containers Floci spawned, plus the state volume
ddev add-on remove floci-az
```

`ddev add-on remove` deliberately leaves two things behind, because neither is
the add-on's to throw away:

- **The state volume**, holding your emulated containers, queues and secrets.
  DDEV does not delete it, and neither does this add-on. The removal output
  prints the exact command; it is `ddev-` plus your project name, then
  `_floci-az`:

  ```bash
  docker volume rm ddev-<project>_floci-az
  ```

  Note the doubled prefix when the project name itself starts with `ddev-`. A
  project named `ddev-floci-az` gives `ddev-ddev-floci-az_floci-az`. If you're
  unsure of the name:

  ```bash
  docker volume ls --filter label=com.docker.compose.volume=floci-az
  ```

- **`.ddev/.env.floci-az`**, so your settings survive a reinstall.

If you skipped the `reset` and the add-on is already gone, the leftover
containers Floci spawned can be cleared by hand. Keep the namespace filter — the
emulator label alone matches every project's floci-az containers, not just this
one's:

```bash
docker rm -f $(docker ps -aq \
  --filter label=floci_emulator=floci-az \
  --filter label=floci_namespace=<project>)
```

## Credits

floci-az is by the [floci-io](https://github.com/floci-io/floci-az) project, MIT
licensed. This add-on only packages it; no Floci source is vendored here.

Behavioural notes in this README were verified against `floci/floci-az:0.11.0` on 2026-08-26.
Upstream ships frequently; the nightly workflow in `.github/workflows/tests.yml`
re-runs the suite against `latest` every day, which is what catches drift.

**Contributed and maintained by [@codementality](https://github.com/codementality)**
