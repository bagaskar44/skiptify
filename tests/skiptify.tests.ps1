$scriptPath = Join-Path -Path $PSScriptRoot -ChildPath "..\skiptify\skiptify.ps1"
. $scriptPath

function New-FakeSpotifyWindow {
    param(
        [int]$Id,
        [IntPtr]$Handle,
        [string]$Title = "Spotify Free",
        [bool]$Responding = $true
    )

    [PSCustomObject]@{
        Id = $Id
        MainWindowHandle = $Handle
        MainWindowTitle = $Title
        Responding = $Responding
    }
}

function Set-SpotifySnapshots {
    param([array]$Snapshots)

    $script:snapshots = New-Object System.Collections.Queue
    foreach ($snapshot in $Snapshots) {
        $script:snapshots.Enqueue($snapshot)
    }
}

Describe "Spotify title classification" {
    It "recognizes a track only when the dash has spaces on both sides" {
        (Test-SpotifyTrackTitle -Title "505 - Arctic Monkeys") | Should Be $true
        (Test-SpotifyTrackTitle -Title "ad-x") | Should Be $false
        (Test-SpotifyTrackTitle -Title "ad- x") | Should Be $false
        (Test-SpotifyTrackTitle -Title "ad -x") | Should Be $false
    }

    It "does not recognize blank and generic titles as tracks" {
        (Test-SpotifyTrackTitle -Title "") | Should Be $false
        (Test-SpotifyTrackTitle -Title $null) | Should Be $false
        (Test-SpotifyTrackTitle -Title "Spotify") | Should Be $false
    }
}

Describe "Skiptify recovery" {
    BeforeEach {
        $script:commands = @()
        Set-SpotifySnapshots @()

        Mock Write-SkiptifyLog {}
        Mock Start-Sleep {}
        Mock Get-SpotifyProcesses { @() }
        Mock Test-SpotifyApplicationErrorWindow { $false }
        Mock Get-SpotifyMainWindow { $null }
        Mock Minimize-SpotifyWindow {}
        Mock Start-SpotifyUri { $true }
        Mock Stop-SpotifyProcesses {}
        Mock Send-SpotifyAppCommand {
            param($Command, $WindowHandle)
            $script:commands += $Command
        }
        Mock Get-SpotifyWindowSnapshot {
            if ($script:snapshots.Count -eq 0) {
                return $null
            }

            return $script:snapshots.Dequeue()
        }
    }

    It "waits for five stable Spotify Free checks after missing and blank snapshots" {
        $free = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11)
        $blank = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11) -Title ""
        Set-SpotifySnapshots @($null, $blank, $free, $free, $free, $free, $free)

        $result = Wait-ForSpotifyFreeReady -TimeoutMs 5000 -RequiredStableChecks 5

        $result.Status | Should Be "Started"
        $result.Process.Id | Should Be 101
    }

    It "resets the stable count when the window identity or title changes" {
        $first = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11)
        $nonFree = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11) -Title "Spotify"
        $second = New-FakeSpotifyWindow -Id 202 -Handle ([IntPtr]22)
        Set-SpotifySnapshots @($first, $first, $nonFree, $second, $second, $second, $second, $second)

        $result = Wait-ForSpotifyFreeReady -TimeoutMs 5000 -RequiredStableChecks 5

        $result.Status | Should Be "Started"
        $result.Process.Id | Should Be 202
    }

    It "times out without issuing playback commands" {
        $result = Wait-ForSpotifyFreeReady -TimeoutMs 0 -RequiredStableChecks 5

        $result.Status | Should Be "TimedOut"
        Assert-MockCalled -Scope It Send-SpotifyAppCommand -Times 0 -Exactly
    }

    It "stops startup when the Spotify Application Error dialog is visible" {
        Mock Test-SpotifyApplicationErrorWindow { $true }

        $result = Wait-ForSpotifyMainWindow -TimeoutMs 5000

        $result.Status | Should Be "Failed"
        $result.Reason | Should Be "Spotify menampilkan dialog error aplikasi."
    }

    It "stops recovery when the Spotify Application Error dialog is visible" {
        Mock Test-SpotifyApplicationErrorWindow { $true }

        $result = Wait-ForSpotifyFreeReady -TimeoutMs 5000

        $result.Status | Should Be "Failed"
        $result.Reason | Should Be "Spotify menampilkan dialog error aplikasi."
    }

    It "minimizes the first window while its title is still blank" {
        $blank = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11) -Title ""
        $free = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11)
        Set-SpotifySnapshots @($blank, $free)

        $result = Wait-ForSpotifyFreeReady -TimeoutMs 5000 -RequiredStableChecks 1

        $result.Status | Should Be "Started"
        Assert-MockCalled -Scope It Minimize-SpotifyWindow -Times 2 -Exactly -ParameterFilter { $WindowHandle -eq [IntPtr]11 }
    }

    It "waits again when Spotify changes during the post-ready delay, then sends Next and Play once" {
        $first = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11)
        $second = New-FakeSpotifyWindow -Id 202 -Handle ([IntPtr]22)
        $secondSong = New-FakeSpotifyWindow -Id 202 -Handle ([IntPtr]22) -Title "Song - Artist"
        Set-SpotifySnapshots @(
            $first, $first, $first, $first, $first,
            $second, $second,
            $second, $second, $second, $second, $second,
            $second, $secondSong
        )

        $result = Restart-SpotifySmooth

        $result.Status | Should Be "CommandsSent"
        $script:commands | Should Be @("Next", "Play")
    }

    It "does not retry Next when Spotify disappears before Play" {
        $free = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11)
        Set-SpotifySnapshots @($free, $free, $free, $free, $free, $free, $null)

        $result = Restart-SpotifySmooth

        $result.Status | Should Be "Failed"
        $script:commands | Should Be @("Next")
    }

    It "fails recovery when the Spotify URI cannot be opened" {
        Mock Start-SpotifyUri { $false }

        $result = Restart-SpotifySmooth

        $result.Status | Should Be "Failed"
        @($script:commands).Count | Should Be 0
    }
    It "bounds recovery even when each ready window changes before confirmation" {
        $savedTimeout = $RecoveryTimeoutMs
        $savedDelay = $PostReadyDelayMs
        try {
            $RecoveryTimeoutMs = 30
            $PostReadyDelayMs = 0
            $free = New-FakeSpotifyWindow -Id 101 -Handle ([IntPtr]11)
            Mock Wait-ForSpotifyFreeReady {
                New-SkiptifyResult -Status "Started" -Process $free
            }
            Mock Get-SpotifyWindowByIdentity { $null }

            $result = Restart-SpotifySmooth

            $result.Status | Should Be "TimedOut"
            Assert-MockCalled -Scope It Send-SpotifyAppCommand -Times 0 -Exactly
        }
        finally {
            $RecoveryTimeoutMs = $savedTimeout
            $PostReadyDelayMs = $savedDelay
        }
    }


}

Describe "Startup readiness" {
    BeforeEach {
        Mock Write-SkiptifyLog {}
        Mock Write-SkiptifyStatus {}
        Mock Test-SkiptifyStopRequested { $false }
        Mock Get-SpotifyProcesses { @([pscustomobject]@{ Id = 99 }) }
        Mock Get-SpotifyMainWindow { $null }
        Mock Start-SpotifySmooth { New-SkiptifyResult -Status "Failed" -Reason "No window" }
    }

    It "opens Spotify when only background processes exist and does not report active on failure" {
        Invoke-Skiptify | Should Be 1
        Assert-MockCalled -Scope It Start-SpotifySmooth -Times 1 -Exactly
        Assert-MockCalled -Scope It Write-SkiptifyStatus -Times 0 -Exactly -ParameterFilter { $Status -eq 'Aktif' }
    }

    It "keeps an existing responsive window without relaunching" {
        Mock Get-SpotifyMainWindow { New-FakeSpotifyWindow -Id 99 -Handle ([IntPtr]9) }
        $script:stopChecks = 0
        Mock Test-SkiptifyStopRequested { $script:stopChecks++; return $script:stopChecks -gt 1 }
        Invoke-Skiptify | Should Be 0
        Assert-MockCalled -Scope It Start-SpotifySmooth -Times 0 -Exactly
    }
}

Describe "Spotify background launch" {
    BeforeEach {
        $script:SpotifyExecutablePath = 'C:\Spotify\Spotify.exe'
        Mock Write-SkiptifyLog {}
        Mock Test-Path { $true }
        Mock Start-Process {}
    }

    It "launches the cached executable minimized with a discoverable window" {
        Start-SpotifyUri | Should Be $true
        Assert-MockCalled -Scope It Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Spotify\Spotify.exe' -and $WindowStyle -eq 'Minimized'
        }
        Assert-MockCalled -Scope It Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'spotify:' }
    }

    It "falls back to the URI when direct launch fails" {
        Mock Start-Process { throw 'Executable unavailable' } -ParameterFilter { $FilePath -ne 'spotify:' }
        Start-SpotifyUri | Should Be $true
        Assert-MockCalled -Scope It Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'spotify:' }
    }

    It "asks Spotify itself to stay minimized during background recovery" {
        Start-SpotifyUri -Background | Should Be $true
        Assert-MockCalled -Scope It Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Spotify\Spotify.exe' -and $WindowStyle -eq 'Minimized' -and $ArgumentList -eq '--minimized'
        }
    }

    It "does not apply background arguments to visible startup" {
        $script:visibleLaunchArguments = 'unset'
        Mock Start-Process {
            param($ArgumentList)
            $script:visibleLaunchArguments = $ArgumentList
        }
        Start-SpotifyUri -Visible -Background | Should Be $true
        Assert-MockCalled -Scope It Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Spotify\Spotify.exe' -and $WindowStyle -eq 'Normal'
        }
        $script:visibleLaunchArguments | Should BeNullOrEmpty
    }

    It "can launch Spotify visibly for the Desktop first-start path" {
        Start-SpotifyUri -Visible | Should Be $true
        Assert-MockCalled -Scope It Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\Spotify\Spotify.exe' -and $WindowStyle -eq 'Normal'
        }
    }
}

Describe "Skiptify worker controls" {
    It "observes a named stop event without polling Spotify" {
        $name = "Local\Skiptify.Test.Stop.$PID"
        $event = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $name)
        try {
            $script:StopEvent = $event
            $script:StatusOutputEnabled = $false
            (Test-SkiptifyStopRequested) | Should Be $false
            $event.Set() | Should Be $true
            (Test-SkiptifyStopRequested) | Should Be $true
        }
        finally {
            $script:StopEvent = $null
            $event.Dispose()
        }
    }

    It "acquires and releases the engine mutex for one worker" {
        # Do not compete with the user's running Skiptify instance.
        Mock New-Object {
            [Threading.Mutex]::new($false, "Local\Skiptify.Test.Engine.$PID")
        } -ParameterFilter { $TypeName -eq 'System.Threading.Mutex' }
        try {
            Initialize-SkiptifyControl | Should Be $true
            $script:EngineMutex | Should Not Be $null
        }
        finally {
            Dispose-SkiptifyControl
        }
        $script:EngineMutex | Should Be $null
    }
}

Describe "Skiptify visual recovery handshake" {
    BeforeEach {
        Mock Write-SkiptifyLog {}
        Mock Start-Sleep {}
        $script:StatusOutputEnabled = $false
        $script:StopEvent = $null
    }

    It "accepts a Stopped recovery result" {
        (New-SkiptifyResult -Status "Stopped" -Reason "cancelled").Status | Should Be "Stopped"
    }

    It "does not request an overlay for the VBS launcher" {
        $fake = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]7; HasExited = $false }
        (Request-SkiptifyOverlay -Process $fake) | Should Be $null
    }

    It "bounds an overlay preparation handshake to 500 ms" {
        $script:StatusOutputEnabled = $true
        $fake = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]7; HasExited = $false }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Request-SkiptifyOverlay -Process $fake
        $watch.Stop()

        $result.Ready | Should Be $false
        $result.Cancelled | Should Be $false
        $watch.ElapsedMilliseconds | Should BeLessThan 1000
        $result.EventName | Should Match "^Local\\Skiptify\.Overlay\.Ready\."
    }
}

Describe "Desktop visible startup" {
    BeforeEach {
        $script:VisibleStartupRequested = $true
        $script:StatusOutputEnabled = $false
        $script:StopEvent = $null
        Mock Write-SkiptifyLog {}
        Mock Restore-SpotifyHiddenWindow { $false }
        Mock Start-SpotifyUri { $true }
        Mock Wait-ForSpotifyMainWindow {
            New-SkiptifyResult -Status "Started" -Process ([pscustomobject]@{ Id = 9; MainWindowHandle = [IntPtr]9 })
        }
        Mock Minimize-SpotifyWindow {}
    }

    AfterEach {
        $script:VisibleStartupRequested = $false
    }

    It "does not minimize the Spotify window during visible Desktop startup" {
        $result = Start-SpotifySmooth

        $result.Status | Should Be "Started"
        Assert-MockCalled -Scope It Start-SpotifyUri -Times 1 -Exactly -ParameterFilter { $Visible -eq $true }
        Assert-MockCalled -Scope It Wait-ForSpotifyMainWindow -Times 1 -Exactly -ParameterFilter { $MinimizeDuringWait -eq $false }
        Assert-MockCalled -Scope It Minimize-SpotifyWindow -Times 0 -Exactly
    }

    It "ignores Spotify's generic startup title" {
        ($IgnoredTitles -contains "Spotify") | Should Be $true
    }

    It "restores a hidden window without launching a second Spotify process" {
        Mock Restore-SpotifyHiddenWindow { $true }
        $result = Start-SpotifySmooth
        $result.Status | Should Be "Started"
        Assert-MockCalled -Scope It Start-SpotifyUri -Times 0 -Exactly
        Assert-MockCalled -Scope It Wait-ForSpotifyMainWindow -Times 1 -Exactly
    }
}

