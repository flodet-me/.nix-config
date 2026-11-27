# Runs inside the VM, elevated, as the VM user (dev), with this recipe folder as
# the working directory (C:\winvm\recipe): files next to this script are there.
# Output shows up in the terminal. Make it safe to run twice.
#
# Restarts: `exit 3010` restarts the VM and runs this script again;
# $env:WINVM_RECIPE_RUN says which run it is (1, 2, ...).
$ErrorActionPreference = 'Stop'

if ($env:WINVM_RECIPE_RUN -eq 1) {
    # Examples:
    # Copy-Item .\myapp.msi C:\Users\Public\ ; Start-Process msiexec '/i C:\Users\Public\myapp.msi /qn' -Wait
    # Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name LogPixels -Value 144
    # Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -NoRestart
    # exit 3010     # restart, then continue below
}

# Run 2 and later: things that need the restart to have happened.
Write-Host "recipe done"
