# Order of the installer flow

The main flows at the bottom of `setup.sh` and `assets/scripts/update.sh` are
not a list of independent steps. Five constraints decide where a step may sit,
and none of them is visible from the step itself — moving one line produces a
core that installs cleanly and runs wrong. This document names the five.

## Applies when

You are adding a step to the main flow of `setup.sh` or `assets/scripts/update.sh`,
or moving an existing one. It is about the order of the flow only; what a single
setting has to touch is [Adding a setting](adding-an-installer-setting.md), and
the three-part split of the flow that the package step forces sits there too,
under *Settings that gate a package*.

**Not about** `ctrl.sh`. It starts and stops an installation that already
exists, so nothing in it renders anything — the order it keeps is the runtime
one described in [Using `ctrl.sh`](../README.md#using-ctrlsh), and that order is
the reason for the first constraint below.

## 1. Everything is written before anything is started

Both entry points write the complete installation — directories, host binaries
and their `conf.json`, the units, the logrotate config, the cron job, the avahi
service, the container assets, the rendered `docker-compose.yml`, the created
containers, `.settings`, `.version` — and only then start a single component of
it. A new step that *writes* goes before the start phase; a new step that
*starts* goes into it.

The reason is not tidiness. A component of the core reads the installation at
startup, so a start that runs earlier reads a file that is not there yet, or
still the old one. The concrete case: the core-manager is configured with
`compose_file_path` (see
[`assets/bin/SENERGY-Platform/mgw-core-manager/conf.json.template`](../assets/bin/SENERGY-Platform/mgw-core-manager/conf.json.template))
and reads the rendered `container/docker-compose.yml` when it starts. Starting
the host binaries before `copyContainerAssets` therefore hands it a file that
does not exist on a fresh install, and on an update the pre-update file that
`handleContainerAssets` deletes seconds later. Both happened, and neither fails
loudly.

Two consequences for the shape of the code:

- **`handleSystemd` installs and enables the units; it does not start them.**
  It records them in `<base_path>/.units`, and the start phase reads that file
  through `startUnits` from `assets/scripts/lib/sysd_ctrl.sh`. Enabling decides
  the next boot, starting decides now — they are separate steps on purpose.
- **The host binaries start before the containers**, inside the start phase.
  The containers mount configuration the core-manager writes: the
  identity-server config under `mounts/kratos` and the gateway's endpoint
  fragment under `mounts/nginx`, both named in the same `conf.json`. `ctrl.sh`
  keeps the same order for the same reason.

Creating the containers with `docker compose up --no-start` is a write step, not
a start step, and belongs before the start phase with the rest.

## 2. `$script_path` means two different things

`assets/scripts/lib/ctr_ctrl.sh` cannot be sourced from `update.sh`, and the
container functions in `update.sh` are not a duplicate that wants cleaning up.

Every function in `ctr_ctrl.sh` ends in `cd $script_path`, and in `ctrl.sh` —
the only caller it was written for — `script_path` is `${0%/*}`, the install
directory. Returning there is correct.

In `update.sh` the same name means `<release>/assets/scripts`: it is set from
`pwd` after the initial `cd ${0%/*}`, and stage two then does `cd ../..` to work
from the release root, because everything it reads is a relative `./assets/...`
path. Its own container functions therefore end in `cd $script_path` **plus**
`cd ../..`. A sourced `ctr_ctrl.sh` would leave the working directory two levels
too deep, and the next step reading `./assets/...` fails.

So: reuse a library function in `update.sh` only when it does not `cd`.
`sysd_ctrl.sh`, `bin_ctrl.sh` and `container.sh` qualify.

## 3. Removing the release workspace stays last

Stage one of an update extracts the new release into `/tmp/mgw-update` and runs
stage two **from inside it** (`handleRelease` in `update.sh`). `$wrk_spc` names
that same directory in stage two, so `rm -r $wrk_spc` at the end of the flow
removes the tree the running script, its sourced libraries and its `./assets`
copies live in.

Nothing may follow it that reads a relative path or `cd`s by way of
`$script_path` — which is every container function and every `copy*` step. Keep
it as the last statement before the closing output.

## 4. `.settings` and `.version` before the start

`saveSettings` and, in the update, `updateVersion` are the last write steps, not
an epilogue after the start. A start can fail — a bad config, a systemd unit
that will not come up, an image that will not run — and what is left behind then
has to be an installation `ctrl.sh` and `update.sh` can still drive. Both source
`<base_path>/.settings`; a core whose files are complete but whose `.settings`
was never written cannot be started, stopped or updated by any of them.

Because `.version` is written before the start, it does not prove the update
worked. `<base_path>/.update_status` does: stage two of `update.sh` sets it to
`running` before the first change and to `success` or `failed` from an EXIT trap,
with the `update_step` the flow had reached. The trap is the one writer after the
workspace is removed and uses absolute paths only. A record that stays `running`
means the update was killed or the gateway lost power.

## 5. The update pulls its images before the stop

`pullContainerImages` in `update.sh` runs before `stopContainers`, while the
old core is still up. Pulling is the step most likely to fail or take long - it
depends on the registries and on the link - and everything from the stop
onwards runs with the core down. A pull placed after the stop turns a registry
outage into an outage of the core; placed before it, a failed pull ends the
update with the old release still running.

This only works because `pullImages` in `assets/scripts/lib/container.sh`
reads the images from the `images` list in `.options` instead of from the
rendered `docker-compose.yml`. Rendering the new compose file that early would
replace a file the running core-manager reads (see constraint 1) before the
core is stopped. `createContainers` then runs `up --no-start` on the new
compose file, and since the template sets no `pull_policy`, compose pulls only
what is missing, which is nothing. An image added to the compose template must
therefore also be in the `images` list, as all of them already are, or it is
pulled after the stop after all.

The pull changes nothing, so it sits before the `running` record in
`.update_status`; a failed pull is still recorded as `failed` with its step.

`setup.sh` is not affected: there is no running core to keep up.
