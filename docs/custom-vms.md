# Custom VMs for special tests

Most tests run on a plain VM: `winvm start`, test, `winvm reset`. Some need a
VM prepared differently: German number formats, a non-admin user, 150 %
scaling, a slow offline PC, or an old version of your app for upgrade tests.
Set it up once; `reset` then returns to exactly that state.

| | by hand + `seal` | recipe |
|---|---|---|
| effort | minutes, click through RDP | write a `setup.ps1` |
| repeatable / shareable | no | yes, it's in git |
| survives an image rebuild | **no**, the VM is deleted | yes, `winvm new` recreates it |
| good for | one-off investigations | anything you'll need again |

## How it fits together

```
image (win10, win11, ...)        built once by `winvm build`, shared, read-only
  └─ sealed state of VM "de"     your preparation (recipe or by hand), this VM only
       └─ working disk           everything a test changes; `reset` throws it away
```

- **Image**: a Windows version installed and provisioned by `winvm build`.
- **VM**: a copy-on-write clone of an image, with its own disk, ports,
  snapshots, NVRAM and TPM. Cheap: it only stores what differs.
- **Sealed state**: what `winvm reset` returns to. For a plain VM that's the
  image. `winvm seal` (or `winvm new --recipe`) makes the VM's current state
  its own reset point. The image and the other VMs don't change.

## The quick way: set it up by hand, then seal

```sh
winvm new upgrade-test                 # a fresh VM from the default image
winvm -n upgrade-test start --wait
winvm -n upgrade-test rdp              # install MyApp 1.0, configure it, ...
winvm -n upgrade-test seal             # this is the clean state from now on

# every test round:
winvm -n upgrade-test start --wait
winvm -n upgrade-test run ./MyApp-2.0-setup.exe /quiet
...                                    # check the result
winvm -n upgrade-test reset            # back to "MyApp 1.0 installed"
```

Fine for a one-off. The downside: nobody can see or repeat what you did, and
rebuilding the image (for example when an evaluation expires, or to get new
updates) deletes the VM. For anything you'll need again, write a recipe.

## The repeatable way: recipes

A recipe is a folder in `recipes/` that turns a fresh VM into the special one.
It is checked into git, so it survives image rebuilds and other people can use
it too.

```sh
winvm recipes                          # the recipes there are
winvm new de --recipe german-formats   # VM "de": created, set up, sealed
winvm -n de start
```

What `winvm new NAME --recipe R` does (the recipe's output appears in your terminal):

```
  create VM from the image
        │
  boot (with internet)
        │
  copy recipes/R to C:\winvm\recipe, install packages.txt
        │
  run setup.ps1  ◀──────────────┐
        │                       │
        ├─ exit 3010 ─▶ restart ┘   ($env:WINVM_RECIPE_RUN = 2, 3, ...)
        ├─ error ─────▶ stop; the VM stays running so you can look
        │
  exit 0: shut down, seal  ─▶  `reset` returns here from now on
```

### Included examples

| recipe | what it gives you |
|---|---|
| `german-formats` | German regional settings: `1.234,56`, `31.10.2026`, German keyboard, Berlin time zone, de-DE system locale. Display language unchanged. For number/date parsing, CSV separators, sorting. |
| `standard-user` | The desktop signs in as `tester`, a standard (non-admin) user. `winvm run` starts programs there, without admin rights (Medium integrity). SSH and the other commands keep using the admin `dev`. |
| `hidpi` | 150 % display scaling: layout, clipped text, blurry bitmaps. Change `$dpi` for 125 % (120) or 200 % (192). |
| `low-spec-offline` | 2 GB RAM, 1 CPU, no network. Only settings, no script. |

### Writing your own

```sh
winvm recipes new my-test              # copies recipes/_template to recipes/my-test
```

A recipe folder contains:

```
recipes/my-test/
  recipe.env      description, image, the VM's settings          (required)
  packages.txt    Chocolatey packages to install                  (optional)
  setup.ps1       PowerShell, runs in the VM as admin             (optional)
  ...             any other files: installers, configs, test data (optional)
```

**recipe.env**

```sh
DESCRIPTION="MyApp 1.0 installed, for upgrade tests"
IMAGE="win11"            # Windows version; default: IMAGE from config.env
VM_RAM="4G"              # the VM's own settings, used whenever it starts
VM_CPUS=2
VM_INTERNET=0            # offline when it runs (installing the recipe is still online)
USB_DEVICES="0951:1666"  # host USB devices attached at every start
AUDIO="pipewire"
```

The `VM_*`, `USB_DEVICES` and `AUDIO` settings are copied to
`state/vms/NAME/vm.env` when the VM is created. Edit that file to change them
later; `winvm -n NAME status` shows them.

**packages.txt**: one [Chocolatey](https://community.chocolatey.org/packages)
package per line (`#` comments). Installed before `setup.ps1`, with retries.

**setup.ps1** runs inside the VM:

- elevated, as the VM user `dev` (so `HKCU:` is the desktop user's registry,
  unless a recipe changes who signs in to the desktop),
- in the recipe folder (`C:\winvm\recipe`): `.\MyApp-1.0.msi` works,
- with `$ErrorActionPreference = 'Stop'` at the top (template): any error
  fails the recipe instead of half-applying it.

Restarts: `exit 3010` restarts the VM and runs the script again;
`$env:WINVM_RECIPE_RUN` is `1`, `2`, ... Use it for settings that need a
restart before the next step, or that only take effect at sign-in:

```powershell
$ErrorActionPreference = 'Stop'
if ($env:WINVM_RECIPE_RUN -eq 1) {
    Start-Process msiexec '/i MyApp-1.0.msi /qn /norestart' -Wait
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -NoRestart | Out-Null
    exit 3010
}
# after the restart: check that it worked, so a broken recipe fails loudly
if (-not (Get-Service MyAppService -ErrorAction SilentlyContinue)) { throw 'MyAppService missing' }
Write-Host "MyApp $((Get-Item 'C:\Program Files\MyApp\myapp.exe').VersionInfo.FileVersion) ready"
```

Things a setup script often does:

```powershell
Start-Process msiexec '/i app.msi /qn /norestart' -Wait          # MSI
Start-Process .\setup.exe '/S' -Wait                              # NSIS/Inno: /S, /VERYSILENT
Add-AppxPackage .\app.msix                                        # MSIX
Set-ItemProperty 'HKCU:\Software\MyApp' -Name Server -Value 'test.local'
Copy-Item .\testdata -Destination C:\testdata -Recurse
New-NetFirewallRule -DisplayName 'block MyApp' -Program 'C:\Program Files\MyApp\myapp.exe' -Direction Outbound -Action Block
Set-Service MyAppUpdater -StartupType Disabled
Add-Content C:\Windows\System32\drivers\etc\hosts '10.0.2.2 api.myapp.test'   # 10.0.2.2 = this host
Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -NoRestart
```

### Developing a recipe

Iterate on a scratch VM instead of creating a new one each time:

```sh
winvm new scratch
winvm -n scratch apply my-test         # run it; the VM stays running for a look
winvm -n scratch ssh                   # check, fix setup.ps1, apply again
winvm -n scratch reset                 # start over from the plain image
winvm destroy scratch
winvm new my-test --recipe my-test     # the real one, once it works
```

Make `setup.ps1` safe to run twice (check before you add, `-Force`,
`-ErrorAction SilentlyContinue` where "already there" is fine): `apply` on an
already prepared VM and restarts both run it again.

When it fails, the VM is left running: `winvm -n NAME ssh` and look around
(`C:\winvm\recipe`, event log, installer logs). `winvm destroy NAME` and
`winvm new` again when fixed.

## Day to day

```sh
winvm list                       # RESETS TO: image / sealed / recipe NAME
winvm -n de status               # settings, what reset returns to
winvm -n de reset                # back to the sealed state
winvm -n de reset --image        # back to the plain image (drops the sealing)
winvm -n de seal                 # changed it by hand? make that the new clean state
winvm -n de apply other-recipe --seal   # layer another recipe on top
winvm -n de snapshot save before-x      # finer checkpoints on top of the sealed state
```

`seal` vs `commit`: `seal` changes only this VM's clean state. `commit`
changes the image itself, for every future VM of that Windows version, and is
only allowed while no other VM uses the image.

## When the image is rebuilt

`winvm build --force --image IMG` deletes the image's VMs, custom ones
included: their sealed state is a layer on top of the old image and can't move
to a new one. The build prints the commands to recreate recipe-made VMs:

```
    custom VMs of the old image were deleted; recreate them on the new one:
    winvm new de --recipe german-formats
```

VMs you set up by hand and sealed are gone after a rebuild: one more reason to
write a recipe.
