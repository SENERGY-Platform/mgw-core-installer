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
   to the setting it belongs with, not at the end. A setting whose default is a
   real value cannot use that marker — see
   [Settings with a non-empty default](#settings-with-a-non-empty-default).

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

## Settings with a non-empty default

`gateway_port`, the three `subnet_*` values and `core_usr` carry a real default
instead of an empty one, and that breaks the marker step 1 rests on: for these,
an empty value does not mean "not resolved yet", it means somebody emptied it.
A `-c` config file with `core_usr=""` in it, or a prompt answered with a bare
line where the current value is already empty, therefore reaches the templates
as an empty string, and nothing on the way there objects.

Write the default into its own variable and initialise the setting from it:

```sh
core_usr_default="core-user"
core_usr="$core_usr_default"
```

then add a `handle*` function that restores it, called from the main flow of
`setup.sh` and from `handleNew()` in `update.sh` like any other resolver:

```sh
handleCoreUser() {
  if [ "$core_usr" = "" ]
  then
    core_usr="$core_usr_default"
  fi
}
```

The extra variable is what keeps the literal in one place. Restating it inside
the `handle*` function works and reads more directly, but the declared default
and the fallback then drift apart on the next change to either. The `*_default`
variables deliberately stay out of `saveSettings()`: they belong to the release,
not to the install, and every entry point sources `settings.sh` before
`.settings` anyway (see below).

What an emptied value produces — each one confirmed by rendering the templates,
not by starting anything:

* `core_usr` → `II_USER:` with no value. This is the dangerous one: the compose
  file stays valid YAML and the container starts, the auth service simply has no
  identity to log into the identity server with.
* `gateway_port` → `- :/tcp` in the nginx service's `ports:` and `listen ;` in
  the public api config, so the gateway cannot come up.
* `subnet_core` / `subnet_module` / `subnet_gateway` → `subnet: /28` in a compose
  network's ipam config, `allow /16;` in the internal api config, and `"/28"` in
  the host manager's `net_range_list`.

## Settings a container renders itself

Step 4 covers the templates the *installer* renders. The gateway configs are not
among them. `assets/container/configs/gateway/template/*.template` is copied
verbatim by `copyContainerAssets`, mounted into the nginx container at
`/etc/nginx/templates`, and rendered by the nginx image's own entrypoint when
the container starts.

A setting a gateway config uses is therefore substituted twice, by two different
mechanisms:

1. the installer's `envsubst` fills `${GATEWAY_PORT}` and the `${SUBNET_*}` into
   `docker-compose.yml`, where they sit in the nginx service's `environment:`
   block;
2. the nginx entrypoint substitutes the same names again, from the container's
   own environment, into `/etc/nginx/conf.d/*.conf`.

Such a setting has a sixth place, then: the `environment:` block of the nginx
service. Leaving it out means the name stays unsubstituted in the rendered nginx
config rather than in the compose file — the entrypoint only replaces names that
are actually set in the container's environment — which shows up in the
container's log and nowhere else.

## Settings that gate a package

A setting whose feature needs a command that is not needed otherwise gets its
package list of its own in `assets/.options` — `require_pkg_systemd`,
`install_pkg_logrotate` and `install_pkg_advertise` are the existing ones — which
`getRequiredPkg()` / `getInstallPkg()` in `assets/scripts/lib/package.sh` append
when the setting is `true`. Adding an entry to the unconditional `require_pkg` or
`install_pkg` instead makes every install carry it, including the ones that
declined the feature.

Both composers read the settings from the surrounding scope, so `handlePackages`
has to run *after* they are resolved. It does in `setup.sh` (after
`handleIntegration`) and in `assets/scripts/update.sh` (after `handleNew`, which
can still switch `advertise` on for an install predating that setting). A new
gating setting must therefore be resolved before that point in both scripts.

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
