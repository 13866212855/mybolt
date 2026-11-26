# ==================================================================
# mybolt (bolt.diy) - Remote Deployment Script (PowerShell engine)
# Bootstrap: upload2remote.bat (2-line launcher, LF/CRLF immune)
# Builds image locally, saves to tar, scp to remote, docker load + run
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

# ====== CONFIGURABLE VARIABLES ======
$ImageName     = "mybolt"
$ContainerName = "mybolt"
$ContainerPort = "7510"
$InternalPort  = "5173"
# No database in this project -> no volume mount
$VolumeMount   = ""

# LLM endpoint comes from the local .env file:
#   OPENAI_LIKE_API_BASE_URL / OPENAI_LIKE_API_KEY
$ApiBaseUrl    = Get-DotEnvValue "OPENAI_LIKE_API_BASE_URL"
$ApiKey        = Get-DotEnvValue "OPENAI_LIKE_API_KEY"

$TarDir  = "d:\temp\tar"
$TarFile = Join-Path $TarDir "$ImageName.tar"

$RemoteUser     = "gpzx"
$RemoteHost     = "172.29.173.42"
$RemotePassword = "9520111"
$RemoteTarDir   = "/bak/tar"
$NetworkName    = "mynet"
$RemoteTarget   = "$RemoteUser@$RemoteHost"

Write-Host "========================================================"
Write-Host "   Deploying $ImageName to Remote Server"
Write-Host "========================================================"
Write-Host ""

Set-Location -Path $PSScriptRoot

if ($ApiKey -eq "" -or $ApiBaseUrl -eq "") {
    Write-Host "[WARNING] OPENAI_LIKE_API_BASE_URL / OPENAI_LIKE_API_KEY not found in .env."
    Write-Host "          The OpenAI-Like provider will NOT be pre-configured in the container."
    Write-Host ""
}

Write-Host "[Step 1/8] Running MCP Server script if exists..."
if (Test-Path "skills\my_create_mcp\my_create_mcp.js") {
    node "skills\my_create_mcp\my_create_mcp.js"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] MCP Server generation script failed!"
        exit 1
    }
} else {
    Write-Host "[INFO] MCP Server generation script not found, skipping."
}
Write-Host ""

Write-Host "[Step 2/8] Checking local temp directories..."
if (-not (Test-Path $TarDir)) {
    New-Item -ItemType Directory -Path $TarDir | Out-Null
    Write-Host "Created directory: $TarDir"
} else {
    Write-Host "Directory already exists: $TarDir"
}
Write-Host ""

Write-Host "[Step 3/8] Building Docker image locally..."
# Multi-stage Dockerfile: the LAST stage is "development" (dev server),
# so explicitly target the production stage
docker build -t $ImageName --target bolt-ai-production .
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Local Docker image build failed!"
    exit 1
}
Write-Host "[SUCCESS] Docker image built successfully!"
Write-Host ""

Write-Host "[Step 4/8] Saving Docker image to tar file..."
docker save -o $TarFile $ImageName
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Docker image save failed!"
    exit 1
}
Write-Host "[SUCCESS] Image saved to $TarFile"
Write-Host ""

Write-Host "[Step 5/8] Uploading image tar to remote server..."
Write-Host "Uploading to ${RemoteTarget}:$RemoteTarDir/"
Write-Host "Note: If prompted for password, enter: $RemotePassword"
# Push-Location + bare filename: a drive-letter path (d:\...) would be
# mistaken by scp as host:path because of the colon
Push-Location $TarDir
scp "$ImageName.tar" "${RemoteTarget}:$RemoteTarDir/"
$scpExit = $LASTEXITCODE
Pop-Location
if ($scpExit -ne 0) {
    Write-Host "[ERROR] SCP upload failed! Please verify OpenSSH client and remote server accessibility."
    exit 1
}
Write-Host "[SUCCESS] File uploaded successfully!"
Write-Host ""

Write-Host "[Step 6/8] Loading image on remote server..."
ssh $RemoteTarget "docker load -i $RemoteTarDir/$ImageName.tar"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Remote docker load failed!"
    exit 1
}
Write-Host "[SUCCESS] Remote docker load succeeded!"
Write-Host ""

Write-Host "[Step 7/8] Preparing remote directories and permissions..."
ssh $RemoteTarget "mkdir -p /bak/docker/$ImageName && chmod -R 777 /bak/docker/$ImageName"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[WARNING] Remote directory preparation encountered issues. Continuing..."
} else {
    Write-Host "[SUCCESS] Remote directory prepared successfully!"
}
Write-Host ""

Write-Host "[Step 8/8] Stopping existing container and running new container..."
$runArgs = @("run", "-d", "--name", $ContainerName, "-p", "${ContainerPort}:${InternalPort}")
if ($ApiBaseUrl -ne "") { $runArgs += @("-e", "OPENAI_LIKE_API_BASE_URL=$ApiBaseUrl") }
if ($ApiKey -ne "") { $runArgs += @("-e", "OPENAI_LIKE_API_KEY=$ApiKey") }
if ($VolumeMount -ne "") { $runArgs += $VolumeMount.Split(" ") }
$runArgs += @("--network", $NetworkName, "--restart", "unless-stopped", $ImageName)
$remoteCmd = "docker stop $ContainerName 2>/dev/null || true; docker rm $ContainerName 2>/dev/null || true; docker " + ($runArgs -join " ")
ssh $RemoteTarget $remoteCmd
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to start remote container!"
    exit 1
}
Write-Host "[SUCCESS] Remote container started successfully!"
Write-Host ""

Write-Host "[Verification] Waiting 3 seconds to check container status..."
Start-Sleep -Seconds 3
ssh $RemoteTarget "docker ps" | Select-String $ContainerName
Write-Host ""

Write-Host "========================================================"
Write-Host "   Deployment Completed Successfully!"
Write-Host "========================================================"
Write-Host " Image Name   : $ImageName"
Write-Host " Container    : $ContainerName"
Write-Host " Access URL   : http://${RemoteHost}:$ContainerPort"
Write-Host " Remote Tar   : ${RemoteHost}:$RemoteTarDir/$ImageName.tar"
