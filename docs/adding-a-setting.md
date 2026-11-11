# Adding a setting

A setting is a `key=value` in a version's `assets/settings.defaults`, overridden per core by
`state/settings`. Adding one means deciding three things — its default for new cores, its value for
existing cores, and what changing it on a running core takes — and touching the places below. A
missed place fails quietly: the setting exists, but an existing core changes behaviour on the next
update, or `ctrl.sh` refuses to change it.

## Applies when

You are adding a value a user or the install can set: an integration switch, a container log level,
a port. Not for values a version fixes for itself (image tags and binary versions belong in
`assets/options`) or for the install's own keys (`install_dir`, `start_core`,
`skip_pkg_install_confirm` in `lib/setup.sh`, `setup_keys`).

## The places

1. **`assets/settings.defaults`**: the key and its default for new installations, in the section
   that fits (identity, integrations, updates, core containers). Keys are only ever added, never
   renamed or removed: `state/settings` of existing cores and older versions after a rollback must
   keep understanding each other. A key left empty is filled in by the install (generated or
   derived) and must then be in `setup_pinned` (place 4).
2. **`assets/settings.pinned`**, if an existing core would otherwise change behaviour: an update
   adds each `key=value` line there to `state/settings` when the key is missing, so a core that ran
   without the setting keeps behaving as before, while new installations get the default from
   `settings.defaults`. Example: a new `gateway_tls` with the default `true` is pinned as
   `gateway_tls=false`. Pinned lines are never removed.
3. **The templates**: every setting is a render variable, uppercased (`gateway_port` becomes
   `${GATEWAY_PORT}`) in every `.tmpl` file under `assets/templates`. Nothing to register.
4. **`lib/setup.sh`**:
   - `setupValidate`: the value's format, checked for the config file, the questions and
     `ctrl.sh settings set`. Without a case the value is taken as it is.
   - `setup_pinned`, if the install writes the key into `state/settings` even when it keeps its
     default (the core's identity, its credentials, the integrations: everything that mustn't float
     with a later version's defaults).
   - `setup.sh` itself, if the interactive install should ask for it; `assets/setup.conf.example`
     in any case.
5. **`lib/ctrl.sh`, `ctrlSettingKind`**: what changing the setting on a running core takes. Without
   a case it is `refused`. The kinds:
   - `none`: only stored (read by the next update)
   - `recreate`: re-render and recreate the containers (`*_log_level`, `*_delay` match by name)
   - `port`, `integration`, `secrets`, `autostart`: see the function's comment
   - `refused`: identity, credentials, subnets; give the reason in `ctrlRefusedReason`
   A setting of the kinds `none` and `recreate` floats with the defaults and may be reset
   (`ctrlResettable`).
6. **The tests**: `tests/unit/setup.bats` for the validation, `tests/unit/ctrl.bats` for its kind,
   a VM test if changing it does more than storing and recreating.

## Migrated installations

Installations of the old installer get their `state/settings` from the old `.settings`
(`lib/migration.sh`, `migrationSettings`). A new setting needs nothing there: the migration builds
the version like an update (with `settings.pinned`), so a pinned value reaches migrated cores too.
