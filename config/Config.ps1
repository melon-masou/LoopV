$NetworkConfig = @{
    # LoopV managed, host-to-VM internal network
    InternalSwitchName = "LoopvNet"
    # LoopV managed, bridge network for L3Gateway mode.
    OutboundSwitchName = "LoopvNet-out"     
    # Built-in Hyper-V NAT switch, used as VM outbound in VmNat mode
    NatSwitchName = "Default Switch"

    # Physical adapter that LoopvNet-out bridges to in L3Gateway mode
    BridgeAdapterName = "Wifi"
    # Keep this false for the outbound External switch. If true, the host OS
    # also joins the outbound layer-2 network and may obtain DHCP alongside the VM.
    OutboundAllowManagementOS = $false

    # Optional. Static MAC for the VM outbound adapter. If unset, Hyper-V assigns a dynamic MAC.
    # OutboundVMAdapterMAC = "00:15:5D:00:AA:01"

    # LoopvNet internal network addresses
    HostAddress = "172.21.200.1"
    VmGateway = "172.21.200.10"
    WslAddress = "172.21.200.20"
    PrefixLength = 24

    GatewayVmName = "LoopV-VM"

    # Optional. Lower values have higher priority. Uncomment to prefer the
    # L3 gateway over ordinary physical-adapter default routes while still
    # allowing more-specific VPN/Tailscale routes to take priority.
    # L3GatewayRouteMetric = 5
}

$VMCreateConfig = @{
    VmMemoryMB = 1024
    ProcessorCount = 2
}

$CloudInitConfig = @{
    EnableCloudInit = $true
    ImagePath = "_run\image.vhdx"
    CloudInitDir = "config\cloud-init"
    SeedDiskSizeMB = 64

    SshListen = $NetworkConfig.VmGateway
    SshPublicKeyPath = @("_run\vm_ssh_key.pub")
    VmUser = "loopv"
    VmPassword = "loopv"

    EnableHypervTimesync = "true"
    DisableHwOffload = "false"
    EnableSerialConsole = "false"
}
