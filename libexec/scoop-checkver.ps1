# Usage: scoop checkver <target> [options] [<args>]
# Summary: Check scoop apps version
# Help: Runs bin/checkver.ps1 against the manifests of an installed app.
#
# To check an app:
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
$opt, $target, $err = getopt $args 'uUfFsv:t' 'update', 'force-update', 'skip-updated', 'version:', 'throw-error'
if ($err) { error "scoop checkver: $err"; exit 1 }
if ($target.Length -eq 0) { error 'no app present'; exit 1 }

$update = $opt.u -or $opt.U -or $opt.update
$force_update = $opt.f -or $opt.F -or $opt.'force-update'
$skip_updated = $opt.s -or $opt.'skip-updated'
# PS 5.1 has no null-coalescing operator, test explicitly
$version = if ($opt.v) { $opt.v } else { $opt.version }
$throw_error = $opt.t -or $opt.'throw-error'

if ($target[0] -like '*/*') {
    $parts = $target[0].Split('/')
    $app = $parts[1]
    $dir = "$bucketsdir\$($parts[0])"
} else {
    $app = $target[0]
    $dir = $bucketsdir
}

$nested_args = @{
    App         = $app
    Dir         = $dir
    Version     = $version
    Update      = $update
    ForceUpdate = $force_update
    SkipUpdated = $skip_updated
    ThrowError  = $throw_error
}
debug "checkver $($nested_args.GetEnumerator() | ForEach-Object { $_ })"
& "$PSScriptRoot\..\bin\checkver.ps1" @netsted_args

exit 0
