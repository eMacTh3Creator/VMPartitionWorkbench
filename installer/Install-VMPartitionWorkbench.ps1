#requires -version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\VM Partition Workbench",
    [switch]$NoDesktopShortcut
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this installer from an elevated PowerShell session.'
}

$sourceDir = Split-Path -Parent $PSScriptRoot
$releaseRoot = if (Test-Path -LiteralPath (Join-Path $sourceDir 'release')) {
    Join-Path $sourceDir 'release'
}
else {
    $sourceDir
}

$releaseExe = Get-ChildItem -LiteralPath $releaseRoot -Filter 'VMPartitionWorkbench-v*-win-x64.exe' -File -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $releaseExe) {
    $fallbackExe = Join-Path $releaseRoot 'VMPartitionWorkbench.exe'
    if (Test-Path -LiteralPath $fallbackExe) {
        $releaseExe = $fallbackExe
    }
}
if (-not $releaseExe) {
    throw "Release executable not found in $releaseRoot"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $releaseExe -Destination (Join-Path $InstallDir 'VMPartitionWorkbench.exe') -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'README.md') -Destination (Join-Path $InstallDir 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $sourceDir 'LICENSE') -Destination (Join-Path $InstallDir 'LICENSE') -Force

$shell = New-Object -ComObject WScript.Shell
$startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\VM Partition Workbench'
New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
$shortcut = $shell.CreateShortcut((Join-Path $startMenuDir 'VM Partition Workbench.lnk'))
$shortcut.TargetPath = Join-Path $InstallDir 'VMPartitionWorkbench.exe'
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Description = 'VMware-oriented virtual disk partition workbench'
$shortcut.Save()

if (-not $NoDesktopShortcut) {
    $desktopShortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'VM Partition Workbench.lnk'))
    $desktopShortcut.TargetPath = Join-Path $InstallDir 'VMPartitionWorkbench.exe'
    $desktopShortcut.WorkingDirectory = $InstallDir
    $desktopShortcut.Description = 'VMware-oriented virtual disk partition workbench'
    $desktopShortcut.Save()
}

Write-Host "Installed to $InstallDir"
