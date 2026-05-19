# Safety Model

VM Partition Workbench is deliberately conservative.

## Guardrails

- It expects VM disks to be powered off before modification.
- It offers a file backup before changing virtual disk metadata or capacity.
- It logs the native command line for every operation.
- It refuses to run `Resize-Partition` against the Windows boot or system disk.
- It does not implement raw host-side partition movement.

## Why partition moves use GParted Live

Moving a partition is more than changing start and end sectors. File system metadata, boot records, partition GUIDs, and guest OS expectations all need to remain consistent. A mature offline partition editor is the right tool for that job.

This app prepares that workflow for VMware:

1. Back up the VM disk files.
2. Expand the virtual disk if needed.
3. Attach the GParted Live ISO to the `.vmx`.
4. Boot the VM into GParted.
5. Move or resize partitions inside the VM.
6. Shut down, remove the ISO, and boot normally.

## Recommended checklist

- Power off the VM.
- Take a VMware snapshot.
- Confirm you have free host disk space for backup copies.
- Build and review the plan.
- Run the plan.
- Boot GParted Live for partition movement.
- Boot the guest OS and run its file system checks if prompted.
