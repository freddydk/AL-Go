Get-Module TestActionsHelper | Remove-Module -Force
Import-Module (Join-Path $PSScriptRoot 'TestActionsHelper.psm1')

Describe "Build Power Platform Settings Action Tests" {
    BeforeAll {
        $actionName = "BuildPowerPlatform"
        $scriptRoot = Join-Path $PSScriptRoot "..\Actions\$actionName" -Resolve
        $scriptName = "$actionName.ps1"
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'scriptPath', Justification = 'False positive.')]
        $scriptPath = Join-Path $scriptRoot $scriptName
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'actionScript', Justification = 'False positive.')]
        $actionScript = GetActionScript -scriptRoot $scriptRoot -scriptName $scriptName

        $testDataPath = Join-Path $PSScriptRoot "PowerPlatformTestData\*";
        $testDataTempPath = Join-Path $PSScriptRoot "PowerPlatformTestData_temp";

        Invoke-Expression $actionScript
    }

    BeforeEach {
        Write-Host "Before test"
        mkdir $testDataTempPath -Force
        copy-item -Path $testDataPath -Destination $testDataTempPath -Recurse -Force
    }

    AfterEach {
        Write-Host "After test"
        Remove-Item -Path $testDataTempPath -Recurse -Force
    }

    It 'Updates the solution file' {

        # The old version is hardcoded in the test data
        $oldVersionString = "1.0.0.0"

        $newBuildString = "222"
        $newRevisionString = "999"
        $newVersionString = "1.0.$newBuildString.$newRevisionString"

        $testSolutionFileBeforeTest = [xml](Get-Content -Encoding UTF8 -Path "$testDataTempPath\other\solution.xml")
        $versionNode = $testSolutionFileBeforeTest.SelectSingleNode("//Version")
        $versionNodeText = $versionNode.'#text'
        $versionNodeText | Should -Not -BeNullOrEmpty
        $versionNodeText | Should -Contain $oldVersionString
        
        BuildPowerPlatform -solutionFolder $testDataTempPath -appBuild $newBuildString -appRevision $newRevisionString

        $testSolutionFileAfterTest = [xml](Get-Content -Encoding UTF8 -Path "$testDataTempPath\other\solution.xml")
        $versionNode = $testSolutionFileAfterTest.SelectSingleNode("//Version")
        $versionNodeText = $versionNode.'#text'
        $versionNodeText | Should -Not -BeNullOrEmpty
        $versionNodeText | Should -Not -Contain $oldVersionString
        $versionNodeText | Should -Contain $newVersionString
    }

    It 'Updates the Power App connections' {
        # note: The old company name and environment name are hardcoded in the test data
        $oldCompanyName = "TestCompanyId"
        $oldEnvironmentName = "TestEnvironmentName"

        $newCompanyName = "NewCompanyName"
        $newEnvironmentName = "NewEnvironmentName"

        # Check file content before running the script
        $connectionFileContent = [string](Get-Content -Encoding UTF8 -Path "$testDataTempPath\CanvasApps\src\TestApp\Connections\Connections.json")
        $connectionFileContent | Should -Not -BeNullOrEmpty
        $connectionFileContent | Should -Match $oldCompanyName
        $connectionFileContent | Should -Match $oldEnvironmentName
        $connectionFileContent | Should -Not -Match $newCompanyName
        $connectionFileContent | Should -Not -Match $newEnvironmentName
        $workflowFileContent = [string](Get-Content -Encoding UTF8 -Path "$testDataTempPath\workflows\TestWorkflow-ABA81736-12D9-ED11-A7C7-000D3A991110.json")
        $workflowFileContent | Should -Not -BeNullOrEmpty
        $workflowFileContent | Should -Match $oldCompanyName
        $workflowFileContent | Should -Match $oldEnvironmentName
        $workflowFileContent | Should -Not -Match $newCompanyName
        $workflowFileContent | Should -Not -Match $newEnvironmentName
        
        # Run the script
        BuildPowerPlatform -solutionFolder $testDataTempPath -CompanyId $newCompanyName -EnvironmentName $newEnvironmentName

        # Check file content after running the script
        $connectionFileContent = [string](Get-Content -Encoding UTF8 -Path "$testDataTempPath\CanvasApps\src\TestApp\Connections\Connections.json")
        $connectionFileContent | Should -Not -BeNullOrEmpty
        $connectionFileContent | Should -Not -Match $oldCompanyName
        $connectionFileContent | Should -Not -Match $oldEnvironmentName
        $connectionFileContent | Should -Match $newCompanyName
        $connectionFileContent | Should -Match $newEnvironmentName

        $workflowFileContent = [string](Get-Content -Encoding UTF8 -Path "$testDataTempPath\workflows\TestWorkFlow-ABA81736-12D9-ED11-A7C7-000D3A991110.json")
        $workflowFileContent | Should -Not -BeNullOrEmpty
        $workflowFileContent | Should -Not -Match $oldCompanyName
        $workflowFileContent | Should -Not -Match $oldEnvironmentName
        $workflowFileContent | Should -Match $newCompanyName
        $workflowFileContent | Should -Match $newEnvironmentName
    }

    # It 'Test action.yaml matches script' {
    #     $permissions = [ordered]@{
    #     }
    #     $outputs = [ordered]@{
    #         "GitHubRunnerJson" = "GitHubRunner in compressed Json format"
    #         "GitHubRunnerShell" = "Shell for GitHubRunner jobs"
    #     }
    #     YamlTest -scriptRoot $scriptRoot -actionName $actionName -actionScript $actionScript -permissions $permissions -outputs $outputs
    # }

    # Call action

}
