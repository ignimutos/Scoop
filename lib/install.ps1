function nightly_version($quiet = $false) {
    if (!$quiet) {
        warn "This is a nightly version. Downloaded files won't be verified."
    }
    return "nightly-$(Get-Date -Format 'yyyyMMdd')"
}

function install_app($app, $architecture, $global, $suggested, $use_cache = $true, $check_hash = $true) {
    $app, $manifest, $bucket, $url = Get-Manifest $app

    if (!$manifest) {
        abort "Couldn't find manifest for '$app'$(if ($bucket) { " from '$bucket' bucket" } elseif ($url) { " at '$url'" })."
    }

    $version = $manifest.version
    if (!$version) { abort "Manifest doesn't specify a version." }
    if ($version -match '[^\w\.\-\+_]') {
        abort "Manifest version has unsupported character '$($matches[0])'."
    }

    $is_nightly = $version -eq 'nightly'
    if ($is_nightly) {
        $version = nightly_version
        $check_hash = $false
    }

    $architecture = Get-SupportedArchitecture $manifest $architecture
    if ($null -eq $architecture) {
        error "'$app' doesn't support current architecture!"
        return
    }

    if ((get_config SHOW_MANIFEST $false) -and ($MyInvocation.ScriptName -notlike '*scoop-update*')) {
        Write-Host "Manifest: $app.json"
        $style = get_config CAT_STYLE
        if ($style) {
            $manifest | ConvertToPrettyJson | bat --no-paging --style $style --language json
        } else {
            $manifest | ConvertToPrettyJson
        }
        $answer = Read-Host -Prompt 'Continue installation? [Y/n]'
        if (($answer -eq 'n') -or ($answer -eq 'N')) {
            return
        }
    }
    Write-Output "Installing '$app' ($version) [$architecture]$(if ($bucket) { " from '$bucket' bucket" } elseif ($url -like (usermanifestsdir) + '\*') { ' from generated manifest' } else { " from '$url'" })"

    $dir = ensure (versiondir $app $version $global)
    $original_dir = $dir # keep reference to real (not linked) directory
    $persist_dir = persistdir $app $global

    $fname = Invoke-ScoopDownload $app $version $manifest $bucket $architecture $dir $use_cache $check_hash
    Invoke-Extraction -Path $dir -Name $fname -Manifest $manifest -ProcessorArchitecture $architecture
    Invoke-HookScript -HookType 'pre_install' -Manifest $manifest -ProcessorArchitecture $architecture
    # persist link, should run before installation
    persist_link $manifest $original_dir $persist_dir

    Invoke-Installer -Path $dir -Name $fname -Manifest $manifest -ProcessorArchitecture $architecture -AppName $app -Global:$global
    ensure_install_dir_not_in_path $dir $global
    $dir = link_current $dir
    create_shims $manifest $dir $global $architecture
    create_startmenu_shortcuts $manifest $dir $global $architecture
    install_psmodule $manifest $dir $global
    env_add_path $manifest $dir $global $architecture
    env_set $manifest $global $architecture

    # persist data
    persist_data $manifest $original_dir $persist_dir
    persist_permission $manifest $global

    Invoke-HookScript -HookType 'post_install' -Manifest $manifest -ProcessorArchitecture $architecture

    # save info for uninstall
    save_installed_manifest $app $bucket $dir $url
    save_install_info @{ 'architecture' = $architecture; 'url' = $url; 'bucket' = $bucket } $dir

    if ($manifest.suggest) {
        $suggested[$app] = $manifest.suggest
    }

    success "'$app' ($version) was installed successfully!"

    show_notes $manifest $dir $original_dir $persist_dir
}

function Invoke-Installer {
    [CmdletBinding()]
    param (
        [string]
        $Path,
        [string[]]
        $Name,
        [psobject]
        $Manifest,
        [Alias('Arch', 'Architecture')]
        [ValidateSet('32bit', '64bit', 'arm64')]
        [string]
        $ProcessorArchitecture,
        [string]
        $AppName,
        [switch]
        $Global,
        [switch]
        $Uninstall
    )
    $type = if ($Uninstall) { 'uninstaller' } else { 'installer' }
    $installer = arch_specific $type $Manifest $ProcessorArchitecture
    if ($installer.file -or $installer.args) {
        # Installer filename is either explicit defined ('installer.file') or file name in the first URL
        if (!$Name) {
            $Name = url_filename @(url $manifest $architecture)
        }
        $progName = "$Path\$(coalesce $installer.file $Name[0])"
        if (!(is_in_dir $Path $progName)) {
            abort "Error in manifest: $((Get-Culture).TextInfo.ToTitleCase($type)) $progName is outside the app directory."
        } elseif (!(Test-Path $progName)) {
            abort "$((Get-Culture).TextInfo.ToTitleCase($type)) $progName is missing."
        }
        $substitutions = @{
            '$dir'     = $Path
            '$global'  = $Global
            '$version' = $Manifest.version
        }
        $fnArgs = substitute $installer.args $substitutions
        if ($progName.EndsWith('.ps1')) {
            & $progName @fnArgs
        } else {
            $status = Invoke-ExternalCommand $progName -ArgumentList $fnArgs -Activity "Running $type ..."
            if (!$status) {
                if ($Uninstall) {
                    abort 'Uninstallation aborted.'
                } else {
                    abort "Installation aborted. You might need to run 'scoop uninstall $AppName' before trying again."
                }
            }
            # Don't remove installer if "keep" flag is set to true
            if (!$installer.keep) {
                Remove-Item $progName
            }
        }
    }
    Invoke-HookScript -HookType $type -Manifest $Manifest -ProcessorArchitecture $ProcessorArchitecture
}

function Invoke-HookScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('installer', 'pre_install', 'post_install', 'uninstaller', 'pre_uninstall', 'post_uninstall')]
        [String] $HookType,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject] $Manifest,
        [Parameter(Mandatory = $true)]
        [Alias('Arch', 'Architecture')]
        [ValidateSet('32bit', '64bit', 'arm64')]
        [string]
        $ProcessorArchitecture
    )

    $script = arch_specific $HookType $Manifest $ProcessorArchitecture
    if ($HookType -in @('installer', 'uninstaller')) {
        $script = $script.script
    }
    if ($script) {
        Write-Host "Running $HookType script... " -NoNewline
        Invoke-Command ([scriptblock]::Create($script -join "`r`n"))
        Write-Host 'Done.' -ForegroundColor Green
    }
}

# get target, name, arguments for shim
function shim_def($item) {
    if ($item -is [array]) { return $item }
    return $item, (strip_ext (fname $item)), $null
}

function create_shims($manifest, $dir, $global, $arch) {
    $shims = @(arch_specific 'bin' $manifest $arch)
    $shims | Where-Object { $_ -ne $null } | ForEach-Object {
        $target, $name, $arg = shim_def $_
        Write-Output "Creating shim for '$name'."

        if (Test-Path "$dir\$target" -PathType leaf) {
            $bin = "$dir\$target"
        } elseif (Test-Path $target -PathType leaf) {
            $bin = $target
        } else {
            $bin = (Get-Command $target).Source
        }
        if (!$bin) { abort "Can't shim '$target': File doesn't exist." }

        shim $bin $global $name (substitute $arg @{ '$dir' = $dir; '$original_dir' = $original_dir; '$persist_dir' = $persist_dir })
    }
}

function rm_shim($name, $shimdir, $app) {
    '', '.shim', '.cmd', '.ps1' | ForEach-Object {
        $shimPath = "$shimdir\$name$_"
        $altShimPath = "$shimPath.$app"
        if ($app -and (Test-Path -Path $altShimPath -PathType Leaf)) {
            Write-Output "Removing shim '$name$_.$app'."
            Remove-Item $altShimPath
        } elseif (Test-Path -Path $shimPath -PathType Leaf) {
            Write-Output "Removing shim '$name$_'."
            Remove-Item $shimPath
            $oldShims = Get-Item -Path "$shimPath.*" -Exclude '*.shim', '*.cmd', '*.ps1'
            if ($null -eq $oldShims) {
                if ($_ -eq '.shim') {
                    Write-Output "Removing shim '$name.exe'."
                    Remove-Item -Path "$shimdir\$name.exe"
                }
            } else {
                (@($oldShims) | Sort-Object -Property LastWriteTimeUtc)[-1] | Rename-Item -NewName { $_.Name -replace '\.[^.]*$', '' }
            }
        }
    }
}

function rm_shims($app, $manifest, $global, $arch) {
    $shims = @(arch_specific 'bin' $manifest $arch)

    $shims | Where-Object { $_ -ne $null } | ForEach-Object {
        $target, $name, $null = shim_def $_
        $shimdir = shimdir $global

        rm_shim $name $shimdir $app
    }
}

# Creates or updates the directory junction for [app]/current,
# pointing to the specified version directory for the app.
#
# Returns the 'current' junction directory if in use, otherwise
# the version directory.
function link_current($versiondir) {
    if (get_config NO_JUNCTION) { return $versiondir.ToString() }

    $currentdir = "$(Split-Path $versiondir)\current"

    Write-Host "Linking $(friendly_path $currentdir) => $(friendly_path $versiondir)"

    if ($currentdir -eq $versiondir) {
        abort "Error: Version 'current' is not allowed!"
    }

    if (Test-Path $currentdir) {
        # remove the junction
        attrib -R /L $currentdir
        Remove-Item $currentdir -Recurse -Force -ErrorAction Stop
    }

    New-DirectoryJunction $currentdir $versiondir | Out-Null
    attrib $currentdir +R /L
    return $currentdir
}

# Removes the directory junction for [app]/current which
# points to the current version directory for the app.
#
# Returns the 'current' junction directory (if it exists),
# otherwise the normal version directory.
function unlink_current($versiondir) {
    if (get_config NO_JUNCTION) { return $versiondir.ToString() }
    $currentdir = "$(Split-Path $versiondir)\current"

    if (Test-Path $currentdir) {
        Write-Host "Unlinking $(friendly_path $currentdir)"

        # remove read-only attribute on link
        attrib $currentdir -R /L

        # remove the junction
        Remove-Item $currentdir -Recurse -Force -ErrorAction Stop
        return $currentdir
    }
    return $versiondir
}

# to undo after installers add to path so that scoop manifest can keep track of this instead
function ensure_install_dir_not_in_path($dir, $global) {
    $path = (Get-EnvVar -Name 'PATH' -Global:$global)

    $fixed, $removed = find_dir_or_subdir $path "$dir"
    if ($removed) {
        $removed | ForEach-Object { Write-Output "Installer added '$(friendly_path $_)' to path. Removing." }
        Set-EnvVar -Name 'PATH' -Value $fixed -Global:$global
    }

    if (!$global) {
        $fixed, $removed = find_dir_or_subdir (Get-EnvVar -Name 'PATH' -Global) "$dir"
        if ($removed) {
            $removed | ForEach-Object { warn "Installer added '$_' to system path. You might want to remove this manually (requires admin permission)." }
        }
    }
}

function find_dir_or_subdir($path, $dir) {
    $dir = $dir.trimend('\')
    $fixed = @()
    $removed = @()
    $path.split(';') | ForEach-Object {
        if ($_) {
            if (($_ -eq $dir) -or ($_ -like "$dir\*")) { $removed += $_ }
            else { $fixed += $_ }
        }
    }
    return [string]::join(';', $fixed), $removed
}

function env_add_path($manifest, $dir, $global, $arch) {
    $env_add_path = arch_specific 'env_add_path' $manifest $arch
    $dir = $dir.TrimEnd('\')
    if ($env_add_path) {
        if (get_config USE_ISOLATED_PATH) {
            Add-Path -Path ('%' + $scoopPathEnvVar + '%') -Global:$global
        }
        $path = $env_add_path.Where({ $_ }).ForEach({ Join-Path $dir $_ | Get-AbsolutePath }).Where({ is_in_dir $dir $_ })
        Add-Path -Path $path -TargetEnvVar $scoopPathEnvVar -Global:$global -Force
    }
}

function env_rm_path($manifest, $dir, $global, $arch) {
    $env_add_path = arch_specific 'env_add_path' $manifest $arch
    $dir = $dir.TrimEnd('\')
    if ($env_add_path) {
        $path = $env_add_path.Where({ $_ }).ForEach({ Join-Path $dir $_ | Get-AbsolutePath }).Where({ is_in_dir $dir $_ })
        Remove-Path -Path $path -Global:$global # TODO: Remove after forced isolating Scoop path
        Remove-Path -Path $path -TargetEnvVar $scoopPathEnvVar -Global:$global
    }
}

function env_set($manifest, $global, $arch) {
    $env_set = arch_specific 'env_set' $manifest $arch
    if ($env_set) {
        $env_set | Get-Member -MemberType NoteProperty | ForEach-Object {
            $name = $_.Name
            $val = $ExecutionContext.InvokeCommand.ExpandString($env_set.$($name))
            Write-Output "Setting $(if ($global) {'system'} else {'user'}) environment variable: $([char]0x1b)[34m$name$([char]0x1b)[0m = $([char]0x1b)[35m$val$([char]0x1b)[0m"
            Set-EnvVar -Name $name -Value $val -Global:$global
            Set-Content env:\$name $val
        }
    }
}
function env_rm($manifest, $global, $arch) {
    $env_set = arch_specific 'env_set' $manifest $arch
    if ($env_set) {
        $env_set | Get-Member -MemberType NoteProperty | ForEach-Object {
            $name = $_.Name
            Write-Output "Removing $(if ($global) {'system'} else {'user'}) environment variable: $([char]0x1b)[34m$name$([char]0x1b)[0m"
            Set-EnvVar -Name $name -Value $null -Global:$global
            if (Test-Path env:\$name) { Remove-Item env:\$name }
        }
    }
}

function show_notes($manifest, $dir, $original_dir, $persist_dir) {
    if ($manifest.notes) {
        Write-Output 'Notes'
        Write-Output '-----'
        Write-Output (wraptext (substitute $manifest.notes @{ '$dir' = $dir; '$original_dir' = $original_dir; '$persist_dir' = $persist_dir }))
        Write-Output '-----'
    }
}

function all_installed($apps, $global) {
    $apps | Where-Object {
        $app, $null, $null = parse_app $_
        installed $app $global
    }
}

# returns (uninstalled, installed)
function prune_installed($apps, $global) {
    $installed = @(all_installed $apps $global)

    $uninstalled = $apps | Where-Object { $installed -notcontains $_ }

    return @($uninstalled), @($installed)
}

function ensure_none_failed($apps) {
    foreach ($app in $apps) {
        $app = ($app -split '/|\\')[-1] -replace '\.json$', ''
        foreach ($global in $true, $false) {
            if ($global) {
                $instArgs = @('--global')
            } else {
                $instArgs = @()
            }
            if (failed $app $global) {
                if (installed $app $global) {
                    info "Repair previous failed installation of $app."
                    & "$PSScriptRoot\..\libexec\scoop-reset.ps1" $app @instArgs
                } else {
                    warn "Purging previous failed installation of $app."
                    & "$PSScriptRoot\..\libexec\scoop-uninstall.ps1" $app @instArgs
                }
            }
        }
    }
}

function show_suggestions($suggested) {
    $installed_apps = (installed_apps $true) + (installed_apps $false)

    foreach ($app in $suggested.keys) {
        $features = $suggested[$app] | Get-Member -type noteproperty | ForEach-Object { $_.name }
        foreach ($feature in $features) {
            $feature_suggestions = $suggested[$app].$feature

            $fulfilled = $false
            foreach ($suggestion in $feature_suggestions) {
                $suggested_app, $bucket, $null = parse_app $suggestion

                if ($installed_apps -contains $suggested_app) {
                    $fulfilled = $true
                    break
                }
            }

            if (!$fulfilled) {
                Write-Host "'$app' suggests installing '$([string]::join("' or '", $feature_suggestions))'." -ForegroundColor DarkYellow
            }
        }
    }
}

function persist_link_def($link) {
    if ($link -is [Array]) {
        $source = $link[0]
        $target = $link[1]
    } else {
        $source = $link
        $target = ''
    }

    return $ExecutionContext.InvokeCommand.ExpandString($source), $target
}

function persist_link($manifest, $original_dir, $persist_dir) {
    $link = $manifest.persist_link
    if ($link) {
        $persist_dir = ensure $persist_dir

        if ($link -is [String]) {
            $link = @($link)
        }
        $link | ForEach-Object {
            $source, $target = persist_link_def $_

            $source = $source.TrimEnd('/').TrimEnd('\\')
            # a plain string carries no target, which lands the whole persist dir here
            $target = "$persist_dir\$target".TrimEnd('/').TrimEnd('\\')

            Write-Host "Linking $source to $target"
            if (Test-Path $source) {
                $source_item = Get-Item $source -Force

                # Check for running processes in the source directory
                if ($source_item -is [System.IO.DirectoryInfo]) {
                    $running = Get-Process | Where-Object {
                        try { $_.Path -and $_.Path.StartsWith($source, [StringComparison]::OrdinalIgnoreCase) }
                        catch { $false }
                    }
                    if ($running) {
                        error "Cannot replace $source - the following processes are using it:"
                        $running | ForEach-Object { Write-Host "  - $($_.Name) (PID: $($_.Id))" }
                        abort "Please close these processes and try again."
                    }
                }

                # a stale link or an empty source is not data to keep: drop it and relink
                if (can_discard_source $source $source_item (Test-Path $target)) {
                    remove_persist_source $source $source_item
                } elseif (Test-Path $target) {
                    if (is_empty_data $target) {
                        # an empty store entry is not data either (a plain-string persist_link
                        # pre-creates it), so move the source in rather than off to a backup
                        Remove-Item $target -Force -Recurse -ErrorAction Stop
                        ensure (Split-Path -Path $target) | Out-Null
                        try {
                            Move-Item $source $target -Force -ErrorAction Stop | Out-Null
                        } catch {
                            $msg = "Cannot move $source to $target : $_"
                            if ($_.Exception.Message -match 'Access.*denied|denied') {
                                $msg += "`n`nPossible solutions:"
                                $msg += "`n  1. Run with administrator privileges"
                                $msg += "`n  2. Manually delete: Remove-Item '$source' -Force -Recurse"
                            }
                            abort $msg
                        }
                    } else {
                        # both source and target hold data, backup source
                        $backup_path = "$target.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                        $i = 1
                        while (Test-Path $backup_path) {
                            $backup_path = "$target.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')($i)"
                            $i++
                        }
                        try {
                            Move-Item -Force $source $backup_path -ErrorAction Stop | Out-Null
                            warn "Found existing data in $source, moved to $backup_path"
                        } catch {
                            error "Cannot move $source to $backup_path : $_"
                            warn "Trying to remove $source instead..."
                            try {
                                Remove-Item $source -Force -Recurse -ErrorAction Stop | Out-Null
                            } catch {
                                $msg = "Cannot remove $source : $_"
                                if ($_.Exception.Message -match 'Access.*denied|denied') {
                                    $msg += "`n`nPossible solutions:"
                                    $msg += "`n  1. Run 'scoop install powertoys --global' with administrator privileges"
                                    $msg += "`n  2. Manually delete: Remove-Item '$source' -Force -Recurse"
                                    $msg += "`n  3. Uninstall conflicting software first via Windows Settings"
                                }
                                abort $msg
                            }
                        }
                    }
                } else {
                    # only source exists, move it to target
                    try {
                        ensure (Split-Path -Path $target) | Out-Null
                        Move-Item $source $target -Force -ErrorAction Stop | Out-Null
                    } catch {
                        $msg = "Cannot move $source to $target : $_"
                        if ($_.Exception.Message -match 'Access.*denied|denied') {
                            $msg += "`n`nPossible solutions:"
                            $msg += "`n  1. Run with administrator privileges"
                            $msg += "`n  2. Manually delete: Remove-Item '$source' -Force -Recurse"
                        }
                        abort $msg
                    }
                }
            }
            if (!(Test-Path $target)) {
                New-Item $target -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
            }

            # create link
            if (is_directory $target) {
                # target is a directory, create junction
                New-DirectoryJunction $source $target | Out-Null
                attrib $source +R /L
            } else {
                # target is a file, create hard link
                New-Item -Path $source -ItemType HardLink -Value $target | Out-Null
            }
        }
    }
}

# Persistent data
function persist_def($persist) {
    if ($persist -is [Array]) {
        $source = $persist[0]
        $target = $persist[1]
    } else {
        $source = $persist
        $target = $null
    }

    if (!$target) {
        $target = $source
    }

    return $source, $target
}

# an empty directory holds no data worth backing up.
# hidden items count as data, hence -Force
function is_empty_data($path) {
    $item = Get-Item $path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $true }
    if ($item -is [System.IO.DirectoryInfo]) {
        return !(Get-ChildItem $path -Force -ErrorAction SilentlyContinue)
    }
    return ($item.Length -eq 0)
}

# a source holding only the copy the archive shipped is not the user's data: for a
# persist entry the store copy is the one the user edited (notepad++ ships plugins/,
# themes/ and userDefineLangs/ inside the zip, so a reinstall would otherwise back that
# bundled copy up every time and leave a stream of '.backup_*' entries in the store).
# extracted files keep the time they were built into the archive, while anything written
# after the extraction is newer than the version dir, so comparing the two tells a
# bundled copy from real data. look at the files, not at the source's own mtime: that one
# is bumped while its children are extracted and can overtake the version dir's. strict
# comparison so a same-second write counts as data. do not use CreationTime: a move
# resets it
function is_pristine_source($source_item, $archive_time) {
    if ($source_item -isnot [System.IO.DirectoryInfo]) {
        return $source_item.LastWriteTime -lt $archive_time
    }
    $files = @(Get-ChildItem $source_item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue)
    # no files at all: nothing was written, an empty directory is handled by is_empty_data
    if (!$files) { return $true }
    $newest = ($files | Measure-Object -Property LastWriteTime -Maximum).Maximum
    return $newest -lt $archive_time
}

# a stale link, or an empty source, carries nothing worth keeping.
# a zero-length *file* is only dispensable when the store already holds the entry:
# otherwise we would create a directory in the store and flip a file persist
# (e.g. 'persist': 'config.ini') into a junction, so it falls through to the move
function can_discard_source($source, $source_item, $target_exists) {
    if ($source_item.LinkType) { return $true }
    if (is_empty_data $source) {
        if ($source_item -is [System.IO.DirectoryInfo]) { return $true }
        return $target_exists
    }
    return $false
}

# remove a leftover link or an empty source.
# junctions get the read-only attribute when they are created, which makes a bare
# Remove-Item fail, so clear it first; report actionable hints on failure
function remove_persist_source($source, $source_item) {
    try {
        if ($source_item.LinkType) { attrib -R /L $source }
        Remove-Item $source -Force -Recurse -ErrorAction Stop | Out-Null
    } catch {
        $msg = "Cannot remove $source : $_"
        if ($_.Exception.Message -match 'Access.*denied|denied') {
            $msg += "`n`nTry: attrib -R /L `"$source`" && rmdir `"$source`""
        }
        abort $msg
    }
}

function persist_data($manifest, $original_dir, $persist_dir) {
    $persist = $manifest.persist
    if ($persist) {
        $persist_dir = ensure $persist_dir

        if ($persist -is [String]) {
            $persist = @($persist)
        }

        # 'scoop update' reuses the version dir of the version being replaced when the
        # version string is unchanged, so the extraction time is the newest mtime there.
        # if it cannot be read, nothing counts as pristine and the backup path still runs
        $archive_item = Get-Item $original_dir -Force -ErrorAction SilentlyContinue
        $archive_time = if ($archive_item) { $archive_item.LastWriteTime } else { [datetime]::MinValue }

        $persist | ForEach-Object {
            $source, $target = persist_def $_

            Write-Host "Persisting $source"

            $source = $source.TrimEnd('/').TrimEnd('\\')

            $source = "$original_dir\$source"
            $target = "$persist_dir\$target".TrimEnd('/').TrimEnd('\\')

            $target_exists = Test-Path $target
            $source_exists = Test-Path $source
            $source_item = if ($source_exists) { Get-Item $source -Force } else { $null }

            # a stale link, or an empty source, holds nothing worth backing up: drop it
            if ($source_exists -and (can_discard_source $source $source_item $target_exists)) {
                remove_persist_source $source $source_item
                $source_exists = $false
            }

            # an empty directory in the store is not data, either - the persist_link
            # fallback may have pre-created it. clear it so real data can move in
            if ($source_exists -and $target_exists -and (is_empty_data $target)) {
                Remove-Item $target -Force -Recurse -ErrorAction Stop
                $target_exists = $false
            }

            # a source that is still the archive's own copy is not user data: drop the
            # bundled copy rather than backing it up on every reinstall
            if ($source_exists -and $target_exists -and (is_pristine_source $source_item $archive_time)) {
                remove_persist_source $source $source_item
                $source_exists = $false
            }

            # if we have had persist data in the store, just create link and go
            if ($target_exists) {
                if ($source_exists) {
                    # rename the source with a timestamp (to keep a backup). keep it in the
                    # store: a version dir is deleted by 'scoop cleanup', which would take
                    # the backup with it. two entries may share a timestamp, so number them
                    $backup_name = "$target.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
                    $i = 1
                    while (Test-Path $backup_name) {
                        $backup_name = "$target.backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')($i)"
                        $i++
                    }
                    Move-Item -Force $source $backup_name
                    warn "Found existing data at $source, moved to $backup_name"
                }
            } elseif ($source_exists) {
                # we don't have persist data in the store, move the source to target, then create link
                # ensure target parent folder exist
                ensure (Split-Path -Path $target) | Out-Null
                Move-Item $source $target
                # we don't have neither source nor target data! we need to create an empty target,
                # but we can't make a judgement that the data should be a file or directory...
                # so we create a directory by default. to avoid this, use pre_install
                # to create the source file before persisting (DON'T use post_install)
            } else {
                $target = New-Object System.IO.DirectoryInfo($target)
                ensure $target | Out-Null
            }

            # create link
            if (is_directory $target) {
                # target is a directory, create junction
                New-DirectoryJunction $source $target | Out-Null
                attrib $source +R /L
            } else {
                # target is a file, create hard link
                New-Item -Path $source -ItemType HardLink -Value $target | Out-Null
            }
        }
    }
}

function unlink_persist_data($manifest, $dir) {
    $persist = $manifest.persist
    # unlink all junction / hard link in the directory
    if ($persist) {
        @($persist) | ForEach-Object {
            $source, $null = persist_def $_
            $source = Get-Item "$dir\$source" -ErrorAction SilentlyContinue
            if ($source.LinkType) {
                $source_path = $source.FullName
                # directory (junction)
                if ($source -is [System.IO.DirectoryInfo]) {
                    # remove read-only attribute on the link
                    attrib -R /L $source_path
                    # remove the junction
                    try {
                        Remove-Item -Path $source_path -Recurse -Force -ErrorAction Stop
                    } catch {
                        $msg = "Cannot unlink persisted data '$source_path': $_"
                        if ($_.Exception.Message -match 'Access.*denied|denied') {
                            $msg += "`n`nTry: attrib -R /L `"$source_path`" && rmdir `"$source_path`""
                        }
                        throw $msg
                    }
                } else {
                    # remove the hard link
                    Remove-Item -Path $source_path -Force -ErrorAction Stop
                }
            }
        }
    }
}

function unlink_persist_link_data($manifest, $dir) {
    $link = $manifest.persist_link
    # unlink all junction / hard link in the directory
    if ($link) {
        @($link) | ForEach-Object {
            $source, $null = persist_link_def $_
            $source = Get-Item "$source" -ErrorAction SilentlyContinue
            if ($source.LinkType) {
                $source_path = $source.FullName
                # directory (junction)
                if ($source -is [System.IO.DirectoryInfo]) {
                    # remove read-only attribute on the link
                    attrib -R /L $source_path
                    # remove the junction
                    try {
                        Remove-Item -Path $source_path -Recurse -Force -ErrorAction Stop
                    } catch {
                        $msg = "Cannot unlink persisted data '$source_path': $_"
                        if ($_.Exception.Message -match 'Access.*denied|denied') {
                            $msg += "`n`nTry: attrib -R /L `"$source_path`" && rmdir `"$source_path`""
                        }
                        throw $msg
                    }
                } else {
                    # remove the hard link
                    Remove-Item -Path $source_path -Force -ErrorAction Stop
                }
            }
        }
    }
}

# check whether write permission for Users usergroup is set to global persist dir, if not then set
function persist_permission($manifest, $global) {
    if ($global -and $manifest.persist -and (is_admin)) {
        $path = persistdir $null $global
        $builtinUsersSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)
        $target_rule = New-Object System.Security.AccessControl.FileSystemAccessRule($builtinUsersSid, 'Write', 'ObjectInherit', 'none', 'Allow')
        $acl = Get-Acl -Path $path
        $acl.SetAccessRule($target_rule)
        $acl | Set-Acl -Path $path
    }
}

# test if there are running processes
function test_running_process($app, $global) {
    $processdir = appdir $app $global | Convert-Path
    $running_processes = Get-Process | Where-Object { $_.Path -like "$processdir\*" } | Out-String

    if ($running_processes) {
        if (get_config IGNORE_RUNNING_PROCESSES) {
            warn "The following instances of `"$app`" are still running. Scoop is configured to ignore this condition."
            Write-Host $running_processes
            return $false
        } else {
            error "The following instances of `"$app`" are still running. Close them and try again."
            Write-Host $running_processes
            return $true
        }
    } else {
        return $false
    }
}

# wrapper function to create junction links
# Required to handle docker/for-win#12240
function New-DirectoryJunction($source, $target) {
    # test if this script is being executed inside a docker container
    if (Get-Service -Name cexecsvc -ErrorAction Ignore) {
        cmd.exe /d /c "mklink /j `"$source`" `"$target`""
    } else {
        New-Item -Path $source -ItemType Junction -Value $target
    }
}

# convert the PSCustomObject tree that ConvertFrom-Json returns into hashtables, so
# Set-Value can walk it with ContainsKey on PowerShell 5.1, which has no -AsHashtable
function ConvertTo-Hashtable($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [System.Collections.IDictionary]) { return $value }
    # only PSCustomObject is a json object; every value is -is [PSObject], so that
    # test would swallow arrays and scalars too
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($prop in $value.PSObject.Properties) {
            $table[$prop.Name] = ConvertTo-Hashtable $prop.Value
        }
        return $table
    }
    if ($value -is [System.Array]) {
        return , @($value | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    return $value
}

# create a seed file under $dir when the persist store holds no data for it yet.
# the seed has to exist before persist_data runs, so call this from pre_install:
# persist_data moves it into the store and links it back. an empty *directory* in
# the store is what persist_data left behind for a path with no source, so drop it
# and seed again; a zero-byte *file* is real data and must be kept
function Initialize-PersistedFile() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Path,
        [string[]]
        $PersistPath,
        [string[]]
        $Content
    )
    if (!$PersistPath) { $PersistPath = $Path }
    if ($PersistPath.Length -ne $Path.Length) {
        throw "-Path and -PersistPath must have the same length."
    }

    for ($i = 0; $i -lt $Path.Length; $i++) {
        $source = Join-Path $dir $Path[$i]
        $target = Join-Path $persist_dir $PersistPath[$i]

        if ((Test-Path $target -PathType Container) -and (is_empty_data $target)) {
            Remove-Item $target -Force -Recurse -ErrorAction Stop
        } elseif (Test-Path $target) {
            continue
        }

        ensure (Split-Path -Path $source -Parent) | Out-Null
        if ($Content) {
            Out-UTF8File -FilePath $source -InputObject $Content
        } else {
            New-Item -Path $source -ItemType File -Force | Out-Null
        }
    }
}

# drop what an installer leaves in $dir: the NSIS plugin directory, plus any
# explicit leftovers. pass globs as single-quoted strings, e.g. -Include '$R0'.
# the patterns are matched against entry names, not handed to Get-ChildItem
# -Include, which only filters leaves on 5.1
function Remove-InstallerResidue() {
    [CmdletBinding()]
    param (
        [string]
        $Path,
        [string[]]
        $Include
    )
    if (!$Path) { $Path = $dir }

    # the plugin directory name starts with a dollar sign: keep it a literal
    $targets = @(Join-Path $Path '$PLUGINSDIR')
    $patterns = @($Include | Where-Object { $_ })
    if ($patterns) {
        $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        foreach ($entry in $entries) {
            foreach ($pattern in $patterns) {
                if ($entry.Name -like $pattern) {
                    $targets += $entry.FullName
                    break
                }
            }
        }
    }

    foreach ($target in $targets) {
        if (!(Test-Path -LiteralPath $target)) { continue }
        # a pattern must not reach outside $dir
        if (!(is_in_dir $Path $target)) {
            warn "Refusing to remove '$target': it is outside '$Path'."
            continue
        }
        try {
            # junctions left by NSIS carry the read-only attribute
            $item = Get-Item -LiteralPath $target -Force
            if ($item.LinkType) { attrib -R /L $target }
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
        } catch {
            warn "Could not remove installer residue '$target': $_"
        }
    }
}

# export app-owned registry keys into the persist store and, with -Delete, remove
# them so the app starts from the restored copy on the next install. the store is
# the only place a backup survives: a version dir is deleted by 'scoop cleanup'
function Save-AppRegistry() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Map,
        [string]
        $To,
        [switch]
        $Delete
    )
    if (!$To) { $To = $persist_dir }
    ensure $To | Out-Null

    foreach ($file in $Map.Keys) {
        $key = $Map[$file]
        if (!(Test-Path ($key -replace '^(HKCU|HKLM)\\', '$1:'))) {
            continue
        }
        $target = Join-Path $To $file
        if (!(Invoke-ExternalCommand reg @('export', $key, $target, '/y') -Quiet)) {
            warn "Could not export registry key '$key' to '$target'."
            continue
        }
        if ($Delete) {
            Invoke-ExternalCommand reg @('delete', $key, '/f') -Quiet | Out-Null
        }
    }
}

# import the backups Save-AppRegistry wrote. every value in the file wins over
# what the installer just wrote, so force any install-time setting afterwards
function Restore-AppRegistry() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]
        $Map,
        [string]
        $From
    )
    if (!$From) { $From = $persist_dir }

    foreach ($file in $Map.Keys) {
        $source = Join-Path $From $file
        if (!(Test-Path $source)) {
            continue
        }
        if (!(Invoke-ExternalCommand reg @('import', $source) -Quiet)) {
            warn "Could not import registry backup '$source'."
        }
    }
}

# pick the Squirrel.Windows payload that matches an architecture: the app itself
# always sits in app-<arch>.7z. a package that renames the file keeps only one
# app*.7z, so a single wildcard hit is accepted; several hits are ambiguous
function Get-SquirrelPayload($Path, $ProcessorArchitecture) {
    $name = switch ($ProcessorArchitecture) {
        'arm64' { 'app-arm64.7z' }
        '32bit' { 'app-32.7z' }
        default { 'app-64.7z' }
    }

    $plugins = Join-Path $Path '$PLUGINSDIR'
    $exact = Join-Path $plugins $name
    if (Test-Path -LiteralPath $exact -PathType Leaf) {
        return Get-Item -LiteralPath $exact
    }

    $candidates = @(Get-ChildItem -LiteralPath $plugins -Filter 'app*.7z' -File -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 1) { return $candidates[0] }
}

# expand the payload Get-SquirrelPayload picks into $dir. only expand: the leftover
# under $PLUGINSDIR is Remove-InstallerResidue's job
function Expand-SquirrelApp() {
    [CmdletBinding()]
    param (
        [string]
        $Path,
        [Alias('Architecture')]
        [string]
        $ProcessorArchitecture
    )
    if (!$Path) { $Path = $dir }
    if (!$ProcessorArchitecture) { $ProcessorArchitecture = $architecture }

    $payload = Get-SquirrelPayload $Path $ProcessorArchitecture
    if (!$payload) {
        abort "Cannot find the $ProcessorArchitecture payload in '$(Join-Path $Path '$PLUGINSDIR')'."
    }
    Expand-7zipArchive $payload.FullName -DestinationPath $Path
}

# set value to file
# behavior of set bool is different between json and otherfile
# json set value with $true or $false
# other file set value with string 'true' or 'false'
function Set-Value() {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$File,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ValuePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [object]$Value,

        [ValidateNotNullOrEmpty()]
        [string]$Type = [System.IO.Path]::GetExtension($File).TrimStart('.').ToLower()
    )
    if (![System.IO.Path]::IsPathRooted($File)) {
        $File = "$persist_dir\$File"
    }
    [System.IO.Directory]::CreateDirectory($(Split-Path $File)) | Out-Null
    switch ($Type) {
        'json' {
            $data = @{}
            if (Test-Path $File) {
                # Get-Content decodes as ANSI on 5.1, which mangles UTF-8 without a BOM
                $parsed = ConvertFrom-Json ([System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8))
                # ConvertFrom-Json returns $null for an empty file
                if ($null -ne $parsed) {
                    $data = ConvertTo-Hashtable $parsed
                    # a top-level array cannot hold named keys: start over instead of
                    # serializing the array's own properties into the file
                    if ($data -isnot [System.Collections.IDictionary]) { $data = @{} }
                }
            }
            $cur = $data
            $len = $ValuePath.Length
            for ($i = 0; $i -lt $len; $i++) {
                $prop = $ValuePath[$i]
                if ($i -lt ($len - 1)) {
                    # a scalar on the path (e.g. "a": 1, then a.b) cannot hold keys
                    if ($cur[$prop] -isnot [System.Collections.IDictionary]) {
                        $cur[$prop] = @{}
                    }
                } else {
                    $cur[$prop] = $Value
                    break
                }
                $cur = $cur[$prop]
            }
            $data | ConvertTo-Json -Depth 100 | Out-UTF8File -FilePath $File
        }
        'ini' {
            if ($ValuePath.Length -ne 2) {
                throw 'INI type only support 2 path element'
            }
            $section = $ValuePath[0]
            $prop = $ValuePath[1]
            if (Test-Path $File) {
                $data = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8)
                if ($data -match "(?m)^\[$section\]") {
                    $regex = "(?m)(?<=^\[$section\][^\[]*?$prop\s*=\s*)[^\r\n]*"
                    if ($data -match $regex) {
                        $data = $data -replace $regex, $Value
                    } else {
                        $data = $data -replace "(?m)(\[$section\])", "`$1`r`n$prop=$Value"
                    }
                } else {
                    $data += "`r`n[$section]`r`n$prop=$Value"
                }
            } else {
                $data = "[$section]`r`n$prop=$Value"
            }
            $data | Out-UTF8File -FilePath $File
        }
        Default {
            throw 'unknown type to process'
        }
    }

}
