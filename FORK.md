# Fork customizations

This is a personal fork of [ScoopInstaller/Scoop](https://github.com/ScoopInstaller/Scoop).
It tracks upstream `master` and keeps a small set of additions on top.

## What's new

1. `scoop checkver <target>` runs `bin/checkver.ps1` for an app, so a manifest
   can be checked without leaving the Scoop command.
2. `persist_link` works like `persist` but sources the link from outside the app
   directory. Use it for apps that keep data in a fixed location such as
   `%AppData%\Thunderbird`.
3. `Set-Value` writes a value into a json or ini file under `$persist_dir`, for
   use from install hooks.
4. Manifest hook helpers for state that does not belong in the app directory:
   `Initialize-PersistedFile` seeds a config file before `persist` takes over,
   `Remove-InstallerResidue` drops installer leftovers, `Save-AppRegistry` /
   `Restore-AppRegistry` back up app-owned registry keys in the persist store,
   and `Expand-SquirrelApp` unpacks the Squirrel.Windows payload.
5. Bucket priorities decide which bucket wins when two buckets hold the same app:
   1. `scoop bucket add <name> [<repo>] [<priority>]`
   2. `scoop bucket alter <name> <priority>`
   Known buckets start at `100 - index`, unknown buckets at
   `bucket-default-priority` (default 200).
6. `gh_proxy` config key routes GitHub release downloads through a
   [gh-proxy](https://github.com/hunshcn/gh-proxy) mirror.
7. `scoop update --ignore-hold` updates held apps and re-applies the hold.

## Hook helpers

These run inside manifest hooks, so they see `$dir`, `$original_dir`,
`$persist_dir`, `$global` and `$architecture` through the caller's scope.

| Helper | Hook | What it does |
| --- | --- | --- |
| `Initialize-PersistedFile -Path <p> [-PersistPath <q>] [-Content <lines>]` | `pre_install` | Seeds a file under `$dir` when the store holds nothing for it. An empty store directory is replaced; a zero-byte file counts as data. `-PersistPath` maps a nested source to a flat store name. |
| `Remove-InstallerResidue [-Path <dir>] [-Include <patterns>]` | install or post_install | Removes `$PLUGINSDIR`, plus entries whose name matches a pattern. A target outside `-Path` is refused. |
| `Save-AppRegistry -Map <file = key> [-To <dir>] [-Delete]` | `uninstaller` or `post_uninstall` | Exports each existing key into `-To` (default `$persist_dir`). With `-Delete`, removes it after a successful export. |
| `Restore-AppRegistry -Map <file = key> [-From <dir>]` | `post_install` | Imports each backup from `-From` (default `$persist_dir`) that exists. An import overwrites install-time values, so set forced values after this call. |
| `Expand-SquirrelApp [-Path <dir>] [-Architecture <arch>]` | `pre_install` | Expands `$PLUGINSDIR\app-<arch>.7z` into `-Path`. A package that renames the file is accepted when exactly one `app*.7z` exists. |

## persist_link

A manifest entry looks like `persist`:

```json
{
    "persist_link": [
        ["%AppData%\\SomeApp", "SomeApp"],
        "%LocalAppData%\\OtherApp"
    ]
}
```

- The first element is the source outside `$ScoopDir`. Environment variables
  are expanded.
- The second element is the name under `scoop\persist\<app>`. Omit it to use
  the whole persist directory for that app.
- The link is created before the installer runs, so the installer writes into
  the persisted location.

## Known limits

1. `persist_link` supports either user or global mode, not both. Many apps use
   only one of the two, so treat global mode as unsupported.
2. A source that holds only the copy shipped in the archive is dropped instead
   of backed up. This keeps reinstall from piling up backups in the store.
