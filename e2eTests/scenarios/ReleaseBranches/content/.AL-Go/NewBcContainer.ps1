Param(
    [Hashtable]$parameters
)

function Invoke-Sudo { 
    & /usr/bin/env sudo pwsh -command "& $args" 
}

$containerName = $parameters.containerName
$artifactUrl = $parameters.artifactUrl

$containerFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder "Extensions\$containerName"
if (Test-Path $containerFolder) {
    Remove-BcContainer $containerName
    Remove-Item -Path $containerFolder -Force -Recurse -ErrorAction Ignore
    New-Item -Path $containerFolder -ItemType Directory -ErrorAction Ignore | Out-Null
}

#$modernDevFolder = Join-Path $platformArtifactPath "ModernDev\program files\Microsoft Dynamics NAV\*\AL Development Environment" -Resolve
#$alLanguageVsix = Join-Path $modernDevFolder 'ALLanguage.vsix'
#Copy-item -Path $alLanguageVsix -Destination $tempZip
$vsixPath = Join-Path $containerFolder 'vsix'
$tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "alc.zip"
Download-File -sourceUrl 'https://bcartifacts.blob.core.windows.net/prerequisites/al-11.0.0-marketplace.vsix' -destinationFile $tempZip
Expand-Archive -Path $tempZip -DestinationPath $vsixPath
if ($isLinux) {
    $alcExePath = Join-Path $vsixPath 'extension/bin/linux/alc'
    Invoke-Sudo "chmod +x $alcExePath"
}

# Populate artifacts cache
$symbolsPath = Join-Path $ENV:GITHUB_WORKSPACE '.artifactcache'
if (!(Test-Path $symbolsPath)) {
    New-Item $symbolsPath -ItemType Directory | Out-Null
    $artifactPaths = Download-Artifacts -artifactUrl $artifactUrl -includePlatform
    $appArtifactPath = $artifactPaths[0]
    $platformArtifactPath = $artifactPaths[1]
    $modernDevFolder = Join-Path $platformArtifactPath "ModernDev\program files\Microsoft Dynamics NAV\*\AL Development Environment" -Resolve
    Copy-Item -Path (Join-Path $modernDevFolder 'System.app') -Destination $symbolsPath
    Copy-Item -Path (Join-Path $appArtifactPath 'Extensions/*.app') -Destination $symbolsPath
}
