# VMware Workflow

This guide covers the intended resize and move workflow for VMware VMs.

## Expand a VMDK

1. Power off the VM.
2. Open VM Partition Workbench as administrator.
3. Browse to the VM's `.vmx`.
4. Load disks and select the target `.vmdk`.
5. Enter a new target capacity in GB.
6. Keep backup enabled.
7. Build and run the plan.

The app uses `vmware-vdiskmanager.exe -x` for VMDK expansion. If the tool is missing, install VMware Workstation or VMware Virtual Disk Development Kit and restart the app.

## Move partitions

1. Download GParted Live from `https://gparted.org/download.php`.
2. In the app, enable **Attach GParted Live ISO to the VMX**.
3. Select the ISO.
4. Build and run the plan.
5. Start the VM and boot from the attached ISO.
6. Move or resize partitions in GParted.
7. Shut down the VM.
8. Remove the ISO from the VM settings.
9. Boot the guest OS normally.

## Resize a mounted Windows partition

For `.vhd` and `.vhdx` disks:

1. Select the virtual disk.
2. Click **Mount VHD**.
3. Refresh host disks.
4. Select the mounted virtual disk, not the host boot disk.
5. Load partitions.
6. Choose the disk and partition numbers.
7. Enable **Include resize**.
8. Use maximum size or enter a target GB size.
9. Build and run the plan.

For `.vmdk` files, expose the guest disk through VMware tooling first, or use the GParted workflow for the safest offline edit.
