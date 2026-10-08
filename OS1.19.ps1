

& {

# =================
# CONFIGURATIONS
# =================

$SubscriptionId   = "4859ec56-96d2-47b5-ae52-3b74174759e1"   
$ResourceGroup    = "win2016-vm-rg"                          
$VMName           = "win2016-vm"                              
$Location         = "eastus"                                 
$Zone             = ""                                          # VM's Availability Zone, e.g. "1". Leave "" if not zonal

# Upgrade media settings
$UpgradeDiskRG    = $ResourceGroup                              # RG to hold the temporary upgrade media disk
$UpgradeDiskName  = "$VMName-UpgradeMediaDisk"                  # Name for the upgrade media managed disk
$UpgradeSku       = "server2025Upgrade"                         # server2025Upgrade | server2022Upgrade | server2019Upgrade | server2016Upgrade | server2012Upgrade
$UpgradeDiskSizeGB = 60                                          # Size (GB) used ONLY when the upgrade disk has to be created fresh. Change as needed.
$UpgradeVolumeLabel = "UPGRADE2025"

# Snapshot settings
$SnapshotPrefix   = "$VMName-PreUpgrade-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Cleanup behaviour after a SUCCESSFUL upgrade
$DeleteSnapshotsAfterSuccess   = $false                     # set $true to auto-delete snapshots after a verified successful upgrade
$DetachUpgradeDiskAfterSuccess = $true                      # set $true to detach the upgrade media disk from the VM after use; set $false to leave it attached
$DeleteUpgradeDiskAfterSuccess = $true                      # set $true to delete the upgrade media disk (managed disk) after use; set $false to keep it


# How long to wait (seconds) for the VM to come back after the upgrade before giving up
$UpgradeTimeoutSeconds = 1800   # 30 minutes

# Windows Defender handling
$ManageDefender = $true   # set $true to auto-disable real-time protection before upgrade and re-enable after

# ------------------
# PRE-FLIGHT CHECKS 
# ------------------

# Minimum free space required on the VM's C: drive before the upgrade is allowed to proceed.
$MinFreeSpaceGB = 40

# If any of these third-party security products are found RUNNING on the VM, the script
$ThirdPartySecurityVendorPatterns = @(
    "Symantec", "Norton", "Trend Micro", "TrendMicro", "McAfee", "Sophos",
    "CrowdStrike", "SentinelOne", "Kaspersky", "ESET", "Bitdefender",
    "Cylance", "Carbon Black", "Malwarebytes", "Webroot", "FireEye", "Forcepoint", "F-Secure"
)


# Azure Cloud Shell/Linux PowerShell -> a folder under the local temp directory.
$LocalLogCopyFolder = if ($env:OS -eq "Windows_NT") {
    "C:\temp"
} else {
    Join-Path ([System.IO.Path]::GetTempPath()) "AzureVMUpgradeLogs-Completed"
}

# ------------------------------------------------------------------
# AUTHORITATIVE LOG INSIDE THE TARGET VM
# C:\UpgradeLog\Windows2025-20260824-200915.log
# ------------------------------------------------------------------
$VMLogFolder = "C:\UpgradeLog"
# Azure Cloud Shell/Linux PowerShell, where the C: drive does not exist.
$VMLogFileName = "Windows2025-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss")
$VMLogPath     = "$VMLogFolder\$VMLogFileName"

# What the target OS version string should contain post-upgrade, used to verify
# the upgrade actually happened before cleanup runs. Match this to $UpgradeSku above
$ExpectedOSVersionContains = "2025"

# Sanitize the user-provided volume label: strip characters NTFS labels don't allow
# (* ? / \ | : < > " and control chars) and enforce the 32-char NTFS limit.
$rawUpgradeVolumeLabel = $UpgradeVolumeLabel
$UpgradeVolumeLabel = ($UpgradeVolumeLabel -replace '[\*\?/\\\|:<>"\x00-\x1F]', '').Trim()
if ($UpgradeVolumeLabel.Length -gt 32) { $UpgradeVolumeLabel = $UpgradeVolumeLabel.Substring(0, 32) }
if ([string]::IsNullOrWhiteSpace($UpgradeVolumeLabel)) {
    $UpgradeVolumeLabel = "UPGRADEMEDIA"
}

# ===============
# LOGGING SETUP
# ===============

$LogFolder = if ($env:OS -eq "Windows_NT") { "C:\AzureVMUpgradeLogs" } else { Join-Path ([System.IO.Path]::GetTempPath()) "AzureVMUpgradeLogs" }
if (-not (Test-Path -Path $LogFolder)) {
    New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogFolder "$VMName-Upgrade-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","STEP")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        "ERROR" { Write-Output $line }
        "WARN"  { Write-Output $line }
        "STEP"  { Write-Output $line }
        default { Write-Output $line }
    }
}

# ---------------------------------------------------------------------------
# SAFE VM RUN COMMAND HELPER
# Azure permits only one Run Command extension execution at a time.
# If another Run Command is still finishing, Azure returns HTTP 409 Conflict.
#----------------------------------------------------------------------------
function Invoke-AzVMRunCommandSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [int]$MaxConflictRetries = 60,
        [int]$RetryDelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaxConflictRetries; $attempt++) {
        try {
            return Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $VMName `
                -CommandId "RunPowerShellScript" -ScriptPath $ScriptPath -ErrorAction Stop
        } catch {
            $errorText = $_.Exception.Message
            $isRunCommandBusy = ($errorText -match "Run command extension execution is in progress") -or
                                ($errorText -match "StatusCode:\s*409") -or
                                ($errorText -match "ErrorCode:\s*Conflict")

            if (-not $isRunCommandBusy) {
                throw
            }

            if ($attempt -eq $MaxConflictRetries) {
                throw "Azure VM Run Command remained busy after $MaxConflictRetries retries ($([int]($MaxConflictRetries * $RetryDelaySeconds / 60)) minutes). Last error: $errorText"
            }

            Write-Log "Azure VM Run Command is busy (HTTP 409). Waiting $RetryDelaySeconds seconds before retry $($attempt + 1)/$MaxConflictRetries..." -Level WARN
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

# ---------------------------------------------------------------------------
# WRITE-VM-LOG HELPER
# Writes a timestamped milestone into the log file INSIDE the target VM.
# Azure-side actions (snapshot/disk/attach/cleanup) are initiated from this
# ---------------------------------------------------------------------------
function Write-VMLogRemote {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","WARN","ERROR","STEP")][string]$Level = "INFO"
    )

    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $messageB64 = [Convert]::ToBase64String($messageBytes)
    $levelBytes = [System.Text.Encoding]::UTF8.GetBytes($Level)
    $levelB64 = [Convert]::ToBase64String($levelBytes)

    $remoteScript = @'
$ErrorActionPreference = "Continue"
$folder = "__VMLOGFOLDER__"
$path   = "__VMLOGPATH__"
$msg = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__MESSAGE_B64__"))
$level = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("__LEVEL_B64__"))

try {
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $path -Value "[$ts] [$level] $msg" -Encoding UTF8
} catch {
    Write-Output "Could not write VM upgrade log: $($_.Exception.Message)"
}
'@

    $remoteScript = $remoteScript.Replace("__VMLOGFOLDER__", $VMLogFolder)
    $remoteScript = $remoteScript.Replace("__VMLOGPATH__", $VMLogPath)
    $remoteScript = $remoteScript.Replace("__MESSAGE_B64__", $messageB64)
    $remoteScript = $remoteScript.Replace("__LEVEL_B64__", $levelB64)

    $tempPath = Join-Path $LogFolder "_temp_vm_log.ps1"
    $remoteScript | Out-File -LiteralPath $tempPath -Encoding utf8 -Force

    try {
        Invoke-AzVMRunCommandSafe -ScriptPath $tempPath -ErrorAction Stop | Out-Null
    } catch {
        # Do not stop the upgrade only because a milestone could not be written.
        Write-Log "VM milestone log write failed (non-fatal): $($_.Exception.Message)" -Level WARN
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "=================================================================="
Write-Log "Azure VM In-Place Upgrade automation started."
Write-Log "Log file: $LogFile"
Write-Log "Target VM: $VMName | Resource Group: $ResourceGroup | Location: $Location"
Write-Log "Target upgrade SKU: $UpgradeSku"
Write-Log "Upgrade media volume label: $UpgradeVolumeLabel"
if ($rawUpgradeVolumeLabel -ne $UpgradeVolumeLabel) {
    Write-Log "NOTE: The volume label you supplied ('$rawUpgradeVolumeLabel') contained invalid/empty characters and was adjusted to '$UpgradeVolumeLabel'." -Level WARN
}
Write-Log "=================================================================="

# Tracks whether the upgrade actually succeeded - gates the cleanup step at the end.
# Do NOT delete snapshots/upgrade disk unless this stays $true all the way through.
$UpgradeTriggerFailed = $false
$UpgradeVerified = $false

# ================================
# Module check + Azure connection
# =================================

try {
    Write-Log "Checking for Az PowerShell module..." -Level STEP
    if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
        Write-Log "Az module not found. Installing Az module for current user..." -Level WARN
        Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.Compute -ErrorAction Stop
    Write-Log "Az modules loaded successfully."
} catch {
    Write-Log "FATAL: Failed to load/install Az module. $_" -Level ERROR
    throw
}

try {
    Write-Log "Connecting to Azure..." -Level STEP
    $context = Get-AzContext
    if (-not $context) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }
    Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Connected to subscription: $SubscriptionId"
} catch {
    Write-Log "FATAL: Could not connect to Azure / set subscription context. $_" -Level ERROR
    throw
}

# ===========================================
# Validate VM exists and check current state
# ===========================================

try {
    Write-Log "Validating VM '$VMName' exists in resource group '$ResourceGroup'..." -Level STEP
    $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop
    Write-Log "VM found. VM Size: $($vm.HardwareProfile.VmSize)"

    $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses |
        Where-Object { $_.Code -like "PowerState*" } | Select-Object -ExpandProperty DisplayStatus
    Write-Log "Current VM power state: $vmStatus"

    if ($vmStatus -ne "VM running") {
        Write-Log "VM is not running. Starting VM..." -Level WARN
        Start-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop | Out-Null
        Write-Log "VM start command issued. Waiting 60 seconds for boot..."
        Start-Sleep -Seconds 60
    }

    # Create the authoritative timestamped log inside the target VM.
    $initVmLogScript = @'
$ErrorActionPreference = "Stop"
$folder = "__VMLOGFOLDER__"
$path = "__VMLOGPATH__"
if (-not (Test-Path -LiteralPath $folder)) {
    New-Item -Path $folder -ItemType Directory -Force | Out-Null
}
$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
@(
    "=================================================================="
    "WINDOWS SERVER 2025 IN-PLACE UPGRADE LOG"
    "Started             : $ts"
    "Log file            : $path"
    "Target              : $env:COMPUTERNAME"
    "=================================================================="
    "[$ts] [STEP] Upgrade automation log initialized."
) | Set-Content -LiteralPath $path -Encoding UTF8
Write-Output "Initialized VM log: $path"
'@
    $initVmLogScript = $initVmLogScript.Replace("__VMLOGFOLDER__", $VMLogFolder)
    $initVmLogScript = $initVmLogScript.Replace("__VMLOGPATH__", $VMLogPath)
    $initPath = Join-Path $LogFolder "_temp_init_vm_log.ps1"
    $initVmLogScript | Out-File -LiteralPath $initPath -Encoding utf8 -Force
    try {
        Invoke-AzVMRunCommandSafe -ScriptPath $initPath -ErrorAction Stop | Out-Null
        Write-Log "Authoritative VM log created: $VMLogPath"
    } finally {
        Remove-Item -LiteralPath $initPath -Force -ErrorAction SilentlyContinue
    }

    Write-VMLogRemote "PRE-CHECK: VM validation completed. VM is available for the upgrade workflow." "STEP"
} catch {
    Write-Log "FATAL: Could not validate/start the VM. $_" -Level ERROR
    throw
}

# ============================================================
# Pre-flight checks: C: drive free space, and third-party
# antivirus/security software. Either failing here stops the script
# ============================================================

try {
    Write-Log "Running pre-flight checks (free space >= ${MinFreeSpaceGB}GB, no third-party security software running)..." -Level STEP
    Write-VMLogRemote "PRE-CHECK: Checking C: drive free space and third-party security software." "STEP"

    $vendorPatternList = $ThirdPartySecurityVendorPatterns -join "|"

    $preflightScript = @'
$ErrorActionPreference = "Stop"
$VMLogPath = "__VMLOGPATH__"
$VMLogFolder = Split-Path $VMLogPath -Parent
if (-not (Test-Path $VMLogFolder)) { New-Item -Path $VMLogFolder -ItemType Directory -Force | Out-Null }
function Write-VMLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $VMLogPath -Value "[$ts] $msg"
}

$minFreeGB = __MINFREEGB__
$vendorPatterns = "__VENDORPATTERNS__" -split '\|'

Write-VMLog "STEP: Pre-flight checks - starting."

# --- Free space check ---
$drive = Get-PSDrive -Name C -ErrorAction Stop
$freeGB = [math]::Round($drive.Free / 1GB, 2)
Write-Output "FREE_SPACE_GB:$freeGB"
Write-VMLog "C: drive free space: ${freeGB}GB (minimum required: ${minFreeGB}GB)."

# --- Third-party security software check ---
$runningServices = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" }
$detected = @()
foreach ($svc in $runningServices) {
    foreach ($pattern in $vendorPatterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($svc.DisplayName -like "*$pattern*" -or $svc.Name -like "*$pattern*") {
            $detected += "$($svc.DisplayName) ($($svc.Name))"
            break
        }
    }
}
$detected = $detected | Select-Object -Unique

if ($detected.Count -gt 0) {
    Write-Output "THIRDPARTY_SECURITY_DETECTED:$($detected -join '; ')"
    Write-VMLog "Third-party security software detected and RUNNING: $($detected -join '; ')"
} else {
    Write-Output "THIRDPARTY_SECURITY_DETECTED:NONE"
    Write-VMLog "No third-party security software detected running."
}

Write-VMLog "STEP: Pre-flight checks - finished."
'@

    $preflightScript = $preflightScript.Replace("__VMLOGPATH__", $VMLogPath)
    $preflightScript = $preflightScript.Replace("__MINFREEGB__", "$MinFreeSpaceGB")
    $preflightScript = $preflightScript.Replace("__VENDORPATTERNS__", $vendorPatternList)
    $preflightPath = Join-Path $LogFolder "_temp_preflight.ps1"
    $preflightScript | Out-File -LiteralPath $preflightPath -Encoding utf8 -Force

    try {
        $preflightResult = Invoke-AzVMRunCommandSafe -ScriptPath $preflightPath -ErrorAction Stop

        $preflightOutput = ($preflightResult.Value | Select-Object -ExpandProperty Message) -join "`n"
        Write-Log "Pre-flight check raw output:`n$preflightOutput"

        # --- Evaluate free space ---
        $freeSpaceLine = ($preflightOutput -split "`n") | Where-Object { $_ -match "^FREE_SPACE_GB:" } | Select-Object -First 1
        if (-not $freeSpaceLine) {
            throw "Could not determine C: drive free space from the VM (no FREE_SPACE_GB output received)."
        }
        $freeSpaceGB = [double]($freeSpaceLine -replace "FREE_SPACE_GB:", "").Trim()
        Write-Log "C: drive free space on '$VMName': ${freeSpaceGB}GB (minimum required: ${MinFreeSpaceGB}GB)."

        if ($freeSpaceGB -lt $MinFreeSpaceGB) {
            Write-Log "FATAL: Insufficient free space on C: drive. Free: ${freeSpaceGB}GB, Required: ${MinFreeSpaceGB}GB. Free up space and re-run." -Level ERROR
            Write-VMLogRemote "ERROR: Pre-flight check FAILED - insufficient C: drive free space (${freeSpaceGB}GB free, ${MinFreeSpaceGB}GB required). Aborting before any changes were made." "ERROR"
            throw "Insufficient free space on C: drive: ${freeSpaceGB}GB free, ${MinFreeSpaceGB}GB required."
        }
        Write-Log "Free space check PASSED."

        # --- Evaluate third-party security software ---
        $secLine = ($preflightOutput -split "`n") | Where-Object { $_ -match "^THIRDPARTY_SECURITY_DETECTED:" } | Select-Object -First 1
        if (-not $secLine) {
            throw "Could not determine third-party security software status from the VM (no THIRDPARTY_SECURITY_DETECTED output received)."
        }
        $secValue = ($secLine -replace "THIRDPARTY_SECURITY_DETECTED:", "").Trim()

        if ($secValue -ne "NONE" -and -not [string]::IsNullOrWhiteSpace($secValue)) {
            Write-Log "FATAL: Third-party antivirus/security software is running on '$VMName': $secValue. This can interfere with the in-place upgrade. Disable it (or add an exclusion process for this run) and re-run the script." -Level ERROR
            Write-VMLogRemote "ERROR: Pre-flight check FAILED - third-party security software detected running: $secValue. Aborting before any changes were made." "ERROR"
            throw "Third-party antivirus/firewall/security software is running on the VM: $secValue"
        }
        Write-Log "Third-party security software check PASSED (none detected running)."

        Write-VMLogRemote "PRE-CHECK: Free space and third-party security checks both PASSED." "INFO"
    } finally {
        Remove-Item -LiteralPath $preflightPath -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log "FATAL: Pre-flight checks failed. $_" -Level ERROR
    throw
}

# =================================
# Snapshot OS disk and data disks
# =================================

$snapshotNames = @()

try {
    Write-Log "Creating snapshot of OS disk..." -Level STEP
    Write-VMLogRemote "SNAPSHOT: Creating OS disk snapshot." "STEP"
    $osDiskName = $vm.StorageProfile.OsDisk.Name
    $osDisk = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $osDiskName -ErrorAction Stop

    $osSnapshotConfig = New-AzSnapshotConfig -SourceUri $osDisk.Id -Location $Location -CreateOption Copy
    $osSnapshotName = "$SnapshotPrefix-OSDisk"
    New-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $osSnapshotName -Snapshot $osSnapshotConfig -ErrorAction Stop | Out-Null
    $snapshotNames += $osSnapshotName
    Write-Log "OS disk snapshot created: $osSnapshotName"
    Write-VMLogRemote "SNAPSHOT: OS disk snapshot created: $osSnapshotName." "INFO"

    $dataDisks = $vm.StorageProfile.DataDisks
    if ($dataDisks -and $dataDisks.Count -gt 0) {
        foreach ($dd in $dataDisks) {
            Write-Log "Creating snapshot of data disk: $($dd.Name)" -Level STEP
            Write-VMLogRemote "SNAPSHOT: Creating data disk snapshot: $($dd.Name)." "STEP"
            $dataDiskObj = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName $dd.Name -ErrorAction Stop
            $dataSnapConfig = New-AzSnapshotConfig -SourceUri $dataDiskObj.Id -Location $Location -CreateOption Copy
            $dataSnapName = "$SnapshotPrefix-$($dd.Name)"
            New-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $dataSnapName -Snapshot $dataSnapConfig -ErrorAction Stop | Out-Null
            $snapshotNames += $dataSnapName
            Write-Log "Data disk snapshot created: $dataSnapName"
            Write-VMLogRemote "SNAPSHOT: Data disk snapshot created: $dataSnapName." "INFO"
        }
    } else {
        Write-Log "No data disks found on this VM."
        Write-VMLogRemote "SNAPSHOT: No data disks found on this VM." "INFO"
    }
} catch {
    Write-Log "FATAL: Snapshot creation failed. Aborting before touching the VM. $_" -Level ERROR
    Write-VMLogRemote "ERROR: Snapshot creation failed. $($_.Exception.Message)" "ERROR"
    throw
}

# =======================================
# Create the upgrade media managed disk
# =======================================

try {
    Write-Log "Checking whether upgrade media disk '$UpgradeDiskName' already exists in RG '$UpgradeDiskRG'..." -Level STEP

    $existingUpgradeDisk = Get-AzDisk -ResourceGroupName $UpgradeDiskRG -DiskName $UpgradeDiskName -ErrorAction SilentlyContinue

    if ($existingUpgradeDisk) {
        Write-Log "Existing upgrade media disk found (Size: $($existingUpgradeDisk.DiskSizeGB) GB). Reusing it - skipping creation."
        Write-VMLogRemote "UPGRADE DISK: Existing media disk found and reused. Name=$UpgradeDiskName; Size=$($existingUpgradeDisk.DiskSizeGB) GB." "INFO"
    } else {
        Write-Log "No existing upgrade media disk found. Creating a new one (SKU: $UpgradeSku, Size: $UpgradeDiskSizeGB GB)..." -Level STEP
        Write-VMLogRemote "UPGRADE DISK: Creating media disk. SKU=$UpgradeSku; Requested size=$UpgradeDiskSizeGB GB." "STEP"

        $publisher = "MicrosoftWindowsServer"
        $offer     = "WindowsServerUpgrade"
        $managedDiskSKU = "Standard_LRS"

        if (-not (Get-AzResourceGroup -Name $UpgradeDiskRG -ErrorAction SilentlyContinue)) {
            Write-Log "Resource group '$UpgradeDiskRG' not found. Creating it..."
            New-AzResourceGroup -Name $UpgradeDiskRG -Location $Location | Out-Null
        }

        $versions = Get-AzVMImage -PublisherName $publisher -Location $Location -Offer $offer -Skus $UpgradeSku |
            Sort-Object -Descending { [version]$_.Version }

        if (-not $versions -or $versions.Count -eq 0) {
            throw "No upgrade media image versions found for SKU '$UpgradeSku' in location '$Location'."
        }

        $latestVersion = $versions[0].Version
        Write-Log "Latest upgrade media image version found: $latestVersion"
        Write-VMLogRemote "UPGRADE DISK: Source Windows Server 2025 upgrade image version selected: $latestVersion." "INFO"

        $image = Get-AzVMImage -Location $Location -PublisherName $publisher -Offer $offer -Skus $UpgradeSku -Version $latestVersion -ErrorAction Stop

        if ($Zone -and $Zone.Trim() -ne "") {
            $diskConfig = New-AzDiskConfig -SkuName $managedDiskSKU -CreateOption FromImage -Zone $Zone -Location $Location -DiskSizeGB $UpgradeDiskSizeGB
        } else {
            $diskConfig = New-AzDiskConfig -SkuName $managedDiskSKU -CreateOption FromImage -Location $Location -DiskSizeGB $UpgradeDiskSizeGB
        }

        Set-AzDiskImageReference -Disk $diskConfig -Id $image.Id -Lun 0

        try {
            New-AzDisk -ResourceGroupName $UpgradeDiskRG -DiskName $UpgradeDiskName -Disk $diskConfig -ErrorAction Stop | Out-Null
        } catch {
            # If the source image is larger than the requested size, Azure will reject the size override.
            # Fall back to letting Azure use the image's native size instead of failing outright.
            Write-Log "Disk creation with explicit size $UpgradeDiskSizeGB GB failed (image may require a larger size). Retrying with default image size..." -Level WARN
            Write-VMLogRemote "WARN: Requested upgrade disk size $UpgradeDiskSizeGB GB was rejected. Retrying with the image native size." "WARN"
            if ($Zone -and $Zone.Trim() -ne "") {
                $diskConfig = New-AzDiskConfig -SkuName $managedDiskSKU -CreateOption FromImage -Zone $Zone -Location $Location
            } else {
                $diskConfig = New-AzDiskConfig -SkuName $managedDiskSKU -CreateOption FromImage -Location $Location
            }
            Set-AzDiskImageReference -Disk $diskConfig -Id $image.Id -Lun 0
            New-AzDisk -ResourceGroupName $UpgradeDiskRG -DiskName $UpgradeDiskName -Disk $diskConfig -ErrorAction Stop | Out-Null
        }

        $createdDisk = Get-AzDisk -ResourceGroupName $UpgradeDiskRG -DiskName $UpgradeDiskName -ErrorAction SilentlyContinue
        $actualDiskSize = if ($createdDisk) { $createdDisk.DiskSizeGB } else { $UpgradeDiskSizeGB }
        Write-Log "Upgrade media disk '$UpgradeDiskName' created successfully. Actual size: $actualDiskSize GB."
        Write-VMLogRemote "UPGRADE DISK: Media disk created successfully. Name=$UpgradeDiskName; Actual size=$actualDiskSize GB." "INFO"
    }
} catch {
    Write-Log "FATAL: Failed to create or reuse upgrade media disk. $_" -Level ERROR
    Write-VMLogRemote "ERROR: Failed to create or reuse upgrade media disk. $($_.Exception.Message)" "ERROR"
    throw
}

# ===================================
# Attach the upgrade disk to the VM
# ===================================

try {
    Write-Log "Attaching upgrade media disk to VM '$VMName'..." -Level STEP
    Write-VMLogRemote "UPGRADE DISK: Attaching media disk '$UpgradeDiskName' to VM '$VMName'." "STEP"

    $upgradeDisk = Get-AzDisk -ResourceGroupName $UpgradeDiskRG -DiskName $UpgradeDiskName -ErrorAction Stop
    $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop

    # Find next free LUN
    $usedLuns = $vm.StorageProfile.DataDisks | Select-Object -ExpandProperty Lun
    $nextLun = 0
    while ($usedLuns -contains $nextLun) { $nextLun++ }

    Add-AzVMDataDisk -VM $vm -Name $UpgradeDiskName -CreateOption Attach -ManagedDiskId $upgradeDisk.Id -Lun $nextLun -ErrorAction Stop | Out-Null
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $vm -ErrorAction Stop | Out-Null

    Write-Log "Upgrade media disk attached at LUN $nextLun."
    Write-VMLogRemote "UPGRADE DISK: Media disk attached successfully at LUN $nextLun." "INFO"
} catch {
    Write-Log "FATAL: Failed to attach upgrade media disk. $_" -Level ERROR
    Write-VMLogRemote "ERROR: Failed to attach upgrade media disk. $($_.Exception.Message)" "ERROR"
    throw
}

# ==============================================
# Label the upgrade media volume inside the VM
# ==============================================

try {
    Write-Log "Labeling upgrade media volume inside the VM as '$UpgradeVolumeLabel' (LUN $nextLun)..." -Level STEP
    Write-VMLogRemote "UPGRADE DISK: Labeling upgrade media volume as '$UpgradeVolumeLabel' (LUN $nextLun)." "STEP"

    $labelVolumeScript = @'
$ErrorActionPreference = "Stop"
$VMLogPath = "__VMLOGPATH__"
$VMLogFolder = Split-Path $VMLogPath -Parent
if (-not (Test-Path $VMLogFolder)) { New-Item -Path $VMLogFolder -ItemType Directory -Force | Out-Null }
function Write-VMLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $VMLogPath -Value "[$ts] $msg"
}

$targetLun = __LUN__
$label = "__VOLUMELABEL__"

Write-VMLog "STEP: Label upgrade media volume - starting. Target LUN=$targetLun, Label=$label."

try {
    # Give Windows a moment to enumerate the newly attached disk.
    Start-Sleep -Seconds 10

    $disk = Get-Disk | Where-Object { $_.Location -match "LUN $targetLun\b" } | Select-Object -First 1

    if (-not $disk) {
        # Retry once after a longer wait - the disk can take a few extra seconds to enumerate.
        Start-Sleep -Seconds 15
        $disk = Get-Disk | Where-Object { $_.Location -match "LUN $targetLun\b" } | Select-Object -First 1
    }

    if (-not $disk) {
        Write-Output "WARNING: Could not identify the upgrade disk at LUN $targetLun. Volume label was NOT set. Setup.exe search will fall back to scanning all non-C: drives."
        Write-VMLog "WARNING: Could not identify disk at LUN $targetLun via Get-Disk -Location. Label not applied."
    } else {
        Write-VMLog "Identified upgrade disk: Disk Number $($disk.Number), Location='$($disk.Location)'."

        if ($disk.IsOffline) {
            Set-Disk -Number $disk.Number -IsOffline $false
            Write-VMLog "Disk $($disk.Number) brought online."
        }
        if ($disk.IsReadOnly) {
            Set-Disk -Number $disk.Number -IsReadOnly $false
            Write-VMLog "Disk $($disk.Number) read-only flag cleared."
        }

        Start-Sleep -Seconds 3

        $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
            Where-Object { $_.DriveLetter } | Select-Object -First 1

        if (-not $partition) {
            $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.Type -ne "Reserved" -and $_.Type -ne "Unknown" } | Select-Object -First 1

            # This partition has no drive letter yet (can happen right after coming online) -
            # assign one so it can be addressed by Set-Volume.
            if ($partition -and -not $partition.DriveLetter) {
                try {
                    $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $partition = Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -ErrorAction SilentlyContinue
                } catch {
                    Write-VMLog "WARNING: Could not assign a drive letter to Disk $($disk.Number) Partition $($partition.PartitionNumber): $_"
                }
            }
        }

        if (-not $partition -or -not $partition.DriveLetter) {
            Write-Output "WARNING: Disk $($disk.Number) (LUN $targetLun) has no accessible/lettered partition. Volume label was NOT set."
            Write-VMLog "WARNING: No usable lettered partition found on Disk $($disk.Number). Label not applied."
        } else {
            # Set-Volume does not accept -Partition; address the volume by drive letter instead.
            Set-Volume -DriveLetter $partition.DriveLetter -NewFileSystemLabel $label -ErrorAction Stop
            $vol = Get-Volume -DriveLetter $partition.DriveLetter
            Write-Output "Upgrade media volume labeled '$label' on drive $($vol.DriveLetter): (Disk $($disk.Number), LUN $targetLun)."
            Write-VMLog "Volume label set to '$label' on drive $($vol.DriveLetter): (Disk $($disk.Number), LUN $targetLun)."
        }
    }
} catch {
    Write-Output "WARNING: Could not label the upgrade media volume: $_"
    Write-VMLog "WARNING: Could not label the upgrade media volume: $_"
}
Write-VMLog "STEP: Label upgrade media volume - finished."
'@

    $labelVolumeScript = $labelVolumeScript.Replace("__VMLOGPATH__", $VMLogPath)
    $labelVolumeScript = $labelVolumeScript.Replace("__LUN__", "$nextLun")
    $labelVolumeScript = $labelVolumeScript.Replace("__VOLUMELABEL__", $UpgradeVolumeLabel)
    $labelVolumeScript | Out-File -FilePath (Join-Path $LogFolder "_temp_label_volume.ps1") -Encoding utf8 -Force

    $labelResult = Invoke-AzVMRunCommandSafe -ScriptPath (Join-Path $LogFolder "_temp_label_volume.ps1") -ErrorAction Stop

    foreach ($status in $labelResult.Value) {
        Write-Log "Volume label output: $($status.Message)"
    }
} catch {
    # Non-fatal: Step 5 falls back to scanning all non-C: drives if the label was not applied.
    Write-Log "Could not label the upgrade media volume (non-fatal, Step 5 will fall back to scanning all non-C: drives). $_" -Level WARN
    Write-VMLogRemote "WARN: Could not label the upgrade media volume. Step 5 will fall back to scanning all non-C: drives. $($_.Exception.Message)" "WARN"
}

# ===============================================
# Disable Windows Defender real-time protection
# ===============================================

if ($ManageDefender) {
    try {
        Write-Log "Disabling Windows Defender real-time protection inside the VM..." -Level STEP
        Write-VMLogRemote "DEFENDER: Disabling Windows Defender real-time protection before OS upgrade." "STEP"

        $disableDefenderScript = @'
$ErrorActionPreference = "Continue"
$VMLogPath = "__VMLOGPATH__"
$VMLogFolder = Split-Path $VMLogPath -Parent
if (-not (Test-Path $VMLogFolder)) { New-Item -Path $VMLogFolder -ItemType Directory -Force | Out-Null }
function Write-VMLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $VMLogPath -Value "[$ts] $msg"
}
Write-VMLog "STEP: Disable Windows Defender - starting."
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.IsTamperProtected) {
        $msg = "WARNING: Tamper Protection is ON. Set-MpPreference may not take effect. Disable Tamper Protection manually (Windows Security app or Intune/Defender for Cloud policy) if the upgrade fails due to AV interference."
        Write-Output $msg
        Write-VMLog $msg
    }
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    Write-Output "Set-MpPreference -DisableRealtimeMonitoring $true executed."
    Write-VMLog "Set-MpPreference -DisableRealtimeMonitoring `$true executed."
    $status = Get-MpComputerStatus
    Write-Output "RealTimeProtectionEnabled is now: $($status.RealTimeProtectionEnabled)"
    Write-VMLog "RealTimeProtectionEnabled is now: $($status.RealTimeProtectionEnabled)"
} catch {
    Write-Output "Could not modify Defender settings: $_"
    Write-VMLog "ERROR - Could not modify Defender settings: $_"
}
Write-VMLog "STEP: Disable Windows Defender - finished."
'@
        $disableDefenderScript = $disableDefenderScript -replace '__VMLOGPATH__', $VMLogPath
        $disableDefenderScript | Out-File -FilePath (Join-Path $LogFolder "_temp_disable_defender.ps1") -Encoding utf8 -Force

        $defenderResult = Invoke-AzVMRunCommandSafe -ScriptPath (Join-Path $LogFolder "_temp_disable_defender.ps1") -ErrorAction Stop

        foreach ($status in $defenderResult.Value) {
            Write-Log "Defender disable output: $($status.Message)"
        }
    } catch {
        Write-Log "Could not disable Windows Defender (non-fatal, continuing). $_" -Level WARN
        Write-VMLogRemote "WARN: Could not disable Windows Defender. Upgrade continues. $($_.Exception.Message)" "WARN"
    }
} else {
    Write-Log "ManageDefender = `$false - skipping Defender disable step. Make sure AV is handled manually if needed." -Level WARN
    Write-VMLogRemote "DEFENDER: Defender disable step skipped because ManageDefender is false." "WARN"
}

# ============================================================
# Ensure VM is running, automatically select the matching target image, then trigger setup.exe
# ============================================================

try {
    Write-Log "Confirming VM is running before triggering the upgrade..." -Level STEP
    $vmStatus = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses |
        Where-Object { $_.Code -like "PowerState*" } | Select-Object -ExpandProperty DisplayStatus

    if ($vmStatus -ne "VM running") {
        Start-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 60
    }
    Write-Log "VM confirmed running."
    Write-VMLogRemote "PRE-CHECK: VM confirmed running immediately before Windows Setup." "INFO"

    Write-Log "Triggering in-place upgrade via Azure Run Command (this runs setup.exe inside the VM)..." -Level STEP
    Write-VMLogRemote "OS UPGRADE: Starting automatic Windows Server 2025 in-place upgrade. The script will match the current edition and installation type, then preserve files, settings and applications." "STEP"
    Write-Log "NOTE: The VM will disconnect/reboot several times during this process. That is expected."

    # This script block executes INSIDE the guest VM.
    # It:
    #   1. Finds setup.exe on the attached upgrade media.
    #   2. Finds install.wim/install.esd used by Windows Setup.
    #   3. Reads the image list with DISM.
    #   4. Selects the Windows Server 2025 image containing "Desktop Experience".
    #      It also tries to match the currently installed Server edition
    #      (Standard/Datacenter) so we do not accidentally select the wrong edition.
    #   5. Starts setup.exe with /auto upgrade and /imageindex.
    #
    # /auto upgrade is the Windows Setup option that preserves applications,
    # files and settings for an in-place upgrade.
    # /imageindex removes the four-image selection prompt.
    $runCommandScript = @'
$ErrorActionPreference = "Stop"
$VMLogPath = "__VMLOGPATH__"
$VMLogFolder = Split-Path $VMLogPath -Parent
if (-not (Test-Path $VMLogFolder)) { New-Item -Path $VMLogFolder -ItemType Directory -Force | Out-Null }
$UpgradeVolumeLabel = "__VOLUMELABEL__"

function Write-VMLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $VMLogPath -Value "[$ts] $msg"
}

function Get-ImageInfo {
    param([Parameter(Mandatory=$true)][string]$ImageFile)

    $dismOutput = & dism.exe /English /Get-WimInfo /WimFile:$ImageFile 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "DISM could not read image file '$ImageFile'. DISM exit code: $exitCode. Output: $($dismOutput -join ' ')"
    }

    return $dismOutput
}

Write-VMLog "STEP: Locate upgrade media, select Desktop Experience image and launch setup.exe - starting."

# ----------------------
# Locate setup.exe.
# ----------------------
$setupPath = $null

$labeledVolume = Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.DriveLetter -and $_.FileSystemLabel -eq $UpgradeVolumeLabel } |
    Select-Object -First 1

if ($labeledVolume) {
    $drv = $labeledVolume.DriveLetter
    $rootPath = "$($drv):\"
    Write-VMLog "Found upgrade volume by label '$UpgradeVolumeLabel' on drive $rootPath. Scanning only this drive for setup.exe."

    $found = Get-ChildItem -Path $rootPath -Filter "setup.exe" -Recurse -Depth 4 `
        -ErrorAction SilentlyContinue -File |
        Where-Object { $_.FullName -match '\\setup\.exe$' } |
        Select-Object -First 1

    if ($found) {
        $setupPath = $found.FullName
        Write-VMLog "Found setup.exe at: $setupPath"
    } else {
        Write-VMLog "WARNING: Labeled volume $rootPath did not contain setup.exe. Falling back to scanning all non-C: drives."
    }
} else {
    Write-VMLog "WARNING: No volume found with label '$UpgradeVolumeLabel'. Falling back to scanning all non-C: drives."
}

if (-not $setupPath) {
    $candidateDrives = Get-Volume |
        Where-Object { $_.DriveLetter -and $_.DriveLetter -ne "C" } |
        Select-Object -ExpandProperty DriveLetter

    Write-VMLog "Candidate non-C drives found: $($candidateDrives -join ', ')"

    foreach ($drv in $candidateDrives) {
        $rootPath = "$($drv):\"
        Write-VMLog "Scanning $rootPath for setup.exe..."

        $found = Get-ChildItem -Path $rootPath -Filter "setup.exe" -Recurse -Depth 4 `
            -ErrorAction SilentlyContinue -File |
            Where-Object { $_.FullName -match '\\setup\.exe$' } |
            Select-Object -First 1

        if ($found) {
            $setupPath = $found.FullName
            Write-VMLog "Found setup.exe at: $setupPath"
            break
        }
    }
}

if (-not $setupPath) {
    Write-Output "ERROR: Could not locate setup.exe on any attached upgrade media volume."
    Write-VMLog "ERROR: Could not locate setup.exe on any attached upgrade media volume."
    exit 1
}

$setupFolder = Split-Path $setupPath -Parent
Write-Output "Upgrade media setup.exe found at: $setupPath"
Write-VMLog "Upgrade media setup.exe found at: $setupPath"

# ------------------------------------------------------------------
# Locate install.wim or install.esd belonging to this setup media.
# ------------------------------------------------------------------
$sourcesFolder = Join-Path $setupFolder "sources"
$imageFile = $null

if (Test-Path (Join-Path $sourcesFolder "install.wim")) {
    $imageFile = Join-Path $sourcesFolder "install.wim"
} elseif (Test-Path (Join-Path $sourcesFolder "install.esd")) {
    $imageFile = Join-Path $sourcesFolder "install.esd"
} else {
    $imageCandidates = Get-ChildItem -Path $setupFolder -Filter "install.wim" -Recurse -Depth 4 `
        -ErrorAction SilentlyContinue -File | Select-Object -First 1

    if (-not $imageCandidates) {
        $imageCandidates = Get-ChildItem -Path $setupFolder -Filter "install.esd" -Recurse -Depth 4 `
            -ErrorAction SilentlyContinue -File | Select-Object -First 1
    }

    if ($imageCandidates) {
        $imageFile = $imageCandidates.FullName
    }
}

if (-not $imageFile) {
    Write-Output "ERROR: Could not locate install.wim or install.esd on the upgrade media."
    Write-VMLog "ERROR: Could not locate install.wim or install.esd on the upgrade media."
    exit 1
}

Write-Output "Windows image file found: $imageFile"
Write-VMLog "Windows image file found: $imageFile"

# ------------------------------------------------------------------
# Detect the currently installed Windows Server edition.
# ------------------------------------------------------------------
$currentProductName = $null
$currentEditionId = $null

try {
    $computerInfo = Get-ComputerInfo -Property WindowsProductName, WindowsEditionId -ErrorAction Stop
    $currentProductName = [string]$computerInfo.WindowsProductName
    $currentEditionId = [string]$computerInfo.WindowsEditionId
} catch {
    $currentProductName = [string](Get-ItemPropertyValue `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
        -Name "ProductName" -ErrorAction SilentlyContinue)

    $currentEditionId = [string](Get-ItemPropertyValue `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
        -Name "EditionID" -ErrorAction SilentlyContinue)
}

Write-Output "Current OS: $currentProductName"
Write-Output "Current edition ID: $currentEditionId"
Write-VMLog "Current OS: $currentProductName | Edition ID: $currentEditionId"

# Determine whether current OS is Standard or Datacenter.
$editionFamily = $null

if ($currentEditionId -match "Datacenter" -or $currentProductName -match "Datacenter") {
    $editionFamily = "Datacenter"
} elseif ($currentEditionId -match "Standard" -or $currentProductName -match "Standard") {
    $editionFamily = "Standard"
}

Write-VMLog "Detected edition family: $editionFamily"

# ------------------------------------------------------------------
# Read all image names and indexes from DISM.
# ------------------------------------------------------------------
$dismOutput = Get-ImageInfo -ImageFile $imageFile

$imageEntries = @()
$currentIndex = $null

foreach ($line in $dismOutput) {
    $trimmed = ([string]$line).Trim()

    if ($trimmed -match '^Index\s*:\s*(\d+)$') {
        $currentIndex = [int]$Matches[1]
    } elseif ($currentIndex -ne $null -and $trimmed -match '^Name\s*:\s*(.+)$') {
        $imageEntries += [PSCustomObject]@{
            Index = $currentIndex
            Name  = $Matches[1].Trim()
        }
        $currentIndex = $null
    }
}

if (-not $imageEntries -or $imageEntries.Count -eq 0) {
    Write-Output "ERROR: DISM did not return any install image indexes/names."
    Write-VMLog "ERROR: DISM did not return any install image indexes/names."
    Write-VMLog "DISM output: $($dismOutput -join ' | ')"
    exit 1
}

Write-VMLog "Images detected on media:"
foreach ($img in $imageEntries) {
    Write-VMLog "  Index $($img.Index): $($img.Name)"
}

# ------------------------------------------------------------------
# AUTOMATIC TARGET IMAGE SELECTION
# The source media can contain :
#   - Windows Server 2025 Standard
#   - Windows Server 2025 Standard (Desktop Experience)
#   - Windows Server 2025 Datacenter
#   - Windows Server 2025 Datacenter (Desktop Experience)
#
# The script detects the CURRENT OS and chooses the matching target:
#
#   Current: Standard + Desktop Experience
#       -> Target: Standard + Desktop Experience
#
#   Current: Standard + Server Core
#       -> Target: Standard + Server Core
#
#   Current: Datacenter + Desktop Experience
#       -> Target: Datacenter + Desktop Experience
#
#   Current: Datacenter + Server Core
#       -> Target: Datacenter + Server Core
#
# ------------------------------------------------------------------

# Read the current installation type from the Windows registry.
# Typical values:
#   Server      = Desktop Experience / GUI installation
#   Server Core = Server Core installation
$currentInstallationType = $null

try {
    $currentInstallationType = [string](Get-ItemPropertyValue `
        -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
        -Name "InstallationType" -ErrorAction Stop)
} catch {
    $currentInstallationType = ""
}

# Determine whether the current OS is Desktop Experience or Server Core.
# We also check the product name as a fallback because some older/custom
# Windows Server images may not expose the expected InstallationType value.
$targetDesktopExperience = $false

if ($currentInstallationType -match "(?i)Server\s*Core") {
    $targetDesktopExperience = $false
} elseif ($currentInstallationType -match "(?i)Server") {
    $targetDesktopExperience = $true
} elseif ($currentProductName -match "(?i)Desktop\s*Experience") {
    $targetDesktopExperience = $true
} else {
    # Last-resort detection using GUI server features.
    try {
        $guiFeature = Get-WindowsFeature -Name Server-Gui-Mgmt-Infra -ErrorAction Stop
        if ($guiFeature.InstallState -eq "Installed") {
            $targetDesktopExperience = $true
        }
    } catch {
        # If this command is unavailable, fail safely below if we cannot
        # determine the installation type from the image names.
    }
}

if ($targetDesktopExperience) {
    $targetInstallType = "Desktop Experience"
} else {
    $targetInstallType = "Server Core"
}

Write-Output "Current InstallationType: $currentInstallationType"
Write-Output "Detected target installation type: $targetInstallType"
Write-VMLog "Current InstallationType: $currentInstallationType"
Write-VMLog "Detected target installation type: $targetInstallType"

# Normalize names so matching is not dependent on minor punctuation/case
# differences such as:
#   "(Desktop Experience)"
#   "Desktop Experience"
#   "Server Core"
function Test-ImageIsDesktopExperience {
    param([Parameter(Mandatory=$true)][string]$Name)

    return ($Name -match "(?i)Desktop\s*Experience")
}

function Test-ImageIsServerCore {
    param([Parameter(Mandatory=$true)][string]$Name)

    # Some media may explicitly say "Server Core"; other media simply omit
    # "Desktop Experience". We therefore treat an image as Core only when it
    # explicitly identifies itself as Server Core.
    return ($Name -match "(?i)Server\s*Core")
}

# First filter by the current edition family.
$editionCandidates = @()

if ($editionFamily) {
    $editionPattern = "(?i)\b" + [regex]::Escape($editionFamily) + "\b"

    $editionCandidates = @($imageEntries | Where-Object {
        $_.Name -match $editionPattern
    })
}

# If the edition cannot be detected, do NOT blindly choose an image.
# This is deliberately fail-safe because selecting the wrong edition can
# cause Setup to reject the in-place upgrade.
if (-not $editionFamily) {
    Write-Output "ERROR: Could not safely determine whether the current OS is Standard or Datacenter."
    Write-VMLog "ERROR: Could not safely determine the current OS edition family (Standard/Datacenter)."
    Write-VMLog "Current OS: $currentProductName | Edition ID: $currentEditionId"
    Write-VMLog "Available media images: $($imageEntries | ForEach-Object { "Index $($_.Index): $($_.Name)" } -join ' | ')"
    exit 1
}

if (-not $editionCandidates -or $editionCandidates.Count -eq 0) {
    Write-Output "ERROR: No target image matching current edition '$editionFamily' was found."
    Write-VMLog "ERROR: No target image matching current edition '$editionFamily' was found."
    Write-VMLog "Available media images: $($imageEntries | ForEach-Object { "Index $($_.Index): $($_.Name)" } -join ' | ')"
    exit 1
}

Write-VMLog "Images matching current edition '$editionFamily':"
foreach ($img in $editionCandidates) {
    Write-VMLog "  Index $($img.Index): $($img.Name)"
}

# Now match the installation type.
$selectedImage = $null

if ($targetDesktopExperience -eq $true) {

    # Desktop Experience is explicit and therefore the safest match.
    $typeCandidates = @($editionCandidates | Where-Object {
        Test-ImageIsDesktopExperience -Name $_.Name
    })

    if ($typeCandidates.Count -eq 1) {
        $selectedImage = $typeCandidates[0]
    } elseif ($typeCandidates.Count -gt 1) {
        # Prefer a non-Evaluation image if the media unexpectedly contains
        # multiple Desktop Experience variants.
        $selectedImage = $typeCandidates |
            Where-Object { $_.Name -notmatch "(?i)Evaluation|Eval" } |
            Select-Object -First 1

        if (-not $selectedImage) {
            $selectedImage = $typeCandidates[0]
        }
    }
} else {

    # For Server Core, prefer an explicitly named "Server Core" image.
    $typeCandidates = @($editionCandidates | Where-Object {
        Test-ImageIsServerCore -Name $_.Name
    })

    if ($typeCandidates.Count -eq 1) {
        $selectedImage = $typeCandidates[0]
    } elseif ($typeCandidates.Count -gt 1) {
        $selectedImage = $typeCandidates |
            Where-Object { $_.Name -notmatch "(?i)Evaluation|Eval" } |
            Select-Object -First 1

        if (-not $selectedImage) {
            $selectedImage = $typeCandidates[0]
        }
    } else {
        # Server Core media is commonly named simply:
        #   "Windows Server 2025 Standard"
        #   "Windows Server 2025 Datacenter"
        # while the GUI image is explicitly:
        #   "... (Desktop Experience)"
        #
        # Therefore, when there is no explicit "Server Core" name, select
        # the matching-edition image that is NOT Desktop Experience.
        $coreCandidates = @($editionCandidates | Where-Object {
            -not (Test-ImageIsDesktopExperience -Name $_.Name)
        })

        if ($coreCandidates.Count -eq 1) {
            $selectedImage = $coreCandidates[0]
        } elseif ($coreCandidates.Count -gt 1) {
            $selectedImage = $coreCandidates |
                Where-Object { $_.Name -notmatch "(?i)Evaluation|Eval" } |
                Select-Object -First 1

            if (-not $selectedImage) {
                $selectedImage = $coreCandidates[0]
            }
        }
    }
}

# Never silently select a wrong installation type.
if (-not $selectedImage) {
    Write-Output "ERROR: Could not find a safe image matching BOTH the current edition '$editionFamily' AND installation type '$targetInstallType'."
    Write-VMLog "ERROR: Could not find a safe image matching BOTH edition '$editionFamily' and installation type '$targetInstallType'."
    Write-VMLog "Current OS: $currentProductName | Edition ID: $currentEditionId | InstallationType: $currentInstallationType"
    Write-VMLog "Candidate images: $($editionCandidates | ForEach-Object { "Index $($_.Index): $($_.Name)" } -join ' | ')"
    exit 1
}

$imageIndex = [int]$selectedImage.Index
$imageName = [string]$selectedImage.Name

Write-Output "============================================================"
Write-Output "AUTOMATIC IMAGE SELECTION RESULT"
Write-Output "Current OS             : $currentProductName"
Write-Output "Current Edition ID     : $currentEditionId"
Write-Output "Current Installation   : $currentInstallationType"
Write-Output "Detected Edition       : $editionFamily"
Write-Output "Detected Install Type  : $targetInstallType"
Write-Output "Selected Image Index   : $imageIndex"
Write-Output "Selected Image Name    : $imageName"
Write-Output "============================================================"

Write-VMLog "AUTOMATIC IMAGE SELECTION RESULT:"
Write-VMLog "  Current OS            : $currentProductName"
Write-VMLog "  Current Edition ID    : $currentEditionId"
Write-VMLog "  Current Installation  : $currentInstallationType"
Write-VMLog "  Detected Edition      : $editionFamily"
Write-VMLog "  Detected Install Type : $targetInstallType"
Write-VMLog "  SELECTED IMAGE INDEX  : $imageIndex"
Write-VMLog "  SELECTED IMAGE NAME   : $imageName"

# ------------------------------------------------------------------
# Start Windows Setup.
#
# /auto upgrade = in-place upgrade, preserving apps, files and settings.
# /imageindex     = explicitly selects the image detected above.
# /dynamicupdate disable = keep the existing behaviour of this script.
# /eula accept    = accept EULA so Setup does not stop for that prompt.
# /quiet          = suppress interactive Setup UI.
#
# The image index is NEVER hard-coded. It is selected from the current
# OS edition + installation type at runtime.
# ------------------------------------------------------------------
Set-Location $setupFolder

$setupArguments = "/auto upgrade /imageindex $imageIndex /dynamicupdate disable /eula accept /quiet"

Write-VMLog "Launching setup.exe with arguments: $setupArguments"
Write-VMLog "This is an in-place upgrade and should keep files, settings and installed applications."
Write-VMLog "Windows Setup detailed logs: C:\Windows\Panther\setupact.log and C:\Windows\Panther\setuperr.log"

$setupProcess = Start-Process -FilePath $setupPath `
    -ArgumentList $setupArguments `
    -Wait `
    -PassThru `
    -NoNewWindow

$setupExitCode = $setupProcess.ExitCode

Write-Output "Setup.exe was launched. Initial setup process exit code: $setupExitCode"
Write-VMLog "Setup.exe initial process exit code: $setupExitCode"
Write-VMLog "The VM may reboot during the upgrade. A reboot/disconnect at this point is expected."

# Do not treat the initial setup.exe process exit as final upgrade success.
# The outer script will reboot/poll the VM and perform the post-upgrade OS check.
'@

    $runCommandScript = $runCommandScript -replace '__VMLOGPATH__', $VMLogPath
    $runCommandScript = $runCommandScript -replace '__VOLUMELABEL__', $UpgradeVolumeLabel
    $runCommandScript | Out-File -FilePath (Join-Path $LogFolder "_temp_runcommand.ps1") -Encoding utf8 -Force

    $result = Invoke-AzVMRunCommandSafe -ScriptPath (Join-Path $LogFolder "_temp_runcommand.ps1") -ErrorAction Stop

    foreach ($status in $result.Value) {
        Write-Log "RunCommand output [$($status.Code)]: $($status.Message)"
        if ($status.Message -match "ERROR: Could not locate setup\.exe") {
            $UpgradeTriggerFailed = $true
        }
    }

    if ($UpgradeTriggerFailed) {
        Write-Log "FATAL: setup.exe could not be located on the upgrade media inside the VM. The upgrade did NOT run." -Level ERROR
        Write-VMLogRemote "ERROR: setup.exe could not be located on the upgrade media. OS upgrade did not start." "ERROR"
        Write-Log "Skipping VM monitoring and cleanup - snapshots and the upgrade disk are preserved so you can investigate/retry." -Level WARN
    } else {
        Write-Log "Upgrade command dispatched. The VM will now reboot multiple times during setup."
        Write-VMLogRemote "OS UPGRADE: Setup command dispatched successfully. Upgrade is now under process; VM reboots are expected." "INFO"
    }
} catch {
    Write-Log "FATAL: Failed to trigger the in-place upgrade via Run Command. $_" -Level ERROR
    Write-VMLogRemote "ERROR: Failed to trigger Windows Setup through Azure Run Command. $($_.Exception.Message)" "ERROR"
    Write-Log "You can still complete the upgrade manually via RDP by running setup.exe on the attached upgrade disk." -Level WARN
    $UpgradeTriggerFailed = $true
}

# ============================
# Poll VM until it's back up
# ============================

if (-not $UpgradeTriggerFailed) {
try {
    Write-Log "Monitoring VM state until upgrade completes (timeout: $UpgradeTimeoutSeconds sec)..." -Level STEP
    Write-VMLogRemote "OS UPGRADE: Monitoring VM state until Windows Setup completes. Timeout=$UpgradeTimeoutSeconds seconds." "INFO"
    $elapsed = 0
    $pollInterval = 60
    $stableRunningChecks = 0

    while ($elapsed -lt $UpgradeTimeoutSeconds) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval

        try {
            $currentStatus = (Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Status).Statuses |
                Where-Object { $_.Code -like "PowerState*" } | Select-Object -ExpandProperty DisplayStatus
            Write-Log "Elapsed: ${elapsed}s | VM power state: $currentStatus"

            if ($currentStatus -eq "VM running") {
                $stableRunningChecks++
            } else {
                $stableRunningChecks = 0
            }

            # Require several consecutive "running" checks to avoid catching an intermediate reboot state
            if ($stableRunningChecks -ge 5) {
                Write-Log "VM has been in a stable 'running' state. Assuming upgrade completed."
                Write-VMLogRemote "OS UPGRADE: VM has returned to a stable running state after Setup reboot cycle." "INFO"
                break
            }
        } catch {
            Write-Log "Could not query VM status this cycle (VM likely mid-reboot). Will retry." -Level WARN
        }
    }

    if ($elapsed -ge $UpgradeTimeoutSeconds) {
        Write-Log "Timeout reached while waiting for VM to stabilize. Please verify upgrade status manually via the portal / boot diagnostics screenshot." -Level WARN
        Write-VMLogRemote "ERROR: Upgrade monitoring timeout reached. VM did not become stable within $UpgradeTimeoutSeconds seconds." "ERROR"
    }
} catch {
    Write-Log "Monitoring loop encountered an error: $_" -Level WARN
}
} else {
    Write-Log "Skipping VM monitoring (Step 6) because the upgrade trigger failed in Step 5." -Level WARN
}

# ===============================
# Verify OS version post-upgrade
# ===============================

if (-not $UpgradeTriggerFailed) {
try {
    Write-Log "Verifying OS version via Run Command..." -Level STEP
    Write-VMLogRemote "VERIFICATION: Checking Windows product name and OS version after upgrade." "STEP"
    $verifyScript = @'
$VMLogPath = "__VMLOGPATH__"
$VMLogFolder = Split-Path $VMLogPath -Parent
if (-not (Test-Path $VMLogFolder)) { New-Item -Path $VMLogFolder -ItemType Directory -Force | Out-Null }
function Write-VMLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $VMLogPath -Value "[$ts] $msg"
}
Write-VMLog "STEP: Post-upgrade OS verification - starting."
$info = Get-ComputerInfo -Property WindowsProductName,OsVersion | Format-List | Out-String
Write-Output $info
Write-VMLog "OS info after upgrade: $($info -replace "`r?`n", ' | ')"
Write-VMLog "STEP: Post-upgrade OS verification - finished."
'@
    $verifyScript = $verifyScript -replace '__VMLOGPATH__', $VMLogPath
    $verifyScript | Out-File -FilePath (Join-Path $LogFolder "_temp_verify.ps1") -Encoding utf8 -Force

    $verifyResult = Invoke-AzVMRunCommandSafe -ScriptPath (Join-Path $LogFolder "_temp_verify.ps1") -ErrorAction Stop

    $verifyOutputCombined = ""
    foreach ($status in $verifyResult.Value) {
        Write-Log "Post-upgrade verification: $($status.Message)"
        $verifyOutputCombined += $status.Message
    }

    if ($verifyOutputCombined -match [regex]::Escape($ExpectedOSVersionContains)) {
        $UpgradeVerified = $true
        Write-Log "Verification PASSED - OS info contains '$ExpectedOSVersionContains'. Upgrade appears successful."
        Write-VMLogRemote "SUCCESS: Post-upgrade OS verification passed. Expected marker '$ExpectedOSVersionContains' was found." "INFO"
    } else {
        $UpgradeVerified = $false
        Write-Log "Verification FAILED - OS info does NOT contain '$ExpectedOSVersionContains'. The VM still appears to be on the pre-upgrade OS." -Level ERROR
        Write-VMLogRemote "ERROR: Post-upgrade OS verification failed. Expected marker '$ExpectedOSVersionContains' was not found." "ERROR"
        Write-Log "This means setup.exe likely did not complete the upgrade (it may have exited immediately, needed a manual EULA/prompt, or hit an error). Check C:\Windows\Panther\setupact.log and setuperr.log on the VM for the real reason." -Level ERROR
    }
} catch {
    Write-Log "Could not run post-upgrade verification. Check the VM manually. $_" -Level WARN
    Write-VMLogRemote "ERROR: Post-upgrade OS verification could not be executed. $($_.Exception.Message)" "ERROR"
    $UpgradeVerified = $false
}
} else {
    Write-Log "Skipping post-upgrade verification (Step 7) because the upgrade trigger failed in Step 5." -Level WARN
}

# ===============================================
#Re-enable Windows Defender real-time protection
# ===============================================

if ($ManageDefender) {
    try {
        Write-Log "Re-enabling Windows Defender real-time protection inside the VM..." -Level STEP
        Write-VMLogRemote "DEFENDER: Re-enabling Windows Defender real-time protection after OS upgrade." "STEP"

        $enableDefenderScript = @'
$ErrorActionPreference = "Continue"
$VMLogPath = "__VMLOGPATH__"
$VMLogFolder = Split-Path $VMLogPath -Parent
if (-not (Test-Path $VMLogFolder)) { New-Item -Path $VMLogFolder -ItemType Directory -Force | Out-Null }
function Write-VMLog($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $VMLogPath -Value "[$ts] $msg"
}
Write-VMLog "STEP: Re-enable Windows Defender - starting."
try {
    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
    Write-Output "Set-MpPreference -DisableRealtimeMonitoring $false executed."
    Write-VMLog "Set-MpPreference -DisableRealtimeMonitoring `$false executed."
    $status = Get-MpComputerStatus
    Write-Output "RealTimeProtectionEnabled is now: $($status.RealTimeProtectionEnabled)"
    Write-VMLog "RealTimeProtectionEnabled is now: $($status.RealTimeProtectionEnabled)"
} catch {
    Write-Output "Could not re-enable Defender settings: $_"
    Write-VMLog "ERROR - Could not re-enable Defender settings: $_"
}
Write-VMLog "STEP: Re-enable Windows Defender - finished."
Write-VMLog "===== UPGRADE AUTOMATION COMPLETE ====="
'@
        $enableDefenderScript = $enableDefenderScript -replace '__VMLOGPATH__', $VMLogPath
        $enableDefenderScript | Out-File -FilePath (Join-Path $LogFolder "_temp_enable_defender.ps1") -Encoding utf8 -Force

        $defenderEnableResult = Invoke-AzVMRunCommandSafe -ScriptPath (Join-Path $LogFolder "_temp_enable_defender.ps1") -ErrorAction Stop

        foreach ($status in $defenderEnableResult.Value) {
            Write-Log "Defender re-enable output: $($status.Message)"
        }
    } catch {
        Write-Log "Could not re-enable Windows Defender automatically. Please verify/enable it manually on the VM. $_" -Level WARN
        Write-VMLogRemote "ERROR: Could not re-enable Windows Defender automatically. Manual verification is required. $($_.Exception.Message)" "ERROR"
    }
} else {
    Write-Log "ManageDefender = `$false - skipping Defender re-enable step." -Level WARN
    Write-VMLogRemote "DEFENDER: Defender re-enable step skipped because ManageDefender is false." "WARN"
}

# ====================================
# Cleanup (controlled by Flag Values)
# ====================================

try {
    Write-Log "Starting cleanup phase..." -Level STEP
    Write-VMLogRemote "CLEANUP: Starting post-upgrade cleanup phase." "STEP"

    if ($UpgradeVerified) {
        $diskWasDetached = $false

        if ($DetachUpgradeDiskAfterSuccess -or $DeleteUpgradeDiskAfterSuccess) {
            if (-not $DetachUpgradeDiskAfterSuccess -and $DeleteUpgradeDiskAfterSuccess) {
                Write-Log "DetachUpgradeDiskAfterSuccess = `$false, but DeleteUpgradeDiskAfterSuccess = `$true. Azure requires a managed disk to be detached before it can be deleted, so detaching anyway to honor the delete request." -Level WARN
                Write-VMLogRemote "CLEANUP: Detach was set to false but Delete was set to true; detaching anyway because Azure requires this before deletion." "WARN"
            }

            try {
                Write-Log "Detaching upgrade media disk from VM '$VMName'..."
                Write-VMLogRemote "CLEANUP: Detaching upgrade media disk '$UpgradeDiskName' from VM '$VMName'." "STEP"
                $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop
                Remove-AzVMDataDisk -VM $vm -DataDiskNames $UpgradeDiskName -ErrorAction Stop | Out-Null
                Update-AzVM -ResourceGroupName $ResourceGroup -VM $vm -ErrorAction Stop | Out-Null
                Start-Sleep -Seconds 15
                $diskWasDetached = $true
                Write-Log "Upgrade media disk detached."
                Write-VMLogRemote "CLEANUP: Upgrade media disk detached successfully." "INFO"
            } catch {
                Write-Log "Could not detach upgrade media disk (non-fatal): $_" -Level WARN
                Write-VMLogRemote "WARN: Could not detach upgrade media disk. $($_.Exception.Message)" "WARN"
            }
        } else {
            Write-Log "Skipping disk detach (DetachUpgradeDiskAfterSuccess = `$false). Upgrade media disk remains attached to the VM."
            Write-VMLogRemote "CLEANUP: Disk detach skipped by configuration. Upgrade media disk remains attached." "INFO"
        }

        if ($DeleteUpgradeDiskAfterSuccess) {
            if ($diskWasDetached) {
                try {
                    Write-Log "Deleting upgrade media disk '$UpgradeDiskName'..."
                    Write-VMLogRemote "CLEANUP: Deleting upgrade media disk '$UpgradeDiskName'." "STEP"
                    Remove-AzDisk -ResourceGroupName $UpgradeDiskRG -DiskName $UpgradeDiskName -Force -ErrorAction Stop | Out-Null
                    Write-Log "Upgrade media disk deleted."
                    Write-VMLogRemote "CLEANUP: Upgrade media disk deleted successfully." "INFO"
                } catch {
                    Write-Log "Could not delete upgrade media disk (non-fatal): $_" -Level WARN
                    Write-VMLogRemote "WARN: Could not delete upgrade media disk. $($_.Exception.Message)" "WARN"
                }
            } else {
                Write-Log "Skipping upgrade disk deletion - the disk could not be confirmed detached, and Azure will not delete an attached disk. Retry cleanup manually once it is detached." -Level WARN
                Write-VMLogRemote "WARN: Upgrade disk deletion skipped because the disk is not confirmed detached." "WARN"
            }
        } else {
            Write-Log "Skipping upgrade disk deletion (DeleteUpgradeDiskAfterSuccess = `$false). Disk retained: $UpgradeDiskName $(if ($diskWasDetached) { '(detached)' } else { '(still attached)' })."
            Write-VMLogRemote "CLEANUP: Upgrade disk deletion skipped by configuration. Disk retained: $UpgradeDiskName $(if ($diskWasDetached) { '(detached)' } else { '(still attached)' })." "INFO"
        }

        if ($DeleteSnapshotsAfterSuccess) {
            foreach ($snap in $snapshotNames) {
                Write-Log "Deleting snapshot: $snap"
                Write-VMLogRemote "CLEANUP: Deleting snapshot '$snap'." "STEP"
                Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName $snap -Force -ErrorAction SilentlyContinue | Out-Null
                Write-VMLogRemote "CLEANUP: Snapshot '$snap' deletion command completed." "INFO"
            }
        } else {
            Write-Log "Skipping snapshot deletion (DeleteSnapshotsAfterSuccess = `$false). Snapshots retained: $($snapshotNames -join ', ')"
        Write-VMLogRemote "CLEANUP: Snapshot deletion skipped by configuration. Snapshots retained: $($snapshotNames -join ', ')." "INFO"
        }
    } else {
        Write-Log "UPGRADE WAS NOT VERIFIED AS SUCCESSFUL - skipping disk/snapshot cleanup entirely." -Level ERROR
        Write-VMLogRemote "ERROR: Upgrade was not verified as successful. Snapshots and upgrade disk are being retained for investigation." "ERROR"
        Write-Log "Snapshots retained: $($snapshotNames -join ', ')" -Level WARN
        Write-Log "Upgrade media disk retained: $UpgradeDiskName (still attached to the VM for a manual/retry run)." -Level WARN
        Write-Log "Investigate via RDP: check C:\Windows\Panther\setupact.log and setuperr.log, and $VMLogPath, before retrying." -Level WARN
    }

    Remove-Item -Path (Join-Path $LogFolder "_temp_runcommand.ps1") -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $LogFolder "_temp_verify.ps1") -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $LogFolder "_temp_disable_defender.ps1") -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $LogFolder "_temp_enable_defender.ps1") -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $LogFolder "_temp_label_volume.ps1") -ErrorAction SilentlyContinue
} catch {
    Write-Log "Cleanup phase encountered an issue (non-fatal): $_" -Level WARN
    Write-VMLogRemote "WARN: Cleanup phase encountered an issue. $($_.Exception.Message)" "WARN"
}

# ============================================================
# Copy the VM's authoritative log file to a local folder
# ============================================================

if ($UpgradeVerified) {
    try {
        Write-Log "Copying the VM's authoritative log file to local folder '$LocalLogCopyFolder'..." -Level STEP

        $fetchLogScript = @'
$ErrorActionPreference = "Stop"
$path = "__VMLOGPATH__"
if (Test-Path -LiteralPath $path) {
    Get-Content -LiteralPath $path -Raw
} else {
    Write-Output "REMOTE_LOG_NOT_FOUND"
}
'@
        $fetchLogScript = $fetchLogScript.Replace("__VMLOGPATH__", $VMLogPath)
        $fetchLogPath = Join-Path $LogFolder "_temp_fetch_log.ps1"
        $fetchLogScript | Out-File -LiteralPath $fetchLogPath -Encoding utf8 -Force

        try {
            $fetchResult = Invoke-AzVMRunCommandSafe -ScriptPath $fetchLogPath -ErrorAction Stop
            $remoteLogContent = ($fetchResult.Value | Select-Object -ExpandProperty Message) -join "`n"

            if ($remoteLogContent -match "^\s*REMOTE_LOG_NOT_FOUND\s*$") {
                Write-Log "Could not copy VM log locally: the log file was not found on the VM at '$VMLogPath'." -Level WARN
            } else {
                if (-not (Test-Path -Path $LocalLogCopyFolder)) {
                    New-Item -Path $LocalLogCopyFolder -ItemType Directory -Force | Out-Null
                }
                $localLogCopyPath = Join-Path $LocalLogCopyFolder $VMLogFileName
                Set-Content -LiteralPath $localLogCopyPath -Value $remoteLogContent -Encoding UTF8
                Write-Log "VM log copied locally to: $localLogCopyPath (same file name as inside the VM)."
            }
        } finally {
            Remove-Item -LiteralPath $fetchLogPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Could not copy the VM log file to '$LocalLogCopyFolder' (non-fatal): $_" -Level WARN
    }
}

Write-Log "=================================================================="
if ($UpgradeVerified) {
    Write-Log "Script completed SUCCESSFULLY. OS upgrade verified. Review $LogFile for full details."
} else {
    Write-Log "Script completed WITH ERRORS. Upgrade was NOT verified as successful - see the ERROR lines above." -Level ERROR
}
Write-Log "VM authoritative log: $VMLogPath"
Write-Log "Remember to re-enable any antivirus/firewall software you disabled manually before this run."
if ($UpgradeVerified) {
    Write-VMLogRemote "SUCCESS: Upgrade automation completed successfully. Windows Server 2025 verification passed." "INFO"
} else {
    Write-VMLogRemote "ERROR: Upgrade automation completed without successful OS verification. Review this log and C:\Windows\Panther\setupact.log / setuperr.log." "ERROR"
}
Write-Log "=================================================================="

if ($UpgradeVerified) {
    Write-Output "`nDONE - Upgrade verified successful. Full log saved at: $LogFile"
} else {
    Write-Output "`nDONE - Upgrade NOT verified. Check the log for errors: $LogFile"
}

} 
