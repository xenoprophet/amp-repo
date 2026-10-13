# Schedule I for AMP

Windows template for [S1DedicatedServers](https://github.com/ifBars/S1DedicatedServers), using IL2CPP and MelonLoader. A Steam account that owns Schedule I is required.

## Applying this template

1. Commit and push all template files to this repository's `main` branch. The update stages download support files from this repository, so local changes must be published before AMP can download them.
2. In AMP's parent controller, fetch `xenoprophet/amp-repo:main` under **Configuration → Instance Deployment → Configuration Repositories**, then refresh the page.
3. For an existing instance, use **Refresh Configuration** from its instance menu in the parent controller to apply the updated application template. Fetching the repository alone does not confirm that an existing instance has adopted the changes. Its template version should be **2**.
4. Stop the game server and run **Update** in the Schedule I instance once. This installs the configuration support files; the game does not need to run to generate its config.
5. Open **Configuration** in the instance and review the server settings, then start the server. Future setting changes apply on the next stop/start.

If an existing instance does not show the new categories after updating its template and refreshing, check that `GenericModule.kvp` references `schedule1metaconfig.json` and `schedule1prestart.json` through the corresponding AMP deployment files. Do not delete an existing instance or its saves to refresh the template.

## Server settings

AMP provides controls for server identity/password, public listing, authentication and client mod verification, messaging, console/web panel, gameplay, autosave, logging, performance, and save paths. Legacy template fields retain their original names so existing AMP values for server name, maximum players, authentication provider, and risky-mod blocking remain usable.

The game/query ports come from AMP's port assignments, rather than separate editable TOML values. The game port is reserved for both UDP gameplay and TCP status queries. TCP console and web panel ports are also reserved, but those services remain disabled and loopback-bound by default. The stdio host console stays enabled for AMP.

AMP writes `AMP_server_settings.json` in `s1ds/3164500`. Before each game launch, `AMP_WriteServerConfig.ps1` converts the values to `UserData/server_config.toml`. The conversion handles string quoting, Windows paths, booleans, decimal values, and the logging array without putting settings in shell commands. It creates the file if missing and retains unknown sections, unknown keys, and standalone comments when updating an existing file.

**For an existing server, review and copy any custom values from your current TOML into AMP before the first managed start.** AMP's controls become authoritative for mapped settings; this version does not automatically import an existing TOML into AMP. Before the first managed write, the original file is copied to `UserData/server_config.toml.before-amp.bak`. This backup is kept on later starts. Backups and configuration files can contain passwords or tokens; keep them private.

Additional Arguments still allows intentional command-line overrides. Those take precedence over the TOML settings. Change managed values through AMP, because editing them directly in the TOML will be replaced on the next start. If you add entirely new mod settings, unrecognized keys are retained.

Enter normal text in string fields, without surrounding quotes. For the logging options, enter a comma-separated list such as `logPlayerActions, logAdminCommands`; leave it empty to disable logging streams. Decimal values use a point, such as `1.5`.

The PowerShell converter is compatible with Windows PowerShell 5.1 and does not require installing Python or another runtime on the server. If support files are missing or a value cannot be converted, the pre-start stage fails before replacing the TOML.

## Staff roles and permissions

`UserData/permissions.toml` stays under the mod's control. This template never generates or overwrites it. The server creates it on first run and saves changes made through its permission commands.

Use AMP's **Console** tab. Replace the sample number with the player's **SteamID64**, and choose the role you want:

```text
group assign 76561198012345678 support
group assign 76561198012345678 moderator
group assign 76561198012345678 administrator
group assign 76561198012345678 operator
```

The built-in roles inherit from one another: default → support → moderator → administrator → operator. Moderator handles player moderation, administrator adds server maintenance, and operator has the highest built-in management access.

```text
group list
perm info 76561198012345678
group unassign 76561198012345678 moderator
```

When changing roles, remove any previous group you no longer want; assigning a group does not replace other memberships. `op <SteamID64>` and `admin <SteamID64>` are shorthand commands. If you edit the permissions file manually, run `reloadpermissions` afterward. Normal console role commands apply immediately and save automatically.

See the [upstream permissions guide](https://github.com/ifBars/S1DedicatedServers/blob/master/docfx/docs/configuration/permissions.md) for custom groups, bans, temporary grants, and direct allow/deny rules.

## Local validation

Run `python -m unittest discover -s tests -v` on a Windows development machine with Python 3.11 or newer. The checks exercise the converter with Windows PowerShell, parse its output as TOML, check AMP field mappings and port assignments, and verify first-run creation, backup preservation, invalid-value handling, and preservation of permission files. Live AMP deployment and game startup still need to be checked on the actual server.
