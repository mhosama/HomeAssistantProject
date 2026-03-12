#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Hyper-V VM management utility for the Home Assistant VM.

.DESCRIPTION
    Common VM operations: status, start, stop, restart, snapshot, restore.

.EXAMPLE
    .\Manage-VM.ps1 status
    .\Manage-VM.ps1 start
    .\Manage-VM.ps1 stop
    .\Manage-VM.ps1 restart
    .\Manage-VM.ps1 snapshot "Before Sunsynk"
    .\Manage-VM.ps1 snapshots
    .\Manage-VM.ps1 restore "Before Sunsynk"
    .\Manage-VM.ps1 ip
    .\Manage-VM.ps1 console
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet("status", "start", "stop", "restart", "snapshot", "snapshots", "restore", "ip", "console", "help")]
    [string]$Action = "status",

    [Parameter(Position = 1)]
    [string]$SnapshotName = ""
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\config.ps1"

$VMName = $Config.VMName

function Write-Success { param([string]$Message) Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host "  [..] $Message" -ForegroundColor Yellow }
function Write-Fail    { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

# Check VM exists
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm -and $Action -ne "help") {
    Write-Fail "VM '$VMName' not found. Run Deploy-HomeAssistant.ps1 first."
    exit 1
}

switch ($Action) {
    "status" {
        Write-Host ""
        Write-Host "  VM Name:      $($vm.Name)" -ForegroundColor White
        Write-Host "  State:        $($vm.State)" -ForegroundColor $(if ($vm.State -eq 'Running') { 'Green' } else { 'Red' })
        Write-Host "  CPUs:         $($vm.ProcessorCount)" -ForegroundColor White
        Write-Host "  Memory:       $([math]::Round($vm.MemoryAssigned / 1GB, 1))GB assigned" -ForegroundColor White
        Write-Host "  Uptime:       $($vm.Uptime)" -ForegroundColor White

        $ips = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        if ($ips) {
            Write-Host "  IP Address:   $($ips -join ', ')" -ForegroundColor Green
            Write-Host "  HA URL:       http://$($ips[0]):8123" -ForegroundColor Cyan
        } else {
            Write-Host "  IP Address:   (not available)" -ForegroundColor DarkGray
        }

        $snapshots = Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue
        Write-Host "  Snapshots:    $(@($snapshots).Count)" -ForegroundColor White
        Write-Host ""
    }

    "start" {
        if ($vm.State -eq 'Running') {
            Write-Info "VM is already running"
        } else {
            Start-VM -Name $VMName
            Write-Success "VM started"
            Write-Info "Wait 2-3 minutes for HA to be accessible"
        }
    }

    "stop" {
        if ($vm.State -eq 'Off') {
            Write-Info "VM is already stopped"
        } else {
            Stop-VM -Name $VMName
            Write-Success "VM stopped"
        }
    }

    "restart" {
        Write-Info "Restarting VM..."
        Restart-VM -Name $VMName -Force
        Write-Success "VM restarted - wait 2-3 minutes for HA"
    }

    "snapshot" {
        if ([string]::IsNullOrWhiteSpace($SnapshotName)) {
            $SnapshotName = "Snapshot_$(Get-Date -Format 'yyyy-MM-dd_HHmm')"
        }
        Checkpoint-VM -Name $VMName -SnapshotName $SnapshotName
        Write-Success "Snapshot created: $SnapshotName"
    }

    "snapshots" {
        $snapshots = Get-VMSnapshot -VMName $VMName -ErrorAction SilentlyContinue
        if (-not $snapshots) {
            Write-Info "No snapshots found"
        } else {
            Write-Host ""
            Write-Host "  Snapshots for '$VMName':" -ForegroundColor White
            foreach ($snap in $snapshots) {
                Write-Host "    - $($snap.Name)  ($($snap.CreationTime))" -ForegroundColor White
            }
            Write-Host ""
        }
    }

    "restore" {
        if ([string]::IsNullOrWhiteSpace($SnapshotName)) {
            Write-Fail "Specify snapshot name: .\Manage-VM.ps1 restore 'Snapshot Name'"
            Write-Info "Use '.\Manage-VM.ps1 snapshots' to list available snapshots"
            exit 1
        }
        $snap = Get-VMSnapshot -VMName $VMName -Name $SnapshotName -ErrorAction SilentlyContinue
        if (-not $snap) {
            Write-Fail "Snapshot '$SnapshotName' not found"
            exit 1
        }
        Write-Info "Restoring snapshot: $SnapshotName (this will stop the VM)..."
        Restore-VMSnapshot -VMSnapshot $snap -Confirm:$false
        Start-VM -Name $VMName
        Write-Success "Restored to '$SnapshotName' and VM started"
    }

    "ip" {
        $ips = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        if ($ips) {
            Write-Host $ips[0]
        } else {
            Write-Fail "No IP address available (is the VM running?)"
        }
    }

    "console" {
        vmconnect.exe localhost $VMName
    }

    "help" {
        Write-Host ""
        Write-Host "  Usage: .\Manage-VM.ps1 <action> [argument]" -ForegroundColor White
        Write-Host ""
        Write-Host "  Actions:" -ForegroundColor Cyan
        Write-Host "    status                  Show VM status and IP" -ForegroundColor White
        Write-Host "    start                   Start the VM" -ForegroundColor White
        Write-Host "    stop                    Stop the VM gracefully" -ForegroundColor White
        Write-Host "    restart                 Restart the VM" -ForegroundColor White
        Write-Host "    snapshot [name]         Create a VM snapshot" -ForegroundColor White
        Write-Host "    snapshots               List all snapshots" -ForegroundColor White
        Write-Host "    restore <name>          Restore a snapshot" -ForegroundColor White
        Write-Host "    ip                      Print the VM's IP address" -ForegroundColor White
        Write-Host "    console                 Open Hyper-V console" -ForegroundColor White
        Write-Host "    help                    Show this help" -ForegroundColor White
        Write-Host ""
    }
}
