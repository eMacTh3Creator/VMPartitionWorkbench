# VM Partition Workbench

PowerShell + WPF desktop tool for VMware-oriented virtual disk partition work.

It is built for the practical VM workflow: expand a virtual disk, mount and resize supported Windows partitions when they are exposed to the host, and prepare the VM to boot into GParted Live for partition moves or complex layout changes.

## What it does

- Loads VMware `.vmx` files and lists attached `.vmdk`, `.vhd`, and `.vhdx` disks.
- Inspects virtual disk capacity and backing files.
- Creates a safety backup of the selected virtual disk files before changes.
- Expands `.vmdk` disks with `vmware-vdiskmanager.exe` when VMware Workstation or VDDK is installed.
- Expands `.vhd` and `.vhdx` disks with Windows `diskpart`.
- Mounts and dismounts `.vhd` and `.vhdx` files for host-side maintenance.
- Resizes a mounted partition with `Resize-Partition`.
- Refuses to resize the Windows boot/system disk.
- Attaches a GParted Live ISO to a `.vmx` file and adds a boot delay so you can move partitions inside the VM.
- Logs every native command it runs.

## Important safety note

Partition movement is intentionally handled by booting the VM into GParted Live. Moving partitions from the host by editing partition tables and file systems directly is risky, VM-format-specific, and easy to get wrong. This app gives you the VMware-first workflow around it: back up, expand the virtual disk, attach the rescue ISO, and boot into a proven partition editor.

Always power off the VM and take a VMware snapshot before making partition changes.

## Quick start

### Option A: portable exe

1. Download the latest `VMPartitionWorkbench-v*-win-x64.exe` from the release folder or GitHub release.
2. Right-click it and choose **Run as administrator**.
3. Choose a `.vmx` file and load the attached virtual disks.
4. Choose a disk, build a plan, review it, then run it.

### Option B: script

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\src\VMPartitionWorkbench.ps1
```

### Optional install

After building or extracting the release zip, run the installer from an elevated PowerShell session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\installer\Install-VMPartitionWorkbench.ps1
```

### CLI examples

List VM disks:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\VMPartitionWorkbench.ps1 -Cli -ListVmDisks -VmxPath "D:\VMs\Lab\Lab.vmx"
```

Expand a VMDK and create a backup:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\VMPartitionWorkbench.ps1 -Cli -DiskPath "D:\VMs\Lab\Lab.vmdk" -ExpandToGB 120 -CreateBackup
```

Prepare a VM to boot GParted Live:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\VMPartitionWorkbench.ps1 -Cli -VmxPath "D:\VMs\Lab\Lab.vmx" -DiskPath "D:\VMs\Lab\Lab.vmdk" -PrepareGParted -GPartedIsoPath "D:\ISO\gparted-live.iso" -CreateBackup
```

## Requirements

- Windows 10 or later.
- Administrator rights for disk operations.
- PowerShell 5.1 for direct script use.
- VMware Workstation or VMware VDDK for `.vmdk` expansion with `vmware-vdiskmanager.exe`.
- GParted Live ISO for partition moves and complex partition edits.

## Build the release

The repository is intentionally SDK-light. It uses PS2EXE to create a portable executable.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build\Build-Release.ps1
```

Artifacts are written to `release\`:

- `VMPartitionWorkbench-v0.1.0-win-x64.exe`
- `VMPartitionWorkbench.ps1`
- `Run-VMPartitionWorkbench.cmd`
- `VMPartitionWorkbench-v0.1.0-portable.zip`
- `installer\Install-VMPartitionWorkbench.ps1`
- `latest.json`
- `checksums.txt`

## GitHub Pages

The root `index.html` is a static GitHub Pages site with a product page, quick start, screenshot, and download links. The included `.github/workflows/pages.yml` workflow deploys the site on pushes to `main` or `master`.

## License

MIT
