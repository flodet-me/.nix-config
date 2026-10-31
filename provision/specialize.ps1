# Runs as SYSTEM in the specialize pass of Windows Setup (from autounattend.xml),
# before the first user profile is created. Changes to the default user hive
# here apply to every account created later, including test accounts.
# Log: C:\winvm\specialize.log (setup.ps1 forwards it to the build output).

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$src = Split-Path -Parent $PSCommandPath
$dst = 'C:\winvm'
New-Item -ItemType Directory -Force $dst | Out-Null
. "$src\settings.ps1"

function Log([string]$msg) {
    Add-Content -Path "$dst\specialize.log" -Value "[specialize] $(Get-Date -Format HH:mm:ss) $msg"
}

function Step([string]$name, [scriptblock]$body) {
    try { & $body; Log "ok: $name" }
    catch { Log "FAILED: ${name}: $_" }
}

function Read-List([string]$file) {
    if (Test-Path $file) {
        Get-Content $file | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ }
    }
}

# reg.exe instead of the registry provider: no open handles that would block `reg unload`.
function Set-Reg([string]$key, [string]$name, $value, [string]$type = 'REG_DWORD') {
    reg.exe add $key /v $name /t $type /d $value /f | Out-Null
    if ($LASTEXITCODE) { throw "reg add $key\$name failed" }
}

# Values that only exist on some Windows versions or that Windows 11 protects
# (Widgets/Chat buttons); the policies above cover them where it matters.
function Set-RegOptional([string]$key, [string]$name, $value) {
    try { Set-Reg $key $name $value } catch { Log "skipped $name (not settable on this Windows version)" }
}

# --- Windows Server ---------------------------------------------------------
# Runs regardless of DEBLOAT: without it Setup can't create the test account.
if ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) {
    Step 'server: allow simple test passwords' {
        # Server enforces complex passwords of 7+ characters, which rejects
        # WIN_PASSWORD when Setup creates the account in the next pass.
        $inf = "$env:TEMP\winvm-secpol.inf"
        secedit.exe /export /cfg $inf /areas SECURITYPOLICY | Out-Null
        (Get-Content $inf) -replace '^PasswordComplexity\s*=.*', 'PasswordComplexity = 0' `
                           -replace '^MinimumPasswordLength\s*=.*', 'MinimumPasswordLength = 0' `
                           -replace '^MaximumPasswordAge\s*=.*', 'MaximumPasswordAge = -1' | Set-Content $inf
        secedit.exe /configure /db "$env:TEMP\winvm-secpol.sdb" /cfg $inf /areas SECURITYPOLICY | Out-Null
        if ($LASTEXITCODE) { throw "secedit exit code $LASTEXITCODE" }
    }
    Step 'server: no Server Manager at logon' {
        Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Server\ServerManager' DoNotOpenAtLogon 1
    }
}

# --- optional Windows features (provision/features.txt) ---------------------
# Enabled here so they finish installing during Setup's next reboot, not on
# every boot of a fresh overlay. Payloads that aren't in the image (NetFx3)
# come from the ISO's sources\sxs; offline that is the only source.
$sxs = Get-PSDrive -PSProvider FileSystem | ForEach-Object { "$($_.Root)sources\sxs" } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
$sourceArgs = @()
if ($sxs) { $sourceArgs += "/source:$sxs" }
if (-not $Online) { $sourceArgs += '/limitaccess' }
foreach ($feature in Read-List "$src\features.txt") {
    Step "feature $feature" {
        dism.exe /online /enable-feature /featurename:$feature /all /norestart /quiet @sourceArgs
        if ($LASTEXITCODE -notin 0, 3010) { throw "dism exit code $LASTEXITCODE" }
    }
}

if (-not $Debloat) { Log 'debloat disabled'; exit 0 }

# --- preinstalled consumer apps ---------------------------------------------
Step 'remove provisioned apps' {
    $patterns = @(Read-List "$src\remove-apps.txt")
    Get-AppxProvisionedPackage -Online | Where-Object {
        $pkg = $_.DisplayName
        $patterns | Where-Object { $pkg -like $_ }
    } | ForEach-Object {
        Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName | Out-Null
        Log "removed $($_.DisplayName)"
    }
}

# --- machine policies -------------------------------------------------------
Step 'machine policies' {
    $p = 'HKLM\SOFTWARE\Policies\Microsoft'
    # Suggested/promoted apps (Candy Crush & co.), Spotlight, "tips".
    # DisableWindowsConsumerFeatures is honored on Enterprise/Education only;
    # the per-user ContentDeliveryManager values below cover Pro/Home.
    Set-Reg "$p\Windows\CloudContent" DisableWindowsConsumerFeatures 1
    Set-Reg "$p\Windows\CloudContent" DisableSoftLanding 1
    Set-Reg "$p\Windows\CloudContent" DisableCloudOptimizedContent 1
    Set-Reg "$p\Windows\CloudContent" DisableConsumerAccountStateContent 1
    # Telemetry to the minimum the edition allows; no feedback prompts.
    Set-Reg "$p\Windows\DataCollection" AllowTelemetry 0
    Set-Reg "$p\Windows\DataCollection" DoNotShowFeedbackNotifications 1
    Set-Reg "$p\Windows\DataCollection" DisableTailoredExperiencesWithDiagnosticData 1
    Set-Reg "$p\Windows\AdvertisingInfo" DisabledByGroupPolicy 1
    # Cortana + web results in Start search.
    Set-Reg "$p\Windows\Windows Search" AllowCortana 0
    Set-Reg "$p\Windows\Windows Search" DisableWebSearch 1
    Set-Reg "$p\Windows\Windows Search" ConnectedSearchUseWeb 0
    # News and Interests on the taskbar, Meet Now, activity history.
    Set-Reg "$p\Windows\Windows Feeds" EnableFeeds 0
    Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' HideSCAMeetNow 1
    Set-Reg "$p\Windows\System" EnableActivityFeed 0
    Set-Reg "$p\Windows\System" PublishUserActivities 0
    Set-Reg "$p\Windows\System" UploadUserActivities 0
    # OneDrive: never set up, never in Explorer.
    Set-Reg "$p\Windows\OneDrive" DisableFileSyncNGSC 1
    # Edge: no first-run wizard, no "recommended settings" nags.
    Set-Reg "$p\Edge" HideFirstRunExperience 1
    Set-Reg "$p\Edge" ShowRecommendationsEnabled 0
    Set-Reg "$p\Edge" PersonalizationReportingEnabled 0
    # Windows 11: Widgets (news feed), Chat/Teams button, Copilot, Start recommendations.
    Set-Reg "$p\Dsh" AllowNewsAndInterests 0
    Set-Reg "$p\Windows\Windows Chat" ChatIcon 3
    Set-Reg "$p\Windows\WindowsCopilot" TurnOffWindowsCopilot 1
    Set-Reg "$p\Windows\Explorer" HideRecommendedSection 1
}

Step 'disable telemetry services' {
    foreach ($svc in 'DiagTrack', 'dmwappushservice') {
        Set-Reg "HKLM\SYSTEM\CurrentControlSet\Services\$svc" Start 4
    }
}

# --- default user profile ---------------------------------------------------
Step 'default user profile' {
    reg.exe load 'HKU\winvm-default' 'C:\Users\Default\NTUSER.DAT' | Out-Null
    if ($LASTEXITCODE) { throw 'could not load default user hive' }
    try {
        $u = 'HKU\winvm-default\Software'
        $cdm = "$u\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        foreach ($name in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled',
                          'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled',
                          'SoftLandingEnabled', 'SubscribedContentEnabled', 'SystemPaneSuggestionsEnabled',
                          'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled',
                          'SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled',
                          'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                          'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
                          'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled') {
            Set-Reg $cdm $name 0
        }
        $cv = "$u\Microsoft\Windows\CurrentVersion"
        Set-Reg "$cv\UserProfileEngagement" ScoobeSystemSettingEnabled 0   # "Let's finish setting up your device"
        Set-Reg "$cv\AdvertisingInfo" Enabled 0
        Set-Reg "$cv\Privacy" TailoredExperiencesWithDiagnosticDataEnabled 0
        Set-Reg "$cv\Search" BingSearchEnabled 0
        Set-Reg "$cv\Search" CortanaConsent 0
        Set-RegOptional "$cv\Feeds" ShellFeedsTaskbarViewMode 2
        Set-Reg "$u\Microsoft\Siuf\Rules" NumberOfSIUFInPeriod 0
        Set-RegOptional "$u\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People" PeopleBand 0
        # Explorer for testing: file extensions, hidden files, open on "This PC".
        $adv = "$cv\Explorer\Advanced"
        Set-Reg $adv HideFileExt 0
        Set-Reg $adv Hidden 1
        Set-Reg $adv LaunchTo 1
        Set-RegOptional $adv ShowCortanaButton 0
        Set-Reg $adv Start_TrackProgs 0
        Set-RegOptional $adv TaskbarDa 0             # Windows 11 Widgets button
        Set-RegOptional $adv TaskbarMn 0             # Windows 11 Chat button
        Set-Reg "$u\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot 1
        # OneDrive installs itself per user from this Run entry at first logon.
        cmd.exe /c "reg delete `"$cv\Run`" /v OneDriveSetup /f >nul 2>&1"
    } finally {
        [gc]::Collect()
        reg.exe unload 'HKU\winvm-default' | Out-Null
    }
}

# Empty Start menu instead of the default tiles (which are mostly ad placeholders).
Step 'empty Start layout' {
    $shell = 'C:\Users\Default\AppData\Local\Microsoft\Windows\Shell'
    New-Item -ItemType Directory -Force $shell | Out-Null
    Set-Content -Encoding UTF8 "$shell\LayoutModification.xml" @'
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1" xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
  <LayoutOptions StartTileGroupCellWidth="6" />
  <DefaultLayoutOverride>
    <StartLayoutCollection>
      <defaultlayout:StartLayout GroupCellWidth="6" />
    </StartLayoutCollection>
  </DefaultLayoutOverride>
</LayoutModificationTemplate>
'@
}

Log 'done'
