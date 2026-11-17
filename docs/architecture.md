# Architecture of a core

What a core consists of once it is installed: the host binaries, the containers, the three Docker
networks and the gateway's routes between them, and how the services work together.

## Applies when

You need to know which service does what, which network or route a module can reach, or where a
request goes. How the installer builds, updates and repairs a core is in [design.md](design.md).

## Overview

The core is split into two layers. **Host binaries** need direct access to the host (Docker
socket, network interfaces, hostname, systemd) and therefore run as plain processes,
managed by systemd or by `ctrl.sh`. They expose their APIs on unix sockets in
`<core root>/sockets`. **Containers** run inside the Compose stack and talk to each other
over Docker networks. Everything is tied together by the nginx gateway, which is the only
component reachable from outside and the only bridge between the containers and the unix
sockets of the host binaries.

## Host binaries

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

## Containers

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

Image tags and binary versions are pinned per release in [`assets/options`](../assets/options).
The containers belong to the compose project `<core_name>_<version folder>`, so each version has
containers of its own, while the volumes (`<stack_name>_<name>`) and networks are shared by all
versions and survive updates. The containers have no restart policy of their own: the
core-manager owns their lifecycle. Log levels and a few module-manager timings are
settings (README, "Settings").

## Networks and how the services interact

Three Docker networks separate the traffic:

| Network | Name | Size | Members |
| --- | --- | --- | --- |
| gateway | `<core_name>-0-gateway-net` | `/28` | nginx only — the outward-facing side. |
| core | `<core_name>-1-core-net` | `/28` | All core containers plus nginx. |
| module | `<core_name>-2-module-net` | `/16` | Module containers, the web UI and nginx. |

The gateway enforces the boundary between them. On the **internal API** (port 80) the
paths `/c-manager`, `/ce-wrapper` and `/h-manager` are restricted to the core subnet, while
`/module-manager` and `/host-manager` are restricted to the module subnet and are proxied to
the `/restricted` prefix of the respective service — modules therefore only ever see the
reduced API surface. `/core-health` (`GET` only, also from the module subnet) is the
core-manager's health report, e.g. for a module that reports the gateway's health to the cloud;
`/core-manager/health` is the same, kept for modules written for older installers. On the
**public API** the module subnet is denied
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
  network and can use `/module-manager` and `/host-manager`, both limited to the
  restricted API surface, and read `/core-health`.
* **Persistence** — the module-manager, secret-manager and Kratos share the `mysqldb`
  instance with one schema each; everything else lives in named volumes or in the secrets
  tmpfs (which is intentionally volatile and is repopulated by the secret-manager).
