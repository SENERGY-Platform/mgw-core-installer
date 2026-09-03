# Dev install pitfalls

What the README does not say. The README describes the
[non-interactive installation](../README.md#non-interactive-installation),
[`ctrl.sh`](../README.md#using-ctrlsh) and the
[host binaries](../README.md#host-binaries); this document carries the failure
modes met while running a core on a dev machine, each of which cost a working
session.

## Applies when

A local dev install on a machine using WSL2 with Docker and systemd as PID 1,
with a minimal-footprint config: `systemd=false`, `logrotate=false`,
`cron=false`, `advertise=false`.

**Not this if**: the installer's systemd units are enabled. Every pitfall below
is a consequence of `systemd=false` — enabling the units is the way to avoid all
of them at once. Installing a core with `systemd=false` is intended for development
and manual testing purposes only. Developers can then use `ctrl.sh` to manage the core.

## The config path needs a slash

`sudo ./setup.sh -c ./config.ini`, not `-c config.ini`. The script is plain `sh`
(dash), and POSIX `.` without a slash searches `PATH` rather than the working
directory. The error is `.: config.ini: not found`, which reads like a missing
file and sends you looking in the wrong place.

## `install_pkg` cannot be overridden from the config

`assets/.options` is sourced **after** the config file. So with
`advertise=false` the installer still `apt install`s `avahi-daemon`, which Ubuntu
then auto-starts. To keep the host clean, remove it from `install_pkg` in a local
clone.

## Start from a non-interactive shell with `setsid`

```sh
sudo setsid sh -c '/opt/mgw/ctrl.sh start > /tmp/mgw-start.log 2>&1'
```

`bin_ctrl.sh` starts the three host binaries with a plain `&` and no `nohup`.
When the calling session ends they die on SIGHUP — so a start from a script, a
CI step or an agent session appears to work and leaves nothing running.

## A stale `.pid` makes the binary start silently skip

---

**Quickfix:** Call `ctrl.sh stop` and `ctrl.sh start` in succession to fix a stale `.pid` file and get a running core.

---

`startBin()` skips starting the binaries when `/opt/mgw/.pid` still lists PIDs.
Containers come up, the web UI answers on `:8080`, and the gateway cannot reach
the unix sockets — which looks like a broken core rather than a leftover file.

Check whether the PIDs in the file are alive; if not, delete it and start again.
**The web UI answering proves only nginx** — verify with
`ps aux | grep 'bin/SENERGY-Platform'`.

## After a host reboot, two things do not come back, this is by design

The symptom: the web UI shows a raw `502 Bad Gateway` from nginx where module or
deployment status should be, and the module-manager logs `get deployments` /
`get containers` errors whose error body is that same 502 HTML page.

Docker restarts the core containers by itself. These do not:

- **The three host binaries** — the `&`-without-`nohup` pitfall above. Without
  the container-engine wrapper the module-manager can neither see nor start any
  container.
- **Module deployment containers**, which carry `RestartPolicy=no` by design;
  their lifecycle belongs to the module-manager.

Fix: clear a stale `.pid`, then start via `setsid` as above. That brings the
binaries back and the deployment containers with them. **Do not `docker start` a
deployment container** to shortcut it — that bypasses the manager's state.

This recurs after every reboot with `systemd=false`.

## `ctrl.sh start` does not create a missing container

---

**Quickfix:** `ctrl.sh ctr-recreate` recreates all containers and thus recreates a missing container. Run `ctrl.sh start`
afterward to get a running core.

---

**WARNING:** Using docker compose to recreate a missing container is possible but not recommended!

`startContainers()` runs `docker compose start`, which starts containers that
exist. It does not create ones that do not. Remove a core container — to pick up
a rebuilt image, say — and `ctrl.sh start` brings up everything else and stays
silent about the gap. The core then runs without it.

Recreate it with `up`, and **pass the project name**:

```sh
docker compose -p mgw_<core-id> up -d --no-deps <service>
```

The `-p` is not optional. Compose otherwise derives the project name from the
directory, which is `container`, and a container created under a different
project name gets **fresh, empty volumes** instead of the existing
`mgw_<core-id>_*` ones. For the module-manager that means its modules,
deployments and repository data appear to be gone — the container is healthy,
the API answers, and everything it should know is missing.

Nothing fails while this happens. The tell is one line in compose's own output:

```
Volume container_mysqldb-data  Created
```

A `Created` line for a volume that should have existed says the project name was
wrong. Check what the container actually attached to before going further:

```sh
docker inspect <container> -f '{{range .Mounts}}{{.Name}} {{end}}'
```

The original volumes are untouched in that case — the new container simply
points elsewhere. Remove it, recreate it with `-p`, and delete the stray
`container_*` volumes.

## Two values that are easy to get wrong

- **First login** uses the Kratos identity `core-user` with the generated
  password from `core_usr_pw` in `/opt/mgw/.settings`. Through the gateway the
  flow is two requests: `GET /core/auth/login/browser` with
  `Accept: application/json` for the flow and CSRF token, then
  `POST /core/auth/login?flow=<id>` with
  `{method: "password", identifier, password, csrf_token}`.
- **The GitHub module repository reference is `main-validated`** (as of
  2026-08-26), and it is a **tag**, not a branch — `refs/heads/main-validated`
  does not resolve. Channels map to directories in that repo: `main`, `testing`
  and `legacy`. A wrong reference **fails silently**: the refresh reports
  success and the repository contributes no modules, which is indistinguishable
  from an empty repository. Verified against a running core: with the reference
  above the catalogue holds 25 modules from `main`, 3 from `testing` and 4 from
  `legacy`; the repository contributes nothing when the reference is wrong.
  A wrong source can be removed with `DELETE /repositories/{SOURCE}` (the source
  URL-encoded) — verified for a `github.com` repository on 2026-08-26. Whether
  it works for a `host-dir` repository was not retested here; that path was
  fixed separately and is the one earlier notes described as broken.

## Side-loading a module for testing

The host-dir repository (`source: localhost`, channel `default`) reads
`/opt/mgw/repositories/host_dir/<dir>/Modfile.yaml`. After a change there:

```
PATCH /core/api/module-manager/repositories?sources=localhost
```

Restricting the refresh to `localhost` avoids GitHub rate limits during
development. Bumping `version:` in the Modfile and refreshing makes the module
show up as updatable, which is how update flows get tested end to end.
