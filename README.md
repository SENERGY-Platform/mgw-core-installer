mgw-core-installer
=======

The multi-gateway (MGW) core is the base layer of a edge gateway. It is not a
single application but a set of host processes and containers that together provide
container orchestration, module (application) lifecycle management, secret storage,
identity/authentication and a HTTP entry point for users and modules.

This repository does not contain the core itself — it contains the **installer** that
assembles a core on a host: it fetches the release binaries from GitHub, renders all
configuration files from templates, wires up systemd/cron/logrotate/avahi and creates the
container stack via Docker Compose.

## Table of contents

* [Installing the mgw-core](#installing-the-mgw-core)
    * [Requirements](#requirements)
    * [Interactive installation](#interactive-installation)
    * [Non-interactive installation](#non-interactive-installation)
    * [What the installer does](#what-the-installer-does)
    * [Resulting layout](#resulting-layout)
    * [After the installation](#after-the-installation)
* [Updating](#updating)
    * [Manual update](#manual-update)
    * [Automatic updates](#automatic-updates)
    * [Beta and alpha releases](#beta-and-alpha-releases)
* [Uninstalling](#uninstalling)
    * [What is removed](#what-is-removed)
    * [What is kept](#what-is-kept)
* [Using `ctrl.sh`](#using-ctrlsh)
* [Services in the core](#services-in-the-core)
    * [Host binaries](#host-binaries)
    * [Containers](#containers)
    * [Networks and how the services interact](#networks-and-how-the-services-interact)

---

## Installing the mgw-core

### Requirements

* **OS:** Linux, Debian/Ubuntu based distribution.
* **Privileges:** root.
* **Must already be present:** `systemctl`, `apt`, and Docker with Compose
  (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`). If Docker is
  missing the installer stops and points to <https://docs.docker.com/engine/install>.
  Both `docker compose` and the legacy `docker-compose` binary are supported — the
  installer detects which one is available.
* **Installed automatically (after confirmation):** `curl`, `tar`, `gzip`, `jq`,
  `avahi-daemon`, `openssl`, `gettext-base` (for `envsubst`), `logrotate`.
* **Network:** outbound HTTPS to GitHub (release binaries) and to the container registries
  (Docker Hub, `ghcr.io`).

### Interactive installation

Download and unpack the release archive published by the
[release workflow](.github/workflows/release.yml), then run the installer as root:

```sh
curl -LO https://github.com/SENERGY-Platform/mgw-core-installer/releases/download/<version>/mgw_core_installer_<version>.tar.gz
tar -xzf mgw_core_installer_<version>.tar.gz
cd mgw_core_installer_<version>
sudo ./setup.sh
```

The installer asks for confirmation and then walks through a number of prompts:

1. **Change default settings?** — install directory (`base_path`, default `/opt/mgw`),
   Compose stack name, core ID, database and database-root passwords, gateway port
   (default `8080`), the three subnets and the host-directory module repository path.
   Anything left empty keeps its default; passwords, core ID and core name are generated
   if unset.
2. **OS startup integration** — installs and enables the systemd units so the core starts
   with the host. If declined, the core has to be started manually with `ctrl.sh`.
3. **Log rotation** — installs a `logrotate.d` config for `<base_path>/log/*.log`.
4. **Automatic updates** — installs a `cron.daily` job that runs `update.sh -a`.
5. **mDNS advertisement** — publishes an avahi service so the core is discoverable in the
   local network.
6. **Allow beta releases** — whether `update.sh` may pick up `-beta` tags.
7. **Start containers** — only asked when systemd integration is enabled, since the
   container stack needs the host binaries to be running.

### Non-interactive installation

Pass a config file with `-c`. The file is sourced as shell, so it is a plain list of
variable assignments; `assets/config.suggestion.ini` is a ready-to-edit starting point:

```sh
sudo ./setup.sh -c /path/to/config.ini
```

In this mode no questions are asked. `skip_pgk_install_confirm=true` also suppresses the
package-installation prompt, and `start_containers=true` starts the stack at the end of the
installation. `./setup.sh -h` prints the usage.

Three paths can additionally be overridden through environment variables, each of which
must be absolute: `SYSTEMD_PATH`, `LOGROTATED_PATH`, `CRON_PATH`.

### What the installer does

In order, `setup.sh`:

1. Detects platform/architecture and the available Compose command.
2. Resolves all settings, generates missing IDs and passwords and exports them as
   environment variables for template rendering.
3. Verifies the required packages and installs the missing optional ones.
4. Creates the directory layout and copies `ctrl.sh`, `update.sh`, `uninstall.sh` and the
   script library into the install directory.
5. Downloads the host binaries listed in `assets/.options` from their GitHub releases,
   extracts the archive matching the host architecture and renders their `conf.json`
   templates. Installed binary versions are recorded in `<base_path>/.binaries`.
6. Renders and installs the systemd mount/service units (prefixed with the core name),
   the logrotate config, the cron job and the avahi service. Installed units are recorded
   in `<base_path>/.units`, then enabled and started.
7. Copies the container configs and the compose template, renders `docker-compose.yml` from
   the installed template, creates the containers with `docker compose up --no-start` and
   optionally starts them. The template is kept in `container/` so that `ctrl.sh` can
   re-render without the release archive.
8. Writes `<base_path>/.settings`, which is the single source of truth for all later
   `ctrl.sh` and `update.sh` runs.

### Resulting layout

```
/opt/mgw                      <- base_path
├── ctrl.sh                   control script
├── update.sh                 update script
├── uninstall.sh              uninstall script
├── .settings                 all resolved settings (sourced by ctrl.sh/update.sh)
├── .version                  installed release
├── .binaries                 installed host binaries and their versions
├── .units                    installed systemd units
├── .pid                      PIDs of the host binaries (only without systemd)
├── .options                  image and binary pins of the installed release
├── bin/SENERGY-Platform/     host binaries + rendered configs
├── container/                docker-compose.yml + its template, .env, container configs
├── deployments/              module deployment data (shared with module-manager)
├── sockets/                  unix sockets of the host binaries
├── mounts/nginx/             gateway config fragments written by the core-manager
├── mounts/kratos/            identity-server config written by the core-manager
├── repositories/host_dir     host-directory module repository
├── log/                      logs of the host binaries (incl. their *_out.log) and the updater
└── scripts/                  shared shell library
/mnt/<core_name>/secrets      tmpfs, shared between secret-manager and modules
```

### After the installation

The web UI is reachable at `http://<host>:<gateway_port>/` — the root path redirects to
`/core/web-ui`, which requires a login. If mDNS advertisement is enabled, the core also
announces itself as `_mgwcore_<core_id>._tcp` with the API, auth and discovery paths as
TXT records.

---

## Updating

Updating is driven by GitHub releases of this repository. The installed release is stored
in `<base_path>/.version` and compared against the release tags.

### Manual update

```sh
sudo /opt/mgw/update.sh
```

The update runs in two stages:

1. **The installed `update.sh`** (no `-path` argument) sources `.settings` and `.version`,
   fetches the release list, and picks the *newest* release that is greater than the
   installed version. `-alpha` releases are always skipped, `-beta` releases only qualify
   when `allow_beta=true`. If the installed version is already the latest tag, the script
   reports "nothing to do" and exits. Otherwise it asks for confirmation, downloads and
   extracts the new release archive to `/tmp/mgw-update` and hands over to stage two.
2. **The new release's `update.sh`** (invoked with `-path=<base_path>`) performs the actual
   update:
    * installs newly required packages,
    * refreshes `ctrl.sh`, `update.sh`, `uninstall.sh` and the script library in the install
      directory,
    * stops the containers, then the systemd units (or the raw processes and the secrets
      tmpfs when running without systemd) and clears the secrets tmpfs,
    * downloads only those host binaries whose pinned version changed, removes binaries that
      are no longer part of the release and re-renders their configs,
    * re-renders the systemd units, logrotate config, cron job and avahi service, removing
      units that no longer exist,
    * replaces the container assets, pulls the new images, recreates the containers and —
      with systemd integration — starts them again,
    * writes the new `.version` and `.settings`.

Because the second stage always comes from the *new* release, migration steps ship with the
release that needs them.

### Automatic updates

If enabled during installation, `/etc/cron.daily/<core_name>_update` runs

```sh
<base_path>/update.sh -a >> <base_path>/log/core_update.log 2>&1
```

`-a` makes the update non-interactive: no confirmation prompts, no colored output, and each
run is stamped with an RFC-3339 timestamp in the log. If a step would require user
interaction (for example a new setting introduced by the release that has no default), the
run aborts with *"user interaction required, please run update manually"* — the update then
has to be triggered by hand.

Automatic updates can be enabled or disabled later by adding or removing that cron file.

### Beta and alpha releases

* Beta releases are only considered when `allow_beta=true`; toggle it with
  `sudo /opt/mgw/ctrl.sh beta-test`.
* Alpha releases are never picked up automatically. An installed alpha version cannot be
  updated at all — `update.sh` exits with *"alpha versions must be updated manually"*, so a
  new release has to be installed by running its `setup.sh`.

---

## Uninstalling

```sh
sudo /opt/mgw/uninstall.sh
```

`uninstall.sh` is installed next to `ctrl.sh` and `update.sh` and takes everything the
installer put on the host back off it. It reads `.settings`, `.units` and `.options` from
the install directory, prints what it is about to remove and asks for confirmation.

| Option | Effect |
| --- | --- |
| `-path=<install path>` | Uninstall the core in that directory instead of the one the script lives in. Only needed when the script is run from an extracted release archive, for example to uninstall a core whose release did not ship `uninstall.sh` yet. |
| `-y` | Do not ask for confirmation. |
| `-i` | Also remove the container images pinned in `.options`. |
| `-h` | Print the usage. |

### What is removed

* **Containers, volumes and networks** — everything labelled `mgw_cid=<core_id>`, which
  includes the containers and volumes of **deployed modules**, plus everything belonging to
  the Compose project (`com.docker.compose.project=<stack_name>`), which is where the core's
  own volumes and networks are found. Both sets are read from the container engine rather
  than from `docker-compose.yml`, so the uninstall also works on an installation whose
  container assets are broken or gone.
* **The host binaries** — the systemd units are stopped, disabled and deleted, or, without
  systemd integration, the processes recorded in `.pid` are terminated. The secrets tmpfs is
  unmounted and `/mnt/<core_name>` removed.
* **The integration files** — `logrotate.d`, `cron.daily` and the avahi service, regardless
  of whether the corresponding setting is still enabled.
* **The install directory** — `<base_path>` with all binaries, configs, logs, deployment
  data and the scripts themselves.
* **The container images** of the core, but only with `-i`. Images a module brought with it
  are not tracked anywhere and are always kept; an image another core on the same host still
  uses cannot be removed by Docker and is reported and skipped.

---

## Using `ctrl.sh`

**WARNING: The `ctrl.sh` script is meant to be used for development and manual testing purposes only!**

`ctrl.sh` must be run as root from the installation directory (`/opt/mgw/ctrl.sh`), reads `.settings` and adapts its behaviour to
whether systemd integration is active.

When a core is installed without systemd integration `ctrl.sh start` and `ctrl.sh stop` must be used
to start and stop the host binaries and docker containers. Such a core comes up with the container
restart policy `no`, so a host restart without a preceding `ctrl.sh stop` leaves the whole core
down rather than the containers running without their host binaries. Calling `ctrl.sh start`
brings it back.

`start` and `stop` may be called from a non-interactive context (a script, a cron job, a CI step). The host binaries
are detached into their own session, so they are not killed when the calling shell or ssh session ends.

```
sudo /opt/mgw/ctrl.sh <command>
```

| Command | Effect | When to use |
| --- | --- | --- |
| `start` | With systemd: starts the units. Without: starts the three host binaries detached from the calling session, records their PIDs in `.pid` and mounts the secrets tmpfs. Then starts the containers. Fails if a binary does not stay alive; a leftover `.pid` from a crash or a reboot is cleaned up. | Bringing the core up on a host without startup integration, after a reboot, or after a manual `stop`. |
| `stop` | Stops the containers, then the units (or kills the processes recorded in `.pid` that are still running as host binaries and unmounts the tmpfs). Does nothing if the binaries are not running. | Maintenance on the host, backups, before changing the Docker setup. |
| `enable` | Enables the installed systemd units and sets the container restart policy back to `unless-stopped`, re-rendering `docker-compose.yml` and recreating the containers. A running core keeps running. | Re-enabling startup integration after `disable`. Requires systemd integration. |
| `disable` | Disables the installed systemd units and sets the container restart policy to `no`, re-rendering `docker-compose.yml` and recreating the containers. A running core keeps running. | Keeping the core from starting on boot without uninstalling it. Requires systemd integration. |
| `ctr-recreate` | Removes and recreates the containers. Volumes are kept. | After editing `container/.env` (for example to raise a log level), or when a container is in a broken state. |
| `ctr-purge` | Removes the containers **and their volumes**, then recreates them. | Last resort / factory reset of the container layer. **Destroys the databases, the module-manager data and the secret-manager master key.** |
| `beta-test` | Toggles `allow_beta` in `.settings`. | Opting in to or out of beta releases for future updates. |
| `help` | Prints the command list. | |

Notes on the order of operations: the host binaries must run before the containers, because
the gateway proxies to their unix sockets and the module-manager talks to the container
engine wrapper through the gateway. `start` therefore always brings up the binaries (or
units) first and waits a second before starting the containers; `stop` reverses that order.

---

## Services in the core

The core is split into two layers. **Host binaries** need direct access to the host (Docker
socket, network interfaces, hostname, systemd) and therefore run as plain processes,
managed by systemd or by `ctrl.sh`. They expose their APIs on unix sockets in
`<base_path>/sockets`. **Containers** run inside the Compose stack and talk to each other
over Docker networks. Everything is tied together by the nginx gateway, which is the only
component reachable from outside and the only bridge between the containers and the unix
sockets of the host binaries.

### Host binaries

| Service | Repository | Socket | Purpose |
| --- | --- | --- | --- |
| **container-engine-wrapper** | `SENERGY-Platform/mgw-container-engine-wrapper` | `ce_wrapper.sock` | Abstracts the container engine. It is the only component with access to `/var/run/docker.sock` and creates, starts, stops and inspects module containers, networks and volumes on behalf of the module-manager. Also sets the container log driver and log limits. |
| **host-manager** | `SENERGY-Platform/mgw-host-manager` | `h_manager.sock` | Provides information about the host itself — network interfaces, addresses, hostname and registered host applications — to modules and to the core. A blacklist keeps the core's own subnets, the Docker socket and blacklisted interfaces out of the data handed to modules. |
| **core-manager** | `SENERGY-Platform/mgw-core-manager` | `c_manager.sock` | Manages the core itself: it rewrites the gateway's public endpoint fragment (`mounts/nginx/dep_endpoints.location`) and the dynamic identity-server config (`mounts/kratos/config.json`), restarts the gateway service through the container-engine wrapper, knows the Compose file and serves the log files of all three host binaries through its log handler. |

The systemd units express their dependencies: the core-manager and host-manager units are
`PartOf=` and ordered `Before=` the ce-wrapper unit, which in turn is `PartOf=`/`Before=`
`docker.service`. A `secrets.mount` unit provides the tmpfs at `/mnt/<core_name>/secrets`
(`nosuid,nodev,noexec,mode=1777,size=100M`).

### Containers

| Service | Image | Networks | Purpose |
| --- | --- | --- | --- |
| **nginx** (gateway) | `nginx:1.31.1-alpine` | gateway, core, module (aliased `core-api`) | The single entry point. Publishes the public API on `${GATEWAY_PORT}` (TCP and UDP) and an internal API on port 80. Terminates authentication via `auth_request` against the identity server, routes to all core services and — through the unix sockets it mounts — to the host binaries. Serves module endpoints under `/endpoints` from the fragment maintained by the core-manager. |
| **mysqldb** | `mysql:8.4.9` | core (aliased `core-db`) | Shared database. The init script creates the `module_manager`, `secret_manager` and `kratos` schemas and grants them to `core_user`. |
| **kratos** (identity-server) | `oryd/kratos:v1.3.1` | core (aliased `identity-server`) | Ory Kratos. Owns human and machine identities, login/logout self-service flows and session validation. Its static config ships with the core, a second config file is written dynamically by the core-manager. |
| **kratos-migrate** | `oryd/kratos:v1.3.1` | core | One-shot job that applies the Kratos SQL migrations before the identity server starts. Restarts on failure only. |
| **auth-service** | `ghcr.io/senergy-platform/mgw-auth-service` | core | Sits in front of the identity server's admin API. Handles user management and the device pairing flow (`/pairing/request` is the one public endpoint that needs no session). Authenticates against Kratos with the generated `core-user` credentials. |
| **module-manager** | `ghcr.io/senergy-platform/mgw-module-manager` | core | The heart of the core: manages module repositories (GitHub and a host directory), module installation, deployments and auxiliary deployments. Translates a module definition into containers, volumes and secrets by calling the ce-wrapper, core-manager, host-manager and secret-manager, and serves the discovery API. |
| **secret-manager** | `ghcr.io/senergy-platform/mgw-secret-manager` | core | Stores secrets (certificates, credentials) in the database, keyed by a master key on its own volume, and materialises them into the shared secrets tmpfs so that module containers can mount them as files. |
| **web-ui** | `ghcr.io/senergy-platform/mgw-gui` | module | The browser UI. It is deliberately placed on the module network and reachable only through the gateway at `/core/web-ui`, so every request passes the session check. |

Image tags and binary versions are pinned centrally in [`assets/.options`](assets/.options);
log levels and a few module-manager timings can be adjusted in `container/.env`.

### Networks and how the services interact

Three Docker networks separate the traffic:

| Network | Name | Size | Members |
| --- | --- | --- | --- |
| gateway | `<core_name>-0-gateway-net` | `/28` | nginx only — the outward-facing side. |
| core | `<core_name>-1-core-net` | `/28` | All core containers plus nginx. |
| module | `<core_name>-2-module-net` | `/16` | Module containers, the web UI and nginx. |

The gateway enforces the boundary between them. On the **internal API** (port 80) the
paths `/c-manager`, `/ce-wrapper` and `/h-manager` are restricted to the core subnet, while
`/module-manager`, `/host-manager` and `/host-info` are restricted to the module subnet and
are proxied to the `/restricted` prefix of the respective service — modules therefore only
ever see the reduced API surface. On the **public API** the module subnet is denied
outright, and everything under `/core/api`, `/core/web-ui`, `/core/swagger` and
`/endpoints` requires a valid Kratos session; unauthenticated browsers are redirected to
`/core/web-ui/login`.

The typical flows are:

* **User login** — the browser hits the public API, nginx sends the request to
  `/core/auth/login`, which is proxied to the identity server's self-service flow. On
  success Kratos sets a session cookie; every later request is validated by nginx through
  an internal `auth_request` to `identity-server/sessions/whoami`.
* **Deploying a module** — the web UI (or an external client) calls
  `/core/api/module-manager`. The module-manager reads the module from a repository, asks
  the **secret-manager** to provide the required secrets in the shared tmpfs, asks the
  **host-manager** for host resources the module requested, and then instructs the
  **ce-wrapper** to create the volumes and containers.
* **Publishing a module endpoint** — when a deployment exposes an endpoint, the
  **core-manager** writes it into `mounts/nginx/dep_endpoints.location` and restarts the
  gateway through the ce-wrapper. The endpoint then appears under `/endpoints` on the
  public API, behind the same session check.
* **A module calling the core** — module containers reach only `core-api` on the module
  network and can use `/module-manager`, `/host-manager` and `/host-info`, all limited to
  the restricted API surface.
* **Persistence** — the module-manager, secret-manager and Kratos share the `mysqldb`
  instance with one schema each; everything else lives in named volumes or in the secrets tmpfs (which is intentionally volatile and
  is repopulated by the secret-manager).

## Further documentation

`docs/` holds the failure modes met while running a core on a dev machine with
`systemd=false` — none of them visible from the outside. See
[dev install pitfalls](docs/dev-install-pitfalls.md).
