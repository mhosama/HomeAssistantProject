# Home Assistant Deployment Package

Copy this entire `deploy\` folder to the Hyper-V server (192.168.0.156) and run the scripts in order.

## Quick Start

```powershell
# On the server, open PowerShell as Administrator:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\path\to\deploy

# Step 1: Deploy the VM
.\01-Deploy-HomeAssistant.ps1

# Step 2: Complete onboarding in browser (http://<IP>:8123)
#   - Create admin account
#   - Set location: Randpark, timezone: Africa/Johannesburg
#   - Create a Long-Lived Access Token:
#       Profile (bottom-left) > Security > Long-Lived Access Tokens > Create

# Step 3: Edit config.ps1 - fill in HA_IP and HA_TOKEN

# Step 4: Install add-ons + HACS
.\02-Setup-Addons.ps1

# Step 5: Edit config.ps1 - fill in integration credentials

# Step 6: Set up integrations
.\03-Setup-Integrations.ps1
```

## Scripts

| Script | Purpose | Prerequisites |
|--------|---------|---------------|
| `config.ps1` | Shared configuration (IPs, credentials, settings) | Edit before each phase |
| `01-Deploy-HomeAssistant.ps1` | Create Hyper-V VM with HAOS | Hyper-V enabled, admin |
| `02-Setup-Addons.ps1` | Install File Editor, SSH, Samba, HACS | HA running, HA_IP + HA_TOKEN set |
| `03-Setup-Integrations.ps1` | Configure Sunsynk, eWeLink, Tapo, etc. | Add-ons + HACS installed, credentials set |
| `Manage-VM.ps1` | VM operations (start/stop/snapshot/restore) | VM deployed |

## Workflow

```
┌─────────────────────────┐
│ 1. Deploy-HomeAssistant │  Creates VM, downloads HAOS, boots it
└────────────┬────────────┘
             │ VM is running, note the IP
             ▼
┌─────────────────────────┐
│ 2. Browser Onboarding   │  http://<IP>:8123 - create account, get token
└────────────┬────────────┘
             │ Edit config.ps1: set HA_IP and HA_TOKEN
             ▼
┌─────────────────────────┐
│ 3. 02-Setup-Addons      │  Installs add-ons and HACS via API
└────────────┬────────────┘
             │ Edit config.ps1: set integration credentials
             ▼
┌─────────────────────────┐
│ 4. 03-Setup-Integrations│  Configures integrations (some need manual HACS steps)
└─────────────────────────┘
```

## Managing the VM

```powershell
.\Manage-VM.ps1 status              # Show VM state, IP, memory
.\Manage-VM.ps1 start               # Start the VM
.\Manage-VM.ps1 stop                # Stop the VM
.\Manage-VM.ps1 restart             # Restart the VM
.\Manage-VM.ps1 snapshot "Baseline" # Take a snapshot before changes
.\Manage-VM.ps1 snapshots           # List all snapshots
.\Manage-VM.ps1 restore "Baseline"  # Roll back to a snapshot
.\Manage-VM.ps1 ip                  # Print the VM's IP
.\Manage-VM.ps1 console             # Open Hyper-V console
```

## What Gets Automated vs Manual

| Task | Automated | Manual |
|------|-----------|--------|
| Hyper-V VM creation | Yes | |
| HAOS download + boot | Yes | |
| Network switch setup | Yes | |
| HA onboarding | | Yes (browser) |
| File Editor / SSH / Samba | Yes (API) | |
| HACS install | Attempted | Fallback: run command in SSH add-on |
| Sunsynk integration | HACS repo added | Install + configure in HA UI |
| Sonoff/eWeLink integration | HACS repo added | Install + configure in HA UI |
| Tapo cameras | Connectivity tested | Configure in HA UI |
| Google Cast | Yes (API) | |
| Samsung TV | | Yes (needs on-screen pairing) |
| Alliance heat pump | | Fully manual (research needed) |
