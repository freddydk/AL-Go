﻿Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "..\Github-Helper.psm1" -Resolve) -DisableNameChecking

<#
    .Synopsis
        Gets the modified files in a GitHub pull request.
#>
function Get-ModifiedFiles {
    param(
        [Parameter(HelpMessage = "The baseline SHA", Mandatory = $true)]
        [string] $baselineSHA
    )

    Push-Location $ENV:GITHUB_WORKSPACE
    $ghEvent = Get-Content $env:GITHUB_EVENT_PATH -Encoding UTF8 | ConvertFrom-Json
    if ($ghEvent.PSObject.Properties.name -eq 'pull_request') {
        $headSHA = $ghEvent.pull_request.head.sha
        Write-Host "Using head SHA $headSHA from pull request"
        git fetch origin $headSHA | Out-Host
        if ($LASTEXITCODE -ne 0) { $host.SetShouldExit(0); throw "Failed to fetch head SHA $headSHA" }
        if ($baselineSHA) {
            Write-Host "This is a pull request, but baseline SHA was specified to $baselineSHA"
        }
        else {
            $baselineSHA = $ghEvent.pull_request.base.sha
            Write-Host "This is a pull request, using baseline SHA $baselineSHA from pull request"
        }
        git fetch origin $baselineSHA | Out-Host
        if ($LASTEXITCODE -ne 0) { $host.SetShouldExit(0); throw "Failed to fetch baseline SHA $baselineSHA" }
    }
    elseif ($baselineSHA) {
        $headSHA = git rev-parse HEAD
        Write-Host "Current HEAD is $headSHA"
        git fetch origin $baselineSHA | Out-Host
        if ($LASTEXITCODE -ne 0) { $host.SetShouldExit(0); throw "Failed to fetch baseline SHA $baselineSHA" }
        Write-Host "Not a pull request, using baseline SHA $baselineSHA and current HEAD $headSHA"
    }
    else {
        Write-Host "Not a pull request and no baseline specified, returning empty list of changed files"
        return @()
    }
    Write-Host "git diff --name-only $baselineSHA $headSHA"
    $modifiedFiles = @(git diff --name-only $baselineSHA $headSHA | ForEach-Object { "$_".Replace('/', [System.IO.Path]::DirectorySeparatorChar) })
    if ($LASTEXITCODE -ne 0) { $host.SetShouldExit(0); throw "Failed to diff baseline SHA $baselineSHA with current HEAD $headSHA" }
    Pop-Location
    return $modifiedFiles
}

<#
.Synopsis
    Filters AL-Go projects based on modified files.

.Outputs
    An array of AL-Go projects, filtered based on the modified files.
#>
function ShouldBuildProject {
    param (
        [Parameter(HelpMessage = "An AL-Go project", Mandatory = $true)]
        $project,
        [Parameter(HelpMessage = "The base folder", Mandatory = $true)]
        $baseFolder,
        [Parameter(HelpMessage = "A list of modified files", Mandatory = $true)]
        $modifiedFiles
    )
    Write-Host "Determining whether to build project $project based on modified files"

    $projectFolders = GetProjectFolders -baseFolder $baseFolder -project $project -includeAlGoFolder

    $modifiedProjectFolders = @()
    foreach($projectFolder in $projectFolders) {
        $projectFolder = Join-Path $baseFolder "$projectFolder/*"

        if ($modifiedFiles -like $projectFolder) {
            $modifiedProjectFolders += $projectFolder
        }
    }

    if ($modifiedProjectFolders.Count -gt 0) {
        Write-Host "Modified files found for project $project : $($modifiedProjectFolders -join ', ')"
        return $true
    }

    Write-Host "No modified files found for project $project. Not building project"
    return $false
}

<#
.Synopsis
    Creates buils dimensions for a list of projects.

.Outputs
    An array of build dimensions for the projects and their corresponding build modes.
    Each build dimension is a hashtable with the following keys:
    - project: The name of the AL-Go project
    - buildMode: The build mode to use for the project
#>
function CreateBuildDimensions {
    param(
        [Parameter(HelpMessage = "A list of AL-Go projects for which to generate build dimensions")]
        $projects = @(),
        $baseFolder
    )

    $buildDimensions = @()

    foreach($project in $projects) {
        $projectSettings = ReadSettings -project $project -baseFolder $baseFolder
        $gitHubRunner = $projectSettings.githubRunner.Split(',').Trim() | ConvertTo-Json -compress
        $githubRunnerShell = $projectSettings.githubRunnerShell
        $buildModes = @($projectSettings.buildModes)

        if(!$buildModes) {
            Write-Host "No build modes found for project $project, using default build mode 'Default'."
            $buildModes = @('Default')
        }

        foreach($buildMode in $buildModes) {
            $buildDimensions += @{
                project = $project
                projectName = $projectSettings.projectName
                buildMode = $buildMode
                gitHubRunner = $gitHubRunner
                githubRunnerShell = $githubRunnerShell
            }
        }
    }

    return @(, $buildDimensions) # force array
}

<#
.Synopsis
    Analyzes a folder for AL-Go projects and determines the build order of these projects.

.Description
    Analyzes a folder for AL-Go projects and determines the build order of these projects.
    The build order is determined by the project dependencies and the projects that have been modified.

.Outputs
    The function returns the following values:
    - projects: An array of all projects found in the folder
    - projectsToBuild: An array of projects that need to be built
    - projectDependencies: A hashtable with the project dependencies
    - projectsOrderToBuild: An array of build dimensions, each build dimension contains the following properties:
        - projects: An array of projects to build
        - projectsCount: The number of projects to build
        - buildDimensions: An array of build dimensions, to be used in a build matrix. Properties of the build dimension are:
            - project: The project to build
            - buildMode: The build mode to use
#>
function Get-ProjectsToBuild {
    param (
        [Parameter(HelpMessage = "The folder to scan for projects to build", Mandatory = $true)]
        $baseFolder,
        [Parameter(HelpMessage = "Whether a full build is required", Mandatory = $false)]
        [bool] $buildAllProjects = $true,
        [Parameter(HelpMessage = "An array of changed files paths, used to filter the projects to build", Mandatory = $false)]
        [string[]] $modifiedFiles = @(),
        [Parameter(HelpMessage = "The maximum depth to build the dependency tree", Mandatory = $false)]
        [int] $maxBuildDepth = 0
    )

    . (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)

    Write-Host "Determining projects to build in $baseFolder"

    Push-Location $baseFolder
    try {
        $settings = $env:Settings | ConvertFrom-Json
        $projects = @(GetProjectsFromRepository -baseFolder $baseFolder -projectsFromSettings $settings.projects)
        Write-Host "Found AL-Go Projects: $($projects -join ', ')"

        $projectsToBuild = @()
        $projectDependencies = @{}
        $projectsOrderToBuild = @()

        if ($projects) {
            if($buildAllProjects) {
                Write-Host "Full build required, building all projects"
                $projectsToBuild = @($projects)
            }
            else {
                Write-Host "Full build not required, filtering projects to build based on the modified files"

                #Include the base folder in the modified files
                $modifiedFilesFullPaths = @($modifiedFiles | ForEach-Object { return Join-Path $baseFolder $_ })
                $projectsToBuild = @($projects | Where-Object { ShouldBuildProject -baseFolder $baseFolder -project $_ -modifiedFiles $modifiedFilesFullPaths })
            }

            if($settings.useProjectDependencies) {
                $buildAlso = @{}

                # Calculate the full projects order
                $fullProjectsOrder = AnalyzeProjectDependencies -baseFolder $baseFolder -projects $projects -buildAlso ([ref]$buildAlso) -projectDependencies ([ref]$projectDependencies)

                $projectsToBuild = @($projectsToBuild | ForEach-Object { $_; if ($buildAlso.Keys -contains $_) { $buildAlso."$_" } } | Select-Object -Unique)
            }
            else {
                # Use a flatten build order (all projects on the same level)
                $fullProjectsOrder = @(@{ 'projects' = $projectsToBuild; 'projectsCount' = $projectsToBuild.Count})
            }

            # Create a project order based on the projects to build
            foreach($depth in $fullProjectsOrder) {
                $projectsOnDepth = @($depth.projects | Where-Object { $projectsToBuild -contains $_ })

                if ($projectsOnDepth) {
                    # Create build dimensions for the projects on the current depth
                    $buildDimensions = CreateBuildDimensions -baseFolder $baseFolder -projects $projectsOnDepth
                    $projectsOrderToBuild += @{
                        projects = $projectsOnDepth
                        projectsCount = $projectsOnDepth.Count
                        buildDimensions = $buildDimensions
                    }
                }
            }
        }

        if ($projectsOrderToBuild.Count -eq 0) {
            Write-Host "Did not find any projects to add to the build order, adding default values"
            $projectsOrderToBuild += @{
                projects = @()
                projectsCount = 0
                buildDimensions = @()
            }
        }
        Write-Host "Projects to build: $($projectsToBuild -join ', ')"

        if($maxBuildDepth -and ($projectsOrderToBuild.Count -gt $maxBuildDepth)) {
            throw "The build depth is too deep, the maximum build depth is $maxBuildDepth. You need to run 'Update AL-Go System Files' to update the workflows"
        }

        return $projects, $projectsToBuild, $projectDependencies, $projectsOrderToBuild
    }
    finally {
        Pop-Location
    }
}

Export-ModuleMember *-*
