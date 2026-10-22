BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\system.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\install.ps1"
    . "$PSScriptRoot\..\lib\decompress.ps1"
}

Describe 'appname_from_url' -Tag 'Scoop' {
    It 'should extract the correct name' {
        appname_from_url 'https://example.org/directory/foobar.json' | Should -Be 'foobar'
    }
}

Describe 'env add and remove path' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        # test data
        $manifest = @{
            'env_add_path' = @('foo', 'bar', '.', '..')
        }
        $testdir = Join-Path $PSScriptRoot 'path-test-directory'
        $global = $false
    }

    It 'should concat the correct path' {
        Mock Add-Path {}
        Mock Remove-Path {}

        # adding
        env_add_path $manifest $testdir $global
        Should -Invoke -CommandName Add-Path -Times 1 -ParameterFilter { $Path -like "$testdir\foo" }
        Should -Invoke -CommandName Add-Path -Times 1 -ParameterFilter { $Path -like "$testdir\bar" }
        Should -Invoke -CommandName Add-Path -Times 1 -ParameterFilter { $Path -like $testdir }
        Should -Invoke -CommandName Add-Path -Times 0 -ParameterFilter { $Path -like $PSScriptRoot }

        env_rm_path $manifest $testdir $global
        Should -Invoke -CommandName Remove-Path -Times 1 -ParameterFilter { $Path -like "$testdir\foo" }
        Should -Invoke -CommandName Remove-Path -Times 1 -ParameterFilter { $Path -like "$testdir\bar" }
        Should -Invoke -CommandName Remove-Path -Times 1 -ParameterFilter { $Path -like $testdir }
        Should -Invoke -CommandName Remove-Path -Times 0 -ParameterFilter { $Path -like $PSScriptRoot }
    }
}

Describe 'shim_def' -Tag 'Scoop' {
    It 'should use strings correctly' {
        $target, $name, $shimArgs = shim_def 'command.exe'
        $target | Should -Be 'command.exe'
        $name | Should -Be 'command'
        $shimArgs | Should -BeNullOrEmpty
    }

    It 'should expand the array correctly' {
        $target, $name, $shimArgs = shim_def @('foo.exe', 'bar')
        $target | Should -Be 'foo.exe'
        $name | Should -Be 'bar'
        $shimArgs | Should -BeNullOrEmpty

        $target, $name, $shimArgs = shim_def @('foo.exe', 'bar', '--test')
        $target | Should -Be 'foo.exe'
        $name | Should -Be 'bar'
        $shimArgs | Should -Be '--test'
    }
}

Describe 'persist_def' -Tag 'Scoop' {
    It 'parses string correctly' {
        $source, $target = persist_def 'test'
        $source | Should -Be 'test'
        $target | Should -Be 'test'
    }

    It 'should handle sub-folder' {
        $source, $target = persist_def 'foo/bar'
        $source | Should -Be 'foo/bar'
        $target | Should -Be 'foo/bar'
    }

    It 'should handle arrays' {
        # both specified
        $source, $target = persist_def @('foo', 'bar')
        $source | Should -Be 'foo'
        $target | Should -Be 'bar'

        # only first specified
        $source, $target = persist_def @('foo')
        $source | Should -Be 'foo'
        $target | Should -Be 'foo'

        # null value specified
        $source, $target = persist_def @('foo', $null)
        $source | Should -Be 'foo'
        $target | Should -Be 'foo'
    }
}

Describe 'is_empty_data' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'empty-data-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'treats a missing path as empty' {
        is_empty_data (Join-Path $testdir 'does-not-exist') | Should -BeTrue
    }

    It 'treats an empty directory as empty' {
        $empty = Join-Path $testdir 'empty'
        New-Item $empty -ItemType Directory -Force | Out-Null
        is_empty_data $empty | Should -BeTrue
    }

    It 'treats a directory with a hidden file as data' {
        $hidden = Join-Path $testdir 'hidden'
        New-Item $hidden -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $hidden '.gitignore') -ItemType File -Force | Out-Null
        is_empty_data $hidden | Should -BeFalse
    }

    It 'treats a directory with a file as data' {
        $full = Join-Path $testdir 'full'
        New-Item $full -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $full 'file.txt') -ItemType File | Out-Null
        is_empty_data $full | Should -BeFalse
    }

    It 'treats a zero-byte file as empty and a non-empty file as data' {
        $zero = Join-Path $testdir 'zero.txt'
        New-Item $zero -ItemType File -Force | Out-Null
        is_empty_data $zero | Should -BeTrue

        $real = Join-Path $testdir 'real.txt'
        Set-Content -Path $real -Value 'data'
        is_empty_data $real | Should -BeFalse
    }
}

Describe 'can_discard_source' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'discard-source-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null

        $empty = Join-Path $testdir 'empty'
        New-Item $empty -ItemType Directory -Force | Out-Null

        $full = Join-Path $testdir 'full'
        New-Item $full -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $full 'file.txt') -ItemType File | Out-Null

        $zeroFile = Join-Path $testdir 'zero.txt'
        New-Item $zeroFile -ItemType File -Force | Out-Null

        $linkTarget = Join-Path $testdir 'link-target'
        New-Item $linkTarget -ItemType Directory -Force | Out-Null
        $link = Join-Path $testdir 'link'
        New-Item -Path $link -ItemType Junction -Value $linkTarget | Out-Null
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'discards a stale link' {
        can_discard_source $link (Get-Item $link -Force) $true | Should -BeTrue
        can_discard_source $link (Get-Item $link -Force) $false | Should -BeTrue
    }

    It 'discards an empty directory whether or not the store has data' {
        can_discard_source $empty (Get-Item $empty -Force) $true | Should -BeTrue
        can_discard_source $empty (Get-Item $empty -Force) $false | Should -BeTrue
    }

    It 'keeps a directory that holds data' {
        can_discard_source $full (Get-Item $full -Force) $true | Should -BeFalse
        can_discard_source $full (Get-Item $full -Force) $false | Should -BeFalse
    }

    It 'keeps a zero-byte file when the store has no entry for it' {
        # dropping it would create a directory in the store and flip a file
        # persist into a junction
        can_discard_source $zeroFile (Get-Item $zeroFile -Force) $false | Should -BeFalse
    }

    It 'discards a zero-byte file when the store already has the entry' {
        can_discard_source $zeroFile (Get-Item $zeroFile -Force) $true | Should -BeTrue
    }
}

Describe 'is_pristine_source' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'pristine-source-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null

        # the version dir's time, taken right after 'extraction': a second after the
        # bundled files are created, before the app rewrites anything
        $archiveTime = (Get-Date).AddSeconds(1)

        # the archive's own copy: files carry their build time, no newer than the version dir
        $bundled = Join-Path $testdir 'themes'
        New-Item $bundled -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $bundled 'Bespin.xml') -ItemType File -Force | Out-Null
        # the directory itself can be newer than the version dir while its files are not
        (Get-Item $bundled).LastWriteTime = (Get-Date).AddSeconds(30)

        # a copy the app rewrote after extraction, so its files are newer
        $rewritten = Join-Path $testdir 'plugins'
        New-Item $rewritten -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $rewritten 'mine.dll') -ItemType File -Force | Out-Null
        (Get-Item (Join-Path $rewritten 'mine.dll')).LastWriteTime = (Get-Date).AddMinutes(1)

        # a persist file (e.g. config.xml) shipped by the archive
        $bundledFile = Join-Path $testdir 'nativeLang.xml'
        New-Item $bundledFile -ItemType File -Force | Out-Null
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'treats a directory holding only archive-time files as pristine' {
        is_pristine_source (Get-Item $bundled -Force) $archiveTime | Should -BeTrue
    }

    It 'keeps a directory the app wrote to after extraction' {
        is_pristine_source (Get-Item $rewritten -Force) $archiveTime | Should -BeFalse
    }

    It 'treats a file older than the extraction as pristine' {
        is_pristine_source (Get-Item $bundledFile -Force) $archiveTime | Should -BeTrue
    }
}

Describe 'ConvertTo-Hashtable' -Tag 'Scoop' {
    It 'converts a nested json object into hashtables' {
        $data = ConvertTo-Hashtable ('{"a":{"b":{"c":[1,{"d":2}]}}}' | ConvertFrom-Json)
        $data | Should -BeOfType [hashtable]
        $data['a']['b']['c'][1]['d'] | Should -Be 2
    }

    It 'keeps scalar values' {
        $data = ConvertTo-Hashtable ('{"n":1,"s":"x","b":true}' | ConvertFrom-Json)
        $data['n'] | Should -Be 1
        $data['s'] | Should -Be 'x'
        $data['b'] | Should -BeTrue
    }

    It 'keeps a nested array as an array' {
        # every value is -is [PSObject]; only PSCustomObject marks a json object
        $data = ConvertTo-Hashtable ('{"a":[1,{"b":2}]}' | ConvertFrom-Json)
        ,$data['a'] | Should -BeOfType [System.Array]
        $data['a'][1]['b'] | Should -Be 2
    }
}

Describe 'Initialize-PersistedFile' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'seed-persisted-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null
    }

    BeforeEach {
        $dir = Join-Path $testdir 'dir'
        $persist_dir = Join-Path $testdir 'persist'
        New-Item $dir, $persist_dir -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item (Join-Path $testdir 'dir'), (Join-Path $testdir 'persist') -Recurse -Force -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes the seed when the store holds nothing' {
        Initialize-PersistedFile -Path 'settings.ini' -Content '[Settings]', 'check = 0'
        Get-Content (Join-Path $dir 'settings.ini') | Should -Be @('[Settings]', 'check = 0')
    }

    It 'creates an empty file when no content is given' {
        Initialize-PersistedFile -Path 'config.ini'
        (Get-Item (Join-Path $dir 'config.ini')).Length | Should -Be 0
    }

    It 'creates missing parent directories' {
        Initialize-PersistedFile -Path 'Resource\config.json' -Content '{}'
        Test-Path (Join-Path $dir 'Resource\config.json') -PathType Leaf | Should -BeTrue
    }

    It 'never overwrites stored data' {
        Set-Content (Join-Path $persist_dir 'settings.ini') 'user data'
        Initialize-PersistedFile -Path 'settings.ini' -Content 'seed'
        Get-Content (Join-Path $persist_dir 'settings.ini') | Should -Be 'user data'
        Test-Path (Join-Path $dir 'settings.ini') | Should -BeFalse
    }

    It 'treats a zero-byte file in the store as data' {
        New-Item (Join-Path $persist_dir 'empty.cfg') -ItemType File -Force | Out-Null
        Initialize-PersistedFile -Path 'empty.cfg'
        Test-Path (Join-Path $dir 'empty.cfg') | Should -BeFalse
    }

    It 'replaces an empty directory in the store' {
        New-Item (Join-Path $persist_dir 'empty.cfg') -ItemType Directory -Force | Out-Null
        Initialize-PersistedFile -Path 'empty.cfg'
        Test-Path (Join-Path $dir 'empty.cfg') -PathType Leaf | Should -BeTrue
        Test-Path (Join-Path $persist_dir 'empty.cfg') | Should -BeFalse
    }

    It 'seeds several paths and maps PersistPath separately' {
        Set-Content (Join-Path $persist_dir 'config.json') '{"user":true}'
        Initialize-PersistedFile -Path 'a.cfg', 'Resource\config.json' -PersistPath 'a.cfg', 'config.json'
        Test-Path (Join-Path $dir 'a.cfg') -PathType Leaf | Should -BeTrue
        Test-Path (Join-Path $dir 'Resource\config.json') | Should -BeFalse
        Get-Content (Join-Path $persist_dir 'config.json') | Should -Be '{"user":true}'
    }

    It 'refuses mismatched Path and PersistPath lengths' {
        { Initialize-PersistedFile -Path 'a', 'b' -PersistPath 'c' } | Should -Throw
    }
}

Describe 'Remove-InstallerResidue' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'installer-residue-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null
    }

    BeforeEach {
        $dir = Join-Path $testdir 'dir'
        New-Item $dir -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $dir 'app.exe') 'binary'
        New-Item (Join-Path $dir '$PLUGINSDIR') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $dir '$PLUGINSDIR\app-64.7z') 'x'
        Set-Content (Join-Path $dir '$R0') 'x'
        Set-Content (Join-Path $dir 'Uninstall App.exe') 'x'
        New-Item (Join-Path $dir 'resources') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $dir 'resources\data.bin') 'x'
    }

    AfterEach {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'removes the plugin directory and keeps the payload' {
        Remove-InstallerResidue
        Test-Path (Join-Path $dir '$PLUGINSDIR') | Should -BeFalse
        Test-Path (Join-Path $dir 'app.exe') | Should -BeTrue
        Test-Path (Join-Path $dir 'resources\data.bin') | Should -BeTrue
    }

    It 'removes extra patterns matched against entry names' {
        Remove-InstallerResidue -Include '$R0', 'Uninstall*'
        Get-ChildItem $dir -Force -Name | Sort-Object | Should -Be @('app.exe', 'resources')
    }

    It 'accepts the $* pattern without touching ordinary files' {
        Remove-InstallerResidue -Include '$*'
        Get-ChildItem $dir -Force -Name | Sort-Object | Should -Be @('app.exe', 'resources', 'Uninstall App.exe')
    }

    It 'does nothing when the residue is already gone' {
        Remove-Item (Join-Path $dir '$PLUGINSDIR') -Recurse -Force
        Remove-InstallerResidue -Include 'nothing*'
        Test-Path (Join-Path $dir 'app.exe') | Should -BeTrue
    }

    It 'never removes the directory itself when $PLUGINSDIR is absent' {
        Remove-Item (Join-Path $dir '$PLUGINSDIR') -Recurse -Force
        Remove-InstallerResidue
        Test-Path $dir | Should -BeTrue
        Test-Path (Join-Path $dir 'app.exe') | Should -BeTrue
    }
}

Describe 'Save-AppRegistry and Restore-AppRegistry' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'app-registry-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null
        # a unique key so a failed cleanup cannot touch anything else
        $key = "HKCU\Software\ScoopTest_$PID"
        $regPath = "HKCU:\Software\ScoopTest_$PID"
    }

    BeforeEach {
        $persist_dir = Join-Path $testdir 'persist'
        New-Item $persist_dir -ItemType Directory -Force | Out-Null
        Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
        New-Item $regPath -Force | Out-Null
        Set-ItemProperty $regPath -Name 'Setting' -Value 'user-value'
    }

    AfterEach {
        Remove-Item $regPath -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $persist_dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'exports a key into the store' {
        Save-AppRegistry -Map @{ 'app.reg' = $key }
        Test-Path (Join-Path $persist_dir 'app.reg') | Should -BeTrue
        Test-Path $regPath | Should -BeTrue
    }

    It 'restores the exported values' {
        Save-AppRegistry -Map @{ 'app.reg' = $key }
        Set-ItemProperty $regPath -Name 'Setting' -Value 'changed'
        Restore-AppRegistry -Map @{ 'app.reg' = $key }
        (Get-ItemProperty $regPath).Setting | Should -Be 'user-value'
    }

    It 'deletes the key after a successful export' {
        Save-AppRegistry -Map @{ 'app.reg' = $key } -Delete
        Test-Path (Join-Path $persist_dir 'app.reg') | Should -BeTrue
        Test-Path $regPath | Should -BeFalse
    }

    It 'skips a missing key without writing a backup' {
        Save-AppRegistry -Map @{ 'absent.reg' = 'HKCU\Software\ScoopTest_NoSuchKey' }
        Test-Path (Join-Path $persist_dir 'absent.reg') | Should -BeFalse
    }

    It 'skips a missing backup on restore' {
        { Restore-AppRegistry -Map @{ 'absent.reg' = $key } } | Should -Not -Throw
        (Get-ItemProperty $regPath).Setting | Should -Be 'user-value'
    }
}

Describe 'Get-SquirrelPayload and Expand-SquirrelApp' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'squirrel-app-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null
    }

    BeforeEach {
        $dir = Join-Path $testdir 'dir'
        New-Item (Join-Path $dir '$PLUGINSDIR') -ItemType Directory -Force | Out-Null
        $plugins = Join-Path $dir '$PLUGINSDIR'
        foreach ($name in 'app-64.7z', 'app-32.7z', 'app-arm64.7z') {
            Set-Content (Join-Path $plugins $name) 'x'
        }
    }

    AfterEach {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'picks the payload that matches the architecture' {
        (Get-SquirrelPayload $dir '64bit').Name | Should -Be 'app-64.7z'
        (Get-SquirrelPayload $dir '32bit').Name | Should -Be 'app-32.7z'
        (Get-SquirrelPayload $dir 'arm64').Name | Should -Be 'app-arm64.7z'
    }

    It 'falls back to a single non-standard archive name' {
        Remove-Item (Join-Path $dir '$PLUGINSDIR\app-*.7z')
        Set-Content (Join-Path $dir '$PLUGINSDIR\app-1.2.3.7z') 'x'
        (Get-SquirrelPayload $dir '64bit').Name | Should -Be 'app-1.2.3.7z'
    }

    It 'returns nothing when several fallback candidates share the name' {
        Remove-Item (Join-Path $dir '$PLUGINSDIR\app-*.7z')
        Set-Content (Join-Path $dir '$PLUGINSDIR\app-a.7z') 'x'
        Set-Content (Join-Path $dir '$PLUGINSDIR\app-b.7z') 'x'
        Get-SquirrelPayload $dir '64bit' | Should -BeNullOrEmpty
    }

    It 'expands the picked payload into the install directory' {
        Mock Expand-7zipArchive {}
        $architecture = 'arm64'
        Expand-SquirrelApp
        Should -Invoke Expand-7zipArchive -Times 1 -ParameterFilter { $Path -like '*app-arm64.7z' -and $DestinationPath -eq $dir }
    }
}

Describe 'Set-Value' -Tag 'Scoop', 'Windows' {
    BeforeAll {
        $testdir = Join-Path $PSScriptRoot 'set-value-test-directory'
        New-Item $testdir -ItemType Directory -Force | Out-Null
    }

    BeforeEach {
        $persist_dir = Join-Path $testdir 'persist'
        New-Item $persist_dir -ItemType Directory -Force | Out-Null
    }

    AfterEach {
        Remove-Item $persist_dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    AfterAll {
        Remove-Item $testdir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes a value a few levels down without truncating it' {
        Set-Value 'config.json' 'a', 'b', 'c', 'd' 42
        $json = [System.IO.File]::ReadAllText((Join-Path $persist_dir 'config.json'), [System.Text.Encoding]::UTF8)
        $json | Should -Not -Match 'System\.(Collections|Management)'
        ($json | ConvertFrom-Json).a.b.c.d | Should -Be 42
    }

    It 'keeps non-ASCII values intact' {
        $value = [string][char]0x4E2D + [string][char]0x6587
        Set-Value 'config.json' 'name' $value
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $persist_dir 'config.json'))
        ($bytes[0] -eq 0xEF) | Should -BeFalse
        ([System.IO.File]::ReadAllText((Join-Path $persist_dir 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json).name | Should -Be $value
    }

    It 'turns an empty file into an object' {
        New-Item (Join-Path $persist_dir 'config.json') -ItemType File -Force | Out-Null
        Set-Value 'config.json' 'k' 'v'
        ([System.IO.File]::ReadAllText((Join-Path $persist_dir 'config.json')) | ConvertFrom-Json).k | Should -Be 'v'
    }

    It 'replaces a scalar that sits on the path' {
        Set-Content (Join-Path $persist_dir 'config.json') '{"a":1}'
        Set-Value 'config.json' 'a', 'b' 2
        ([System.IO.File]::ReadAllText((Join-Path $persist_dir 'config.json')) | ConvertFrom-Json).a.b | Should -Be 2
    }

    It 'starts over when the top-level value is an array' {
        Set-Content (Join-Path $persist_dir 'config.json') '[1,2,3]'
        Set-Value 'config.json' 'k' 'v'
        $json = [System.IO.File]::ReadAllText((Join-Path $persist_dir 'config.json')) | ConvertFrom-Json
        $json.k | Should -Be 'v'
        @($json.PSObject.Properties.Name) | Should -Be @('k')
    }

    It 'updates an existing ini key and appends a missing one' {
        Set-Content (Join-Path $persist_dir 'config.ini') "[Section]`r`nKey = 1"
        Set-Value 'config.ini' 'Section', 'Key' 2
        Set-Value 'config.ini' 'Section', 'Extra' 3
        $content = Get-Content (Join-Path $persist_dir 'config.ini') -Raw
        $content | Should -Match 'Key\s*=\s*2'
        $content | Should -Match 'Extra=3'
    }
}
