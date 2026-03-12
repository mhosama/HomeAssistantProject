# Setup Guide: Hyper-V + HAOS Deployment

Step-by-step instructions to deploy Home Assistant OS on a Hyper-V virtual machine on the Windows 10 server (192.168.0.156).

## Prerequisites

- Windows 10 Enterprise with Hyper-V enabled
- Admin access to the server
- Network access to 192.168.0.x subnet
- Internet connectivity for downloading HAOS image

## Step 1: Enable Hyper-V (if not already enabled)

Open PowerShell as Administrator:

```powershell
# Check if Hyper-V is enabled
Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V

# Enable if needed (requires reboot)
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

## Step 2: Download HAOS Image

1. Go to the [Home Assistant Installation page](https://www.home-assistant.io/installation/windows)
2. Download the **HAOS `.vhdx` image** for Windows / Hyper-V
3. Save to a known location, e.g., `C:\VMs\HAOS\`
4. Extract the `.vhdx` file from the downloaded archive

## Step 3: Create External Virtual Switch

The VM needs an external switch bridged to the physical NIC so it gets a real IP on your 192.168.0.x network.

```powershell
# List physical network adapters
Get-NetAdapter

# Create external switch (replace "Ethernet" with your adapter name)
New-VMSwitch -Name "HA-External" -NetAdapterName "Ethernet" -AllowManagementOS $true
```

> **Note**: `-AllowManagementOS $true` ensures the host server keeps network access through the same adapter.

## Step 4: Create the Hyper-V VM

```powershell
# Variables - adjust paths as needed
$VMName = "HomeAssistant"
$VMPath = "C:\VMs\HomeAssistant"
$VHDXPath = "C:\VMs\HAOS\haos_ova-XX.X.vhdx"  # Update with actual filename
$SwitchName = "HA-External"

# Create VM (Gen2, 4GB RAM, 2 vCPUs)
New-VM -Name $VMName `
       -Generation 2 `
       -MemoryStartupBytes 4GB `
       -Path $VMPath `
       -SwitchName $SwitchName

# Attach the HAOS VHDX as boot disk
Add-VMHardDiskDrive -VMName $VMName -Path $VHDXPath

# Configure VM settings
Set-VM -Name $VMName `
       -ProcessorCount 2 `
       -AutomaticStartAction Start `
       -AutomaticStopAction ShutDown `
       -AutomaticStartDelay 30

# Disable Secure Boot (required for HAOS)
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

# Set boot order to boot from the VHDX
$HDD = Get-VMHardDiskDrive -VMName $VMName
Set-VMFirmware -VMName $VMName -FirstBootDevice $HDD
```

## Step 5: Start the VM

```powershell
Start-VM -Name $VMName

# Connect to VM console to watch boot process
vmconnect.exe localhost $VMName
```

Wait 2-5 minutes for HAOS to boot. The console will display the HA URL (e.g., `http://192.168.0.x:8123`).

## Step 6: Network Configuration

### Option A: DHCP Reservation (Recommended)

1. Note the HA VM's MAC address:
   ```powershell
   Get-VMNetworkAdapter -VMName "HomeAssistant" | Select-Object MacAddress
   ```
2. In your router's admin panel, create a DHCP reservation mapping that MAC to a static IP (e.g., `192.168.0.100`)
3. Restart the VM or wait for DHCP renewal

### Option B: Static IP via HA CLI

1. Connect to the VM console
2. Login at the `ha >` prompt and configure:
   ```
   ha network info
   ha network update eth0 --ipv4-method static --ipv4-address 192.168.0.100/24 --ipv4-gateway 192.168.0.1 --ipv4-nameserver 8.8.8.8
   ```

## Step 7: First Boot & Onboarding

1. Open a browser and navigate to `http://<HA_IP>:8123`
2. Wait for the "Preparing Home Assistant" screen (can take up to 20 minutes on first boot)
3. Create your admin account
4. Set your home location (Randpark, South Africa) and timezone (Africa/Johannesburg)
5. Configure any auto-discovered integrations

## Step 8: Essential Add-ons

Navigate to **Settings > Add-ons > Add-on Store** and install:

### File Editor
- Allows editing configuration files from the HA web UI
- Enable "Show in sidebar" after installation

### Terminal & SSH
- Provides CLI access to HAOS
- Configure a password or SSH key after installation
- Enable "Show in sidebar"

### Samba Share
- Exposes HA config files as a Windows network share
- After installation, configure a username/password
- Access from Windows: `\\<HA_IP>\config`

## Step 9: HACS Installation

HACS (Home Assistant Community Store) is needed for custom integrations like Sunsynk.

1. Open the Terminal add-on
2. Run:
   ```bash
   wget -O - https://get.hacs.xyz | bash -
   ```
3. Restart Home Assistant: **Settings > System > Restart**
4. Navigate to **Settings > Devices & Services > Add Integration**
5. Search for "HACS" and follow the GitHub authentication flow

## Verification Checklist

- [ ] Hyper-V VM created and running
- [ ] HAOS booted successfully
- [ ] HA accessible at `http://<HA_IP>:8123`
- [ ] Static IP configured (DHCP reservation or static)
- [ ] Admin account created
- [ ] Location and timezone set correctly
- [ ] File Editor add-on installed
- [ ] Terminal & SSH add-on installed
- [ ] Samba Share add-on installed
- [ ] HACS installed and configured
- [ ] VM set to auto-start with the host

## VM Management Quick Reference

```powershell
# Start/Stop/Restart VM
Start-VM -Name "HomeAssistant"
Stop-VM -Name "HomeAssistant"
Restart-VM -Name "HomeAssistant"

# Check VM status
Get-VM -Name "HomeAssistant"

# Take a snapshot before major changes
Checkpoint-VM -Name "HomeAssistant" -SnapshotName "Before-Integration-X"

# View VM resource usage
Get-VM -Name "HomeAssistant" | Select-Object Name, State, CPUUsage, MemoryAssigned
```
