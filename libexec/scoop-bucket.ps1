# Usage: scoop bucket add|alter|list|known|rm [<args>]
# Summary: Manage Scoop buckets
# Help: Add, list or remove buckets.
#
# Buckets are repositories of apps available to install. Scoop comes with
# a default bucket, but you can also add buckets that you or others have
# published.
#
# To add a bucket:
#     scoop bucket add <name> [<repo>] [<priority>]
#
# e.g.:
#     scoop bucket add extras https://github.com/ScoopInstaller/Extras.git
#
# Since the 'extras' bucket is known to Scoop, this can be shortened to:
#     scoop bucket add extras
#
# To alter a bucket:
#     scoop bucket alter <name> <priority>
#
# e.g.:
#     scoop bucket alter main 1000
#
# To list all known buckets, use:
#     scoop bucket known
param($cmd, $name, $arg1, $arg2)

if (get_config USE_SQLITE_CACHE) {
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\database.ps1"
}

$usage_add = 'usage: scoop bucket add <name> [<repo>] [<priority>]'
$usage_alter = 'usage: scoop bucket alter <name> <priority>'
$usage_rm = 'usage: scoop bucket rm <name>'

switch ($cmd) {
    'add' {
        if (!$name) {
            '<name> missing'
            $usage_add
            exit 1
        }
        if ($arg2) {
            if ($arg2 -match '\d+') {
                $priority = [int]$arg2
            } else {
                "Wrong priority '$arg2'. Try int."
                $usage_add
                exit 1
            }
            $repo = $arg1
        } else {
            if ($arg1) {
                if ($arg1 -match '\d+') {
                    $priority = [int]$arg1
                    $repo = known_bucket_repo $name
                } else {
                    $repo = $arg1
                }
            } else {
                $repo = known_bucket_repo $name
            }
        }
        if (!$repo) {
            "Unknown bucket '$name'. Try specifying <repo>."
            $usage_add
            exit 1
        }
        $status = add_bucket $name $repo $priority
        exit $status
    }
    'alter' {
        if (!$name) {
            '<name> missing'
            $usage_alter
            exit 1
        }

        if ($arg1 -and ($arg1 -match '\d+')) {
            $priority = [int]$arg1
        } else {
            "Wrong priority '$arg1'. Try int."
            $usage_add
            exit 1
        }

        $status = alter_bucket $name $priority
        exit $status
    }
    'rm' {
        if (!$name) {
            '<name> missing'
            $usage_rm
            exit 1
        }
        $status = rm_bucket $name
        exit $status
    }
    'list' {
        $buckets = list_buckets
        if (!$buckets.Length) {
            warn "No bucket found. Please run 'scoop bucket add main' to add the default 'main' bucket."
            exit 2
        } else {
            $buckets
            exit 0
        }
    }
    'known' {
        known_buckets
        exit 0
    }
    default {
        "scoop bucket: cmd '$cmd' not supported"
        my_usage
        exit 1
    }
}
