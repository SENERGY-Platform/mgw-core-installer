# Design of the installer

How the installer is built and why: the layout, the state files, the lock, the update and its
error handling, recovery, restore, uninstall and the migration of old installations, and what
changed for users of the old installer. The README describes how to use the installer; this note
describes what a change to it must not break. The code comments refer to these rules by their
names (G1, S8, ...).

## Applies when

You are changing how the installer installs, updates, repairs or removes a core, the files it
writes, or what it does when something fails. Not for adding a setting (see
[adding-a-setting.md](adding-a-setting.md)) or running the tests (see [testing.md](testing.md)).

## Principles

- **A failed update never breaks a core.** Everything new is prepared next to the running version;
  the switch is one atomic link; until the new version's first host binary starts, everything can
  be undone.
- **Version folders are never modified.** A version folder (`vX_Y_Z`) is built once from a
  release's assets and the settings. An update builds a new one; rolling back means pointing at the
  old one again.
- **Data lives outside the version folders.** Volumes, networks, `deployments/`, `mounts/`,
  `repositories/`, `state/` survive every update and every repair.
- **Records first.** Every operation records what it is about to do before it does it, so a kill
  at any point leaves enough to complete or undo it.
- **Parsed, never sourced.** Settings, records and config files are `key=value`, read by a parser.
  A file written by another version is never executed.

## Layout

- **Core root**: `<install_dir>/<core_id>`; for a migrated installation the install directory
  itself.
- **Version folders** `vX_Y_Z` (dots become underscores, `-beta.1` becomes `-beta_1`): `assets/`
  (the release's files), `bin/` (the host binaries), `config/` (rendered from
  `assets/templates`), links `ctrl.sh`, `update.sh`, `restore.sh`, `uninstall.sh` into
  `assets/scripts`. A folder being built is `vX_Y_Z_tmp`, renamed when complete.
- **`current`**: a link to the active version folder, switched with a rename (atomic).
- **`/etc`**: the service units, the logrotate, cron and avahi files are links into
  `current/config` with the same names, kept in line by a declarative reconcile
  (`lib/reconcile.sh`): what should exist is what `current/config` holds. The secrets mount unit
  and the recovery unit are plain files the core owns: they must work while `current` is being
  switched.
- **Docker**: the compose project `<core_name>_<version folder>`, so each version has containers of
  its own; volumes `<stack_name>_<name>` and networks `<core_name>-0/1/2-*-net` are external,
  created by the installer and shared by all versions. The containers have no restart policy; the
  core-manager starts them when it starts, stops them when it stops and restarts crashed ones.
- **`stack_name`** exists only for compatibility: the old installer named the volumes after it,
  and docker volumes can't be renamed. It equals `core_name` on every new installation.

## State files (`state/`)

| File | Written by | Content |
| --- | --- | --- |
| `settings` | install, `ctrl.sh settings`, an update (pinned keys) | the settings set for this core, on top of the version's `settings.defaults` |
| `install` | `setup.sh` | the install's result and every object it created, in order |
| `update` | stage two of an update, recovery, migration | the last update: writer, kind, result, phase, versions, folders, `was_running`, `rolled_back`, `interrupted`, `recovery_failed`, `restored`, step, warnings |
| `update.previous` | recovery, restore | a record taken over from another version, kept unparsed |
| `check` | stage one of an update | the last look for a release |
| `restore` | `restore.sh` | the last restore |
| `target_state` | `ctrl.sh start/stop`, install, update, restore | whether the core is meant to run, with the boot id; after a reboot `autostart` decides |
| `images` | install, update | every core image pulled, for the cleanup |
| `attempts` | stage two | failures of a version, for the retry limit |
| `pid` | `ctrl.sh` without autostart | the host binaries' processes |
| `lock` | everyone | the lock file |
| `host-manager/` | the host-manager | its data |

Every record is written completely each time, to a temp file that is flushed and renamed. The
writer owns the whole record: a version that takes over a record it didn't write keeps the old one
as `update.previous` and starts a fresh one. The core-manager reads `update` and `check` (fields
`format`, `result`, `phase`, ... are stable across versions) and reports them through its health
API.

## The lock

`state/lock`, held with `flock` on descriptor 9 by whoever changes the core: `setup.sh`,
`update.sh`, `ctrl.sh`, `restore.sh`, `uninstall.sh`, the recovery. Taking it waits at most two
seconds, then gives up and names the holder. The kernel releases it when the holder dies, so a
killed holder leaves no lock behind, only its entry. Stage one of an update hands it to stage two
(inherited descriptor, `MGW_LOCK_HELD`); a process that inherited the lock never releases it,
because the release would apply to its parent too. Host binaries started while the lock is held
close descriptor 9.

## The update

`current/update.sh` (stage one, the running version's code) checks GitHub for a newer release
(`state/check`), downloads it into `vX_Y_Z_tmp` and runs that version's `update.sh -stage=2`. Stage
two is the new version's code: it knows what it needs. The exit code is the only contract between
the two (S4).

From an extracted release archive, `update.sh -path=<core root>` (also `./update.sh` in the archive
root) takes stage one's place: lock, recovery, the copy of the archive into `vX_Y_Z_tmp` (checked
against the release's checksums), then the copy's stage two as usual. It only goes forward (the same
version is left alone, an older one is refused and left to `restore.sh -downgrade`) and is always a
manual run. Given the install directory of the old installer, the same command migrates it.

Phases of stage two and their handling on failure (PLAN.md 13):

- **B, preparing**: render, download the host binaries, rename to `vX_Y_Z`, pull the images,
  create the containers. The old core runs, untouched. Failure: the new containers and folder are
  removed, the images kept; not counted for the retry limit.
- **C, switching**: stop the old core, point `current` at the new version, reconcile `/etc`.
  Failure: the rollback (new containers removed, `current` back, reconcile, the old core started if
  it was running), counted.
- **D, starting**: the new core's host binaries start. **The point of no return is the first host
  binary starting (S8)**: it may run data migrations the old version can't read. Failure: recorded,
  no rollback; the new version stays.
- **E, cleanup**: the old version folder, its containers and unused images are removed. Failure: a
  warning; the next update removes the leftovers.

Guarantees (PLAN.md 13):

- **G1** error handling never touches data (volumes, networks, deployments, mounts, repositories,
  `state/host-manager`, existing settings); it only removes what the update created.
- **G2** before the point of no return everything is as it was, including whether the core runs.
- **G3** after the point of no return there is no automatic rollback.
- **G4** every attempt leaves a record; a finished script never leaves `running` behind.
- **G5** an interrupted update is resolved before anything else touches the core.
- **G6** every handling step can be repeated.
- **G7** handling and recovery run under the lock.
- **G8** automatic updates skip a version that failed `update_retry_limit` times from the stop on; a
  manual run resets the count.
- **G9** if the handling itself fails, nothing more is attempted: the record says
  `recovery_failed`, `ctrl.sh` refuses changing commands, the service units don't start at boot
  (they require the recovery unit), and `restore.sh` is the way out.

Special cases worth knowing: a record that can't be written stops the update where that is still
cheap (S2); leftovers with the target folder name are removed, never the folder `current` points to
(S3); the secrets tmpfs is never unmounted by an update (S5); a failed avahi reload is a warning
(S7).

## Recovery

An interruption is a stop without the script's own handling: SIGKILL, a power loss. SIGINT,
SIGTERM and SIGHUP are trapped and get the normal handling. What is left is a record that says
`running` while nobody holds the lock.

`recover.sh` resolves it, run by the recovery unit at boot (before the service units, which require
it), by `update.sh` before it looks for a release, and by `restore.sh`. **The version that wrote
the record recovers it**: the recovery hands over to the writer's own `recover.sh` (after checking
the writer folder's checksums), and the writer handles the phase it recorded as its own failure
handling would have. If the writer's folder is missing or damaged, nobody knows exactly what
changed: G9. An unfinished install is removed with its own list. A recovery at boot never starts
units: they start by themselves right after the recovery unit, and starting them from it would wait
for itself.

## Restore

`restore.sh` rebuilds one version (that of the `restore.sh` that runs) onto the core's existing data,
whatever broke. It tries the recovery first. It needs `state/settings` (it never generates
credentials: the data only works with the passwords it was created with) and reuses every object
that exists. It records itself in `state/restore`; a restore that didn't finish blocks the core
(ctrl.sh and the recovery refuse) until it is run again, from the copy of itself it leaves in
`<core root>/.restore` when `current` is gone. Restoring an older version needs `-downgrade`.

## The installer's log

Every script that changes a core writes its output into `<core root>/log/core_installer.log` as well
as to the terminal (`lib/log.sh`), each line stamped with the time, the script and its pid. Stdout and
stderr go into a FIFO; a reader in the background passes the bytes on to the terminal at once (a
prompt without a line break shows) and stamps whole lines into the file. The terminal stays on
descriptor 7, so a logging script started by another one logs with its own name, and a script that
`exec`s another keeps one reader (`MGW_LOG_PID`). At the end a script waits up to 5 seconds for its
reader. Processes started for good while a script runs (the host binaries) get their own output and
close descriptors 7 and 9, or they would keep the FIFO, the terminal and the lock. The core-manager
serves the file (`log_hdl.json`); the cron file discards the output it already logs.

## Uninstall

`uninstall.sh` finds the core's objects by the names in `state/settings` and the label `mgw_cid`,
removes everything including the modules' containers and volumes, and lists what it couldn't. It is
best effort and never stops at the first failure.

## Migration of old installations

The old installer's stage one (`<install_dir>/update.sh`) downloads the newest release to
`/tmp/mgw-update` and runs its `assets/scripts/update.sh -path=<install_dir>`; the new `update.sh`
recognises the old layout and hands over to `assets/scripts/migration.sh`. All migration logic is
in `migration.sh` and `lib/migration.sh`, so it can be removed again without touching the rest.

- The old stage one has no lock and deletes `/tmp/mgw-update` when it starts. The migration
  therefore checks without changing anything, takes the new lock, records itself (`kind=migration`)
  and copies the release into `<install_dir>/vX_Y_Z_tmp`, checks the copy against the release's
  checksums and runs on from there.
- It migrates in place with the update's phases: the version is built while the old core runs; the
  old core is stopped, its files in `/etc` moved aside into `state/migration/etc`; the core-owned
  units are written and `current` activated; the core is started if it was running. Volumes and
  networks have the old names, the new compose file uses them as external.
- A failure before the first host binary starts rolls back to the old flat layout and starts the
  old core with its own `ctrl.sh` (at boot through `systemd-run`, as the recovery unit can't wait for
  it). A failure or interruption after it leaves the new layout; the old installation's leftovers
  then stay until uninstall (a known gap, accepted).
- Failures and refusals are also written to the old `.update_status`, which the old core-manager
  reads. Installations older than `v0.30.0-alpha1` are refused.

## Releases

`.github/build_release.sh` builds the archive (used by the release workflow and the VM tests):
`assets/version`, `assets/checksums` (the recovery checks a version folder against it before handing
over), the links `update.sh`, `restore.sh` and `uninstall.sh` in the archive root, the asset name
`mgw_core_installer_<version>.tar.gz` (the old stage one looks for `<version>.tar.gz`). Before it
publishes, the workflow checks that every volume a core image declares is mounted
(`.github/check_volumes.sh`): an unmounted declared path gets an anonymous volume, whose data is lost
with every update. Alphas and betas are published as pre-releases; `update.sh` never picks an alpha.

## Breaking changes from the old installer

What changes for users, scripts and monitoring that worked with the old installer (up to
v0.33.0-beta2). Installations are migrated automatically; these are the differences afterwards.

| Old | New |
| --- | --- |
| everything in one directory (`/opt/mgw`) | a core root per core, `<install_dir>/<core_id>` for new installations; a migrated core keeps its directory as core root |
| `setup.sh -c config.ini`, a sourced shell file (`assets/config.suggestion.ini`) | `setup.sh -c <file>` in the settings format, parsed: `key=value`, no quotes, no comments after a value, unknown keys fail (`assets/setup.conf.example`) |
| the setting `systemd` | `autostart` |
| `skip_pgk_install_confirm` (misspelt) | `skip_pkg_install_confirm` |
| the path settings (`base_path`, `secrets_path`, `log_path`, `systemd_path`, ...) and the environment overrides `SYSTEMD_PATH`, `LOGROTATED_PATH`, `CRON_PATH` | gone: paths are derived from the core root, the `/etc` locations are fixed (Debian, Ubuntu) |
| `ctr_restart_policy` | gone: the containers have no restart policy, the core-manager owns their lifecycle |
| `<base_path>/.settings`, sourced | `state/settings`, parsed, only what was set (the defaults come from the version) |
| `container/.env` (log levels, delays) | settings, changed with `ctrl.sh settings set` |
| `.version`, `.options`, `.binaries`, `.units`, `.pid` | `current/assets/version`, `current/assets/options`, the version folder, the links in `/etc`, `state/pid` |
| `.update_status` (JSON) | `state/update` and `state/check` (`key=value`), reported by the core-manager's health API |
| `ctrl.sh enable` / `disable` | `ctrl.sh settings set autostart true/false` |
| `ctrl.sh beta-test` | `ctrl.sh settings set allow_beta true` |
| `ctrl.sh ctr-purge` | gone; `ctrl.sh ctr-recreate` recreates the containers |
| `<base_path>/ctrl.sh`, `update.sh`, `uninstall.sh` | `<core root>/current/ctrl.sh`, `update.sh`, `restore.sh`, `uninstall.sh` |
| `uninstall.sh -i` (also remove the images) | the images are always removed |
| `update.sh` asked before updating and for new settings | no questions; new settings get their default or the pinned value |
| container names `<core_name>-<service>`, compose project `<stack_name>` | `<core_name>-<version folder>-<service>`, project `<core_name>_<version folder>` |
| the host-manager's data in `bin/SENERGY-Platform/mgw-host-manager/` | `state/host-manager/` |
| tags `vX.Y.Z-betaN` | `vX.Y.Z-beta.N` (SemVer); both are understood |
