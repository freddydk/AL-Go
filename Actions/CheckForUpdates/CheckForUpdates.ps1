﻿Param(
    [Parameter(HelpMessage = "The GitHub actor running the action", Mandatory = $false)]
    [string] $actor,
    [Parameter(HelpMessage = "Base64 encoded GhTokenWorkflow secret", Mandatory = $false)]
    [string] $token,
    [Parameter(HelpMessage = "URL of the template repository (default is the template repository used to create the repository)", Mandatory = $false)]
    [string] $templateUrl = "",
    [Parameter(HelpMessage = "Set this input to true in order to download latest version of the template repository (else it will reuse the SHA from last update)", Mandatory = $true)]
    [bool] $downloadLatest,
    [Parameter(HelpMessage = "Set this input to Y in order to update AL-Go System Files if needed", Mandatory = $false)]
    [string] $update = 'N',
    [Parameter(HelpMessage = "Set the branch to update", Mandatory = $false)]
    [string] $updateBranch,
    [Parameter(HelpMessage = "Direct Commit?", Mandatory = $false)]
    [bool] $directCommit
)

. (Join-Path -Path $PSScriptRoot -ChildPath "..\AL-Go-Helper.ps1" -Resolve)
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\TelemetryHelper.psm1' -Resolve)
. (Join-Path -Path $PSScriptRoot -ChildPath "yamlclass.ps1")
. (Join-Path -Path $PSScriptRoot -ChildPath "CheckForUpdates.HelperFunctions.ps1")

# ContainerHelper is used for determining project folders and dependencies
DownloadAndImportBcContainerHelper

if (-not $templateUrl.Contains('@')) {
    $templateUrl += "@main"
}
if ($templateUrl -notlike "https://*") {
    $templateUrl = "https://github.com/$templateUrl"
}
# Remove www part (if exists)
$templateUrl = $templateUrl -replace "^(https:\/\/)(www\.)(.*)$", '$1$3'

# TemplateUrl is now always a full url + @ and a branch name

if ($update -eq 'Y') {
    if (-not $token) {
        throw "The GhTokenWorkflow secret is needed. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information."
    }
}

$readToken = $token
if ($token) {
    # token comes from a secret, base 64 encoded
    $token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($token))

    # Get token with read permissions for this and the template repository - if private and in the same organization
    $repositories = @($ENV:GITHUB_REPOSITORY)
    if ($templateUrl -like "https://github.com/$($ENV:GITHUB_REPOSITORY_OWNER)/*") {
        $repositories += $templateUrl.Split('@')[0]
    }
    $readToken = GetAccessToken -token $token -permissions @{"actions"="read";"contents"="read";"metadata"="read"} -repositories $repositories
}

# Use Authenticated API request if possible to avoid the 60 API calls per hour limit
$headers = GetHeaders -token $readToken

# CheckForUpdates will read all AL-Go System files from the Template repository and compare them to the ones in the current repository
# CheckForUpdates will apply changes to the AL-Go System files based on AL-Go repo settings, such as "runs-on" etc.
# if $update is set to Y, CheckForUpdates will also update the AL-Go System files in the current repository using a PR or a direct commit (if $directCommit is set to true)
# if $update is set to N, CheckForUpdates will only check for updates and output a warning if there are updates available
# if $downloadLatest is set to true, CheckForUpdates will download the latest version of the template repository, else it will use the templateSha setting in the .github/AL-Go-Settings file

# Get Repo settings as a hashtable (do NOT read any specific project settings, nor any specific workflow, user or branch settings)
$repoSettings = ReadSettings -buildMode '' -project '' -workflowName '' -userName '' -branchName '' | ConvertTo-HashTable -recurse
$templateSha = $repoSettings.templateSha
$unusedALGoSystemFiles = $repoSettings.unusedALGoSystemFiles
$includeBuildPP = $repoSettings.type -eq 'PTE' -and $repoSettings.powerPlatformSolutionFolder -ne ''
if (!$includeBuildPP) {
    # Remove PowerPlatform workflows if no PowerPlatformSolution exists
    $unusedALGoSystemFiles += @('_BuildPowerPlatformSolution.yaml','PushPowerPlatformChanges.yaml','PullPowerPlatformChanges.yaml')
}

# If templateUrl has changed, download latest version of the template repository (ignore templateSha)
if ($repoSettings.templateUrl -ne $templateUrl -or $templateSha -eq '') {
    $downloadLatest = $true
}

$realTemplateFolder = $null
$templateFolder = DownloadTemplateRepository -headers $headers -templateUrl $templateUrl -templateSha ([ref]$templateSha) -downloadLatest $downloadLatest
Write-Host "Template Folder: $templateFolder"

$templateBranch = $templateUrl.Split('@')[1]
$templateOwner = $templateUrl.Split('/')[3]
$templateInfo = "$templateOwner/$($templateUrl.Split('/')[4])"

$isDirectALGo = IsDirectALGo -templateUrl $templateUrl
if (-not $isDirectALGo) {
    $templateRepoSettingsFile = Join-Path $templateFolder "*/$RepoSettingsFile"
    if (Test-Path -Path $templateRepoSettingsFile -PathType Leaf) {
        $templateRepoSettings = Get-Content $templateRepoSettingsFile -Encoding UTF8 | ConvertFrom-Json | ConvertTo-HashTable -Recurse
        if ($templateRepoSettings.Keys -contains "templateUrl" -and $templateRepoSettings.templateUrl -ne $templateUrl) {
            # The template repository is a url to another AL-Go repository (an indirect template repository)
            # TemplateUrl and TemplateSha from .github/AL-Go-Settings.json in the indirect template reposotiry points to the "real" template repository
            # Copy files and folders from the indirect template repository, but grab the unmodified file from the "real" template repository if it exists and apply customizations
            # Copy .github/AL-Go-Settings.json to .github/templateRepoSettings.json (will be read before .github/AL-Go-Settings.json in the final repo)
            # Copy .AL-Go/settings.json to .github/templateProjectSettings.json (will be read before .AL-Go/settings.json in the final repo)

            Write-Host "Indirect AL-Go template repository detected, downloading the 'real' template repository"
            $realTemplateUrl = $templateRepoSettings.templateUrl
            if ($templateRepoSettings.Keys -contains "templateSha") {
                $realTemplateSha = $templateRepoSettings.templateSha
            }
            else {
                $realTemplateSha = ""
            }

            # Download the "real" template repository - use downloadLatest if no TemplateSha is specified in the indirect template repository
            $realTemplateFolder = DownloadTemplateRepository -headers $headers -templateUrl $realTemplateUrl -templateSha ([ref]$realTemplateSha) -downloadLatest ($realTemplateSha -eq '')
            Write-Host "Real Template Folder: $realTemplateFolder"

            # Set TemplateBranch and TemplateOwner
            # Keep TemplateUrl and TemplateSha pointing to the indirect template repository
            $templateBranch = $realTemplateUrl.Split('@')[1]
            $templateOwner = $realTemplateUrl.Split('/')[3]

            # If the indirect template contains unusedALGoSystemFiles, we need to remove them from the current repository
            if ($templateRepoSettings.ContainsKey('unusedALGoSystemFiles')) {
                $unusedALGoSystemFiles += $templateRepoSettings.unusedALGoSystemFiles
            }
        }
    }
}

# CheckFiles is an array of hashtables with the following properties:
# dstPath: The path to the file in the current repository
# srcPath: The path to the file in the template repository
# pattern: The pattern to use when searching for files in the template repository
# type: The type of file (script, workflow, releasenotes)
# The files currently checked are:
# - All files in .github/workflows
# - All files in .github that ends with .copy.md
# - All PowerShell scripts in .AL-Go folders (all projects)
$checkfiles = @(
    @{ 'dstPath' = (Join-Path '.github' 'workflows'); 'newname' = ''; 'srcPath' = Join-Path '.github' 'workflows'; 'pattern' = '*'; 'type' = 'workflow' },
    @{ 'dstPath' = '.github'; 'newname' = ''; 'srcPath' = '.github'; 'pattern' = '*.copy.md'; 'type' = 'releasenotes' }
)

if ($realTemplateFolder) {
    $checkfiles += @(
        @{ 'dstPath' = [system.IO.Path]::GetDirectoryName($TemplateRepoSettingsFile); 'newname' = [system.IO.Path]::GetFileName($TemplateRepoSettingsFile); 'SrcPath' = [system.IO.Path]::GetDirectoryName($RepoSettingsFile); 'pattern' = [system.IO.Path]::GetFileName($RepoSettingsFile); 'type' = 'template repo settings' }
        @{ 'dstPath' = [system.IO.Path]::GetDirectoryName($TemplateProjectSettingsFile); 'newname' = [system.IO.Path]::GetFileName($TemplateProjectSettingsFile); 'SrcPath' = [system.IO.Path]::GetDirectoryName($ALGoSettingsFile); 'pattern' = [system.IO.Path]::GetFileName($ALGoSettingsFile); ; 'type' = 'template project settings' }
    )
}

# Get the list of projects in the current repository
$baseFolder = $ENV:GITHUB_WORKSPACE
$projects = @(GetProjectsFromRepository -baseFolder $baseFolder -projectsFromSettings $repoSettings.projects)
Write-Host "Projects found: $($projects.Count)"
foreach($project in $projects) {
    Write-Host "- $project"
    $checkfiles += @(@{ 'dstPath' = Join-Path $project '.AL-Go'; 'newname' = ''; 'srcPath' = '.AL-Go'; 'pattern' = '*.ps1'; 'type' = 'script' })
}

# $updateFiles will hold an array of files, which needs to be updated
$updateFiles = @()
# $removeFiles will hold an array of files, which needs to be removed
$removeFiles = @()

# Dependency depth determines how many build jobs we need to run sequentially
# Every build job might spin up multiple jobs in parallel to build the projects without unresolved deependencies
$depth = 1
if ($projects.Count -gt 1) {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "..\DetermineProjectsToBuild\DetermineProjectsToBuild.psm1" -Resolve) -DisableNameChecking
    $allProjects, $modifiedProjects, $projectsToBuild, $projectDependencies, $buildOrder = Get-ProjectsToBuild -baseFolder $baseFolder -buildAllProjects $true -maxBuildDepth 100
    $depth = $buildOrder.Count
    Write-Host "Calculated dependency depth to be $depth"
}

# Loop through all folders in CheckFiles and check if there are any files that needs to be updated
foreach($checkfile in $checkfiles) {
    Write-Host "Checking $($checkfile.srcPath)/$($checkfile.pattern)"
    $type = $checkfile.type
    $srcPath = $checkfile.srcPath
    $dstPath = $checkfile.dstPath
    $dstFolder = Join-Path $baseFolder $dstPath
    $srcFolder = GetSrcFolder -repoType $repoSettings.type -templateUrl $templateUrl -templateFolder $templateFolder -srcPath $srcPath
    $realSrcFolder = $null
    if ($realTemplateFolder -and $type -notlike 'template*settings') {
        # Get Real source folder except for template settings - these are applied from the indirect temoplate´repository
        $realSrcFolder = GetSrcFolder -repoType $repoSettings.type -templateUrl $realTemplateUrl -templateFolder $realTemplateFolder -srcPath $srcPath
    }
    if ($srcFolder) {
        Push-Location -Path $srcFolder
        try {
            # Remove unused AL-Go system files
            $unusedALGoSystemFiles | ForEach-Object {
                if (Test-Path -Path (Join-Path $dstFolder $_) -PathType Leaf) {
                    Write-Host "Remove unused AL-Go system file: $_"
                    $removeFiles += @(Join-Path $dstPath $_)
                }
            }

            # Loop through all files in the template repository matching the pattern
            Get-ChildItem -Path $srcFolder -Filter $checkfile.pattern | ForEach-Object {
                # Read the template file and modify it based on the settings
                # Compare the modified file with the file in the current repository
                if ($checkfile.newname) {
                    $filename = $checkfile.newname
                }
                else {
                    $filename = $_.Name
                }
                Write-Host "- $filename"
                $dstFile = Join-Path $dstFolder $filename
                $srcFile = $_.FullName
                $realSrcFile = $srcFile
                $isFileDirectALGo = $isDirectALGo
                Write-Host "SrcFolder: $srcFolder"
                if ($realSrcFolder) {
                    # if SrcFile is an indirect template repository, we need to find the file in the "real" template repository
                    $fname = Join-Path $realSrcFolder (Resolve-Path $srcFile -Relative)
                    if (Test-Path -Path $fname -PathType Leaf) {
                        Write-Host "File is available in the 'real' template repository"
                        $realSrcFile = $fname
                        $isFileDirectALGo = IsDirectALGo -templateUrl $realTemplateUrl
                    }
                }
                if ($type -eq "workflow") {
                    # for workflow files, we might need to modify the file based on the settings
                    $srcContent = GetWorkflowContentWithChangesFromSettings -srcFile $realsrcFile -repoSettings $repoSettings -depth $depth -includeBuildPP $includeBuildPP
                }
                else {
                    # For non-workflow files, just read the file content
                    $srcContent = Get-ContentLF -Path $realSrcFile
                }

                # Replace static placeholders
                $srcContent = $srcContent.Replace('{TEMPLATEURL}', $templateUrl)

                if ($isFileDirectALGo) {
                    # If we are using direct AL-Go repo, we need to change the owner to the remplateOwner, the repo names to AL-Go and AL-Go/Actions and the branch to templateBranch
                    ReplaceOwnerRepoAndBranch -srcContent ([ref]$srcContent) -templateOwner $templateOwner -templateBranch $templateBranch
                }

                $customizationAnchors = GetCustomizationAnchors
                if ($type -eq 'workflow' -and $realSrcFile -ne $srcFile) {
                    # Apply customizations from indirect template repository
                    Write-Host "Apply customizations from indirect template repository: $srcFile"
                    [Yaml]::ApplyCustomizations([ref] $srcContent, $srcFile, $customizationAnchors)
                }

                if ($unusedALGoSystemFiles -notcontains $fileName) {
                    if (Test-Path -Path $dstFile -PathType Leaf) {
                        if ($type -eq 'workflow') {
                            Write-Host "Apply customizations from my repository: $dstFile"
                            [Yaml]::ApplyCustomizations([ref] $srcContent,$dstFile, $customizationAnchors)
                        }
                        # file exists, compare and add to $updateFiles if different
                        $dstContent = Get-ContentLF -Path $dstFile
                        if ($dstContent -cne $srcContent) {
                            Write-Host "Updated $type ($(Join-Path $dstPath $filename)) available"
                            $updateFiles += @{ "DstFile" = Join-Path $dstPath $filename; "content" = $srcContent }
                        }
                    }
                    else {
                        # new file, add to $updateFiles
                        Write-Host "New $type ($(Join-Path $dstPath $filename)) available"
                        $updateFiles += @{ "DstFile" = Join-Path $dstPath $filename; "content" = $srcContent }
                    }
                }
            }
        }
        finally {
            Pop-Location
        }
    }
}

# Apply Custom AL-Go System Files from settings
$updateFiles += @(GetCustomALGoSystemFiles -baseFolder $baseFolder -settings $repoSettings -projects $projects)

if ($update -ne 'Y') {
    # $update not set, just issue a warning in the CI/CD workflow that updates are available
    if (($updateFiles) -or ($removeFiles)) {
        if ($updateFiles) {
            Write-Host "Updated files:"
            $updateFiles | ForEach-Object { Write-Host "- $($_.DstFile)" }

        }
        if ($removeFiles) {
            Write-Host "Removed files:"
            $removeFiles | ForEach-Object { Write-Host "- $_" }
        }
        OutputWarning -message "There are updates for your AL-Go system, run 'Update AL-Go System Files' workflow to download the latest version of AL-Go."
    }
    else {
        OutputNotice -message "No updates available for AL-Go for GitHub."
    }
}
else {
    # $update set, update the files
    try {
        # If a pull request already exists with the same REF, then exit
        $branchSHA = RunAndCheck git rev-list -n 1 $updateBranch
        $commitMessage = "[$($updateBranch)@$($branchSHA.SubString(0,7))] Update AL-Go System Files from $templateInfo - $($templateSha.SubString(0,7))"

        # Get Token with permissions to modify workflows in this repository
        $writeToken = GetAccessToken -token $token -permissions @{"actions"="read";"contents"="write";"pull_requests"="write";"workflows"="write"}
        $env:GH_TOKEN = $writeToken

        $existingPullRequest = (gh api --paginate "/repos/$env:GITHUB_REPOSITORY/pulls?base=$updateBranch" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" | ConvertFrom-Json) | Where-Object { $_.title -eq $commitMessage } | Select-Object -First 1
        if ($existingPullRequest) {
            OutputWarning "Pull request already exists for $($commitMessage): $($existingPullRequest.html_url)."
            exit
        }

        # If $directCommit, then changes are made directly to the default branch
        $serverUrl, $branch = CloneIntoNewFolder -actor $actor -token $writeToken -updateBranch $updateBranch -DirectCommit $directCommit -newBranchPrefix 'update-al-go-system-files'

        invoke-git status

        UpdateSettingsFile -settingsFile (Join-Path ".github" "AL-Go-Settings.json") -updateSettings @{ "templateUrl" = $templateUrl; "templateSha" = $templateSha }

        # Update the files
        # Calculate the release notes, while updating
        $releaseNotes = ""
        $updateFiles | ForEach-Object {
            # Create the destination folder if it doesn't exist
            $path = [System.IO.Path]::GetDirectoryName($_.DstFile)
            if (-not (Test-Path -path $path -PathType Container)) {
                New-Item -Path $path -ItemType Directory | Out-Null
            }
            if (([System.IO.Path]::GetFileName($_.DstFile) -eq "RELEASENOTES.copy.md") -and (Test-Path $_.DstFile)) {
                # Read the release notes of the version currently installed
                $oldReleaseNotes = Get-ContentLF -Path $_.DstFile
                # Get the release notes of the new version (for the PR body)
                $releaseNotes = $_.Content
                # The first line with ## vX.Y, this is the latest shipped version already installed
                $version = $oldReleaseNotes.Split("`n") | Where-Object { $_ -like '## v*.*' } | Select-Object -First 1
                if ($version) {
                    # Only use the release notes up to the version already installed
                    $index = $releaseNotes.IndexOf("`n$version`n")
                    if ($index -ge 0) {
                        $releaseNotes = $releaseNotes.Substring(0,$index)
                    }
                }
            }
            Write-Host "Update $($_.DstFile)"
            $_.Content | Set-ContentLF -Path $_.DstFile
        }
        if ($releaseNotes -eq "") {
            $releaseNotes = "No release notes available!"
        }
        $removeFiles | ForEach-Object {
            Write-Host "Remove $_"
            Remove-Item (Join-Path (Get-Location).Path $_) -Force
        }

        Write-Host "ReleaseNotes:"
        Write-Host $releaseNotes

        if (!(CommitFromNewFolder -serverUrl $serverUrl -commitMessage $commitMessage -branch $branch -body $releaseNotes -headBranch $updateBranch)) {
            OutputNotice -message "No updates available for AL-Go for GitHub."
        }
    }
    catch {
        if ($directCommit) {
            throw "Failed to update AL-Go System Files. Make sure that the personal access token, defined in the secret called GhTokenWorkflow, is not expired and it has permission to update workflows. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information. (Error was $($_.Exception.Message))"
        }
        else {
            throw "Failed to create a pull-request to AL-Go System Files. Make sure that the personal access token, defined in the secret called GhTokenWorkflow, is not expired and it has permission to update workflows. Read https://github.com/microsoft/AL-Go/blob/main/Scenarios/GhTokenWorkflow.md for more information. (Error was $($_.Exception.Message))"
        }
    }
}
