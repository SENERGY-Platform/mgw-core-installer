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

## `install_pkg` cannot be overridden from the config (no longer needed)

`assets/.options` is sourced **after** the config file, so a package list cannot
be replaced from a config — and it used to be one flat list, which meant
`advertise=false` still `apt install`ed `avahi-daemon`, which Ubuntu then
auto-starts. The workaround was to strip it from `install_pkg` in a local clone.

The conditional packages now live in their own lists in `assets/.options`
(`require_pkg_systemd`, `install_pkg_logrotate`, `install_pkg_advertise`) and are
appended by `getRequiredPkg`/`getInstallPkg` in `lib/package.sh` only when the
setting that needs them is `true`. A minimal-footprint config therefore installs
neither `avahi-daemon` nor `logrotate` and does not require `systemctl`, without
any local edit. Sourcing order is unchanged: overriding a list from a config file
is still impossible, it just no longer matters.

## Starting from a non-interactive shell (fixed)

`ctrl.sh start` can be called from a script, a cron job, a CI step or an agent
session as it is:

```sh
sudo /opt/mgw/ctrl.sh start
```

`bin_ctrl.sh` used to start the three host binaries with a plain `&` and no
`nohup`, which left them in the caller's session, process group and controlling
terminal. When that session ended they died on SIGHUP — a start appeared to
work, the containers stayed up because Docker owns them, and nothing of the
core's host layer was left running. `startBin()` now starts each binary through
`setsid` with its file descriptors redirected, so each one is a session leader
without a controlling terminal and cannot be reached by that SIGHUP.

**On a core installed before that change** the old `startBin()` is still in
`/opt/mgw/scripts/bin_ctrl.sh` — either run `update.sh` or keep using the
workaround:

```sh
sudo setsid sh -c '/opt/mgw/ctrl.sh start > /tmp/mgw-start.log 2>&1'
```

## A stale `.pid` no longer makes the binary start skip

`startBin()` used to skip starting the binaries whenever `/opt/mgw/.pid`
existed. Containers came up, the web UI answered on `:8080`, and the gateway
could not reach the unix sockets — which looks like a broken core rather than a
leftover file. `ctrl.sh stop` on the same state failed outright, because
`stopBin()` treated a missing or unreadable `.pid` as an error.

Both are gone. `.pid` is now checked against `/proc/<pid>/cmdline` instead of
being trusted:

- every binary accounted for → `processes already running`, nothing to do
- some accounted for → the survivors are stopped and all three start again
- none → the file is stale, it is removed and all three start
- pids that belong to no host binary are never signalled, which matters after a
  reboot, where they may well have been reused by unrelated processes

`stop` uses the same matching and is a no-op when nothing runs, so
`stop`-then-`start` is always safe.

A start that does not produce three living processes now fails loudly instead of
reporting success: stdout and stderr of each binary go to
`/opt/mgw/log/{ce_wrapper,h_manager,c_manager}_out.log`, which is where a bad
config or a missing binary shows up. **The web UI answering proves only
nginx** — verify the host layer with `ps aux | grep 'bin/SENERGY-Platform'`.

## An update no longer aborts on a stale `.pid` (fixed)

`update.sh` had its own copy of the stop logic that signalled every pid in
`/opt/mgw/.pid` without checking what it belonged to. After a reboot — the state
a `systemd=false` core is in every morning — the first pid is dead and the
update stops at:

```
./assets/scripts/update.sh: 264: kill: No such process
```

The place it stops at is what makes this expensive: the containers have already
been removed by then, so the core is down, half updated, and the binaries are
whatever the reboot left. Running the update again works, because the second run
finds no containers to stop.

The teardown now delegates to `stopBin()` from `bin_ctrl.sh` and uses the same
`/proc/<pid>/cmdline` matching as `ctrl.sh` — a stale file is reported as
`no processes to stop` and removed, and pids that belong to no host binary are
never signalled. The secrets tmpfs is also unmounted now when there is no `.pid`
at all; before, a tmpfs left mounted by `ctrl.sh` survived the update.

**This one does not need the core to be updated first.** The two fixes above
live in `bin_ctrl.sh`, which runs from `/opt/mgw/scripts/`, so a core installed
before them keeps the old behaviour until an update replaces that file. Stage
two of an update is the opposite case: it always runs the **new release's**
`update.sh` from the extracted archive, never the installed copy. The first
update onto a release that carries this fix already uses the fixed version.

## After a host reboot, nothing comes back, this is by design

None of the three layers of a `systemd=false` core returns on its own:

- **The core containers.** On an install without systemd the seven long-running
  services get the restart policy `no` instead of `unless-stopped`
  (`ctr_restart_policy` in `.settings`), so Docker leaves them down.
- **The three host binaries** — nothing starts them without systemd. Without
  the container-engine wrapper the module-manager can neither see nor start any
  container.
- **Module deployment containers**, which carry `RestartPolicy=no` by design;
  their lifecycle belongs to the module-manager.

Fix: `sudo /opt/mgw/ctrl.sh start`. The stale `.pid` the reboot left behind is
handled, and the binaries bring the deployment containers with them. **Do not
`docker start` a deployment container** to shortcut it — that bypasses the
manager's state.

The whole core being down is the *wanted* outcome. The state to avoid is the
mixed one — containers up, host binaries down — and its symptom is the one to
recognise: the web UI shows a raw `502 Bad Gateway` from nginx where module or
deployment status should be, and the module-manager logs `get deployments` /
`get containers` errors whose error body is that same 502 HTML page. Two ways to
still land in it: a core installed before the restart policy became a setting,
whose containers keep `unless-stopped` until an update recreates them, and
starting containers by hand with `docker start`.

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

- **First login** uses a Kratos identity whose name is `core_usr` in
  `/opt/mgw/.settings` — `core-user` unless the install set something else — with
  the generated password from `core_usr_pw` in the same file. Both are also
  printed by `setup.sh` at the end of an interactive install. Through the gateway the
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
