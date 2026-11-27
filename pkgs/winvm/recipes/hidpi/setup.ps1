# High-DPI rendering of the app under test: 150 % scaling for the VM user.
# Other common values: 120 = 125 %, 192 = 200 %.
$ErrorActionPreference = 'Stop'
$dpi = 144

if ($env:WINVM_RECIPE_RUN -eq 1) {
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name LogPixels -Value $dpi -Type DWord
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Win8DpiScaling -Value 1 -Type DWord
    exit 3010                                      # takes effect at the next sign-in
}
Write-Host "scaling: $([int]((Get-ItemProperty 'HKCU:\Control Panel\Desktop').LogPixels * 100 / 96)) %"
