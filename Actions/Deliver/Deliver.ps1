Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "The GitHub token running the action", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "Specifies the parent telemetry scope for the telemetry signal", Mandatory = $false)]
    [string] $parentTelemetryScopeJson = '{}',
    [Parameter(HelpMessage = "Projects to deliver (default is all)", Mandatory = $false)]
    [string] $projects = "*",
    [Parameter(HelpMessage = "Delivery target (AppSource or StorageAccount)", Mandatory = $true)]
    [ValidateSet('AppSource','Storage')]
    [string] $deliveryTarget,
    [Parameter(HelpMessage = "Artifacts to deliver", Mandatory = $true)]
    [string] $artifacts,
    [Parameter(HelpMessage = "Type of delivery (CD or Publish)", Mandatory = $false)]
    [ValidateSet('CD','Publish')]
    [string] $type = "CD",
    [Parameter(HelpMessage = "Secrets from repository in compressed Json format", Mandatory = $false)]
    [string] $secretsJson = '{"AppSourceContext":"", "StorageContext":""}'
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0
$telemetryScope = $null
$bcContainerHelperPath = $null

# IMPORTANT: No code that can fail should be outside the try/catch

try {
    . (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
    $BcContainerHelperPath = DownloadAndImportBcContainerHelper -baseFolder $ENV:GITHUB_WORKSPACE

    import-module (Join-Path -path $PSScriptRoot -ChildPath "..\TelemetryHelper.psm1" -Resolve)
    $telemetryScope = CreateScope -eventId 'DO0081' -parentTelemetryScopeJson $parentTelemetryScopeJson

    if ($projects -eq '') { $projects = "*" }

    $projectList = @(Get-ChildItem -Path $ENV:GITHUB_WORKSPACE -Directory -Recurse -Depth 2 | Where-Object { ($_.BaseName -like $projects) -and (Test-Path (Join-Path $_.FullName ".AL-Go") -PathType Container) } | ForEach-Object { $_.BaseName })
    if (Test-Path (Join-Path $ENV:GITHUB_WORKSPACE ".AL-Go") -PathType Container) {
        $projectList += @(".")
    }
    if ($projectList.Count -eq 0) {
        throw "No projects matches the pattern '$projects'"
    }
    Write-Host "Projects:"
    $projectList | Out-Host

    $key = "$($deliveryTarget)Context"
    Write-Host "Using $key"
    Set-Variable -Name $key -Value $env:deliveryContext

    $projectList | ForEach-Object {
        $project = $_
        Write-Host "Project '$project'"
        $apps = @()
        $baseFolder = Join-Path $ENV:GITHUB_WORKSPACE "artifacts\$_"

        if ($artifacts -like "$($ENV:GITHUB_WORKSPACE)*") {
            # artifacts already present
        }
        elseif ($artifacts -eq "current" -or $artifacts -eq "prerelease" -or $artifacts -eq "draft") {
            # latest released version
            $releases = GetReleases -token $token -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY
            if ($artifacts -eq "current") {
                $release = $releases | Where-Object { -not ($_.prerelease -or $_.draft) } | Select-Object -First 1
            }
            elseif ($artifacts -eq "prerelease") {
                $release = $releases | Where-Object { -not ($_.draft) } | Select-Object -First 1
            }
            elseif ($artifacts -eq "draft") {
                $release = $releases | Select-Object -First 1
            }
            if (!($release)) {
                throw "Unable to locate $artifacts release"
            }
            New-Item $baseFolder -ItemType Directory | Out-Null
            DownloadRelease -token $token -projects $project -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY -release $release -path $baseFolder
            $apps = @((Get-ChildItem -Path $baseFolder) | ForEach-Object { $_.FullName })
            if (!$apps) {
                throw "Artifact $artifacts was not found on any release. Make sure that the artifact files exist and files are not corrupted."
            }
        }
        else {
            New-Item $baseFolder -ItemType Directory | Out-Null
            $allArtifacts = GetArtifacts -token $token -api_url $ENV:GITHUB_API_URL -repository $ENV:GITHUB_REPOSITORY -mask "Apps" -projects $project -Version $artifacts -branch "main"
            if ($allArtifacts) {
                $allArtifacts | ForEach-Object {
                    $appFile = DownloadArtifact -token $token -artifact $_ -path $baseFolder
                    if (!(Test-Path $appFile)) {
                        throw "Unable to download artifact $($_.name)"
                    }
                }
            }
            else {
                throw "Could not find any Apps artifacts for projects $projects, version $artifacts"
            }
        }

        if ($deliveryTarget -eq "Storage") {
            if ($project -and ($project -ne '.')) {
                $projectName = $project -replace "[^a-z0-9]", "-"
            }
            else {
                $projectName = $env:RepoName -replace "[^a-z0-9]", "-"
            }
            try {
                if (get-command New-AzureStorageContext -ErrorAction SilentlyContinue) {
                    Write-Host "Using Azure.Storage PowerShell module"
                }
                else {
                    if (!(get-command New-AzStorageContext -ErrorAction SilentlyContinue)) {
                        OutputError -message "When delivering to storage account, the build agent needs to have either the Azure.Storage or the Az.Storage PowerShell module installed."
                        exit
                    }
                    Write-Host "Using Az.Storage PowerShell module"
                    Set-Alias -Name New-AzureStorageContext -Value New-AzStorageContext
                    Set-Alias -Name Get-AzureStorageContainer -Value Get-AzStorageContainer
                    Set-Alias -Name Set-AzureStorageBlobContent -Value Set-AzStorageBlobContent
                }
                $storageAccount = $storageContext | ConvertFrom-Json | ConvertTo-HashTable
                if ($storageAccount.ContainsKey('sastoken')) {
                    $storageContext = New-AzureStorageContext -StorageAccountName $storageAccount.StorageAccountName -SasToken $storageAccount.sastoken
                }
                else {
                    $storageContext = New-AzureStorageContext -StorageAccountName $storageAccount.StorageAccountName -StorageAccountKey $storageAccount.StorageAccountKey
                }
                Write-Host "Storage Context OK"
            }
            catch {
                throw "StorageContext secret is malformed. Needs to be formatted as Json, containing StorageAccountName, containerName, blobName and sastoken or storageAccountKey, which points to an existing container in a storage account."
            }

            $storageContainerName =  $storageAccount.ContainerName.ToLowerInvariant().replace('{project}',$projectName).ToLowerInvariant()
            $storageBlobName = $storageAccount.BlobName.ToLowerInvariant()
            Write-Host "Storage Container Name is $storageContainerName"
            Write-Host "Storage Blob Name is $storageBlobName"
            Get-AzureStorageContainer -Context $storageContext -name $storageContainerName | Out-Null
            Write-Host "Delivering to $storageContainerName in $($storageAccount.StorageAccountName)"
            "Apps","TestApps" | ForEach-Object {
                $atype = $_
                $artfolder = Join-Path $baseFolder "*-$atype-*"
                if (Test-Path -path $artfolder -PathType Container) {
                    $artfolder = ( Get-Item -path $artfolder).FullName
                    Write-Host $artfolder
                    $versions = @("$($env:RepoVersion).$($env:appBuild).$($env:appRevision)-preview","preview")
                    if ($type -eq "Publish") {
                        $versions += @("$($env:RepoVersion).$($env:appBuild).$($env:appRevision)","latest")
                    }
                    $tempFile = Join-Path $ENV:TEMP "$([Guid]::newguid().ToString()).zip"
                    try {
                        Write-Host "Compressing"
                        Compress-Archive -Path $artfolder -DestinationPath $tempFile -Force
                        $versions | ForEach-Object {
                            $version = $_
                            $blob = $storageBlobName.replace('{project}',$projectName).replace('{version}',$version).replace('{type}',$atype).ToLowerInvariant()
                            Write-Host "Delivering $blob"
                            Set-AzureStorageBlobContent -Context $storageContext -Container $storageContainerName -File $tempFile -blob $blob -Force | Out-Null
                        }
                    }
                    finally {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        elseif ($deliveryTarget -eq "AppSource") {
            $appSourceContextHt = $appSourceContext | ConvertFrom-Json | ConvertTo-HashTable
            $authContext = New-BcAuthContext @appSourceContextHt

            $projectSettings = Get-Content -Path (Join-Path $ENV:GITHUB_WORKSPACE "$project\.AL-Go\settings.json") | ConvertFrom-Json | ConvertTo-HashTable -Recurse
            if ($projectSettings.ContainsKey("mainAppFolder")) {
                $mainAppFolder = $projectSettings.mainAppFolder
            }
            else {
                try {
                    $mainAppFolder = $projectSettings.appFolders[0]
                }
                catch {
                    throw "Unable to determine main App folder"
                }
            }
            if (-not $projectSettings.ContainsKey('AppSourceProductId')) {
                throw "AppSourceProductId needs to be specified in $project\.AL-Go\settings.json in order to deliver to AppSource"
            }
            Write-Host "MainAppFolder $mainAppFolder"

            $mainAppJson = Get-Content -Path (Join-Path $ENV:GITHUB_WORKSPACE "$mainAppFolder\app.json") | ConvertFrom-Json
            $mainAppVersion = [Version]$mainAppJson.Version
            $mainAppFileName = "$($mainAppJson.Publisher)_$($mainAppJson.Name)_$($mainAppVersion.Major).$($mainAppVersion.Minor).$($env:appBuild).$($env:appRevision).app".Split([System.IO.Path]::GetInvalidFileNameChars()) -join ''
            Write-Host $mainAppFileName

            $artfolder = Join-Path $baseFolder "*-Apps-*"
            if (Test-Path -path $artfolder -PathType Container) {
                $artfolder = ( Get-Item -path $artfolder).FullName
                $appFile = Get-ChildItem -path $artFolder | Where-Object { $_.name -eq $mainAppFileName } | ForEach-Object { $_.FullName }
                $libraryAppFiles = @(Get-ChildItem -path $artFolder | Where-Object { $_.name -ne $mainAppFileName } | ForEach-Object { $_.FullName })
                Write-Host "Main App File:"
                Write-Host $appFile
                Write-Host "Library App Files:"
                $libraryAppFiles | Out-Host
                if (-not $appFile) {
                    throw "Unable to locate main app file ($mainAppFileName doesn't exist)"
                }
                New-AppSourceSubmission -authContext $authContext -productId $projectSettings.AppSourceProductId -appFile $appFile -libraryAppFiles $libraryAppFiles -doNotWait
            }
        }
    }

    TrackTrace -telemetryScope $telemetryScope
}
catch {
    OutputError -message "Deliver action failed.$([environment]::Newline)Error: $($_.Exception.Message)$([environment]::Newline)Stacktrace: $($_.scriptStackTrace)"
    TrackException -telemetryScope $telemetryScope -errorRecord $_
}
finally {
    CleanupAfterBcContainerHelper -bcContainerHelperPath $bcContainerHelperPath
}
