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
$script:AppVersion = '0.2.0'
$script:LogLines = New-Object 'System.Collections.ObjectModel.ObservableCollection[string]'
$script:CurrentPlan = @()
$script:PartitionMapRows = @()
$script:SelectedPartitionRow = $null
$script:PartitionDragState = $null
$script:PartitionSelectionUpdating = $false

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
        [double]$PartitionSizeGB = 0,
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
        if (-not $ResizeToMaximum -and $PartitionSizeGB -le 0) {
            throw 'Enter a target partition size in GB, or choose maximum supported size.'
        }

        $previewSize = if ($ResizeToMaximum) { 'maximum supported size' } else { ('{0:0.##} GB' -f $PartitionSizeGB) }
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
        [double]$SizeGB,
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
        [Int64][Math]::Round($SizeGB * 1GB)
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

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($partition in Get-Partition -DiskNumber $DiskNumber | Sort-Object PartitionNumber) {
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        $supportedSizeMin = $null
        $supportedSizeMax = $null
        try {
            $supportedSize = Get-PartitionSupportedSize -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber -ErrorAction Stop
            $supportedSizeMin = [Int64]$supportedSize.SizeMin
            $supportedSizeMax = [Int64]$supportedSize.SizeMax
        }
        catch {
            $supportedSizeMin = $null
            $supportedSizeMax = $null
        }

        $sizeBytes = [Int64]$partition.Size
        $offsetBytes = [Int64]$partition.Offset
        [void]$rows.Add([pscustomobject]@{
            DiskNumber      = $DiskNumber
            PartitionNumber = $partition.PartitionNumber
            DriveLetter     = $partition.DriveLetter
            Type            = $partition.Type
            Size            = Format-ByteSize $partition.Size
            Offset          = Format-ByteSize $partition.Offset
            SizeBytes       = $sizeBytes
            OffsetBytes     = $offsetBytes
            EndBytes        = $offsetBytes + $sizeBytes
            DiskSizeBytes   = [Int64]$disk.Size
            FileSystem      = if ($volume) { $volume.FileSystem } else { '' }
            Label           = if ($volume) { $volume.FileSystemLabel } else { '' }
            SupportedSizeMinBytes = $supportedSizeMin
            SupportedSizeMaxBytes = $supportedSizeMax
            SupportedSizeMin      = Format-ByteSize $supportedSizeMin
            SupportedSizeMax      = Format-ByteSize $supportedSizeMax
            IsResizable           = ($null -ne $supportedSizeMax)
            IsUnallocated         = $false
            DiskIsBoot            = [bool]$disk.IsBoot
            DiskIsSystem          = [bool]$disk.IsSystem
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

                        <GroupBox Header="Visual partition map">
                            <Grid>
                                <Grid.RowDefinitions>
                                    <RowDefinition Height="Auto"/>
                                    <RowDefinition Height="118"/>
                                    <RowDefinition Height="Auto"/>
                                </Grid.RowDefinitions>
                                <TextBlock x:Name="PartitionMapHelpText" Text="Load a host disk to visualize partitions. Click a partition to select it, drag its right handle to set a resize target, or right-click for partition actions." Foreground="#A1A1AA" Margin="0,0,0,8"/>
                                <Border Grid.Row="1" Background="#111113" BorderBrush="#3F3F46" BorderThickness="1" CornerRadius="6" Padding="8" ClipToBounds="True">
                                    <Canvas x:Name="PartitionMapCanvas" MinHeight="90" Background="#111113" ClipToBounds="True"/>
                                </Border>
                                <Grid Grid.Row="2" Margin="0,10,0,0">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="SelectedPartitionText" Text="No partition selected." Foreground="#D4D4D8" VerticalAlignment="Center"/>
                                    <StackPanel Grid.Column="1" Orientation="Horizontal">
                                        <Button x:Name="PartitionSetMaxButton" Content="Resize to max"/>
                                        <Button x:Name="PartitionClearResizeButton" Content="Clear resize"/>
                                        <Button x:Name="PartitionCopyDetailsButton" Content="Copy details"/>
                                    </StackPanel>
                                </Grid>
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

        <TextBlock Grid.Row="3" Margin="0,12,0,0" Foreground="#A1A1AA" Text="Version 0.2.0 - VMware-first virtual disk maintenance. Always back up before partition work."/>
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
        'RefreshHostDisksButton', 'LoadPartitionsButton', 'PartitionMapHelpText',
        'PartitionMapCanvas', 'SelectedPartitionText', 'PartitionSetMaxButton',
        'PartitionClearResizeButton', 'PartitionCopyDetailsButton', 'PartitionList',
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

    function New-SolidBrush {
        param([Parameter(Mandatory = $true)][string]$Color)

        $brush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Color))
        $brush.Freeze()
        return $brush
    }

    function Reset-CurrentPlanPreview {
        if ($script:CurrentPlan -and $script:CurrentPlan.Count -gt 0) {
            $controls.PlanText.Text = 'Plan needs to be rebuilt because the partition selection or resize target changed.'
        }
        $script:CurrentPlan = @()
    }

    function Get-PartitionDisplayName {
        param([Parameter(Mandatory = $true)]$Row)

        if ([bool]$Row.IsUnallocated) {
            return 'Unallocated'
        }

        $drive = [string]$Row.DriveLetter
        $driveText = if (-not [string]::IsNullOrWhiteSpace($drive)) { " $drive`:" } else { '' }
        return "Partition $($Row.PartitionNumber)$driveText"
    }

    function Get-PartitionDetailsText {
        param([Parameter(Mandatory = $true)]$Row)

        if ([bool]$Row.IsUnallocated) {
            return @(
                'Range: Unallocated'
                "Disk: $($Row.DiskNumber)"
                "Offset: $(Format-ByteSize $Row.OffsetBytes)"
                "Size: $(Format-ByteSize $Row.SizeBytes)"
            ) -join [Environment]::NewLine
        }

        $lines = @(
            "Disk: $($Row.DiskNumber)"
            "Partition: $($Row.PartitionNumber)"
            "Drive letter: $($Row.DriveLetter)"
            "Type: $($Row.Type)"
            "File system: $($Row.FileSystem)"
            "Label: $($Row.Label)"
            "Offset: $($Row.Offset)"
            "Size: $($Row.Size)"
            "Supported minimum: $($Row.SupportedSizeMin)"
            "Supported maximum: $($Row.SupportedSizeMax)"
        )
        return $lines -join [Environment]::NewLine
    }

    function Copy-PartitionDetails {
        param([Parameter(Mandatory = $true)]$Row)

        [System.Windows.Clipboard]::SetText((Get-PartitionDetailsText -Row $Row))
        Write-AppLog "Copied details for $(Get-PartitionDisplayName -Row $Row)." 'OK'
    }

    function Update-SelectedPartitionSummary {
        if ($null -eq $script:SelectedPartitionRow) {
            $controls.SelectedPartitionText.Text = 'No partition selected.'
            return
        }

        $row = $script:SelectedPartitionRow
        $summary = "$(Get-PartitionDisplayName -Row $row) | $($row.Type) | $($row.FileSystem) | $($row.Size)"
        if ([bool]$controls.ResizePartitionCheck.IsChecked -and
            [int]$row.DiskNumber -eq [int]$controls.PartitionDiskNumberText.Text -and
            [int]$row.PartitionNumber -eq [int]$controls.PartitionNumberText.Text) {
            if ([bool]$controls.ResizeToMaxCheck.IsChecked) {
                $summary = "$summary | resize target: maximum supported size"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($controls.PartitionSizeText.Text)) {
                $summary = "$summary | resize target: $($controls.PartitionSizeText.Text) GB"
            }
        }

        $controls.SelectedPartitionText.Text = $summary
    }

    function Select-PartitionForEditing {
        param(
            [Parameter(Mandatory = $true)]$Row,
            [bool]$SyncTable = $true,
            [bool]$RedrawMap = $true
        )

        if ([bool]$Row.IsUnallocated) {
            return
        }

        $script:SelectedPartitionRow = $Row
        $controls.PartitionDiskNumberText.Text = [string]$Row.DiskNumber
        $controls.PartitionNumberText.Text = [string]$Row.PartitionNumber

        if ($SyncTable) {
            try {
                $script:PartitionSelectionUpdating = $true
                foreach ($item in $controls.PartitionList.Items) {
                    if ([int]$item.DiskNumber -eq [int]$Row.DiskNumber -and [int]$item.PartitionNumber -eq [int]$Row.PartitionNumber) {
                        $controls.PartitionList.SelectedItem = $item
                        $controls.PartitionList.ScrollIntoView($item)
                        break
                    }
                }
            }
            finally {
                $script:PartitionSelectionUpdating = $false
            }
        }

        Update-SelectedPartitionSummary
        Reset-CurrentPlanPreview
        if ($RedrawMap) {
            Redraw-PartitionMap
        }
    }

    function Set-PartitionResizeMaximum {
        param([Parameter(Mandatory = $true)]$Row)

        if (-not (Test-PartitionResizeTargetAllowed -Row $Row)) {
            return
        }

        Select-PartitionForEditing -Row $Row
        $controls.ResizePartitionCheck.IsChecked = $true
        $controls.ResizeToMaxCheck.IsChecked = $true
        $controls.PartitionSizeText.Text = ''
        Update-SelectedPartitionSummary
        Reset-CurrentPlanPreview
        Write-AppLog "Resize target set to maximum supported size for $(Get-PartitionDisplayName -Row $Row)." 'OK'
    }

    function Set-PartitionResizeTarget {
        param(
            [Parameter(Mandatory = $true)]$Row,
            [Parameter(Mandatory = $true)][Int64]$TargetSizeBytes,
            [bool]$FromDrag = $false
        )

        if (-not (Test-PartitionResizeTargetAllowed -Row $Row)) {
            return
        }

        Select-PartitionForEditing -Row $Row -RedrawMap (-not $FromDrag)
        $targetGb = [Math]::Max(0.01, [Math]::Round(($TargetSizeBytes / 1GB), 2))
        $controls.ResizePartitionCheck.IsChecked = $true
        $controls.ResizeToMaxCheck.IsChecked = $false
        $controls.PartitionSizeText.Text = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.##}', $targetGb)
        Update-SelectedPartitionSummary
        Reset-CurrentPlanPreview
    }

    function Clear-PartitionResizeTarget {
        $controls.ResizePartitionCheck.IsChecked = $false
        $controls.ResizeToMaxCheck.IsChecked = $true
        $controls.PartitionSizeText.Text = ''
        Update-SelectedPartitionSummary
        Reset-CurrentPlanPreview
        Write-AppLog 'Cleared partition resize target.' 'OK'
    }

    function Mark-GPartedWorkflowFromMap {
        $controls.PrepareGPartedCheck.IsChecked = $true
        Reset-CurrentPlanPreview
        Write-AppLog 'GParted boot workflow marked from the partition map. Choose the ISO path before building the plan.' 'OK'
    }

    function Test-PartitionResizeTargetAllowed {
        param([Parameter(Mandatory = $true)]$Row)

        if ([bool]$Row.DiskIsBoot -or [bool]$Row.DiskIsSystem) {
            Show-AppError 'Resize planning is blocked for the Windows boot/system disk. Choose a mounted VM disk, or use the GParted workflow for offline partition moves.'
            return $false
        }

        return $true
    }

    function Get-PartitionMapColor {
        param([Parameter(Mandatory = $true)]$Row)

        if ([bool]$Row.IsUnallocated) {
            return '#27272A'
        }

        $type = ([string]$Row.Type).ToLowerInvariant()
        $fileSystem = ([string]$Row.FileSystem).ToUpperInvariant()
        if ($type -match 'system|efi') {
            return '#2563EB'
        }
        if ($type -match 'reserved') {
            return '#52525B'
        }
        if ($type -match 'recovery') {
            return '#7C3AED'
        }
        if ($fileSystem -eq 'NTFS') {
            return '#0F766E'
        }
        if ($fileSystem -eq 'FAT32') {
            return '#B45309'
        }
        return '#4F46E5'
    }

    function Get-NextPartitionBoundaryBytes {
        param([Parameter(Mandatory = $true)]$Row)

        $nextBoundary = [Int64]$Row.DiskSizeBytes
        foreach ($candidate in $script:PartitionMapRows) {
            if ([Int64]$candidate.OffsetBytes -gt [Int64]$Row.OffsetBytes -and [Int64]$candidate.OffsetBytes -lt $nextBoundary) {
                $nextBoundary = [Int64]$candidate.OffsetBytes
            }
        }
        return $nextBoundary
    }

    function Get-MinimumResizeBytes {
        param([Parameter(Mandatory = $true)]$Row)

        if ($null -ne $Row.SupportedSizeMinBytes -and [Int64]$Row.SupportedSizeMinBytes -gt 0) {
            return [Int64]$Row.SupportedSizeMinBytes
        }

        return [Int64][Math]::Min([double]$Row.SizeBytes, [double]1GB)
    }

    function New-PartitionContextMenu {
        param([Parameter(Mandatory = $true)]$Row)

        $menu = New-Object System.Windows.Controls.ContextMenu
        $partitionRow = $Row

        if ([bool]$Row.IsUnallocated) {
            $copyItem = New-Object System.Windows.Controls.MenuItem
            $copyItem.Header = 'Copy range details'
            $copyItem.Add_Click({ Copy-PartitionDetails -Row $partitionRow }.GetNewClosure())
            [void]$menu.Items.Add($copyItem)

            $gpartedItem = New-Object System.Windows.Controls.MenuItem
            $gpartedItem.Header = 'Prepare GParted workflow'
            $gpartedItem.Add_Click({ Mark-GPartedWorkflowFromMap }.GetNewClosure())
            [void]$menu.Items.Add($gpartedItem)
            return $menu
        }

        $selectItem = New-Object System.Windows.Controls.MenuItem
        $selectItem.Header = 'Select partition'
        $selectItem.Add_Click({ Select-PartitionForEditing -Row $partitionRow }.GetNewClosure())
        [void]$menu.Items.Add($selectItem)

        $resizeMaxItem = New-Object System.Windows.Controls.MenuItem
        $resizeMaxItem.Header = 'Resize to maximum supported'
        $resizeMaxItem.Add_Click({ Set-PartitionResizeMaximum -Row $partitionRow }.GetNewClosure())
        [void]$menu.Items.Add($resizeMaxItem)

        [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))

        $gpartedItem = New-Object System.Windows.Controls.MenuItem
        $gpartedItem.Header = 'Prepare GParted workflow'
        $gpartedItem.Add_Click({ Mark-GPartedWorkflowFromMap }.GetNewClosure())
        [void]$menu.Items.Add($gpartedItem)

        $copyItem = New-Object System.Windows.Controls.MenuItem
        $copyItem.Header = 'Copy partition details'
        $copyItem.Add_Click({ Copy-PartitionDetails -Row $partitionRow }.GetNewClosure())
        [void]$menu.Items.Add($copyItem)

        return $menu
    }

    function Add-PartitionMapSegment {
        param(
            [Parameter(Mandatory = $true)]$Segment,
            [Parameter(Mandatory = $true)][double]$MapWidth,
            [Parameter(Mandatory = $true)][double]$Top,
            [Parameter(Mandatory = $true)][double]$Height
        )

        if ([Int64]$Segment.DiskSizeBytes -le 0 -or [Int64]$Segment.SizeBytes -le 0) {
            return
        }

        $left = ([double]$Segment.OffsetBytes / [double]$Segment.DiskSizeBytes) * $MapWidth
        $width = ([double]$Segment.SizeBytes / [double]$Segment.DiskSizeBytes) * $MapWidth
        if ($left -gt $MapWidth) {
            return
        }
        if ($width -lt 4) {
            $width = 4
        }
        if (($left + $width) -gt $MapWidth) {
            $width = [Math]::Max(2, $MapWidth - $left)
        }

        $isSelected = $false
        if (-not [bool]$Segment.IsUnallocated -and $null -ne $script:SelectedPartitionRow) {
            $isSelected = ([int]$Segment.DiskNumber -eq [int]$script:SelectedPartitionRow.DiskNumber -and [int]$Segment.PartitionNumber -eq [int]$script:SelectedPartitionRow.PartitionNumber)
        }

        $border = New-Object System.Windows.Controls.Border
        $border.Width = $width
        $border.Height = $Height
        $border.CornerRadius = New-Object System.Windows.CornerRadius 5
        $border.BorderThickness = New-Object System.Windows.Thickness $(if ($isSelected) { 2 } else { 1 })
        $border.BorderBrush = New-SolidBrush $(if ($isSelected) { '#F59E0B' } elseif ([bool]$Segment.IsUnallocated) { '#52525B' } else { '#1F2937' })
        $border.Background = New-SolidBrush (Get-PartitionMapColor -Row $Segment)
        $border.ClipToBounds = $true
        $border.ContextMenu = New-PartitionContextMenu -Row $Segment
        $border.ToolTip = Get-PartitionDetailsText -Row $Segment

        $stack = New-Object System.Windows.Controls.StackPanel
        $stack.Margin = New-Object System.Windows.Thickness 7,5,7,5

        $title = New-Object System.Windows.Controls.TextBlock
        $title.FontWeight = [System.Windows.FontWeights]::SemiBold
        $title.FontSize = 12
        $title.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $title.Text = Get-PartitionDisplayName -Row $Segment
        $title.Foreground = New-SolidBrush '#FFFFFF'
        [void]$stack.Children.Add($title)

        if ($width -gt 70) {
            $detail = New-Object System.Windows.Controls.TextBlock
            $detail.FontSize = 11
            $detail.Foreground = New-SolidBrush '#E4E4E7'
            $detail.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            if ([bool]$Segment.IsUnallocated) {
                $detail.Text = Format-ByteSize $Segment.SizeBytes
            }
            else {
                $detail.Text = "$($Segment.Size) $($Segment.FileSystem)"
            }
            [void]$stack.Children.Add($detail)
        }

        $border.Child = $stack
        [System.Windows.Controls.Canvas]::SetLeft($border, $left)
        [System.Windows.Controls.Canvas]::SetTop($border, $Top)
        [void]$controls.PartitionMapCanvas.Children.Add($border)

        if (-not [bool]$Segment.IsUnallocated) {
            $partitionRow = $Segment
            $border.Add_MouseLeftButtonDown({
                param($sender, $eventArgs)
                Select-PartitionForEditing -Row $partitionRow
                $eventArgs.Handled = $true
            }.GetNewClosure())
            $border.Add_MouseRightButtonDown({
                param($sender, $eventArgs)
                Select-PartitionForEditing -Row $partitionRow -RedrawMap $false
            }.GetNewClosure())

            $handle = New-Object System.Windows.Controls.Border
            $handle.Width = 7
            $handle.Height = $Height
            $handle.CornerRadius = New-Object System.Windows.CornerRadius 3
            $handle.Background = New-SolidBrush '#FDE68A'
            $handle.Opacity = 0.9
            $handle.Cursor = [System.Windows.Input.Cursors]::SizeWE
            $handle.ToolTip = 'Drag to set a partition resize target'
            $handle.Add_MouseLeftButtonDown({
                param($sender, $eventArgs)
                Start-PartitionResizeDrag -Row $partitionRow -EventArgs $eventArgs
                $eventArgs.Handled = $true
            }.GetNewClosure())

            $handleLeft = [Math]::Min($MapWidth - 7, [Math]::Max(0, $left + $width - 4))
            [System.Windows.Controls.Canvas]::SetLeft($handle, $handleLeft)
            [System.Windows.Controls.Canvas]::SetTop($handle, $Top)
            [void]$controls.PartitionMapCanvas.Children.Add($handle)
        }
    }

    function Redraw-PartitionMap {
        $canvas = $controls.PartitionMapCanvas
        $canvas.Children.Clear()

        $mapWidth = [double]$canvas.ActualWidth
        if ($mapWidth -lt 120) {
            $mapWidth = [double]$canvas.RenderSize.Width
        }
        if ($mapWidth -lt 120) {
            $mapWidth = 860
        }

        if (-not $script:PartitionMapRows -or $script:PartitionMapRows.Count -eq 0) {
            $emptyText = New-Object System.Windows.Controls.TextBlock
            $emptyText.Text = 'Select a host disk and load partitions.'
            $emptyText.Foreground = New-SolidBrush '#A1A1AA'
            [System.Windows.Controls.Canvas]::SetLeft($emptyText, 12)
            [System.Windows.Controls.Canvas]::SetTop($emptyText, 34)
            [void]$canvas.Children.Add($emptyText)
            return
        }

        $diskSize = [Int64]$script:PartitionMapRows[0].DiskSizeBytes
        $cursor = [Int64]0
        $top = 12.0
        $height = 66.0
        foreach ($row in ($script:PartitionMapRows | Sort-Object OffsetBytes)) {
            if ([Int64]$row.OffsetBytes -gt $cursor) {
                $gapSize = [Int64]$row.OffsetBytes - $cursor
                $gap = [pscustomobject]@{
                    DiskNumber = $row.DiskNumber
                    PartitionNumber = 0
                    DriveLetter = ''
                    Type = 'Unallocated'
                    Size = Format-ByteSize $gapSize
                    Offset = Format-ByteSize $cursor
                    SizeBytes = $gapSize
                    OffsetBytes = $cursor
                    EndBytes = [Int64]$row.OffsetBytes
                    DiskSizeBytes = $diskSize
                    FileSystem = ''
                    Label = ''
                    IsUnallocated = $true
                }
                Add-PartitionMapSegment -Segment $gap -MapWidth $mapWidth -Top $top -Height $height
            }

            Add-PartitionMapSegment -Segment $row -MapWidth $mapWidth -Top $top -Height $height
            $cursor = [Int64]$row.EndBytes
        }

        if ($diskSize -gt $cursor) {
            $gapSize = $diskSize - $cursor
            $lastDiskNumber = $script:PartitionMapRows[0].DiskNumber
            $gap = [pscustomobject]@{
                DiskNumber = $lastDiskNumber
                PartitionNumber = 0
                DriveLetter = ''
                Type = 'Unallocated'
                Size = Format-ByteSize $gapSize
                Offset = Format-ByteSize $cursor
                SizeBytes = $gapSize
                OffsetBytes = $cursor
                EndBytes = $diskSize
                DiskSizeBytes = $diskSize
                FileSystem = ''
                Label = ''
                IsUnallocated = $true
            }
            Add-PartitionMapSegment -Segment $gap -MapWidth $mapWidth -Top $top -Height $height
        }

        $diskLabel = New-Object System.Windows.Controls.TextBlock
        $diskLabel.Text = "Disk $($script:PartitionMapRows[0].DiskNumber) | $(Format-ByteSize $diskSize)"
        $diskLabel.Foreground = New-SolidBrush '#A1A1AA'
        $diskLabel.FontSize = 11
        [System.Windows.Controls.Canvas]::SetLeft($diskLabel, 0)
        [System.Windows.Controls.Canvas]::SetTop($diskLabel, 84)
        [void]$canvas.Children.Add($diskLabel)
    }

    function Load-PartitionsForDisk {
        param([Parameter(Mandatory = $true)][int]$DiskNumber)

        $rows = @(Get-PartitionRows -DiskNumber $DiskNumber)
        $script:PartitionMapRows = $rows
        $script:SelectedPartitionRow = $null
        $controls.PartitionDiskNumberText.Text = [string]$DiskNumber
        $controls.PartitionNumberText.Text = ''
        $controls.ResizePartitionCheck.IsChecked = $false
        $controls.ResizeToMaxCheck.IsChecked = $true
        $controls.PartitionSizeText.Text = ''
        $controls.PartitionList.ItemsSource = $rows
        $controls.SelectedPartitionText.Text = 'No partition selected.'
        Reset-CurrentPlanPreview
        Redraw-PartitionMap
        Write-AppLog "Loaded $($rows.Count) partition(s) for disk $DiskNumber." 'OK'
    }

    function Start-PartitionResizeDrag {
        param(
            [Parameter(Mandatory = $true)]$Row,
            [Parameter(Mandatory = $true)][System.Windows.Input.MouseButtonEventArgs]$EventArgs
        )

        if (-not (Test-PartitionResizeTargetAllowed -Row $Row)) {
            return
        }

        Select-PartitionForEditing -Row $Row -RedrawMap $false
        $guide = New-Object System.Windows.Shapes.Rectangle
        $guide.Width = 3
        $guide.Height = 74
        $guide.Fill = New-SolidBrush '#F59E0B'
        $guide.IsHitTestVisible = $false
        [System.Windows.Controls.Canvas]::SetTop($guide, 8)
        [void]$controls.PartitionMapCanvas.Children.Add($guide)

        $script:PartitionDragState = [pscustomobject]@{
            Row = $Row
            Guide = $guide
            DiskSizeBytes = [Int64]$Row.DiskSizeBytes
            MinSizeBytes = Get-MinimumResizeBytes -Row $Row
            MaxEndBytes = Get-NextPartitionBoundaryBytes -Row $Row
            LastTargetBytes = [Int64]$Row.SizeBytes
        }

        [void][System.Windows.Input.Mouse]::Capture($controls.PartitionMapCanvas)
        Update-PartitionResizeDrag -EventArgs $EventArgs
    }

    function Update-PartitionResizeDrag {
        param([Parameter(Mandatory = $true)][System.Windows.Input.MouseEventArgs]$EventArgs)

        if ($null -eq $script:PartitionDragState) {
            return
        }

        $canvas = $controls.PartitionMapCanvas
        $mapWidth = [Math]::Max(1, [double]$canvas.ActualWidth)
        $position = $EventArgs.GetPosition($canvas)
        $x = [Math]::Min($mapWidth, [Math]::Max(0, [double]$position.X))
        $row = $script:PartitionDragState.Row
        $diskSize = [double]$script:PartitionDragState.DiskSizeBytes
        $targetEnd = [Int64][Math]::Round(($x / $mapWidth) * $diskSize)
        $minEnd = [Int64]$row.OffsetBytes + [Int64]$script:PartitionDragState.MinSizeBytes
        $maxEnd = [Int64]$script:PartitionDragState.MaxEndBytes
        if ($targetEnd -lt $minEnd) {
            $targetEnd = $minEnd
        }
        if ($targetEnd -gt $maxEnd) {
            $targetEnd = $maxEnd
        }

        $targetSize = [Int64]($targetEnd - [Int64]$row.OffsetBytes)
        $script:PartitionDragState.LastTargetBytes = $targetSize
        Set-PartitionResizeTarget -Row $row -TargetSizeBytes $targetSize -FromDrag $true

        $guideLeft = ([double]$targetEnd / $diskSize) * $mapWidth
        [System.Windows.Controls.Canvas]::SetLeft($script:PartitionDragState.Guide, [Math]::Min($mapWidth - 3, [Math]::Max(0, $guideLeft - 1.5)))
    }

    function Complete-PartitionResizeDrag {
        if ($null -eq $script:PartitionDragState) {
            return
        }

        $row = $script:PartitionDragState.Row
        $targetSize = [Int64]$script:PartitionDragState.LastTargetBytes
        [void][System.Windows.Input.Mouse]::Capture($null)
        [void]$controls.PartitionMapCanvas.Children.Remove($script:PartitionDragState.Guide)
        $script:PartitionDragState = $null
        Redraw-PartitionMap
        Write-AppLog "Drag resize target set for $(Get-PartitionDisplayName -Row $row): $(Format-ByteSize $targetSize)." 'OK'
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
            try {
                Load-PartitionsForDisk -DiskNumber ([int]$controls.HostDiskList.SelectedItem.Number)
            }
            catch {
                Show-AppError $_.Exception.Message
            }
        }
    })

    $controls.LoadPartitionsButton.Add_Click({
        try {
            $diskNumber = [int]$controls.PartitionDiskNumberText.Text
            Load-PartitionsForDisk -DiskNumber $diskNumber
        }
        catch {
            Show-AppError $_.Exception.Message
        }
    })

    $controls.PartitionList.Add_SelectionChanged({
        if (-not $script:PartitionSelectionUpdating -and $controls.PartitionList.SelectedItem) {
            Select-PartitionForEditing -Row $controls.PartitionList.SelectedItem -SyncTable $false
        }
    })

    $controls.PartitionMapCanvas.Add_SizeChanged({ Redraw-PartitionMap })
    $controls.PartitionMapCanvas.Add_MouseMove({
        param($sender, $eventArgs)
        Update-PartitionResizeDrag -EventArgs $eventArgs
    })
    $controls.PartitionMapCanvas.Add_MouseLeftButtonUp({ Complete-PartitionResizeDrag })

    $controls.PartitionSetMaxButton.Add_Click({
        if ($script:SelectedPartitionRow) {
            Set-PartitionResizeMaximum -Row $script:SelectedPartitionRow
        }
    })

    $controls.PartitionClearResizeButton.Add_Click({ Clear-PartitionResizeTarget })

    $controls.PartitionCopyDetailsButton.Add_Click({
        if ($script:SelectedPartitionRow) {
            Copy-PartitionDetails -Row $script:SelectedPartitionRow
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
            $partitionSize = 0.0
            if (-not [string]::IsNullOrWhiteSpace($controls.PartitionDiskNumberText.Text)) {
                $diskNumber = [int]$controls.PartitionDiskNumberText.Text
            }
            if (-not [string]::IsNullOrWhiteSpace($controls.PartitionNumberText.Text)) {
                $partitionNumber = [int]$controls.PartitionNumberText.Text
            }
            if (-not [string]::IsNullOrWhiteSpace($controls.PartitionSizeText.Text)) {
                $partitionSize = [double]::Parse($controls.PartitionSizeText.Text, [Globalization.CultureInfo]::InvariantCulture)
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
