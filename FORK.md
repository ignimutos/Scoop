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
4. Bucket priorities decide which bucket wins when two buckets hold the same app:
   1. `scoop bucket add <name> [<repo>] [<priority>]`
   2. `scoop bucket alter <name> <priority>`
   Known buckets start at `100 - index`, unknown buckets at
   `bucket-default-priority` (default 200).
5. `gh_proxy` config key routes GitHub release downloads through a
   [gh-proxy](https://github.com/hunshcn/gh-proxy) mirror.
6. `scoop update --ignore-hold` updates held apps and re-applies the hold.

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
