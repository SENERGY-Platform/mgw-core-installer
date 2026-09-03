# Adding a setting

A setting is a value that ends up in `<base_path>/.settings`, the file every
later `ctrl.sh` and `update.sh` run sources. Adding one means touching up to
five places, and missing one of them fails in a different way each time. This
document lists them in order and explains the sourcing rule that makes the last
one work.

## Applies when

You are adding a value to `assets/scripts/lib/settings.sh` — a new user-facing
option, or one derived from an existing setting. It does not cover the values in
`assets/container/.env` (log levels and module-manager timings), which are read
by Compose at container start and never enter `.settings`, nor the image and
version pins in `assets/.options`.

## The five places

1. **Declare it with a default** in the variable block at the top of
   `assets/scripts/lib/settings.sh`. An empty default (`name=""`) is what marks
   the setting as "not resolved yet" and is what step 5 tests for. Put it next
   to the setting it belongs with, not at the end.

2. **Add it to `saveSettings()`** in the same file, as a `name=$name` line.
   Without this the value is resolved on every run and never persisted, which
   looks like it works during the install and quietly drops out afterwards.

3. **Add it to `exportSettingsToEnv()`** in the same file, as
   `NAME="$name"`, if a template needs it. Uppercase is the convention for the
   exported form.

4. **Add `$NAME` to the envsubst variable list** in `renderCompose()` in
   `assets/scripts/lib/container.sh`, if the compose template uses it.
   `envsubst` is called with an explicit list, and it substitutes *only* the
   names in that list — a `${NAME}` that is missing from it is left in the
   rendered `docker-compose.yml` verbatim rather than being filled in. That is
   deliberate for the handful of `${...}` that Compose itself interpolates from
   `container/.env`. The other templates (`conf.json`, the units, logrotate,
   cron, avahi) are rendered with a bare `envsubst` and need nothing here.

   If `ctrl.sh` is to change the setting at runtime, note that `renderCompose()`
   reads the template from `$container_path`, not from the release archive, and
   that it needs `exportSettingsToEnv` and `parseImages` to have run first.

5. **Resolve it for existing installs** in `handleNew()` in
   `assets/scripts/update.sh`, in the same `if [ "$name" = "" ]` shape the other
   settings use there. `handleNew` is the hook for everything a release
   introduces; without it, a core installed before the setting existed runs with
   the empty default.

Then call whatever resolves the value from `setup.sh` as well — the `handle*`
functions run between `handleDefaultSettings` and `exportSettingsToEnv` in the
main flow at the bottom of the file.

## Why `handleNew` can test for an empty value

Every entry point sources the defaults **before** the resolved settings:

| Script | first | then |
| --- | --- | --- |
| `setup.sh` | `assets/scripts/lib/settings.sh` | the `-c` config file, if given |
| `update.sh` | `assets/scripts/lib/settings.sh` (from the new release) | `<base_path>/.settings` |
| `ctrl.sh` | `scripts/settings.sh` (the installed copy) | `<base_path>/.settings` |

Both files are plain shell sourced into the same scope, so the second one simply
overwrites the variables it sets. A setting that a release has just introduced
does not appear in an old `.settings`, so nothing overwrites it and it keeps the
empty default from `settings.sh` — which is exactly the condition `handleNew`
tests. The same rule gives a `-c` config file precedence over the defaults in
`setup.sh`.

This is also why `update.sh` sources the **new** release's `settings.sh`: it has
to know about settings the installed core has never heard of.

## Derived settings

A setting computed from another one (rather than asked for) is best written as a
`handle*` function that only assigns when the value is empty:

```sh
handleRestartPolicy() {
  if [ "$ctr_restart_policy" = "" ]
  then
    if [ "$systemd" = "true" ]
    then
      ctr_restart_policy="unless-stopped"
    else
      ctr_restart_policy="no"
    fi
  fi
}
```

Placed in `lib/settings.sh`, the one library both `setup.sh` and `update.sh`
source, a single function then covers all three cases: it resolves the value on
a fresh install, back-fills it on an existing one when called from `handleNew`,
and still lets an explicit value from a `-c` config file win. `ctr_restart_policy`
is the worked example; what it does for a core without systemd is described in
[Using `ctrl.sh`](../README.md#using-ctrlsh).
