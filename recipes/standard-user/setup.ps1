# Apps under test run without admin rights, like on most managed PCs: the
# desktop signs in as 'tester' (standard user); `winvm run` starts programs
# there. SSH, scp and the other winvm commands keep using the admin 'dev'.
$ErrorActionPreference = 'Stop'
$user = 'tester'
$password = 'tester'

if ($env:WINVM_RECIPE_RUN -eq 1) {
    # net.exe: unlike New-LocalUser it accepts short passwords on desktop Windows.
    net user $user $password /add /passwordchg:no /expires:never | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "net user failed ($LASTEXITCODE)" }
    Set-LocalUser $user -PasswordNeverExpires $true
    $users = (Get-LocalGroup -SID 'S-1-5-32-545').Name     # "Users", localized
    if (-not (Get-LocalGroupMember $users | Where-Object Name -like "*\$user")) { Add-LocalGroupMember $users $user }
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $winlogon -Name AutoAdminLogon -Value '1'
    Set-ItemProperty $winlogon -Name DefaultUserName -Value $user
    Set-ItemProperty $winlogon -Name DefaultPassword -Value $password
    Set-ItemProperty $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
    exit 3010
}

$owner = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1 | Invoke-CimMethod -MethodName GetOwner
if ($owner.User -ne $user) { throw "the desktop belongs to '$($owner.User)', not '$user'" }
$admins = (Get-LocalGroup -SID 'S-1-5-32-544').Name
if (Get-LocalGroupMember $admins | Where-Object Name -like "*\$user") { throw "$user is an administrator" }
Write-Host "desktop user: $user (standard user)"
