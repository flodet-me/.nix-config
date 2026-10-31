# Defaults for winvm.ps1 (VirtualBox on a Windows host). Don't edit this file
# for personal tweaks: put changes in config.local.ps1 next to it, e.g.
#   $Config.RamMB = 12288
#   $Config.Images.win11.Iso = 'D:\iso\Win11_24H2_EnglishInternational_x64.iso'
#   $Config.Images.win11.Locale = 'en_GB'

$Config = @{
    DefaultImage = 'win10'

    # VM hardware
    Cpus   = 4
    RamMB  = 8192
    DiskGB = 80

    # The user Windows is installed with (local admin, signs in automatically).
    User     = 'dev'
    Password = 'dev'

    # Host ports on 127.0.0.1 for the VM "default"; VM number N uses PORT + N.
    SshPort = 2222
    RdpPort = 33890

    # Install all Windows updates during build ($false: faster, unpatched).
    Updates = $true
    # Turn off automatic Windows Update afterwards, so a VM's state stays put.
    DisableWindowsUpdate = $true

    # Guest Additions ISO; '' = the one that comes with VirtualBox.
    AdditionsIso = ''

    # Where VirtualBox keeps the VMs' disks. Linked clones are small.
    VmFolder = Join-Path $PSScriptRoot 'vms'

    # Windows versions. Iso: path to the official ISO (same as the Linux
    # version's iso/ folder by default). Edition: name as on the ISO
    # (winvm.ps1 build lists them if it doesn't match). Key: generic install
    # key, installs without activating. Efi: UEFI + TPM 2.0 + Secure Boot.
    # Locale/Country/Language: must match the ISO (an en-GB ISO: en_GB / GB / en-GB).
    # TimeZone: 'Etc/UTC', 'Europe/Berlin' or a Windows name ('W. Europe Standard Time');
    # not 'UTC', which VirtualBox turns into an invalid 'GMT'.
    Images = @{
        win10 = @{
            Description = 'Windows 10 22H2 Pro'
            Iso         = Join-Path $PSScriptRoot '..\iso\win10.iso'
            Edition     = 'Windows 10 Pro'
            Key         = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
            Efi         = $true
            Locale      = 'en_US'; Country = 'US'; Language = ''    # '' = the ISO's language
            TimeZone    = 'Etc/UTC'
        }
        win11 = @{
            Description = 'Windows 11 Pro'
            Iso         = Join-Path $PSScriptRoot '..\iso\win11-pro.iso'
            Edition     = 'Windows 11 Pro'
            Key         = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
            Efi         = $true
            Locale      = 'en_US'; Country = 'US'; Language = ''
            TimeZone    = 'Etc/UTC'
        }
        'win11-ltsc' = @{
            Description = 'Windows 11 Enterprise LTSC 2024 (90-day evaluation)'
            Iso         = Join-Path $PSScriptRoot '..\iso\win11-ltsc.iso'
            Edition     = 'Windows 11 Enterprise LTSC 2024 Evaluation'
            Key         = ''
            Efi         = $true
            Locale      = 'en_US'; Country = 'US'; Language = ''
            TimeZone    = 'Etc/UTC'
        }
        server2025 = @{
            Description = 'Windows Server 2025 Standard, Desktop Experience (180-day evaluation)'
            Iso         = Join-Path $PSScriptRoot '..\iso\server2025.iso'
            Edition     = 'Windows Server 2025 SERVERSTANDARD'
            Key         = ''
            Efi         = $true
            Locale      = 'en_US'; Country = 'US'; Language = ''
            TimeZone    = 'Etc/UTC'
        }
    }
}
