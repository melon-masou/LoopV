# LoopV

LoopV is a set of Windows scripts that use Hyper-V to set up a local VM as a transparent proxy gateway, taking over host and WSL traffic and DNS via TProxy for network traffic analysis and proxying.

Tested on Windows 11 with Hyper-V; should also work on Windows 10.

## Setup

### Configuration

Edit `config\Config.ps1`:

- `BridgeAdapterName`: name of the physical adapter to bridge in L3Gateway mode. Run `ipconfig` in CMD to find your adapter name.
- `NatSwitchName`: name of the built-in Hyper-V NAT switch. The default `Default Switch` is correct for most installations.
- `VmMemoryMB`, `ProcessorCount`: VM hardware allocation.
- `EnableCloudInit`: set to `$false` to skip cloud-init and install the OS manually.

### Initialize Networking

Run `scripts\NetworkInit.bat`. This creates the managed virtual switches.

### Prepare the VM Image

If you prefer to install the OS manually, set EnableCloudInit = $false in Config.ps1 and skip this section.

- Download a Debian generic cloud qcow2 image from https://cloud.debian.org/images/cloud
- Convert it to VHDX using qemu-img and place it at `_run\image.vhdx`. qemu-img is available via package manager inside WSL or [QEMU for Windows](https://www.qemu.org/download/#windows)
  ```
  qemu-img convert -p -O vhdx _run/debian-13-generic-amd64.qcow2 _run/image.vhdx
  ```
- Generate an SSH key pair for VM access:
  ```
  ssh-keygen -t ed25519 -f _run\vm_ssh_key -N ""
  ```

### Create the VM

Run `scripts\GatewayVMCreate.bat`. This creates the VM and runs cloud-init on first boot.

Install and configure your traffic interception tool or proxy inside the VM.

### Network Modes

The gateway VM supports two modes (after creation it starts in VmNat mode):

- VmNat: VM accesses the internet through the host NAT. Host traffic is not routed through the VM, but it can serve as a gateway for WSL or other VMs.
- L3Gateway: VM takes over Layer 3 ownership of the physical adapter, including DHCP address acquisition and outbound routing. All host traffic is routed through VM first.

Use `scripts\ModeVmNat.bat` and `scripts\ModeL3Gateway.bat` to switch between modes.

> **Note:** Switching to L3Gateway may cause the host to lose internet access if the VM is not correctly configured. Switch back to VmNat mode to restore connectivity.

## WSL

In L3Gateway mode, WSL traffic routes through the host and into the VM gateway. No extra configuration needed.

In VmNat mode, WSL needs to be connected to the `LoopvNet` switch to reach the VM gateway. You can follow this [comment](https://github.com/microsoft/WSL/issues/4150#issuecomment-1018524753) to bridge WSL to the `LoopvNet` switch, then manually configure the WSL interface and gateway.

We have scripts to help attach the switch to WSL and configure networking:

- Download `WSLAttachSwitch.exe` from https://github.com/dantmnf/WSLAttachSwitch/releases and place it at `_run\WSLAttachSwitch.exe`
- Run `wsl\AttachTaskRegister.bat` to register a scheduled task that allows WSL to trigger the switch attach
- Inside WSL, ensure:
  - No network manager (systemd-networkd, netplan, etc.) is managing WSL's network interfaces
  - `/etc/wsl.conf` contains:
    ```ini
    [network]
    generateResolvConf = false
    ```
    which prevent WSL rewriting DNS setting.
- Inside WSL, run `wsl\WslUseGateway.sh` to attach the switch and route all WSL traffic through the VM gateway.
  - To apply automatically on every WSL startup, add to `/etc/wsl.conf`:
    ```ini
    [boot]
    command=/mnt/c/path/to/loopv/wsl/WslUseGateway.sh
    ```
    Files may be stored on Windows, with their paths converted for use in WSL via `wslpath`.

Could use `wsl\WslAttachOnly.sh` to attach the interface without changing the default gateway or DNS.
