# Locale-sensitive code (number/date parsing, CSV separators, sorting) under
# German regional settings. The display language stays as it is.
$ErrorActionPreference = 'Stop'

if ($env:WINVM_RECIPE_RUN -eq 1) {
    Set-Culture de-DE                              # formats of the VM user
    Set-WinHomeLocation -GeoId 94                  # Germany
    $languages = Get-WinUserLanguageList           # keep the language, German keyboard
    $languages[0].InputMethodTips.Clear()
    $languages[0].InputMethodTips.Add("$('{0:x4}' -f ([Globalization.CultureInfo]$languages[0].LanguageTag).LCID):00000407")
    Set-WinUserLanguageList $languages -Force
    Set-TimeZone -Id 'W. Europe Standard Time'
    Set-WinSystemLocale de-DE                      # non-Unicode programs; needs a restart
    exit 3010
}

$c = Get-Culture
Write-Host "culture $($c.Name): $((1234.56).ToString('N2', $c)) / $((Get-Date '2026-10-31').ToString('d', $c)); system locale $((Get-WinSystemLocale).Name); time zone $((Get-TimeZone).Id)"
