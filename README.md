mgw-core-installer
=======

The multi-gateway (MGW) core is the base layer of an edge gateway: it runs the gateway's modules
(device connectors and other add-ons), stores their secrets, manages logins and provides the web UI.

This repository contains the **installer** for the core. It installs a core on a host, keeps it
up to date and repairs it if something goes wrong. Everything is done with a few scripts that you
run as root.

## Table of contents

* [Requirements](#requirements)
* [Installing](#installing)
* [Everyday use](#everyday-use)
* [Settings](#settings)
* [Updates](#updates)
* [When something is wrong](#when-something-is-wrong)
* [Logs](#logs)
* [Uninstalling](#uninstalling)
* [Moving from the old installer](#moving-from-the-old-installer)
* [Further documentation](#further-documentation)

---

## Requirements

* **Debian 13 (trixie)** and **root** access.
* **Docker with the Compose plugin**, version 2.9.0 or newer. Debian's own packages are enough:

  ```sh
  sudo apt install docker.io docker-compose
  ```

  Docker's own packages work as well (<https://docs.docker.com/engine/install/debian>). The old
  `docker-compose` v1 doesn't, and neither do the Compose releases 2.19.0, 2.25.0, 5.1.0 and 5.1.1,
  which have bugs the installer can't work with. The installer checks this before it changes
  anything.
* **Internet access** to GitHub and to the container registries (Docker Hub, `ghcr.io`).
* The install directory (default `/opt/mgw`) on the root file system.

The installer installs the other tools it needs (`curl`, `jq`, `openssl`, ...) after asking you.

---

## Installing

Download and unpack a release, then run the installer:

```sh
curl -LO https://github.com/SENERGY-Platform/mgw-core-installer/releases/download/<version>/mgw_core_installer_<version>.tar.gz
mkdir mgw_core_installer_<version>
tar -xzf mgw_core_installer_<version>.tar.gz -C mgw_core_installer_<version>
cd mgw_core_installer_<version>
sudo ./setup.sh
```

Take `<version>` from the [releases page](https://github.com/SENERGY-Platform/mgw-core-installer/releases),
e.g. `v0.40.0`.

The installer asks a few questions. Pressing Enter takes the default, which is right for most
gateways:

* whether to change the default settings (install directory, web UI user and passwords, gateway
  port, network ranges). Passwords left empty are generated;
* whether the core should start at boot, rotate its logs, update itself daily, and announce itself
  in the local network;
* whether to take beta releases, and whether to start the core right away.

It checks everything before it changes anything. If something is in the way (a port in use, a
network range that is taken, missing Docker), it stops and tells you what. If the install fails
half way, it removes what it created.

### Without questions

To install without questions, e.g. from a script, put the settings into a file and pass it with
`-c`. [`assets/setup.conf.example`](assets/setup.conf.example) is a starting point with every
setting explained:

```sh
sudo ./setup.sh -c /path/to/setup.conf
```

### After the installation

The installer prints where the core is installed, `/opt/mgw/<core id>`, and how to log in.

* **Web UI:** `http://<gateway address>:8080/` (or the port you chose). Log in with the user
  `core-user`.
* **Password:** printed at the end of an interactive install. It is also stored with the core's
  settings:

  ```sh
  sudo grep '^core_usr_pw=' /opt/mgw/<core id>/state/settings
  ```

**Keep a copy of `/opt/mgw/<core id>/state/settings`** in a safe place. It holds the passwords
the core's data was created with; without it, a core whose folder is lost can't be restored.

---

## Everyday use

Everything is done with `ctrl.sh` in the core's folder:

```sh
sudo /opt/mgw/<core id>/current/ctrl.sh <command>
```

| Command | What it does |
| --- | --- |
| `status` | shows the version, whether the core runs, the last update, and whether the core needs a repair |
| `start`, `stop`, `restart` | starts, stops or restarts the core |
| `settings list` | shows the settings you can change, see [Settings](#settings) |
| `settings set <key> <value>` | changes a setting and applies it |
| `settings reset <key>` | goes back to the default |
| `ctr-recreate` | recreates the core's containers |

A core you stopped stays stopped, also after an update. After a reboot it starts by itself if it
was installed to start at boot (`autostart`).

If a command answers *"the core needs repair"*, see [When something is wrong](#when-something-is-wrong).

---

## Settings

Change settings with `ctrl.sh settings set`, never by editing files: `ctrl.sh` checks the value
and applies it. `ctrl.sh settings list` shows the settings you can change; the ones marked "(set)"
were changed for this core, the others have the default.

| Setting | Default | What changing it does |
| --- | --- | --- |
| `gateway_port` | `8080` | the port of the web UI and the API. The core restarts its containers; the new port must be free. |
| `autostart` | `true` | whether the core starts at boot and is restarted after a crash. The core is restarted. |
| `cron` | `true` | whether the core updates itself daily. |
| `allow_beta` | `false` | whether updates also take beta releases. Takes effect with the next update. |
| `update_retry_limit` | `3` | how often an automatic update tries a release that failed, before it waits for the next one. |
| `logrotate` | `true` | whether the logs are rotated (monthly once they exceed 10 MB, twelve are kept). |
| `advertise` | `true` | whether the core announces itself in the local network (mDNS), so apps can find it. |
| `secrets_size` | `100M` | the memory reserved for the modules' secrets. Takes effect at the next reboot. |
| the `*_log_level` settings, `module_manager_http_access_log`, the startup delays | | how much the core's services log, and timings of the module-manager. The core restarts its containers. |

Some settings are fixed at the install and can't be changed later, because the core's data and
networks depend on them: the core id and name, the passwords and the web UI user, the network
ranges and the module repository folder. `ctrl.sh settings list -a` shows them as well, marked "fixed".

---

## Updates

### Automatic updates

With `cron` on (the default), the core checks for a new release once a day and updates itself. It
takes regular releases, and beta releases if `allow_beta` is on. It never takes an alpha release.

To update right away, run:

```sh
sudo /opt/mgw/<core id>/current/update.sh
```

### Installing a specific release

To install a particular release, e.g. a beta or an alpha, download and unpack it as for the
install, then run its `update.sh` with the core's folder:

```sh
sudo ./update.sh -path=/opt/mgw/<core id>
```

This only goes forward: an older release is refused (see [When something is wrong](#when-something-is-wrong)
to go back).

### If an update fails

An update never leaves you with a half-installed core:

* Until the new version starts, the update can be undone completely. If it fails up to that point,
  the core goes back to the version it had and keeps running as before.
* Once the new version has started, it stays: it may already have converted data that the old
  version can't read. A failure from then on is recorded, and the new version keeps running as far
  as it can.
* If the power fails or the update is killed, the core finishes or undoes the update by itself:
  at the next boot (if it starts at boot, `autostart`), or with the next update.

`ctrl.sh status` shows how the last update went ("last update: ..."), with warnings if there were
any. A gateway connected to the platform reports it there as well. An automatic update tries a release that failed
up to three times (`update_retry_limit`), then waits for the next release. Running `update.sh` by
hand always tries again.

---

## When something is wrong

**1. Check the status:**

```sh
sudo /opt/mgw/<core id>/current/ctrl.sh status
```

If it says *"the core needs repair"*, it names the command to run, usually:

```sh
sudo /opt/mgw/<core id>/current/restore.sh
```

This happens only if an update or a repair went wrong in a way the core couldn't undo by itself.
Until the repair, `ctrl.sh` refuses commands that change the core.

**2. Repair with `restore.sh`:** it rebuilds the core's current version and keeps all its data:
the modules and their data, the users, the settings. It first checks whether an interrupted update
can simply be finished; only if that's not enough, it rebuilds. It downloads what it needs and asks
before it starts. Use it whenever the core is broken, whatever the cause.

| Option | Meaning |
| --- | --- |
| `-y` | don't ask, just do it |
| `-start` | start the core afterwards |
| `-downgrade` | allow going back to an older version (see below) |
| `-s=<file>` | use a copy of the settings file, if the core's folder is lost (see below) |

To restore a particular version, run `restore.sh` from its unpacked release archive:

```sh
sudo ./restore.sh -path=/opt/mgw/<core id>
```

**Going back to an older version** works the same way, with `-downgrade`. Be careful: a newer
version may have converted data that the older one can't read.

**If the core's folder is lost** but Docker still has its data, restore from a release archive
with your copy of the settings file:

```sh
sudo ./restore.sh -path=/opt/mgw/<core id> -s=/path/to/copy/of/settings
```

Without that file the core can't be restored: its data only works with the passwords it was
created with. If some of the core's data is missing, the restore says so: that part starts empty.

---

## Logs

All logs are in `/opt/mgw/<core id>/log`:

* `core_installer.log`: what the installer did: installs, updates, repairs and changes made with
  `ctrl.sh`, each line with its time (UTC). This is the first place to look when an update failed.
  It also has every warning in full.
* `ce_wrapper.log`, `c_manager.log`, `h_manager.log`: the core's own services.

The core also offers these logs through its API, where the installer's log is called
`core-installer`. With `logrotate` on, old logs are rotated and compressed.

---

## Uninstalling

```sh
sudo /opt/mgw/<core id>/current/uninstall.sh
```

This removes the core completely: its modules and **all their data**, the users, the containers,
images, settings and logs. There is no undo. It asks first (`-y` skips the question). It also works
on a broken core; whatever it can't remove, it lists at the end.

A module repository folder outside the core's folder is kept, and so is a Docker image another
container on the host still uses.

---

## Moving from the old installer

Gateways installed with the old installer (one folder, usually `/opt/mgw`, with `ctrl.sh` and
`.settings` in it) **move to the new installer by themselves** with their next daily update. Their
modules, data and settings are kept, and the core stays in its folder (`/opt/mgw`). There is no way
back to the old installer.

**Before that, make sure the gateway runs Debian 13 with Docker and the Compose plugin 2.9.0 or
newer** (see [Requirements](#requirements)). When you upgrade a gateway to Debian 13, check
afterwards that Docker is still installed: if Docker came only with the old `docker-compose`
package, the upgrade can remove it.

If a gateway isn't ready, it isn't moved: it keeps its old core, running as before, and tries
again every day. The reason is shown in the old core's update status and reported to the platform.

| Reason shown | What to do |
| --- | --- |
| Debian 13 is required | upgrade the gateway to Debian 13 |
| the docker compose plugin is required / too old / has a bug | install or update the Compose plugin |
| older than v0.30.0-alpha1 | update the old core once by hand to a release from v0.30.0 on: unpack that release and run its `assets/scripts/update.sh -path=/opt/mgw` |
| the settings don't fit the new layout | the old core was set up with folders outside its install folder (the message names the setting); such a gateway can't be moved automatically |
| volumes named `<stack_name>-<volume>` | see below |

**Volumes created by Compose 2.8.0.** That release named the core's data volumes differently. The
move is refused so that the new core doesn't start with empty data. Stop the old core
(`/opt/mgw/ctrl.sh stop`), copy each volume the message names into one with the new name, run the
update again and start the core:

```sh
docker volume create <stack_name>_<volume>
docker run --rm -v <stack_name>-<volume>:/from -v <stack_name>_<volume>:/to alpine cp -a /from/. /to/
sudo /opt/mgw/update.sh              # the old core's update, moves it
sudo /opt/mgw/current/ctrl.sh start  # the moved core stays stopped, as the old one was
```

To move a gateway right away, or to a particular release, unpack the release and run
`sudo ./update.sh -path=/opt/mgw`.

After the move, control the core with `/opt/mgw/current/ctrl.sh`; `ctrl.sh status` shows how the
move went. If the move fails before the new core starts, the old core is started again and the
next daily update tries once more.

What changed compared to the old installer (commands, settings, files) is listed in the
[breaking changes](docs/design.md#breaking-changes-from-the-old-installer).

---

## Further documentation

For developers:

* [docs/architecture.md](docs/architecture.md): the services of a core, its networks and the
  gateway's routes, and how modules reach the core.
* [docs/design.md](docs/design.md): how the installer works and why: the layout on disk, the
  update and its guarantees, recovery and restore, the migration, releases, and the breaking
  changes from the old installer.
* [docs/adding-a-setting.md](docs/adding-a-setting.md): what a new setting has to touch.
* [docs/testing.md](docs/testing.md): the unit and VM tests, and how to test the release workflow.
