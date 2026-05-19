#requires -version 5.1
<#
VM Partition Workbench
PowerShell + WPF desktop helper for VMware-oriented virtual disk resize and
partition maintenance workflows.
#>

[CmdletBinding()]
param(
    [switch]$Cli,
    [string]$VmxPath,
    [string]$DiskPath,
    [int]$ExpandToGB,
    [string]$GPartedIsoPath,
    [switch]$PrepareGParted,
    [switch]$CreateBackup,
    [switch]$DryRun,
    [switch]$ListVmDisks
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'VM Partition Workbench'
$script:AppVersion = '0.1.0'
$script:LogLines = New-Object 'System.Collections.ObjectModel.ObservableCollection[string]'
$script:CurrentPlan = @()

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogLines) {
        [void]$script:LogLines.Add($line)
    }
    Write-Host $line
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Resolve-ExistingPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = Resolve-FullPath $Path
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Path not found: $full"
    }

    return $full
}

function Format-ByteSize {
    param([Nullable[Int64]]$Bytes)

    if ($null -eq $Bytes) {
        return 'Unknown'
    }

    $value = [double]$Bytes
    foreach ($unit in @('B', 'KB', 'MB', 'GB', 'TB')) {
        if ($value -lt 1024 -or $unit -eq 'TB') {
            return '{0:N2} {1}' -f $value, $unit
        }
        $value = $value / 1024
    }
}

function ConvertTo-CommandLineArgument {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    return '"' + ($Argument -replace '"', '\"') + '"'
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $argumentLine = ($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
    Write-AppLog ("> {0} {1}" -f $FilePath, $argumentLine)

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $FilePath
    $processInfo.Arguments = $argumentLine
    $processInfo.UseShellExecute = $false
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        $stdout -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-AppLog $_ }
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        $stderr -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-AppLog $_ 'WARN' }
    }

    if ($process.ExitCode -ne 0) {
        throw "Command failed with exit code $($process.ExitCode): $FilePath"
    }
}

function Find-Executable {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$CandidatePaths = @()
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    foreach ($candidate in $CandidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return $null
}

function Get-VMwareToolReport {
    $pf = ${env:ProgramFiles}
    $pf86 = ${env:ProgramFiles(x86)}
    $vdiskCandidates = @(
        (Join-Path $pf 'VMware\VMware Workstation\vmware-vdiskmanager.exe'),
        (Join-Path $pf86 'VMware\VMware Workstation\vmware-vdiskmanager.exe'),
        (Join-Path $pf 'VMware\VMware Virtual Disk Development Kit\bin\vmware-vdiskmanager.exe'),
        (Join-Path $pf86 'VMware\VMware Virtual Disk Development Kit\bin\vmware-vdiskmanager.exe')
    )
    $mountCandidates = @(
        (Join-Path $pf 'VMware\VMware Virtual Disk Development Kit\bin\vmware-mount.exe'),
        (Join-Path $pf86 'VMware\VMware Virtual Disk Development Kit\bin\vmware-mount.exe'),
        (Join-Path $pf 'VMware\VMware Workstation\vmware-mount.exe'),
        (Join-Path $pf86 'VMware\VMware Workstation\vmware-mount.exe')
    )

    [pscustomobject]@{
        VDiskManager = Find-Executable -Name 'vmware-vdiskmanager.exe' -CandidatePaths $vdiskCandidates
        DiskMount    = Find-Executable -Name 'vmware-mount.exe' -CandidatePaths $mountCandidates
        VMRun        = Find-Executable -Name 'vmrun.exe' -CandidatePaths @(
            (Join-Path $pf 'VMware\VMware Workstation\vmrun.exe'),
            (Join-Path $pf86 'VMware\VMware Workstation\vmrun.exe')
        )
    }
}

function Read-VmxVirtualDisks {
    param([Parameter(Mandatory = $true)][string]$Path)

    $vmx = Resolve-ExistingPath $Path
    $base = [System.IO.Path]::GetDirectoryName($vmx)
    $rows = New-Object System.Collections.Generic.List[object]

    foreach ($line in Get-Content -LiteralPath $vmx) {
        if ($line -match '^\s*(?<slot>(?:scsi|sata|ide|nvme)\d+:\d+)\.fileName\s*=\s*"(?<file>[^"]+)"') {
            $slot = $Matches.slot
            $fileName = $Matches.file
            if ($fileName -notmatch '\.(vmdk|vhd|vhdx)$') {
                continue
            }

            $resolved = if ([System.IO.Path]::IsPathRooted($fileName)) {
                $fileName
            }
            else {
                Join-Path $base $fileName
            }

            $full = Resolve-FullPath $resolved
            $info = Get-VirtualDiskInfo -Path $full -NoThrow
            [void]$rows.Add([pscustomobject]@{
                Slot     = $slot
                FileName = $fileName
                Path     = $full
                Exists   = Test-Path -LiteralPath $full
                Capacity = $info.CapacityText
                Type     = $info.Type
            })
        }
    }

    return $rows
}

function Get-VmdkDescriptorLines {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $sampleLength = [int][Math]::Min($stream.Length, 65536)
        $bytes = New-Object byte[] $sampleLength
        $read = $stream.Read($bytes, 0, $sampleLength)
        $sample = [Text.Encoding]::ASCII.GetString($bytes, 0, $read)
        if ($sample -match '# Disk DescriptorFile' -or $sample -match 'createType=' -or $sample -match '^\s*RW\s+\d+') {
            return $sample -split "`r?`n"
        }
    }
    catch {
        Write-AppLog "Unable to inspect VMDK descriptor: $($_.Exception.Message)" 'WARN'
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }

    return @()
}

function Get-VmdkExtentFiles {
    param([Parameter(Mandatory = $true)][string]$Path)

    $disk = Resolve-FullPath $Path
    $base = [System.IO.Path]::GetDirectoryName($disk)
    $files = New-Object System.Collections.Generic.List[string]
    [void]$files.Add($disk)

    foreach ($line in Get-VmdkDescriptorLines -Path $disk) {
        if ($line -match '^\s*RW\s+\d+\s+\S+\s+"(?<extent>[^"]+)"') {
            $extent = $Matches.extent
            $extentPath = if ([System.IO.Path]::IsPathRooted($extent)) {
                $extent
            }
            else {
                Join-Path $base $extent
            }
            if (-not $files.Contains($extentPath)) {
                [void]$files.Add($extentPath)
            }
        }
    }

    return $files | Select-Object -Unique
}

function Get-VmdkCapacityBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sectors = [Int64]0
    foreach ($line in Get-VmdkDescriptorLines -Path $Path) {
        if ($line -match '^\s*RW\s+(?<sectors>\d+)\s+\S+') {
            $sectors += [Int64]$Matches.sectors
        }
    }

    if ($sectors -gt 0) {
        return $sectors * 512
    }

    if (Test-Path -LiteralPath $Path) {
        return (Get-Item -LiteralPath $Path).Length
    }

    return $null
}

function Get-VirtualDiskInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$NoThrow
    )

    try {
        $full = Resolve-FullPath $Path
        $extension = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
        $capacityBytes = $null
        $type = switch ($extension) {
            '.vmdk' { 'VMDK' }
            '.vhd'  { 'VHD' }
            '.vhdx' { 'VHDX' }
            default { 'Unknown' }
        }

        if (-not (Test-Path -LiteralPath $full)) {
            return [pscustomobject]@{
                Path         = $full
                Type         = $type
                Exists       = $false
                CapacityGB   = $null
                CapacityText = 'Missing'
                FileSizeText = 'Missing'
            }
        }

        if ($extension -eq '.vmdk') {
            $capacityBytes = Get-VmdkCapacityBytes -Path $full
        }
        elseif ($extension -in @('.vhd', '.vhdx')) {
            $getVhd = Get-Command Get-VHD -ErrorAction SilentlyContinue
            if ($getVhd) {
                try {
                    $vhdInfo = Get-VHD -Path $full
                    $capacityBytes = [Int64]$vhdInfo.Size
                }
                catch {
                    $capacityBytes = (Get-Item -LiteralPath $full).Length
                }
            }
            else {
                $capacityBytes = (Get-Item -LiteralPath $full).Length
            }
        }
        else {
            $capacityBytes = (Get-Item -LiteralPath $full).Length
        }

        $capacityGb = if ($null -ne $capacityBytes) { [Math]::Round(($capacityBytes / 1GB), 2) } else { $null }
        [pscustomobject]@{
            Path         = $full
            Type         = $type
            Exists       = $true
            CapacityGB   = $capacityGb
            CapacityText = Format-ByteSize $capacityBytes
            FileSizeText = Format-ByteSize ((Get-Item -LiteralPath $full).Length)
        }
    }
    catch {
        if ($NoThrow) {
            return [pscustomobject]@{
                Path         = $Path
                Type         = 'Unknown'
                Exists       = $false
                CapacityGB   = $null
                CapacityText = 'Unknown'
                FileSizeText = 'Unknown'
            }
        }
        throw
    }
}

function New-PlanOperation {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Preview,
        [Parameter(Mandatory = $true)][object]$Data
    )

    [pscustomobject]@{
        Kind    = $Kind
        Title   = $Title
        Preview = $Preview
        Data    = $Data
    }
}

function Build-OperationPlan {
    param(
        [string]$DiskPath,
        [string]$VmxPath,
        [int]$ExpandToGB = 0,
        [bool]$CreateBackup = $true,
        [bool]$PrepareGParted = $false,
        [string]$GPartedIsoPath,
        [bool]$ResizePartition = $false,
        [int]$PartitionDiskNumber = -1,
        [int]$PartitionNumber = -1,
        [int]$PartitionSizeGB = 0,
        [bool]$ResizeToMaximum = $true
    )

    if ([string]::IsNullOrWhiteSpace($DiskPath)) {
        throw 'Choose a virtual disk first.'
    }

    $disk = Resolve-ExistingPath $DiskPath
    $extension = [System.IO.Path]::GetExtension($disk).ToLowerInvariant()
    $ops = New-Object System.Collections.Generic.List[object]
    $tools = Get-VMwareToolReport

    if ($CreateBackup) {
        [void]$ops.Add((New-PlanOperation -Kind 'Backup' -Title 'Create virtual disk backup' -Preview "Copy selected virtual disk files beside the source disk before any change." -Data ([pscustomobject]@{
            DiskPath = $disk
            VmxPath  = $VmxPath
        })))
    }

    if ($ExpandToGB -gt 0) {
        if ($extension -eq '.vmdk') {
            if (-not $tools.VDiskManager) {
                throw 'vmware-vdiskmanager.exe was not found. Install VMware Workstation or VMware VDDK, or add it to PATH.'
            }
            [void]$ops.Add((New-PlanOperation -Kind 'ExpandVmdk' -Title "Expand VMDK capacity to $ExpandToGB GB" -Preview "vmware-vdiskmanager.exe -x ${ExpandToGB}GB `"$disk`"" -Data ([pscustomobject]@{
                DiskPath = $disk
                SizeGB   = $ExpandToGB
                ToolPath = $tools.VDiskManager
            })))
        }
        elseif ($extension -in @('.vhd', '.vhdx')) {
            [void]$ops.Add((New-PlanOperation -Kind 'ExpandVhd' -Title "Expand VHD/VHDX capacity to $ExpandToGB GB" -Preview "diskpart expand vdisk maximum=$($ExpandToGB * 1024)" -Data ([pscustomobject]@{
                DiskPath = $disk
                SizeGB   = $ExpandToGB
            })))
        }
        else {
            throw "Unsupported virtual disk extension for expansion: $extension"
        }
    }

    if ($PrepareGParted) {
        if ([string]::IsNullOrWhiteSpace($VmxPath)) {
            throw 'Choose a .vmx file before preparing the GParted boot workflow.'
        }
        if ([string]::IsNullOrWhiteSpace($GPartedIsoPath)) {
            throw 'Choose a GParted Live ISO path first.'
        }
        $vmx = Resolve-ExistingPath $VmxPath
        $iso = Resolve-ExistingPath $GPartedIsoPath

        [void]$ops.Add((New-PlanOperation -Kind 'ConfigureGParted' -Title 'Attach GParted Live ISO to VMX' -Preview "Back up the VMX and set the CD-ROM to boot $iso." -Data ([pscustomobject]@{
            VmxPath = $vmx
            IsoPath = $iso
        })))
    }

    if ($ResizePartition) {
        if ($PartitionDiskNumber -lt 0 -or $PartitionNumber -lt 1) {
            throw 'Enter the mounted VM disk number and partition number before resizing.'
        }
        if (-not $ResizeToMaximum -and $PartitionSizeGB -lt 1) {
            throw 'Enter a target partition size in GB, or choose maximum supported size.'
        }

        $previewSize = if ($ResizeToMaximum) { 'maximum supported size' } else { "$PartitionSizeGB GB" }
        [void]$ops.Add((New-PlanOperation -Kind 'ResizePartition' -Title "Resize mounted partition to $previewSize" -Preview "Resize-Partition -DiskNumber $PartitionDiskNumber -PartitionNumber $PartitionNumber" -Data ([pscustomobject]@{
            DiskNumber      = $PartitionDiskNumber
            PartitionNumber = $PartitionNumber
            SizeGB          = $PartitionSizeGB
            ToMaximum       = $ResizeToMaximum
        })))
    }

    if ($ops.Count -eq 0) {
        throw 'No operations selected.'
    }

    return $ops
}

function Format-OperationPlan {
    param([object[]]$Plan)

    if (-not $Plan -or $Plan.Count -eq 0) {
        return 'No plan has been built yet.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add('Review this plan carefully. Close the VM and take a VMware snapshot before running.')
    [void]$lines.Add('')
    $index = 1
    foreach ($op in $Plan) {
        [void]$lines.Add(('{0}. {1}' -f $index, $op.Title))
        [void]$lines.Add(('   {0}' -f $op.Preview))
        $index++
    }

    return $lines -join [Environment]::NewLine
}

function Backup-VirtualDisk {
    param(
        [Parameter(Mandatory = $true)][string]$DiskPath,
        [string]$VmxPath
    )

    $disk = Resolve-ExistingPath $DiskPath
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupRoot = Join-Path ([System.IO.Path]::GetDirectoryName($disk)) ("vm-partition-backup-$timestamp")
    [void](New-Item -ItemType Directory -Path $backupRoot -Force)

    $extension = [System.IO.Path]::GetExtension($disk).ToLowerInvariant()
    $files = if ($extension -eq '.vmdk') {
        Get-VmdkExtentFiles -Path $disk
    }
    else {
        @($disk)
    }

    if ($VmxPath -and (Test-Path -LiteralPath $VmxPath)) {
        $files += (Resolve-FullPath $VmxPath)
    }

    foreach ($file in ($files | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $file) {
            $destination = Join-Path $backupRoot (Split-Path -Leaf $file)
            Write-AppLog "Backing up $file to $destination"
            Copy-Item -LiteralPath $file -Destination $destination -Force
        }
        else {
            Write-AppLog "Skipping missing VMDK extent: $file" 'WARN'
        }
    }

    Write-AppLog "Backup complete: $backupRoot" 'OK'
}

function Expand-VmdkDisk {
    param(
        [Parameter(Mandatory = $true)][string]$DiskPath,
        [Parameter(Mandatory = $true)][int]$SizeGB,
        [Parameter(Mandatory = $true)][string]$ToolPath
    )

    Invoke-NativeCommand -FilePath $ToolPath -ArgumentList @('-x', ("{0}GB" -f $SizeGB), $DiskPath)
    Write-AppLog "VMDK capacity expanded. Boot the guest or GParted to grow/move partitions." 'OK'
}

function Invoke-DiskPartScript {
    param([Parameter(Mandatory = $true)][string[]]$Lines)

    $scriptPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('vpw-diskpart-{0}.txt' -f ([guid]::NewGuid().ToString('N'))))
    try {
        Set-Content -LiteralPath $scriptPath -Value $Lines -Encoding ASCII
        Invoke-NativeCommand -FilePath 'diskpart.exe' -ArgumentList @('/s', $scriptPath)
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Expand-VhdDisk {
    param(
        [Parameter(Mandatory = $true)][string]$DiskPath,
        [Parameter(Mandatory = $true)][int]$SizeGB
    )

    $maximumMb = $SizeGB * 1024
    Invoke-DiskPartScript -Lines @(
        ('select vdisk file="{0}"' -f $DiskPath),
        ('expand vdisk maximum={0}' -f $maximumMb),
        'exit'
    )
    Write-AppLog "VHD/VHDX capacity expanded to $SizeGB GB." 'OK'
}

function Mount-VhdDisk {
    param([Parameter(Mandatory = $true)][string]$DiskPath)

    $disk = Resolve-ExistingPath $DiskPath
    Invoke-DiskPartScript -Lines @(
        ('select vdisk file="{0}"' -f $disk),
        'attach vdisk',
        'exit'
    )
    Write-AppLog "Mounted virtual disk: $disk" 'OK'
}

function Dismount-VhdDisk {
    param([Parameter(Mandatory = $true)][string]$DiskPath)

    $disk = Resolve-ExistingPath $DiskPath
    Invoke-DiskPartScript -Lines @(
        ('select vdisk file="{0}"' -f $disk),
        'detach vdisk',
        'exit'
    )
    Write-AppLog "Dismounted virtual disk: $disk" 'OK'
}

function Set-VmxLine {
    param(
        [string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escaped = [regex]::Escape($Key)
    $line = '{0} = "{1}"' -f $Key, ($Value -replace '"', '\"')
    $found = $false
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\s*$escaped\s*=") {
            $Lines[$i] = $line
            $found = $true
        }
    }

    if (-not $found) {
        $Lines += $line
    }

    return ,$Lines
}

function Configure-GPartedBoot {
    param(
        [Parameter(Mandatory = $true)][string]$VmxPath,
        [Parameter(Mandatory = $true)][string]$IsoPath
    )

    $vmx = Resolve-ExistingPath $VmxPath
    $iso = Resolve-ExistingPath $IsoPath
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$vmx.vpw-backup-$timestamp"

    Copy-Item -LiteralPath $vmx -Destination $backupPath -Force
    $lines = @(Get-Content -LiteralPath $vmx)
    $lines = Set-VmxLine -Lines $lines -Key 'ide1:0.present' -Value 'TRUE'
    $lines = Set-VmxLine -Lines $lines -Key 'ide1:0.fileName' -Value $iso
    $lines = Set-VmxLine -Lines $lines -Key 'ide1:0.deviceType' -Value 'cdrom-image'
    $lines = Set-VmxLine -Lines $lines -Key 'ide1:0.startConnected' -Value 'TRUE'
    $lines = Set-VmxLine -Lines $lines -Key 'bios.bootDelay' -Value '5000'

    Set-Content -LiteralPath $vmx -Value $lines -Encoding ASCII
    Write-AppLog "VMX updated for GParted boot. Backup: $backupPath" 'OK'
}

function Resize-MountedPartition {
    param(
        [Parameter(Mandatory = $true)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][int]$PartitionNumber,
        [int]$SizeGB,
        [bool]$ToMaximum
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($disk.IsBoot -or $disk.IsSystem) {
        throw 'Refusing to resize the Windows boot/system disk. Mount a VM disk and choose that disk number instead.'
    }

    $targetSize = if ($ToMaximum) {
        $supported = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber
        $supported.SizeMax
    }
    else {
        [Int64]$SizeGB * 1GB
    }

    Resize-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -Size $targetSize -ErrorAction Stop
    Write-AppLog "Partition resized: Disk $DiskNumber Partition $PartitionNumber -> $(Format-ByteSize $targetSize)" 'OK'
}

function Execute-PlanOperation {
    param([Parameter(Mandatory = $true)]$Operation)

    switch ($Operation.Kind) {
        'Backup' {
            Backup-VirtualDisk -DiskPath $Operation.Data.DiskPath -VmxPath $Operation.Data.VmxPath
        }
        'ExpandVmdk' {
            Expand-VmdkDisk -DiskPath $Operation.Data.DiskPath -SizeGB $Operation.Data.SizeGB -ToolPath $Operation.Data.ToolPath
        }
        'ExpandVhd' {
            Expand-VhdDisk -DiskPath $Operation.Data.DiskPath -SizeGB $Operation.Data.SizeGB
        }
        'ConfigureGParted' {
            Configure-GPartedBoot -VmxPath $Operation.Data.VmxPath -IsoPath $Operation.Data.IsoPath
        }
        'ResizePartition' {
            Resize-MountedPartition -DiskNumber $Operation.Data.DiskNumber -PartitionNumber $Operation.Data.PartitionNumber -SizeGB $Operation.Data.SizeGB -ToMaximum $Operation.Data.ToMaximum
        }
        default {
            throw "Unknown operation kind: $($Operation.Kind)"
        }
    }
}

function Get-HostDiskRows {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($disk in Get-Disk | Sort-Object Number) {
        [void]$rows.Add([pscustomobject]@{
            Number         = $disk.Number
            FriendlyName   = $disk.FriendlyName
            BusType        = $disk.BusType
            Size           = Format-ByteSize $disk.Size
            PartitionStyle = $disk.PartitionStyle
            Status         = $disk.OperationalStatus -join ', '
            Boot           = [bool]$disk.IsBoot
            System         = [bool]$disk.IsSystem
        })
    }
    return $rows
}

function Get-PartitionRows {
    param([Parameter(Mandatory = $true)][int]$DiskNumber)

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($partition in Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        [void]$rows.Add([pscustomobject]@{
            DiskNumber      = $DiskNumber
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = $partition.DriveLetter
            Type            = $partition.Type
            Size            = Format-ByteSize $partition.Size
            Offset          = Format-ByteSize $partition.Offset
            FileSystem      = if ($volume) { $volume.FileSystem } else { '' }
            Label           = if ($volume) { $volume.FileSystemLabel } else { '' }
        })
    }
    return $rows
}

function Add-WpfAssemblies {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function New-AppIconImageSource {
    Add-WpfAssemblies

    $bitmap = New-Object System.Drawing.Bitmap 256, 256
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $panel = [System.Drawing.Color]::FromArgb(24, 24, 27)
    $teal = [System.Drawing.Color]::FromArgb(15, 118, 110)
    $amber = [System.Drawing.Color]::FromArgb(245, 158, 11)
    $green = [System.Drawing.Color]::FromArgb(34, 197, 94)
    $white = [System.Drawing.Color]::FromArgb(244, 244, 245)

    $brushPanel = New-Object System.Drawing.SolidBrush($panel)
    $brushTeal = New-Object System.Drawing.SolidBrush($teal)
    $brushAmber = New-Object System.Drawing.SolidBrush($amber)
    $brushGreen = New-Object System.Drawing.SolidBrush($green)
    $brushWhite = New-Object System.Drawing.SolidBrush($white)
    $font = New-Object System.Drawing.Font('Segoe UI', 34, [System.Drawing.FontStyle]::Bold)

    function Add-IconRoundedRect {
        param(
            [System.Drawing.Graphics]$Graphics,
            [System.Drawing.Brush]$Brush,
            [System.Drawing.RectangleF]$Rectangle,
            [float]$Radius
        )

        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $diameter = $Radius * 2
        $arc = [System.Drawing.RectangleF]::new($Rectangle.X, $Rectangle.Y, $diameter, $diameter)
        $path.AddArc($arc, 180, 90)
        $arc.X = $Rectangle.Right - $diameter
        $path.AddArc($arc, 270, 90)
        $arc.Y = $Rectangle.Bottom - $diameter
        $path.AddArc($arc, 0, 90)
        $arc.X = $Rectangle.X
        $path.AddArc($arc, 90, 90)
        $path.CloseFigure()
        $Graphics.FillPath($Brush, $path)
        $path.Dispose()
    }

    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        Add-IconRoundedRect $graphics $brushPanel ([System.Drawing.RectangleF]::new(18, 18, 220, 220)) 36
        Add-IconRoundedRect $graphics $brushTeal ([System.Drawing.RectangleF]::new(44, 56, 168, 52)) 16
        Add-IconRoundedRect $graphics $brushAmber ([System.Drawing.RectangleF]::new(44, 128, 104, 52)) 16
        Add-IconRoundedRect $graphics $brushGreen ([System.Drawing.RectangleF]::new(158, 128, 54, 52)) 16
        $graphics.DrawString('VM', $font, $brushWhite, 84, 64)

        $stream = New-Object System.IO.MemoryStream
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        $stream.Position = 0

        $image = New-Object System.Windows.Media.Imaging.BitmapImage
        $image.BeginInit()
        $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $image.StreamSource = $stream
        $image.EndInit()
        $image.Freeze()
        $stream.Dispose()

        return $image
    }
    finally {
        $font.Dispose()
        $brushPanel.Dispose()
        $brushTeal.Dispose()
        $brushAmber.Dispose()
        $brushGreen.Dispose()
        $brushWhite.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Show-AppError {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-AppLog $Message 'ERROR'
    if ([System.Windows.Application]::Current) {
        [void][System.Windows.MessageBox]::Show($Message, $script:AppName, 'OK', 'Error')
    }
}

function Start-AppGui {
    Add-WpfAssemblies

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="VM Partition Workbench" Width="1160" Height="780"
        MinWidth="980" MinHeight="680" WindowStartupLocation="CenterScreen"
        Background="#111113" Foreground="#F4F4F5">
    <Window.Resources>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="#F4F4F5"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="#D4D4D8"/>
            <Setter Property="Padding" Value="0,8,0,4"/>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Margin" Value="0,0,0,8"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="Background" Value="#1F1F23"/>
            <Setter Property="Foreground" Value="#F4F4F5"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="CaretBrush" Value="#F4F4F5"/>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Margin" Value="0,0,8,8"/>
            <Setter Property="Padding" Value="12,7"/>
            <Setter Property="Background" Value="#0F766E"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#115E59"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#F4F4F5"/>
            <Setter Property="Margin" Value="0,4,0,8"/>
        </Style>
        <Style TargetType="GroupBox">
            <Setter Property="Foreground" Value="#F4F4F5"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="Margin" Value="0,0,0,12"/>
            <Setter Property="Padding" Value="12"/>
        </Style>
        <Style TargetType="TabControl">
            <Setter Property="Background" Value="#111113"/>
            <Setter Property="BorderBrush" Value="#27272A"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Padding" Value="14,8"/>
            <Setter Property="Background" Value="#1F1F23"/>
            <Setter Property="Foreground" Value="#F4F4F5"/>
        </Style>
        <Style TargetType="ListView">
            <Setter Property="Background" Value="#18181B"/>
            <Setter Property="Foreground" Value="#F4F4F5"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
        </Style>
    </Window.Resources>
    <Grid Margin="18">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel>
                <TextBlock Text="VM Partition Workbench" FontSize="30" FontWeight="Bold"/>
                <TextBlock Text="Virtual disk resize, mounted-partition resize, and GParted boot prep for VMware VM maintenance." Foreground="#A1A1AA" Margin="0,4,0,0"/>
            </StackPanel>
            <Border Grid.Column="1" BorderBrush="#F59E0B" BorderThickness="1" Padding="12,8" Background="#2A2111">
                <TextBlock x:Name="AdminStatusText" Foreground="#FDE68A" FontWeight="SemiBold"/>
            </Border>
        </Grid>

        <Border Grid.Row="1" Background="#18181B" BorderBrush="#27272A" BorderThickness="1" Padding="12" Margin="0,0,0,14">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="VMwareStatusText" Grid.Column="0"/>
                <TextBlock x:Name="SelectedDiskStatusText" Grid.Column="1" Foreground="#D4D4D8"/>
                <TextBlock Grid.Column="2" Text="Move partitions by booting the VM into GParted Live. Native resize blocks Windows boot/system disks." Foreground="#A1A1AA"/>
            </Grid>
        </Border>

        <TabControl x:Name="MainTabs" Grid.Row="2">
            <TabItem Header="VM Disk">
                <Grid Margin="12">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="380"/>
                        <ColumnDefinition Width="14"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0">
                        <Label Content="VMX file"/>
                        <TextBox x:Name="VmxPathText"/>
                        <StackPanel Orientation="Horizontal">
                            <Button x:Name="BrowseVmxButton" Content="Browse VMX"/>
                            <Button x:Name="LoadVmxButton" Content="Load disks"/>
                        </StackPanel>

                        <Label Content="Virtual disk"/>
                        <TextBox x:Name="DiskPathText"/>
                        <StackPanel Orientation="Horizontal">
                            <Button x:Name="BrowseDiskButton" Content="Browse disk"/>
                            <Button x:Name="InspectDiskButton" Content="Inspect"/>
                        </StackPanel>

                        <GroupBox Header="VHD/VHDX attach">
                            <StackPanel>
                                <TextBlock Text="Attach VHD/VHDX files to Windows, then refresh host disks and choose the mounted disk number for partition resize." Foreground="#A1A1AA" Margin="0,0,0,8"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="MountVhdButton" Content="Mount VHD"/>
                                    <Button x:Name="DismountVhdButton" Content="Dismount VHD"/>
                                </StackPanel>
                            </StackPanel>
                        </GroupBox>
                    </StackPanel>

                    <Grid Grid.Column="2">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="150"/>
                        </Grid.RowDefinitions>
                        <TextBlock Text="Virtual disks referenced by the VMX" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,8"/>
                        <ListView x:Name="DiskList" Grid.Row="1">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="Slot" DisplayMemberBinding="{Binding Slot}" Width="80"/>
                                    <GridViewColumn Header="Type" DisplayMemberBinding="{Binding Type}" Width="80"/>
                                    <GridViewColumn Header="Capacity" DisplayMemberBinding="{Binding Capacity}" Width="110"/>
                                    <GridViewColumn Header="Exists" DisplayMemberBinding="{Binding Exists}" Width="70"/>
                                    <GridViewColumn Header="Path" DisplayMemberBinding="{Binding Path}" Width="610"/>
                                </GridView>
                            </ListView.View>
                        </ListView>
                        <TextBlock Grid.Row="2" Text="Host disks" FontSize="16" FontWeight="SemiBold" Margin="0,12,0,8"/>
                        <ListView x:Name="HostDiskList" Grid.Row="3">
                            <ListView.View>
                                <GridView>
                                    <GridViewColumn Header="#" DisplayMemberBinding="{Binding Number}" Width="42"/>
                                    <GridViewColumn Header="Name" DisplayMemberBinding="{Binding FriendlyName}" Width="260"/>
                                    <GridViewColumn Header="Bus" DisplayMemberBinding="{Binding BusType}" Width="90"/>
                                    <GridViewColumn Header="Size" DisplayMemberBinding="{Binding Size}" Width="100"/>
                                    <GridViewColumn Header="Style" DisplayMemberBinding="{Binding PartitionStyle}" Width="80"/>
                                    <GridViewColumn Header="Boot" DisplayMemberBinding="{Binding Boot}" Width="60"/>
                                    <GridViewColumn Header="System" DisplayMemberBinding="{Binding System}" Width="70"/>
                                </GridView>
                            </ListView.View>
                        </ListView>
                    </Grid>
                </Grid>
            </TabItem>

            <TabItem Header="Operations">
                <ScrollViewer Margin="12" VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                        <GroupBox Header="Safety">
                            <StackPanel>
                                <CheckBox x:Name="BackupCheck" Content="Create a file backup beside the virtual disk before running the plan" IsChecked="True"/>
                                <TextBlock Text="Close the VM before changing disks. A VMware snapshot is still recommended before file backup because snapshots capture VM state and metadata." Foreground="#A1A1AA"/>
                            </StackPanel>
                        </GroupBox>

                        <GroupBox Header="Expand virtual disk capacity">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="220"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <Label Content="Target capacity in GB"/>
                                    <TextBox x:Name="ExpandSizeText" Text=""/>
                                </StackPanel>
                                <TextBlock Grid.Column="1" Margin="16,26,0,0" Text="For VMDK, this uses vmware-vdiskmanager. For VHD/VHDX, this uses diskpart. Capacity expansion does not automatically move partitions." Foreground="#A1A1AA"/>
                            </Grid>
                        </GroupBox>

                        <GroupBox Header="Move or complex-resize partitions with GParted Live">
                            <StackPanel>
                                <CheckBox x:Name="PrepareGPartedCheck" Content="Attach GParted Live ISO to the VMX and add a boot delay"/>
                                <Label Content="GParted ISO path"/>
                                <TextBox x:Name="GPartedIsoText"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button x:Name="BrowseIsoButton" Content="Browse ISO"/>
                                    <Button x:Name="OpenGPartedButton" Content="Open download page"/>
                                </StackPanel>
                                <TextBlock Text="This is the safe move workflow: boot the VM into GParted Live, move/resize partitions inside the guest disk, then remove the ISO from the VM settings." Foreground="#A1A1AA"/>
                            </StackPanel>
                        </GroupBox>

                        <GroupBox Header="Resize a mounted Windows partition">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="190"/>
                                    <ColumnDefinition Width="190"/>
                                    <ColumnDefinition Width="190"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Grid.Column="0">
                                    <CheckBox x:Name="ResizePartitionCheck" Content="Include resize"/>
                                    <Label Content="Disk number"/>
                                    <TextBox x:Name="PartitionDiskNumberText"/>
                                </StackPanel>
                                <StackPanel Grid.Column="1">
                                    <Label Content="Partition number"/>
                                    <TextBox x:Name="PartitionNumberText"/>
                                </StackPanel>
                                <StackPanel Grid.Column="2">
                                    <CheckBox x:Name="ResizeToMaxCheck" Content="Use maximum size" IsChecked="True"/>
                                    <Label Content="Target size GB"/>
                                    <TextBox x:Name="PartitionSizeText"/>
                                </StackPanel>
                                <StackPanel Grid.Column="3" Margin="16,0,0,0">
                                    <TextBlock Text="Use this after mounting a VHD/VHDX, or after a VMDK has been exposed as a Windows disk by VMware tooling. The app refuses to resize the host boot/system disk." Foreground="#A1A1AA" Margin="0,24,0,8"/>
                                    <StackPanel Orientation="Horizontal">
                                        <Button x:Name="RefreshHostDisksButton" Content="Refresh disks"/>
                                        <Button x:Name="LoadPartitionsButton" Content="Load partitions"/>
                                    </StackPanel>
                                </StackPanel>
                            </Grid>
                        </GroupBox>

                        <GroupBox Header="Partitions on selected host disk">
                            <ListView x:Name="PartitionList" Height="180">
                                <ListView.View>
                                    <GridView>
                                        <GridViewColumn Header="Disk" DisplayMemberBinding="{Binding DiskNumber}" Width="52"/>
                                        <GridViewColumn Header="Part" DisplayMemberBinding="{Binding PartitionNumber}" Width="52"/>
                                        <GridViewColumn Header="Letter" DisplayMemberBinding="{Binding DriveLetter}" Width="58"/>
                                        <GridViewColumn Header="Type" DisplayMemberBinding="{Binding Type}" Width="170"/>
                                        <GridViewColumn Header="Size" DisplayMemberBinding="{Binding Size}" Width="110"/>
                                        <GridViewColumn Header="Offset" DisplayMemberBinding="{Binding Offset}" Width="110"/>
                                        <GridViewColumn Header="FS" DisplayMemberBinding="{Binding FileSystem}" Width="80"/>
                                        <GridViewColumn Header="Label" DisplayMemberBinding="{Binding Label}" Width="220"/>
                                    </GridView>
                                </ListView.View>
                            </ListView>
                        </GroupBox>
                    </StackPanel>
                </ScrollViewer>
            </TabItem>

            <TabItem Header="Plan and Run">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="BuildPlanButton" Content="Build plan"/>
                        <Button x:Name="RunPlanButton" Content="Run plan"/>
                        <CheckBox x:Name="DryRunCheck" Content="Dry run only" VerticalAlignment="Center" Margin="8,0,0,8"/>
                    </StackPanel>
                    <TextBox x:Name="PlanText" Grid.Row="1" AcceptsReturn="True" AcceptsTab="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="13"/>
                </Grid>
            </TabItem>

            <TabItem Header="Log">
                <Grid Margin="12">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>
                    <StackPanel Orientation="Horizontal">
                        <Button x:Name="SaveLogButton" Content="Save log"/>
                        <Button x:Name="ClearLogButton" Content="Clear"/>
                    </StackPanel>
                    <ListBox x:Name="LogList" Grid.Row="1" Background="#18181B" Foreground="#F4F4F5" BorderBrush="#3F3F46" FontFamily="Consolas" FontSize="12"/>
                </Grid>
            </TabItem>
        </TabControl>

        <TextBlock Grid.Row="3" Margin="0,12,0,0" Foreground="#A1A1AA" Text="Version 0.1.0 - VMware-first virtual disk maintenance. Always back up before partition work."/>
    </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.Icon = New-AppIconImageSource

    $controls = @{}
    @(
        'AdminStatusText', 'VMwareStatusText', 'SelectedDiskStatusText',
        'VmxPathText', 'DiskPathText', 'BrowseVmxButton', 'LoadVmxButton',
        'BrowseDiskButton', 'InspectDiskButton', 'DiskList', 'HostDiskList',
        'MountVhdButton', 'DismountVhdButton', 'BackupCheck', 'ExpandSizeText',
        'PrepareGPartedCheck', 'GPartedIsoText', 'BrowseIsoButton',
        'OpenGPartedButton', 'ResizePartitionCheck', 'PartitionDiskNumberText',
        'PartitionNumberText', 'ResizeToMaxCheck', 'PartitionSizeText',
        'RefreshHostDisksButton', 'LoadPartitionsButton', 'PartitionList',
        'BuildPlanButton', 'RunPlanButton', 'DryRunCheck', 'PlanText',
        'LogList', 'SaveLogButton', 'ClearLogButton'
    ) | ForEach-Object { $controls[$_] = $window.FindName($_) }

    $controls.LogList.ItemsSource = $script:LogLines

    function Refresh-ToolStatus {
        $tools = Get-VMwareToolReport
        $vdisk = if ($tools.VDiskManager) { 'vmware-vdiskmanager found' } else { 'vmware-vdiskmanager missing' }
        $mount = if ($tools.DiskMount) { 'vmware-mount found' } else { 'vmware-mount optional' }
        $controls.VMwareStatusText.Text = "$vdisk | $mount"
        $controls.AdminStatusText.Text = if (Test-IsAdministrator) { 'Running as administrator' } else { 'Not elevated' }
    }

    function Refresh-HostDisks {
        try {
            $controls.HostDiskList.ItemsSource = @(Get-HostDiskRows)
            Write-AppLog 'Host disk list refreshed.' 'OK'
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    }

    function Load-SelectedVmx {
        try {
            $rows = @(Read-VmxVirtualDisks -Path $controls.VmxPathText.Text)
            $controls.DiskList.ItemsSource = $rows
            if ($rows.Count -gt 0) {
                $controls.DiskList.SelectedIndex = 0
                $controls.DiskPathText.Text = $rows[0].Path
            }
            Write-AppLog "Loaded $($rows.Count) disk(s) from VMX." 'OK'
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    }

    function Inspect-SelectedDisk {
        try {
            $info = Get-VirtualDiskInfo -Path $controls.DiskPathText.Text
            $controls.SelectedDiskStatusText.Text = "Selected: $($info.Type) | Capacity $($info.CapacityText) | File $($info.FileSizeText)"
            Write-AppLog "Inspected disk: $($info.Path) ($($info.Type), $($info.CapacityText))" 'OK'
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    }

    $controls.BrowseVmxButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'VMware configuration (*.vmx)|*.vmx|All files (*.*)|*.*'
        if ($dialog.ShowDialog()) {
            $controls.VmxPathText.Text = $dialog.FileName
            Load-SelectedVmx
        }
    })

    $controls.LoadVmxButton.Add_Click({ Load-SelectedVmx })

    $controls.BrowseDiskButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'Virtual disks (*.vmdk;*.vhd;*.vhdx)|*.vmdk;*.vhd;*.vhdx|All files (*.*)|*.*'
        if ($dialog.ShowDialog()) {
            $controls.DiskPathText.Text = $dialog.FileName
            Inspect-SelectedDisk
        }
    })

    $controls.InspectDiskButton.Add_Click({ Inspect-SelectedDisk })

    $controls.DiskList.Add_SelectionChanged({
        if ($controls.DiskList.SelectedItem) {
            $controls.DiskPathText.Text = $controls.DiskList.SelectedItem.Path
            Inspect-SelectedDisk
        }
    })

    $controls.MountVhdButton.Add_Click({
        try {
            Mount-VhdDisk -DiskPath $controls.DiskPathText.Text
            Refresh-HostDisks
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.DismountVhdButton.Add_Click({
        try {
            Dismount-VhdDisk -DiskPath $controls.DiskPathText.Text
            Refresh-HostDisks
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.BrowseIsoButton.Add_Click({
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
        $dialog.Filter = 'ISO images (*.iso)|*.iso|All files (*.*)|*.*'
        if ($dialog.ShowDialog()) {
            $controls.GPartedIsoText.Text = $dialog.FileName
        }
    })

    $controls.OpenGPartedButton.Add_Click({
        Start-Process 'https://gparted.org/download.php'
    })

    $controls.RefreshHostDisksButton.Add_Click({ Refresh-HostDisks })

    $controls.HostDiskList.Add_SelectionChanged({
        if ($controls.HostDiskList.SelectedItem) {
            $controls.PartitionDiskNumberText.Text = [string]$controls.HostDiskList.SelectedItem.Number
        }
    })

    $controls.LoadPartitionsButton.Add_Click({
        try {
            $diskNumber = [int]$controls.PartitionDiskNumberText.Text
            $controls.PartitionList.ItemsSource = @(Get-PartitionRows -DiskNumber $diskNumber)
            Write-AppLog "Loaded partitions for disk $diskNumber." 'OK'
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.PartitionList.Add_SelectionChanged({
        if ($controls.PartitionList.SelectedItem) {
            $controls.PartitionNumberText.Text = [string]$controls.PartitionList.SelectedItem.PartitionNumber
        }
    })

    $controls.BuildPlanButton.Add_Click({
        try {
            $expand = 0
            if (-not [string]::IsNullOrWhiteSpace($controls.ExpandSizeText.Text)) {
                $expand = [int]$controls.ExpandSizeText.Text
            }

            $diskNumber = -1
            $partitionNumber = -1
            $partitionSize = 0
            if (-not [string]::IsNullOrWhiteSpace($controls.PartitionDiskNumberText.Text)) {
                $diskNumber = [int]$controls.PartitionDiskNumberText.Text
            }
            if (-not [string]::IsNullOrWhiteSpace($controls.PartitionNumberText.Text)) {
                $partitionNumber = [int]$controls.PartitionNumberText.Text
            }
            if (-not [string]::IsNullOrWhiteSpace($controls.PartitionSizeText.Text)) {
                $partitionSize = [int]$controls.PartitionSizeText.Text
            }

            $script:CurrentPlan = @(Build-OperationPlan `
                -DiskPath $controls.DiskPathText.Text `
                -VmxPath $controls.VmxPathText.Text `
                -ExpandToGB $expand `
                -CreateBackup ([bool]$controls.BackupCheck.IsChecked) `
                -PrepareGParted ([bool]$controls.PrepareGPartedCheck.IsChecked) `
                -GPartedIsoPath $controls.GPartedIsoText.Text `
                -ResizePartition ([bool]$controls.ResizePartitionCheck.IsChecked) `
                -PartitionDiskNumber $diskNumber `
                -PartitionNumber $partitionNumber `
                -PartitionSizeGB $partitionSize `
                -ResizeToMaximum ([bool]$controls.ResizeToMaxCheck.IsChecked))

            $controls.PlanText.Text = Format-OperationPlan -Plan $script:CurrentPlan
            Write-AppLog 'Plan built.' 'OK'
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.RunPlanButton.Add_Click({
        try {
            if (-not $script:CurrentPlan -or $script:CurrentPlan.Count -eq 0) {
                throw 'Build a plan first.'
            }

            if ([bool]$controls.DryRunCheck.IsChecked) {
                Write-AppLog 'Dry run selected. No operations executed.' 'WARN'
                return
            }

            if (-not (Test-IsAdministrator)) {
                throw 'Run as administrator before executing disk operations.'
            }

            $answer = [System.Windows.MessageBox]::Show(
                'This will modify virtual disk files or mounted partitions. Confirm that the VM is powered off and backed up.',
                $script:AppName,
                'OKCancel',
                'Warning')
            if ($answer -ne 'OK') {
                Write-AppLog 'Run cancelled by user.' 'WARN'
                return
            }

            foreach ($operation in $script:CurrentPlan) {
                Write-AppLog "Running: $($operation.Title)"
                Execute-PlanOperation -Operation $operation
            }
            Write-AppLog 'Plan completed.' 'OK'
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.SaveLogButton.Add_Click({
        try {
            $dialog = New-Object Microsoft.Win32.SaveFileDialog
            $dialog.Filter = 'Log file (*.log)|*.log|Text file (*.txt)|*.txt'
            $dialog.FileName = 'VMPartitionWorkbench.log'
            if ($dialog.ShowDialog()) {
                Set-Content -LiteralPath $dialog.FileName -Value @($script:LogLines) -Encoding UTF8
                Write-AppLog "Saved log: $($dialog.FileName)" 'OK'
            }
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.ClearLogButton.Add_Click({ $script:LogLines.Clear() })

    Refresh-ToolStatus
    Refresh-HostDisks
    Write-AppLog "$script:AppName $script:AppVersion started."
    [void]$window.ShowDialog()
}

function Invoke-CliMode {
    if ($ListVmDisks) {
        if ([string]::IsNullOrWhiteSpace($VmxPath)) {
            throw '-VmxPath is required with -ListVmDisks.'
        }
        Read-VmxVirtualDisks -Path $VmxPath | Format-Table -AutoSize
        return
    }

    $plan = @(Build-OperationPlan `
        -DiskPath $DiskPath `
        -VmxPath $VmxPath `
        -ExpandToGB $ExpandToGB `
        -CreateBackup ([bool]$CreateBackup) `
        -PrepareGParted ([bool]$PrepareGParted) `
        -GPartedIsoPath $GPartedIsoPath)

    Write-Host (Format-OperationPlan -Plan $plan)
    if ($DryRun) {
        Write-AppLog 'Dry run selected. No operations executed.' 'WARN'
        return
    }
    if (-not (Test-IsAdministrator)) {
        throw 'Run as administrator before executing disk operations.'
    }
    foreach ($operation in $plan) {
        Execute-PlanOperation -Operation $operation
    }
}

try {
    if ($Cli) {
        Invoke-CliMode
    }
    else {
        Start-AppGui
    }
}
catch {
    Write-AppLog $_.Exception.Message 'ERROR'
    if (-not $Cli) {
        try {
            Add-WpfAssemblies
            [void][System.Windows.MessageBox]::Show($_.Exception.Message, $script:AppName, 'OK', 'Error')
        }
        catch {
            Write-Error $_
        }
    }
    exit 1
}
