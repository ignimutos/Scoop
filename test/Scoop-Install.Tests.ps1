BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\system.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\install.ps1"
}

Describe 'appname_from_url' -Tag 'Scoop' {
    It 'should extract the correct name' {
        appname_from_url 'https://example.org/directory/foobar.json' | Should -Be 'foobar'
    }
}

Describe 'url_filename' -Tag 'Scoop' {
    It 'should extract the real filename from an url' {
        url_filename 'http://example.org/foo.txt' | Should -Be 'foo.txt'
        url_filename 'http://example.org/foo.txt?var=123' | Should -Be 'foo.txt'
    }

    It 'can be tricked with a hash to override the real filename' {
        url_filename 'http://example.org/foo-v2.zip#/foo.zip' | Should -Be 'foo.zip'
    }
}

Describe 'url_remote_filename' -Tag 'Scoop' {
    It 'should extract the real filename from an url' {
        url_remote_filename 'http://example.org/foo.txt' | Should -Be 'foo.txt'
        url_remote_filename 'http://example.org/foo.txt?var=123' | Should -Be 'foo.txt'
    }

    It 'can not be tricked with a hash to override the real filename' {
        url_remote_filename 'http://example.org/foo-v2.zip#/foo.zip' | Should -Be 'foo-v2.zip'
    }
}

Describe 'is_in_dir' -Tag 'Scoop', 'Windows' {
    It 'should work correctly' {
        is_in_dir 'C:\test' 'C:\foo' | Should -BeFalse
        is_in_dir 'C:\test' 'C:\test\foo\baz.zip' | Should -BeTrue
        is_in_dir "$PSScriptRoot\..\" "$PSScriptRoot" | Should -BeFalse
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
