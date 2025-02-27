# Readme or Not

## What's new

1. add `Scoop checkver` alias to bin/checkver.ps1
2. add `persist_link` similar to `persist`, make unportable file out of `$ScoopDir` under persist control
3. add `install.ps1/Set-Value` method to update config value
4. support bucket sorting:
    1. `scoop bucket add <name> [<repo>] [<priority>]`
    2. `scoop bucket alter <name> <priority>`
5. support [Github Proxy](https://github.com/hunshcn/gh-proxy), config key is `gh_proxy`

## What's wrong

1. for now `persist_link` only support one of `user` or `global` mode, many software only support current user mode, and others only support global mode. so just forget `global` mode
