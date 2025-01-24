$script:realTokenCache = @{
    "token" = ''
    "repository" = ''
    "realToken" = ''
    "permissions" = ''
    "expires" = [datetime]::Now
}

<#
 .SYNOPSIS
  This function will return the Access Token based on the gitHubAppClientId and privateKey
  This GitHub App must be installed in the repositories for which the access is requested
  The permissions of the GitHub App must include the permissions requested
 .PARAMETER gitHubAppClientId
  The GitHub App Client ID
 .Parameter privateKey
  The GitHub App Private Key
 .PARAMETER api_url
  The GitHub API URL
 .PARAMETER repository
  The Current GitHub repository
 .PARAMETER repositories
  The repositories to request access to
 .PARAMETER permissions
  The permissions to request for the Access Token
#>
function GetGitHubAppAuthToken {
    Param(
        [string] $gitHubAppClientId,
        [string] $privateKey,
        [string] $api_url = $ENV:GITHUB_API_URL,
        [string] $repository,
        [hashtable] $permissions = @{},
        [string[]] $repositories = @()
    )

    Write-Host "Using GitHub App with ClientId $gitHubAppClientId for authentication"
    $jwt = GenerateJwtForTokenRequest -gitHubAppClientId $gitHubAppClientId -privateKey $privateKey
    $headers = @{
        "Accept" = "application/vnd.github+json"
        "Authorization" = "Bearer $jwt"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    Write-Host "Get App Info $api_url/repos/$repository/installation"
    $appinfo = Invoke-RestMethod -Method GET -UseBasicParsing -Headers $headers -Uri "$api_url/repos/$repository/installation"
    $body = @{}
    # If repositories are provided, limit the requested repositories to those
    if ($repositories) {
        $body += @{ "repositories" = @($repositories | ForEach-Object { $_.SubString($_.LastIndexOf('/')+1) } ) }
    }
    # If permissions are provided, limit the requested permissions to those
    if ($permissions) {
        $body += @{ "permissions" = $permissions }
    }
    Write-Host "Get Token Response $($appInfo.access_tokens_url) with $($body | ConvertTo-Json -Compress)"
    $tokenResponse = Invoke-RestMethod -Method POST -UseBasicParsing -Headers $headers -Body ($body | ConvertTo-Json -Compress) -Uri $appInfo.access_tokens_url
    Write-Host "return token"
    return $tokenResponse.token, $tokenResponse.expires_in
}

<#
 .SYNOPSIS
  Generate JWT for token request
  As documented here: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
 .PARAMETER gitHubAppClientId
  The GitHub App Client ID
 .Parameter privateKey
  The GitHub App Private Key
#>
function GenerateJwtForTokenRequest {
    Param(
        [string] $gitHubAppClientId,
        [string] $privateKey
    )

    $header = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{
        alg = "RS256"
        typ = "JWT"
    }))).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    $payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{
        iat = [System.DateTimeOffset]::UtcNow.AddSeconds(-10).ToUnixTimeSeconds()
        exp = [System.DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
        iss = $gitHubAppClientId
    }))).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    $signature = pwsh -command {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $privateKey = "$($args[1])"
        $rsa.ImportFromPem($privateKey)
        $signature = [Convert]::ToBase64String($rsa.SignData([System.Text.Encoding]::UTF8.GetBytes($args[0]), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        Write-OutPut $signature
    } -args "$header.$payload", $privateKey
    return "$header.$payload.$signature"
}

<#
 .SYNOPSIS
  This function will return the GitHub Access Token.
  If the given token is a Personal Access Token, it will be returned unaltered
  If the given token is a GitHub App token, it will be used to get an Access Token from GitHub
 .PARAMETER token
  The given token (PAT or GitHub App token)
 .PARAMETER api_url
  The GitHub API URL
 .PARAMETER repository
  The Current GitHub repository
 .PARAMETER repositories
  The repositories to request access to
 .PARAMETER permissions
  The permissions to request for the Access Token
#>
function GetAccessToken {
    Param(
        [string] $token,
        [string] $api_url = $ENV:GITHUB_API_URL,
        [string] $repository = $ENV:GITHUB_REPOSITORY,
        [string[]] $repositories = @($repository),
        [hashtable] $permissions = @{}
    )

    if ([string]::IsNullOrEmpty($token)) {
        return [string]::Empty
    }

    if (($script:realTokenCache.token -eq $token -or $script:realTokenCache.realToken -eq $token) -and
        $script:realTokenCache.repository -eq $repository -and
        $script:realTokenCache.permissions -eq ($permissions | ConvertTo-Json -Compress) -and
        $script:realTokenCache.expires -gt [datetime]::Now.AddMinutes(10)) {
        # Same token request or re-request with cached token - and cached token won't expire in 10 minutes
        return $script:realTokenCache.realToken
    }
    elseif (!($token.StartsWith("{"))) {
        # a PAT token, return it as is
        return $token
    }
    else {
        # GitHub App token format: {"GitHubAppClientId":"<client_id>","PrivateKey":"<private_key>"}
        try {
            $json = $token | ConvertFrom-Json
            $realToken, $expiresIn = GetGitHubAppAuthToken -gitHubAppClientId $json.GitHubAppClientId -privateKey $json.PrivateKey -api_url $api_url -repository $repository -repositories $repositories -permissions $permissions
            $script:realTokenCache = @{
                "token" = $token
                "repository" = $repository
                "realToken" = $realToken
                "permissions" = $permissions | ConvertTo-Json -Compress
                "expires" = [datetime]::Now.AddSeconds($expiresIn)
            }
            return $realToken
        }
        catch {
            throw "Error getting access token from GitHub App. The error was ($($_.Exception.Message))"
        }
    }
}

<#
 .SYNOPSIS
  This function will return the headers for the GitHub API request
 .PARAMETER token
  The GitHub token
 .PARAMETER accept
  The Accept header value
 .PARAMETER apiVersion
  The X-GitHub-Api-Version header value
 .PARAMETER api_url
  The GitHub API URL
 .PARAMETER repository
  The Current GitHub repository
#>
function GetHeaders {
    param (
        [string] $token,
        [string] $accept = "application/vnd.github+json",
        [string] $apiVersion = "2022-11-28",
        [string] $api_url = $ENV:GITHUB_API_URL,
        [string] $repository = $ENV:GITHUB_REPOSITORY
    )
    $headers = @{
        "Accept" = $accept
        "X-GitHub-Api-Version" = $apiVersion
    }
    if (![string]::IsNullOrEmpty($token)) {
        $accessToken = GetAccessToken -token $token -api_url $api_url -repository $repository -permissions @{"contents"="read";"metadata"="read";"actions"="read"}
        $headers["Authorization"] = "token $accessToken"
    }
    return $headers
}


Export-ModuleMember -Function GetAccessToken, GetHeaders
