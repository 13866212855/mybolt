# ==================================================================
# mybolt (bolt.diy) - Local Docker Deployment Script (PowerShell engine)
# Bootstrap: redeploy.bat (2-line launcher, LF/CRLF immune)
# Image/Container: mybolt   Host port: 7510 -> 5173 (vite preview)
# ==================================================================

# Read one value from the local .env file (git-ignored), so that no API key
# is ever stored in this script or in the repository. Returns "" if not found.
function Get-DotEnvValue([string]$Name) {
    $envFile = Join-Path $PSScriptRoot ".env"
    if (-not (Test-Path $envFile)) { return "" }
    foreach ($line in Get-Content -Path $envFile) {
        $t = $line.Trim()
        if ($t -eq "" -or $t.StartsWith("#")) { continue }
        $i = $t.IndexOf("=")
        if ($i -lt 1) { continue }
        if ($t.Substring(0, $i).Trim() -eq $Name) {
            $v = $t.Substring($i + 1).Trim()
            if ($v -match '^([''"])(.*?)\1') {
                $v = $Matches[2].Trim()
            } else {
                $v = ($v -replace '\s+#.*$', '').Trim()
            }
            return $v
        }
    }
    return ""
}

$ImageName     = "mybolt"
$ContainerName = "mybolt"
$HostPort      = "7510"
$InternalPort  = "5173"
# No database in this project -> no volume mount
$VolumeMount   = ""

# LLM endpoint comes from the local .env file:
#   OPENAI_LIKE_API_BASE_URL / OPENAI_LIKE_API_KEY
$ApiBaseUrl    = Get-DotEnvValue "OPENAI_LIKE_API_BASE_URL"
$ApiKey        = Get-DotEnvValue "OPENAI_LIKE_API_KEY"

Set-Location -Path $PSScriptRoot

Write-Host "========================================"
Write-Host " $ImageName - Docker Deployment (Windows)"
Write-Host "========================================"
Write-Host ""

if ($ApiKey -eq "" -or $ApiBaseUrl -eq "") {
    Write-Host "[WARNING] OPENAI_LIKE_API_BASE_URL / OPENAI_LIKE_API_KEY not found in .env."
    Write-Host "          The OpenAI-Like provider will NOT be pre-configured in the container."
    Write-Host ""
}

Write-Host "[1/4] Building Docker image..."
# Multi-stage Dockerfile: the LAST stage is "development" (dev server),
# so explicitly target the production stage
docker build -t "${ImageName}:latest" --target bolt-ai-production .
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Docker build failed. Deployment aborted."
    exit 1
}
Write-Host "Build successful."
Write-Host ""

Write-Host "[2/4] Stopping and removing old container..."
docker stop $ContainerName 2>$null
docker rm $ContainerName 2>$null
Write-Host "Done."
Write-Host ""

Write-Host "[3/4] Cleaning up dangling images..."
docker images $ImageName -q --filter "dangling=true" | ForEach-Object { docker rmi $_ 2>$null }
Write-Host "Done."
Write-Host ""

Write-Host "[4/4] Starting new container..."
$runArgs = @("run", "-d", "--name", $ContainerName, "-p", "${HostPort}:${InternalPort}")
if ($ApiBaseUrl -ne "") { $runArgs += @("-e", "OPENAI_LIKE_API_BASE_URL=$ApiBaseUrl") }
if ($ApiKey -ne "") { $runArgs += @("-e", "OPENAI_LIKE_API_KEY=$ApiKey") }
if ($VolumeMount -ne "") { $runArgs += $VolumeMount.Split(" ") }
$runArgs += @("--restart", "unless-stopped", "${ImageName}:latest")
docker @runArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to start Docker container."
    exit 1
}
Write-Host ""

Write-Host "[Verify] Waiting 3 seconds, then checking container status..."
Start-Sleep -Seconds 3
docker ps | Select-String $ContainerName
Write-Host ""

Write-Host "========================================"
Write-Host " Deployment Successful!"
Write-Host " Access URL: http://localhost:$HostPort"
Write-Host "========================================"
