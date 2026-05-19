#requires -version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ProgramFiles\VM Partition Workbench"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'Run this uninstaller from an elevated PowerShell session.'
}

$startMenuDir = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\VM Partition Workbench'
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'VM Partition Workbench.lnk'

Remove-Item -LiteralPath $startMenuDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'VM Partition Workbench removed.'
