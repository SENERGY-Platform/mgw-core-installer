mgw-core-installer
=======

The multi-gateway (MGW) core is the base layer of an edge gateway. It is not a
single application but a set of host processes and containers that together provide
container orchestration, module (application) lifecycle management, secret storage,
identity/authentication and an HTTP entry point for users and modules.

This repository does not contain the core itself — it contains the **installer** that
assembles a core on a host, keeps it updated and repairs it: it fetches the release binaries
from GitHub, renders all configuration files from templates, wires up
systemd/cron/logrotate/avahi and creates the container stack via Docker Compose.

## Table of contents

* [Installing](#installing)
    * [Requirements](#requirements)
    * [Interactive installation](#interactive-installation)
    * [Non-interactive installation](#non-interactive-installation)
    * [What the installer does](#what-the-installer-does)
    * [Resulting layout](#resulting-layout)
    * [After the installation](#after-the-installation)
* [Controlling the core: `ctrl.sh`](#controlling-the-core-ctrlsh)
* [Settings](#settings)
* [Updating](#updating)
    * [Automatic and manual updates](#automatic-and-manual-updates)
    * [Manual update from a downloaded release](#manual-update-from-a-downloaded-release)
    * [What an update does, and what happens when it fails](#what-an-update-does-and-what-happens-when-it-fails)
    * [Beta releases](#beta-releases)
    * [The result of an update](#the-result-of-an-update)
* [Recover and restore](#recover-and-restore)
* [Uninstalling](#uninstalling)
* [Migrating an installation of the old installer](#migrating-an-installation-of-the-old-installer)
* [Services in the core](#services-in-the-core)
    * [Host binaries](#host-binaries)
    * [Containers](#containers)
    * [Networks and how the services interact](#networks-and-how-the-services-interact)
* [Further documentation](#further-documentation)

---

## Installing

### Requirements

* **OS:** Linux, Debian/Ubuntu based distribution.
* **Privileges:** root.
* **Must already be present:** `apt`, and Docker with the Compose plugin (`docker compose`).
  If Docker is missing, the installer stops and points to
  <https://docs.docker.com/engine/install>. `systemctl` is additionally required when the core
  starts at boot (`autostart`).
* **Installed automatically (after confirmation):** `curl`, `tar`, `gzip`, `jq`, `openssl`,
  `gettext-base` (for `envsubst`) — plus `logrotate` if log rotation is enabled, `cron` if
  automatic updates are, and `avahi-daemon` if mDNS advertisement is.
* **Disk:** the install directory must be on the root file system: systemd reads the unit files
  linked from there at boot.
* **Network:** outbound HTTPS to GitHub (release binaries) and to the container registries
  (Docker Hub, `ghcr.io`).

### Interactive installation

Download and unpack a release archive, then run the installer as root:

```sh
curl -LO https://github.com/SENERGY-Platform/mgw-core-installer/releases/download/<version>/mgw_core_installer_<version>.tar.gz
mkdir mgw_core_installer_<version>
tar -xzf mgw_core_installer_<version>.tar.gz -C mgw_core_installer_<version>
cd mgw_core_installer_<version>
sudo ./setup.sh
```

The installer asks whether to change the default settings (install directory, default
`/opt/mgw`; core id; web UI user; database passwords; gateway port, default `8080`; the three
subnets; the host-directory module repository), then whether the core starts at boot, log
rotation, automatic updates, mDNS advertisement, beta releases, and whether to start the core
right away. Anything left empty keeps its default; the core id and the passwords are generated.

Running `setup.sh` from a clone of this repository works as well. There is no release version
to take, so the core is labelled `dev-<unix timestamp>`; automatic updates never touch such a
core, a manual update moves it to the newest release.

### Non-interactive installation

Pass a config file with `-c`:

```sh
sudo ./setup.sh -c /path/to/setup.conf
```

[`assets/setup.conf.example`](assets/setup.conf.example) is a ready-to-edit starting point. The
file has the format of the settings: `key=value`, one per line, the value taken literally (no
quotes, no comment after a value). It is parsed, not sourced. A key left out keeps its default,
an unknown key fails the install, and every value is checked before anything is changed.
`skip_pkg_install_confirm=true` installs missing packages without asking, `start_core=true`
starts the core at the end.

The config files of the old installer (`config.suggestion.ini`, sourced as shell) don't work
any more: see the [breaking changes](docs/design.md#breaking-changes-from-the-old-installer).

### What the installer does

1. Checks everything before it changes anything: Docker, the settings, the install directory,
   and collisions with existing units, volumes, networks, the port and the subnets.
2. Installs the missing packages.
3. Creates the core root `<install_dir>/<core_id>` and writes `state/settings`. From here on,
   every object it creates (folders, units, volumes, networks, containers) is recorded in
   `state/install` first. If the install fails, it removes exactly what it created; an install
   that was killed is cleaned up by the next `setup.sh` or at the next boot.
4. Builds the version folder: copies the release's assets, renders the configuration, downloads
   the host binaries, creates the core's networks and volumes, pulls the images and creates the
   containers.
5. Writes the secrets mount unit and the recovery unit, points `current` at the version and links
   the units and the logrotate, cron and avahi files into `/etc`.
6. Records the success and, if asked, starts the core.

At the end it prints how to control the core and how to log in.

### Resulting layout

```
/opt/mgw/<core_id>              the core root
├── v1_2_3/                     one folder per version (dots become underscores)
│   ├── assets/                 the release's files, never modified
│   ├── bin/                    the host binaries of this version
│   ├── config/                 rendered from assets/templates
│   └── ctrl.sh, update.sh, restore.sh, uninstall.sh   links into assets/scripts
├── current -> v1_2_3           the active version, switched atomically by updates
├── deployments/                module deployment data (shared with the module-manager)
├── log/                        logs of the host binaries and of the updates
├── mounts/                     config fragments the core-manager writes (gateway, identity server)
├── repositories/host_dir/      the host-directory module repository
├── sockets/                    unix sockets of the host binaries
└── state/
    ├── settings                the settings set for this core (overriding the version's defaults)
    ├── update, check           the last update and the last check for a release
    ├── install, restore        the records of the install and of the last restore
    ├── target_state            whether the core is meant to run
    ├── images, attempts        the pulled core images, failures for the retry limit
    ├── host-manager/           the host-manager's data
    ├── pid                     only without autostart: the host binaries' processes
    └── lock                    the core's lock
/mnt/<core_name>/secrets        tmpfs, shared between the secret-manager and the modules
```

Everything outside the version folders survives updates. In `/etc`, the service units, the
logrotate, cron and avahi files are links into `current/config`; the mount unit and the recovery
unit are plain files the core owns.

### After the installation

The web UI is reachable at `http://<host>:<gateway_port>/` — the root path redirects to
`/core/web-ui`, which requires a login with `core_usr` and `core_usr_pw` (stored in
`state/settings`). If mDNS advertisement is enabled, the core announces itself as
`_snrgy-mgwcore._tcp` with the API, auth and discovery paths and the core id as TXT records.

---

## Controlling the core: `ctrl.sh`

```sh
sudo /opt/mgw/<core_id>/current/ctrl.sh <command>
```

| Command | What it does |
| --- | --- |
| `start` | starts the core: the host binaries; the core-manager starts the containers |
| `stop` | stops the core; the core-manager stops the containers first |
| `restart` | stop, then start |
| `ctr-recreate` | recreates the core's containers (a running core is stopped and started again) |
| `settings list`, `settings get <key>` | shows the settings |
| `settings set <key> <value>`, `settings reset <key>` | changes a setting and applies it, see [Settings](#settings) |
| `status` | the core's state, its version, its last update and check, and who holds its lock |

`-y` answers every confirmation with yes. The changing commands take the core's lock, so they
never run at the same time as an update. They don't repair anything: if the core needs repair
(an interrupted update that couldn't be recovered, a failed restore), they refuse and name the
`restore.sh` to run.

`start` and `stop` also record whether the core is meant to run: a core stopped on purpose stays
stopped after an update. After a reboot, `autostart` decides.

---

## Settings

The effective settings are the version's defaults (`assets/settings.defaults`) with
`state/settings` on top. `state/settings` holds what was set for this core: the install's
choices and generated values, and what was changed later with `ctrl.sh settings set`. Both files
are `key=value` and parsed, never sourced. A new version may bring new settings with new
defaults; an update adds a setting to `state/settings` only where the new default would change
the behaviour of an existing core.

What changing a setting with `ctrl.sh settings set` takes:

| Settings | Effect |
| --- | --- |
| `allow_beta`, `update_retry_limit` | stored, effective with the next update |
| the log levels, `module_manager_http_access_log`, the startup delays | the containers are recreated |
| `gateway_port` | the new port must be free; the containers are recreated |
| `logrotate`, `cron`, `advertise` | the package is installed if missing, the file in `/etc` is linked or removed |
| `secrets_size` | the mount unit is rewritten; effective at the next reboot |
| `autostart` | switches between systemd services and detached processes; the core is stopped and started again |
| `core_id`, `core_name`, `stack_name`, the passwords, `core_usr`, the subnets, `host_dir_repository_path` | refused: they are part of the existing volumes, networks, databases and containers |

`ctrl.sh settings reset <key>` goes back to the version's default; only the first two rows
follow the defaults, the others keep the value the install wrote.

---

## Updating

Updates come from the GitHub releases of this repository. Tags follow semantic versioning:
`vX.Y.Z`, `vX.Y.Z-beta.N`, `vX.Y.Z-alpha.N` (older tags have the form `vX.Y.Z-betaN`).

### Automatic and manual updates

With `cron=true`, `/etc/cron.daily/<core_name>_update` runs `current/update.sh -a` once a day,
logging to `log/core_update.log`. By hand:

```sh
sudo /opt/mgw/<core_id>/current/update.sh
```

An automatic run skips a version that failed `update_retry_limit` times (default 3) and never
updates a `dev-` version. A manual run always tries, and resets the count.

### Manual update from a downloaded release

To update to a specific release, e.g. a beta without `allow_beta` or an alpha, which `update.sh`
never picks by itself, unpack its archive anywhere and run its `update.sh` with the core root:

```sh
sudo ./update.sh -path=/opt/mgw/<core_id>
```

It works like any update, with the same rollback; only the version comes from the archive instead
of GitHub. The host binaries and images are still downloaded. The archive's version must be newer
than the running one: the same version is left as it is (`restore.sh` rebuilds it), an older one is
refused (`restore.sh -downgrade` installs it, see [Recover and restore](#recover-and-restore)). The
same command migrates an installation of the old installer, given its install directory (see
[Migrating](#migrating-an-installation-of-the-old-installer)).

### What an update does, and what happens when it fails

1. The running version (stage one) checks for a newer release, downloads it and copies it into
   a new version folder `vX_Y_Z_tmp`, then hands over to the new version's `update.sh`.
2. The new version (stage two) prepares itself while the old core keeps running: renders its
   configuration, downloads its host binaries, pulls its images, creates its containers. A
   failure here removes what it created; the old core never noticed.
3. It stops the old core and points `current` at the new version. A failure here rolls back to
   the old version, which is started again if it was running.
4. It starts the new core, if the old one was meant to run. Once the first host binary of the new
   version has started, there is no rollback any more: it may have migrated data the old version
   can't read. A failure from here on is recorded and the new version stays.
5. On success it removes the old version folder, its containers and the images no longer used.
   The volumes, the settings and everything outside the version folders stay.

A failed rollback, which should never happen, stops everything and points to `restore.sh`. An
update that was interrupted (power loss, a killed process) is completed or undone automatically:
by the recovery unit at the next boot, or by the next `update.sh`, before it looks for a release.

### Beta releases

With `allow_beta=true` (`ctrl.sh settings set allow_beta true`) updates also take beta releases.
Alpha releases are never taken by `update.sh`, also not by hand: an alpha is installed on purpose,
with `setup.sh` or `restore.sh -path=` from its archive. A core on an alpha updates to newer
releases as usual.

### The result of an update

`ctrl.sh status` shows the last update and the last check. The details are in
`state/update` (the update: versions, phase, result, whether it was rolled back or interrupted,
the failed step, warnings) and `state/check` (the last look for a release). The core-manager
reports both through its health API.

---

## Recover and restore

Both repair a core, but they react to different things.

* **Recover** (`assets/scripts/recover.sh`, internal) finishes an interrupted operation. It only
  acts if a record says an install or update was interrupted, and does exactly what that
  operation's own error handling would have done at that point: interrupted while preparing, the
  half-built version is removed; while switching, it rolls back to the previous version; while
  starting, the new version stays; an unfinished install is removed completely. It runs by itself
  (the recovery unit at boot, `update.sh` before it updates), needs no network, and does nothing
  if nothing was interrupted.
* **Restore** (`restore.sh`) repairs a broken core, whatever happened. It doesn't ask what went
  wrong: it rebuilds one version onto the core's existing data (the volumes and
  `state/settings`). It needs downloads and is started by a person.

Recover is the cheap first attempt, restore the step after it. `restore.sh` is the one repair
command to run; it tries the recovery first and only rebuilds if that isn't enough.

```sh
sudo /opt/mgw/<core_id>/current/restore.sh               # rebuild the current version
sudo ./restore.sh -path=/opt/mgw/<core_id>               # from an unpacked release archive: its version
```

| Option | Meaning |
| --- | --- |
| `-y` | answer yes to the confirmation |
| `-start` | start the core afterwards, whatever its target state says |
| `-downgrade` | allow restoring a version older than the one the core ran |
| `-s=<file>` | a copy of `state/settings`, for a core root that is lost while the volumes survived |

Restore reuses every object of the core that exists and recreates missing ones; it never removes
data. A volume that is missing is created empty and named in the output and in `state/restore`:
its data is lost. Without `state/settings` (or a copy with `-s`) a core can't be restored: the
data in the volumes only works with the passwords it was created with.

---

## Uninstalling

```sh
sudo /opt/mgw/<core_id>/current/uninstall.sh [-y]
sudo ./uninstall.sh -path=/opt/mgw/<core_id> [-y]        # from an unpacked release archive
```

Removes everything of the core: its containers and those of the deployed modules, its images,
volumes and networks, the units and files in `/etc`, the secrets tmpfs and the core root. There
are no options to keep data. It works on a broken or half-installed core as well; whatever it
can't remove is listed at the end.

A host-directory module repository (`host_dir_repository_path`) outside the core root is not
removed: the installation was pointed at it, and other cores may use it too. This also applies to
installations migrated from the old installer that had their own install directory: the old
installer still put their repository in `/opt/mgw/repositories/host_dir`, and the migration keeps
it there.

---

## Migrating an installation of the old installer

Installations of the old installer (one flat directory, usually `/opt/mgw`, with `.settings`,
`ctrl.sh`, `bin/` and `container/`) are migrated by their next update: the old `update.sh`,
by cron or by hand, downloads the new release and hands over to it. Nothing has to be done by
hand. To migrate to a specific release instead, e.g. an alpha or a beta, unpack its archive and run
`sudo ./update.sh -path=<install dir>` (e.g. `-path=/opt/mgw`). The install directory becomes the
core root (there is no `<core_id>` level), the volumes, the module deployments and the settings are
taken over.

* **Minimum version:** installations from `v0.30.0-alpha1` on are migrated. An older one is
  refused without any change; update it first to an old-layout release from `v0.30.0` on:
  download that release's archive, unpack it and run its `assets/scripts/update.sh
  -path=<install dir>`. The next update migrates it.
* **Settings that don't fit:** the new layout derives its paths from the core root and uses the
  standard locations in `/etc`. An installation whose `.settings` points elsewhere is refused
  before anything is changed, naming the setting.
* **Where to look:** a refusal or a failure is written to the old `.update_status` as well, so
  the old core-manager reports it. After the migration, `current/ctrl.sh status` shows it.
* **When it fails:** a failure before the new core starts rolls back to the old installation,
  which is started again with its own `ctrl.sh`; the next update tries again (the retry limit
  applies). An interrupted migration is recovered by the next update or at boot.
* **Known gap:** if the migration fails or is interrupted after the first host binary of the new
  version has started, the new layout stays (no rollback, as for any update) and the old
  installation's leftovers are never removed: its files (`bin/`, `container/`, `scripts/`, the old
  scripts and dot files), its stopped containers and its images. They take disk space, nothing
  else; `uninstall.sh` removes them with the core.

What changed for users and scripts compared to the old installer is listed in the
[breaking changes](docs/design.md#breaking-changes-from-the-old-installer).

---

## Services in the core

The core is split into two layers. **Host binaries** need direct access to the host (Docker
socket, network interfaces, hostname, systemd) and therefore run as plain processes,
managed by systemd or by `ctrl.sh`. They expose their APIs on unix sockets in
`<core root>/sockets`. **Containers** run inside the Compose stack and talk to each other
over Docker networks. Everything is tied together by the nginx gateway, which is the only
component reachable from outside and the only bridge between the containers and the unix
sockets of the host binaries.

### Host binaries

| Service | Repository | Socket | Purpose |
| --- | --- | --- | --- |
| **container-engine-wrapper** | `SENERGY-Platform/mgw-container-engine-wrapper` | `ce_wrapper.sock` | Abstracts the container engine. It is the only component with access to `/var/run/docker.sock` and creates, starts, stops and inspects module containers, networks and volumes on behalf of the module-manager. Also sets the container log driver and log limits. |
| **host-manager** | `SENERGY-Platform/mgw-host-manager` | `h_manager.sock` | Provides information about the host itself — network interfaces, addresses, hostname and registered host applications — to modules and to the core. A blacklist keeps the core's own subnets, the Docker socket and blacklisted interfaces out of the data handed to modules. Its data lives in `state/host-manager`. |
| **core-manager** | `SENERGY-Platform/mgw-core-manager` | `c_manager.sock` | Manages the core itself: it starts the core containers when it starts and stops them when it stops, restarts crashed ones, rewrites the gateway's public endpoint fragment (`mounts/nginx/dep_endpoints.location`) and the dynamic identity-server config (`mounts/kratos/config.json`), serves the log files of the host binaries, and reports the state of updates and checks through its health API. |

With `autostart=true` they run as systemd services `<core_name>-ce-wrapper`,
`<core_name>-host-manager` and `<core_name>-core-manager`, restarted after a crash. They run after
the recovery unit `<core_name>-recover.service`, which completes or undoes an interrupted install
or update at boot, and the core-manager and host-manager are `PartOf=` the ce-wrapper unit,
which is `PartOf=` `docker.service`. Without autostart, `ctrl.sh start` starts them as detached
processes, recorded in `state/pid`. A mount unit provides the tmpfs at
`/mnt/<core_name>/secrets` (`secrets_size`, default 100M).

### Containers

| Service | Image | Networks | Purpose |
| --- | --- | --- | --- |
| **nginx** (gateway) | `nginx` | gateway, core, module (aliased `core-api`) | The single entry point. Publishes the public API on `gateway_port` (TCP and UDP) and an internal API on port 80. Terminates authentication via `auth_request` against the identity server, routes to all core services and — through the unix sockets it mounts — to the host binaries. Serves module endpoints under `/endpoints` from the fragment maintained by the core-manager. |
| **mysqldb** | `mysql` | core (aliased `core-db`) | Shared database. The init script creates the `module_manager`, `secret_manager` and `kratos` schemas and grants them to `core_user`. |
| **kratos** (identity-server) | `oryd/kratos` | core (aliased `identity-server`) | Ory Kratos. Owns human and machine identities, login/logout self-service flows and session validation. Its static config ships with the core, a second config file is written dynamically by the core-manager. |
| **kratos-migrate** | `oryd/kratos` | core | One-shot job that applies the Kratos SQL migrations before the identity server starts. |
| **auth-service** | `ghcr.io/senergy-platform/mgw-auth-service` | core | Sits in front of the identity server's admin API. Handles user management and the device pairing flow (`/pairing/request` is the one public endpoint that needs no session). Authenticates against Kratos with the generated `core-user` credentials. |
| **module-manager-migration** | `ghcr.io/senergy-platform/mgw-module-manager-migration` | core | One-shot job that migrates the module-manager's data before it starts. |
| **module-manager** | `ghcr.io/senergy-platform/mgw-module-manager` | core | The heart of the core: manages module repositories (GitHub and a host directory), module installation, deployments and auxiliary deployments. Translates a module definition into containers, volumes and secrets by calling the ce-wrapper, core-manager, host-manager and secret-manager, and serves the discovery API. |
| **secret-manager** | `ghcr.io/senergy-platform/mgw-secret-manager` | core | Stores secrets (certificates, credentials) in the database, keyed by a master key on its own volume, and materialises them into the shared secrets tmpfs so that module containers can mount them as files. |
| **web-ui** | `ghcr.io/senergy-platform/mgw-gui` | module | The browser UI. It is deliberately placed on the module network and reachable only through the gateway at `/core/web-ui`, so every request passes the session check. |

Image tags and binary versions are pinned per release in [`assets/options`](assets/options).
The containers belong to the compose project `<core_name>_<version folder>`, so each version has
containers of its own, while the volumes (`<stack_name>_<name>`) and networks are shared by all
versions and survive updates. The containers have no restart policy of their own: the
core-manager owns their lifecycle. Log levels and a few module-manager timings are
[settings](#settings).

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
  instance with one schema each; everything else lives in named volumes or in the secrets
  tmpfs (which is intentionally volatile and is repopulated by the secret-manager).

## Further documentation

* [docs/design.md](docs/design.md) — how the installer works and why: the layout, the state
  files, the update phases and their guarantees, recovery, restore, the migration, and the
  breaking changes from the old installer.
* [docs/adding-a-setting.md](docs/adding-a-setting.md) — what a new setting has to touch.
* [docs/testing.md](docs/testing.md) — the unit and VM tests, and how to test the release
  workflow.
