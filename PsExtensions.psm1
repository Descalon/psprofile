Import-Module -Name posh-git
Import-Module -Name posh-sshell

Function Get-GitignoreType {
    [CmdletBinding()]
    Param(
        [string]$Name
    )
    $response = Invoke-WebRequest -Uri "http://www.gitignore.io/api/list"
    $content = $response.Content -split ','
    if ($Name) {
        $content | Where-Object { $_ -like $Name }
    }
    else {
        $content
    }
}
Function New-GitignoreFile {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true, position)]
        [ValidateScript( {
                If ($_ -eq "list") {
                    Throw [System.Management.Automation.ValidationMetadataException] "For the list command use Get-GitignoreTypes"
                }
                else {
                    return $true
                }
            })]
        [string[]]$list,
        [Parameter(Mandatory = $false)]
        [switch]$Append
    )
    Begin {
        try {
            $params = ($list | ForEach-Object { [uri]::EscapeDataString($_) }) -join ","
            $response = Invoke-WebRequest -Uri "http://www.gitignore.io/api/$params"
        }
        catch {
            $applicableTypes = $list -join '|'
            $errors = `
            ($_.ErrorDetails.Message -split "`n") `
            | Select-String -Pattern "#!! ERROR: (?<typeName>$applicableTypes) is undefined" `
            | ForEach-Object { $_.Matches.Groups | Where-Object { $_.Name -eq "typeName" } | Select-Object -ExpandProperty value }

            ForEach ($e in $errors) {
                Write-Error -Message "Could not find $e on gitignore.io"
            }
            return
        }
    }
    Process {
        $text = $Append ? "Appending" : "Creating"
        if ((-not $Append) -and (Test-Path "./.gitignore")) {
            Write-Warning "This command will overwrite current .gitignore. If you wish to append, use -Append when calling this cmdlet."
        }
        if ($PSCmdlet.ShouldProcess("./.gitignore", "$text $params")) {
            $response `
            | Select-Object -ExpandProperty content `
            | Out-File  -FilePath ".\.gitignore" `
                -Encoding ascii `
                -Append:$Append
            Write-Verbose "Created .gitignore file with $($list -join ', ')"
        }
    }
}

Function Update-LocalSolution {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    Param (
        [ValidatePattern(".*\.sln")]
        [string]$SolutionFile
    )
    Begin {
        if (-not $SolutionFile) {
            $f = Get-ChildItem *.sln | Select-Object -First 1
            Write-Verbose "Found $f"
            if ($null -eq $f) {
                Write-Error "Could not find solution file (*.sln) in $pwd"
                return
            }
            $SolutionFile = $f
        }
        $projectFiles = Get-ChildItem -Path ("*.fsproj", "*.csproj") -Recurse
    }
    Process {
        if ($PSCmdlet.ShouldProcess("$SolutionFile", "Adding $($projectFiles.count) *.(cs|fs)proj file(s)")) {
            $projectFiles | ForEach-Object {
                & dotnet sln $f add $_
            }
        }
    }

}
Function Close-CurrentBranch {
    [CmdletBinding()]
    param()

    $currentBranch = (Get-VCSStatus).branch

    & "git" "checkout" "master" | Out-Null
    & "git" "merge" "$currentBranch" "--no-ff" | Out-Null
    & "git" "branch" -d "$currentBranch" | Out-Null
}
Function Resolve-RelativeTo {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory)]
        [String] $Root,
        [Parameter(Mandatory)]
        [String] $Target
    )
    Push-Location
    Set-Location -Path $Root
    $leaf = Resolve-Path -Path $Target -Relative
    $leaf = $leaf -replace '\.\\'
    $base = Split-Path -Path $Root -Leaf
    Join-Path -Path $base -ChildPath $leaf
    Pop-Location
}

Function Get-ExpandedProperty {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Object] $InputObject,
        [Parameter(Mandatory)]
        [String] $Property
    )
    Process {
        $InputObject | Select-Object -ExpandProperty $Property
    }
}

Function Copy-CurrentPath {
    $path = Get-Location | Get-ExpandedProperty -Property 'Path'
    $path | clip
}

Function New-DotnetProject {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'low')]
    Param(
        [Parameter(Mandatory)]
        [ValidateSet("console", "classlib", "wpf", "winforms", "worker", "mgdesktopgl", "mstest", "nunit", "nunit-test", "xunit", "razorcomponent", "page", "viewimports", "viewstart", "blazorserverside", "blazorhosted", "blazorlib", "blazor", "web", "mvc", "webapp", "angular", "react", "reactredux", "razorclasslib", "webapi", "grpc", "globaljson", "nugetconfig", "tool-manifest", "webconfig", "sln")]
        [string]$ProjectType,
        [Parameter(Mandatory)]
        [string]$ProjectName
    )
    if ($PSCmdlet.ShouldProcess("dotnet", "create $ProjectType in $pwd")) {
        & dotnet new $ProjectType -o $ProjectName
        & dotnet new xunit -o "tests\$ProjectName.tests"
    }
}

Function Convert-ToCleanLocation {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $Path
    )
    Process {
        $Path | Convert-Path | Set-Location
    }
}

Function Start-ElevatedSession {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param()
    begin {
        $targetPath = Get-Location
        $targetProfile = Join-Path -Path $PSScriptRoot -ChildPath "adminProfile.ps1"
    }
    process {
        Write-Verbose "Targeting location: $targetPath"
        if (-not $PSCmdlet.ShouldProcess("Elevated terminal", "Starting")) {
            return;
        }
        Start-Process pwsh `
            -Verb runas `
            -ArgumentList @(
            "-ExecutionPolicy ByPass",
            "-NoLogo",
            "-NoProfile",
            "-NoExit",
            "-File $targetProfile",
            "-WorkingDirectory $targetPath"
        )
    }
}

Function Get-DotnetProject {
    [CmdletBinding()]
    param()
    $content = & dotnet new --list
    $headers = $content[0] -split '\s\s+'
    $content | Select-Object -Skip 2 | Select-Object -SkipLast 1 | ForEach-Object {
        $values = $_ -split '\s\s+' | Where-Object { $_ -ne "" }
        if ($values.Count -eq 3) {
            $values += $values[2]
            $values[2] = ""
        }
        $languages = $values[2] -split ','
        $defaultLanguage = $languages | Select-Object -First 1 | Select-Object @{Label = "Name"; Expression = { $_.TrimStart('[').TrimEnd(']') } } | Select-Object -ExpandProperty Name
        [PSCustomObject]@{
            $headers[0]        = $values[0]
            $headers[1]        = $values[1]
            "Default Language" = $defaultLanguage
            $headers[2]        = (($languages | Select-Object -Skip 1) -join ',').Trim()
            $headers[3]        = $values[3]
        };
    }
}
Function Update-ExtensionsModule {
    [CmdletBinding(
        SupportsShouldProcess,
        ConfirmImpact = 'Low'
    )]
    Param()
    If ($PSCmdlet.ShouldProcess("Extensions module", "Reload")) {
        $path = Join-Path -Path $PSScriptRoot -ChildPath "PSExtensions.psm1"
        Import-Module -Name $path -Force -Verbose:$VerbosePreference
    }
}

Function Set-EnvironmentVariable {
    [CmdletBinding(
        SupportsShouldProcess,
        ConfirmImpact = 'High'
    )]
    Param(
        [Parameter(Mandatory)]
        [string] $Variable,
        [Parameter(Mandatory)]
        [string] $Value,
        [Parameter()]
        [ValidateSet("Machine", "User")]
        [String] $Target
    )
    Begin {
        Switch ($Target) {
            "Machine" {
                $EnvTarget = [System.EnvironmentVariableTarget]::Machine
                Break
            }
            Default {
                $EnvTarget = [System.EnvironmentVariableTarget]::User
                Break
            }
        }
    }
    Process {
        if ($PSCmdlet.ShouldProcess($Variable, "Setting value $($Value) on target $($EnvTarget)")) {
            [System.Environment]::SetEnvironmentVariable($Variable, $Value, $EnvTarget)
        }
    }
}

Function Remove-EnvironmentVariable {
    [CmdletBinding(
        SupportsShouldProcess,
        ConfirmImpact = 'High'
    )]
    Param(
        [Parameter(Mandatory)]
        [string] $Variable,
        [Parameter(Mandatory)]
        [ValidateSet("Machine", "User")]
        [String] $Target
    )
    Begin {
        Switch ($Target) {
            "Machine" {
                $EnvTarget = [System.EnvironmentVariableTarget]::Machine
                Break
            }
            Default {
                $EnvTarget = [System.EnvironmentVariableTarget]::User
                Break
            }
        }
    }
    Process {
        if ($PSCmdlet.ShouldProcess($Variable, "Removing variable for target $($EnvTarget)")) {
            [System.Environment]::SetEnvironmentVariable($Variable, "", $EnvTarget)
        }
    }
}

Function Invoke-OhMyPosh {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
    [CmdletBinding()]
    param(
        [string]$Path
    )
    oh-my-posh init pwsh --config $Path | Invoke-Expression
}


Set-Alias -Name gig         -Value New-GitignoreFile
Set-Alias -Name lgi         -Value Get-GitignoreType
Set-Alias -Name cakeinit    -Value Get-CakeBootstrapScript
Set-Alias -Name paginit     -Value Start-Pageant
Set-Alias -Name cpwd        -Value Copy-CurrentPath
Set-Alias -Name kill        -Value Stop-Process
Set-Alias -Name su          -Value Start-ElevatedSession
Set-Alias -Name uem         -Value Update-ExtensionsModule
Set-Alias -name reload      -Value Update-ExtensionsModule
Set-Alias -Name env         -Value Set-EnvironmentVariable

Remove-Alias -Name sl -Force -ErrorAction SilentlyContinue
Set-Alias -Name sl -Value Convert-ToCleanLocation -Force

Export-ModuleMember -Function "*-*"
Export-ModuleMember -Alias "*"
