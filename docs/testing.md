# Testing

How the installer is tested: unit tests locally, VM tests against a real Docker and systemd, two
tests by hand (a reboot, the release workflow), and how to put a module on a test core. Every change
to the scripts is tested on the VM before it is committed; the unit tests alone don't see docker,
systemd or a real update.

## Applies when

You are changing the installer and need to prove it works, writing a new test, or a VM test fails
and you need to know what it relies on.

## Unit tests

```sh
bats tests/unit
```

`tests/unit/*.bats` test the libraries in `assets/scripts/lib` that need neither docker nor
systemd: settings, records, the lock, versions, the render, the reconcile on temporary folders,
the migration's reading of an old installation. The tests run under bats (bash); the code under test
runs under dash (`dsh` in `tests/unit/helpers.bash`), the shell `/bin/sh` is on Debian gateways.
`shellcheck -s sh` must pass on every script.

## VM tests

```sh
tests/vm/run.sh [-j <jobs>] [tests/vm/<file>.bats ...]
```

`run.sh` builds the fake host binary (`tests/vm/fakebin`), copies the repository to the VM and runs
`sudo bats` there, on all files or the ones given. `MGW_TEST_VM` (default
`mgw-user@192.168.122.253`) and `MGW_TEST_VM_KEY` (default `~/.ssh/mgw_test_vm_ed25519`) select the
VM; it needs Debian or Ubuntu with Docker, the compose plugin, bats, and GNU parallel for `-j`.
`-j 6` runs the files in parallel (the whole suite in about ten minutes); the tests within a file
always run in order, each file builds on its own previous tests.

- **Releases**: the tests build their installer releases with `.github/build_release.sh`, the
  script the release workflow uses, with test versions (`v0.40.0`, `v0.41.0`, ...). An overlay
  folder can replace files of a test release, e.g. an `options` with a broken image.
- **GitHub mock** (`tests/vm/github_mock.py`, `tests/vm/github.bash`): the installer asks it instead
  of api.github.com when `MGW_TEST_GITHUB_API` is set. It serves the test releases of the installer
  from a folder and passes every other request to GitHub, caching the answers and the downloads in
  `/var/tmp/mgw-test-cache` on the VM, so the host binaries (about 130 MiB) are downloaded once.
- **Keepers** (`tests/vm/keepers.sh`): during a run, a stopped container per core image keeps the
  images on the VM, so a test removing images (a cleanup, an uninstall) can't remove one another file
  is about to use.
- **Parallel files** need ranges of their own: each file uses its own install directory, core id,
  subnets (`10.<n>.0.0`, `10.<n+120>.0.0`, see the comment at the top of each file) and gateway
  ports. A new file takes a free range and adds it to those comments.
- **Test hooks**, honoured only when set explicitly (`lib/state.sh`):
  - `MGW_TEST_FAIL_AT="<step> ..."` makes the named steps fail as if their command had failed
    (`prepare`, `stop`, `activate`, `start`, `started`, `success`, `cleanup`, `rollback`, ...)
  - `MGW_TEST_KILL_AT=<step>` kills the script with SIGKILL at the named point, like a power loss
    (`preparing`, `switching`, `stopped`, `activated`, `starting`, and the migration's `copying`,
    `copied`, `settings`, `moved`, `cleaning`)
  - `MGW_TEST_GITHUB_API` points the installer at the mock
- **Migration tests** (`tests/vm/migration*.bats`, helpers in `tests/vm/migration.bash`) install real
  old releases from their GitHub archives (cached), point the old `lib/github.sh` at the mock and the
  old work folders (`/tmp/mgw-update`, `/tmp/mgw-install`) at folders of their own, and migrate
  through the real old stage one.
- **Volume check** (`tests/vm/volumes.bats`): `.github/check_volumes.sh` against today's images and
  against a compose file with a mount removed.

A VM test that fails leaves its output in the bats report; the core it worked on is removed by the
file's teardown. Long runs are best started in the background and looked at once they end.

## The reboot test, by hand

The recovery unit at boot can't be tested in the suite: a reboot would end the other files running
in parallel. It is tested by hand when the recovery or the units change:

1. install a core (or an old installation for the migration) on the VM and kill an update or a
   migration with `MGW_TEST_KILL_AT` at the step to test (e.g. `activated`, `starting`)
2. `sudo systemctl reboot`
3. after the boot: `journalctl -b -u <core_name>-recover.service`, `state/update` (`interrupted`,
   `rolled_back`, the warning "recovered by the boot recovery"), the units, the containers,
   `ctrl.sh status`
4. remove the core

## The release workflow, in a fork

The workflow only runs on GitHub, on a pushed tag. To test a change to it, push the branch to a fork,
enable Actions there (forks have them off), push a tag (e.g. `v0.40.0-beta.1`), check the release
(the archive, its pre-release mark) and the run's log, then delete the release and the tag in the
fork. A fork is safe for any tag: gateways only ask `SENERGY-Platform/mgw-core-installer` for
releases. Never test with a tag in this repository: a test tag with a newer version would be taken
by the old installer's `update.sh` on every gateway.

## A module on a test core

The module-manager reads modules from a host-directory repository, `host_dir_repository_path`
(source `localhost`, channel `default`), so a test needs no GitHub repository: a folder with a
`Modfile.yml` is enough. `tests/vm/migration.bash` (`deployTestModule`) does it end to end:

1. write `<host_dir_repository_path>/<folder>/Modfile.yml`, e.g. one service with an image already on
   the VM
2. call the module-manager directly, at its container's address on the core network, port 80
   (single URL encoding; through the gateway it would be double):
   `POST /modules-change-request` with `[{"id": "<module id>", "source": "localhost", "channel":
   "default"}]`, then `PATCH /modules-change-request`, which returns a job
3. wait until `GET /jobs/<id>` has an `end` other than `0001-01-01T00:00:00Z`, then check
   `has_error` in `GET /results/modules-change/<id>`
4. `POST /deployments` with `[{"module_id": "<module id>"}]`, the same wait and check with
   `/results/deployments/<id>`
5. `POST /deployments-enable` with `["<module id>"]`: a new deployment is disabled; enabled, the
   module-manager's monitor starts its containers (labels `mgw_cid=<core_id>`, `mgw_did`)
