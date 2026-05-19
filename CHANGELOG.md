# Changelog

## 0.2.0

- Added a visual partition map for host-exposed disks.
- Added click-to-select partition synchronization between the map, form fields, and table.
- Added drag-to-resize target staging for mounted partition resize plans.
- Added right-click partition actions for selection, maximum resize targeting, GParted workflow prep, and details copy.
- Added unallocated-space visualization and supported size metadata.
- Kept resize planning blocked for Windows boot/system disks.
- Updated the product site copy for the visual partition workflow.

## 0.1.0

- Initial PowerShell + WPF desktop app.
- VMX disk discovery for VMware virtual machines.
- VMDK, VHD, and VHDX inspection.
- VMDK expansion through `vmware-vdiskmanager.exe`.
- VHD/VHDX expansion and attach/detach through `diskpart`.
- Mounted partition resize through `Resize-Partition`.
- Host boot/system disk resize block.
- GParted Live VMX boot preparation for partition move workflows.
- GitHub Pages-ready product site.
