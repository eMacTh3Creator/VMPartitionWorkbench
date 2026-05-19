#requires -version 5.1
[CmdletBinding()]
param(
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$srcDir = Join-Path $repoRoot 'src'
$releaseDir = Join-Path $repoRoot 'release'
$assetDir = Join-Path $repoRoot 'assets'
$scriptPath = Join-Path $srcDir 'VMPartitionWorkbench.ps1'
$exePath = Join-Path $releaseDir 'VMPartitionWorkbench.exe'
$cmdPath = Join-Path $srcDir 'Run-VMPartitionWorkbench.cmd'
$iconPath = Join-Path $assetDir 'vm-partition-workbench.ico'

New-Item -ItemType Directory -Force -Path $releaseDir, $assetDir | Out-Null

if (-not (Test-Path -LiteralPath $iconPath)) {
    & (Join-Path $PSScriptRoot 'New-VisualAssets.ps1') | Out-Host
}

$ps2exeModule = Get-Module -ListAvailable ps2exe | Select-Object -First 1
if ($ps2exeModule) {
    Import-Module $ps2exeModule.Path -ErrorAction Stop
}
else {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $candidateModules = @(
        (Join-Path $documents 'PowerShell\Modules\ps2exe\*\ps2exe.psd1'),
        (Join-Path $documents 'WindowsPowerShell\Modules\ps2exe\*\ps2exe.psd1')
    )
    $modulePath = $candidateModules |
        ForEach-Object { Get-ChildItem -Path $_ -ErrorAction SilentlyContinue } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $modulePath) {
        throw 'PS2EXE module was not found. Install it with: Install-Module ps2exe -Scope CurrentUser'
    }
    Import-Module $modulePath -ErrorAction Stop
}

$ps2exeArgs = @{
    inputFile     = $scriptPath
    outputFile    = $exePath
    title         = 'VM Partition Workbench'
    description   = 'VMware-oriented virtual disk partition maintenance workbench'
    company       = 'Open Source'
    product       = 'VM Partition Workbench'
    version       = '0.1.0.0'
    copyright     = 'MIT'
    x64           = $true
    STA           = $true
    noConsole     = $true
    requireAdmin  = $true
    DPIAware      = $true
    supportOS     = $true
}

if (Test-Path -LiteralPath $iconPath) {
    $ps2exeArgs.iconFile = $iconPath
}

Invoke-ps2exe @ps2exeArgs

Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $releaseDir 'VMPartitionWorkbench.ps1') -Force
Copy-Item -LiteralPath $cmdPath -Destination (Join-Path $releaseDir 'Run-VMPartitionWorkbench.cmd') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $releaseDir 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $releaseDir 'LICENSE') -Force

$releaseInstallerDir = Join-Path $releaseDir 'installer'
New-Item -ItemType Directory -Force -Path $releaseInstallerDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'installer\Install-VMPartitionWorkbench.ps1') -Destination $releaseInstallerDir -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'installer\Uninstall-VMPartitionWorkbench.ps1') -Destination $releaseInstallerDir -Force

$readmeText = @(
    'VM Partition Workbench portable release',
    '',
    'Run VMPartitionWorkbench.exe as administrator.',
    'The script version is included for auditing and CLI usage:',
    '  powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\VMPartitionWorkbench.ps1',
    '',
    'Close VMs and take snapshots before partition work.'
)
Set-Content -LiteralPath (Join-Path $releaseDir 'README.txt') -Value $readmeText -Encoding ASCII

$zipPath = Join-Path $releaseDir 'VMPartitionWorkbench-portable.zip'
Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
$preZipHashRows = Get-ChildItem -LiteralPath $releaseDir -File -Recurse |
    Where-Object { $_.Name -notin @('checksums.txt', 'VMPartitionWorkbench-portable.zip') } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        $relative = $_.FullName.Substring($releaseDir.Length + 1)
        '{0}  {1}' -f $hash.Hash, $relative
    }
Set-Content -LiteralPath (Join-Path $releaseDir 'checksums.txt') -Value $preZipHashRows -Encoding ASCII

$zipSources = @(
    (Join-Path $releaseDir 'VMPartitionWorkbench.exe'),
    (Join-Path $releaseDir 'VMPartitionWorkbench.ps1'),
    (Join-Path $releaseDir 'Run-VMPartitionWorkbench.cmd'),
    (Join-Path $releaseDir 'README.md'),
    (Join-Path $releaseDir 'README.txt'),
    (Join-Path $releaseDir 'LICENSE'),
    (Join-Path $releaseDir 'checksums.txt'),
    (Join-Path $releaseDir 'installer')
)

$compressed = $false
for ($attempt = 1; $attempt -le 5 -and -not $compressed; $attempt++) {
    try {
        Start-Sleep -Milliseconds (400 * $attempt)
        Compress-Archive -Path $zipSources -DestinationPath $zipPath -Force
        $compressed = $true
    }
    catch {
        if ($attempt -eq 5) {
            throw
        }
        Write-Warning "Zip attempt $attempt failed: $($_.Exception.Message)"
    }
}

$hashRows = Get-ChildItem -LiteralPath $releaseDir -File -Recurse |
    Where-Object { $_.Name -ne 'checksums.txt' } |
    Sort-Object FullName |
    ForEach-Object {
        $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
        $relative = $_.FullName.Substring($releaseDir.Length + 1)
        '{0}  {1}' -f $hash.Hash, $relative
    }
Set-Content -LiteralPath (Join-Path $releaseDir 'checksums.txt') -Value $hashRows -Encoding ASCII

Write-Host "Release built: $exePath"
Write-Host "Portable zip: $zipPath"
