Param(
    [Hashtable]$parameters
)

function GetParam {
    Param(
        [string] $name,
        $default
    )

    if ($parameters.ContainsKey($name)) {
        return $parameters."$name"
    }
    else {
        return $default
    }
}

$containerName = GetParam -name 'containerName' -default 'bcbuild'
$appProjectFolder = $parameters.appProjectFolder
$appOutputFolder = GetParam -name 'appOutputFolder' -default ((Join-Path $appProjectFolder "output"))
$appSymbolsFolder = GetParam -name 'appSymbolsFolder' -default ((Join-Path $appProjectFolder ".alPackages"))
$appName = GetParam -name 'appName' -default ''
$copyAppToSymbolsFolder = GetParam -name 'CopyAppToSymbolsFolder' -default $false
$generateReportLayout = GetParam -name 'generateReportLayout' -default 'NotSpecified'
$azureDevOps = GetParam -name 'azureDevOps' -default $false
$gitHubActions = GetParam -name 'gitHubActions' -default $false
$enableCodeCop = GetParam -name 'enableCodeCop' -default $false
$enableAppSourceCop = GetParam -name 'enableAppSourceCop' -default $false
$enablePerTenantExtensionCop = GetParam -name 'enablePerTenantExtensionCop' -default $false
$enableUICop = GetParam -name 'enableUICop' -default $false
$failOn = GetParam -name 'failOn' -default 'none'
$rulesetFile = GetParam -name 'rulesetFile' -default ''
$customCodeCops = @(GetParam -name 'customCodeCops' -default @())
$nowarn = GetParam -name 'nowarn' -default ''
$preProcessorSymbols = @(GetParam -name 'preProcessorSymbols' -default @())
$generateCrossReferences = GetParam -name 'generateCrossReferences' -default $false
$reportSuppressedDiagnostics = GetParam -name 'reportSuppressedDiagnostics' -default $false
$assemblyProbingPaths = GetParam -name 'assemblyProbingPaths' -default ''
$features = @(GetParam -name 'features' -default @())
$treatWarningsAsErrors = @(GetParam -name 'treatWarningsAsErrors' -default $bcContainerHelperConfig.TreatWarningsAsErrors)
$outputTo = GetParam -name 'outputTo' -default { Param($line) Write-Host $line }

$startTime = [DateTime]::Now

$containerFolder = Join-Path $bcContainerHelperConfig.hostHelperFolder "Extensions\$containerName"
if (!(Test-Path $containerFolder)) {
    throw "Build container doesn't exist"
}

Write-Host "Using Symbols Folder: $appSymbolsFolder"
if (!(Test-Path -Path $appSymbolsFolder -PathType Container)) {
    New-Item -Path $appSymbolsFolder -ItemType Directory | Out-Null
}

$GenerateReportLayoutParam = ""
if (($GenerateReportLayout -ne "NotSpecified") -and ($platformversion.Major -ge 14)) {
    if ($GenerateReportLayout -eq "Yes") {
        $GenerateReportLayoutParam = "/GenerateReportLayout+"
    }
    else {
        $GenerateReportLayoutParam = "/GenerateReportLayout-"
    }
}

$CustomCodeCops | ForEach-Object {
    if (!(Test-Path $_ -PathType Leaf)) {
        throw "The custom code cop ($_) does not exist"
    }
}

if ($rulesetFile -and !(Test-Path $rulesetFile -PathType Leaf)) {
    throw "RuleSetFile ($ruleSetFile) does not exist"
}

$appJsonFile = Join-Path $appProjectFolder 'app.json'
$appJsonObject = [System.IO.File]::ReadAllLines($appJsonFile) | ConvertFrom-Json
if ($appName -eq '') {
    $appName = "$($appJsonObject.Publisher)_$($appJsonObject.Name)_$($appJsonObject.Version).app".Split([System.IO.Path]::GetInvalidFileNameChars()) -join ''
}

$vsixPath = Join-Path $containerFolder 'vsix'
$symbolsPath = Join-Path $ENV:GITHUB_WORKSPACE '.artifactcache'

# Copy Symbols from artifacts cache
Get-ChildItem -Path $symbolsPath -Filter '*.app' -Recurse | ForEach-Object {
    $symbolFileName = Join-Path $appSymbolsFolder $_.Name
    if (!(Test-Path $symbolFileName)) { Copy-Item -Path $_.FullName -Destination $symbolFileName } 
}

$binPath = Join-Path $vsixPath 'extension/bin'
if ($isLinux) {
    $alcPath = Join-Path $binPath 'linux'
    $alcExe = 'alc'
}
else {
    $alcPath = Join-Path $binPath 'win32'
    $alcExe = 'alc.exe'
}
if (-not (Test-Path $alcPath)) {
    $alcPath = $binPath
}

$appOutputFile = Join-Path $appOutputFolder $appName
Write-Host "Compiling..."

Set-Location -Path $alcPath

$alcItem = Get-Item -Path (Join-Path $alcPath $alcExe)
[System.Version]$alcVersion = $alcItem.VersionInfo.FileVersion

$alcParameters = @("/project:""$($appProjectFolder.TrimEnd('/\'))""", "/packagecachepath:""$($appSymbolsFolder.TrimEnd('/\'))""", "/out:""$appOutputFile""")
if ($GenerateReportLayoutParam) {
    $alcParameters += @($GenerateReportLayoutParam)
}

if ($EnableCodeCop) {
    $alcParameters += @("/analyzer:$(Join-Path $binPath 'Analyzers\Microsoft.Dynamics.Nav.CodeCop.dll')")
}
if ($EnableAppSourceCop) {
    $alcParameters += @("/analyzer:$(Join-Path $binPath 'Analyzers\Microsoft.Dynamics.Nav.AppSourceCop.dll')")
}
if ($EnablePerTenantExtensionCop) {
    $alcParameters += @("/analyzer:$(Join-Path $binPath 'Analyzers\Microsoft.Dynamics.Nav.PerTenantExtensionCop.dll')")
}
if ($EnableUICop) {
    $alcParameters += @("/analyzer:$(Join-Path $binPath 'Analyzers\Microsoft.Dynamics.Nav.UICop.dll')")
}

if ($CustomCodeCops.Count -gt 0) {
    $CustomCodeCops | ForEach-Object { $alcParameters += @("/analyzer:$_") }
}

if ($rulesetFile) {
    $alcParameters += @("/ruleset:$rulesetfile")
}

if ($nowarn) {
    $alcParameters += @("/nowarn:$nowarn")
}

if ($GenerateCrossReferences) {
    $alcParameters += @("/generatecrossreferences")
}

if ($ReportSuppressedDiagnostics) {
    if ($alcVersion -ge [System.Version]"9.1.0.0") {
        $alcParameters += @("/reportsuppresseddiagnostics")
    }
    else {
        Write-Host -ForegroundColor Yellow "ReportSuppressedDiagnostics was specified, but the version of the AL Language Extension does not support this. Get-LatestAlLanguageExtensionUrl returns a location for the latest AL Language Extension"
    }
}

if ($assemblyProbingPaths) {
    $alcParameters += @("/assemblyprobingpaths:$assemblyProbingPaths")
}

if ($features) {
    $alcParameters +=@("/features:$($features -join ',')")
}

$preprocessorSymbols | where-Object { $_ } | ForEach-Object { $alcParameters += @("/D:$_") }

Write-Host ".\$alcExe $([string]::Join(' ', $alcParameters))"
$result = & ".\$alcExe" $alcParameters | Out-String

if ($lastexitcode -ne 0 -and $lastexitcode -ne -1073740791) {
    "App generation failed with exit code $lastexitcode"
}

if ($treatWarningsAsErrors) {
    $regexp = ($treatWarningsAsErrors | ForEach-Object { if ($_ -eq '*') { ".*" } else { $_ } }) -join '|'
    $result = $result | ForEach-Object { $_ -replace "^(.*)warning ($regexp):(.*)`$", '$1error $2:$3' }
}

$devOpsResult = ""
if ($result) {
    if ($gitHubActions) {
        $devOpsResult = Convert-ALCOutputToAzureDevOps -FailOn $FailOn -AlcOutput $result -DoNotWriteToHost -gitHubActions -basePath $ENV:GITHUB_WORKSPACE
    }
    else {
        $devOpsResult = Convert-ALCOutputToAzureDevOps -FailOn $FailOn -AlcOutput $result -DoNotWriteToHost
    }
}
if ($AzureDevOps -or $gitHubActions) {
    $devOpsResult | ForEach-Object { $outputTo.Invoke($_) }
}
else {
    $result | ForEach-Object { $outputTo.Invoke($_) }
    if ($devOpsResult -like "*task.complete result=Failed*") {
        throw "App generation failed"
    }
}

$result | Where-Object { $_ -like "App generation failed*" } | ForEach-Object { throw $_ }

$timespend = [Math]::Round([DateTime]::Now.Subtract($startTime).Totalseconds)
$appFile = Join-Path $appOutputFolder $appName

if (Test-Path -Path $appFile) {
    Write-Host "$appFile successfully created in $timespend seconds"
    if ($CopyAppToSymbolsFolder) {
        Copy-Item -Path $appFile -Destination $appSymbolsFolder
    }
}
else {
    throw "App generation failed"
}
$appFile
