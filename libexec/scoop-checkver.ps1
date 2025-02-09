# Usage: scoop checkver <target> [options] [<args>]
# Summary: Check scoop apps version
# Help: Available subcommands: add, rm, list.
#
# Aliases are custom Scoop subcommands that can be created to make common tasks easier.
#
# To check a app:
#
#     scoop checkver <target>
#
# e.g.,
#
#     scoop checkver main
#     scoop checkver main/git
#
# Options:
#   see bin/checkver.ps1

. "$PSScriptRoot\..\lib\getopt.ps1"
$opt, $target, $err = getopt $args 'ufsvt:' 'update', 'force-update', 'skip-updated', 'version', 'throw-error'
if ($err) { "scoop checkver: $err"; exit 1 }
if ($target.Length -eq 0) { 'no app present'; exit 1 }

$update = $opt.u -or $opt.update
$force_update = $opt.f -or $opt.'force-update'
$skip_updated = $opt.s -or $opt.'skip-updated'
$version = $opt.v ?? $opt.version
$throw_error = $opt.t -or $opt.'throw-error'

$parts = $target[0].Split('/')
if ($parts.Length -eq 1) {
    $parts += '*'
}

$app = $parts[1]
$dir = "$bucketsdir\$($parts[0])"
$netsted_args = @{
    App         = $app
    Dir         = $dir
    Version     = $version
    Update      = $update
    ForceUpdate = $force_update
    SkipUpdated = $skip_updated
    ThrowError  = $throw_error
}

& "$PSScriptRoot\..\bin\checkver.ps1" @netsted_args

exit 0
