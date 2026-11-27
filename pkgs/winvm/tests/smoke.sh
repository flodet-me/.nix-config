#!/usr/bin/env bash
# Smoke test for winvm: the everyday commands against a built base image, on a
# throwaway VM. No rebuild, about 5 minutes.
#
#   tests/smoke.sh [--image IMG] [--keep]
#
#   Tests the winvm in $WINVM, else the one on PATH, with its WINVM_HOME.
#
#   --image IMG   test this Windows version (default: IMAGE from config.env)
#   --keep        keep the test VM afterwards (default: destroy it)
#
# Exit status: 0 if every check passed, 1 otherwise. Needs a built image
# (winvm build) and 4 GB of free RAM.
set -uo pipefail

WINVM=${WINVM:-$(command -v winvm)} || { echo "no winvm: put it on PATH or set WINVM" >&2; exit 2; }
VM=smoke-test
image="" keep=0
while (($#)); do
    case $1 in
        --image) image=${2:?--image needs a name}; shift ;;
        --keep) keep=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

passed=0 failed=0 failures=()
if [[ -t 1 ]]; then G=$'\e[32m' R=$'\e[31m' B=$'\e[1m' N=$'\e[0m'; else G="" R="" B="" N=""; fi
step() { printf '%s── %s%s\n' "$B" "$*" "$N"; }
ok() { passed=$((passed + 1)); printf '   %sok%s    %s\n' "$G" "$N" "$*"; }
fail() { failed=$((failed + 1)); failures+=("$*"); printf '   %sFAIL%s  %s\n' "$R" "$N" "$*"; }
# check DESCRIPTION COMMAND...: passes if the command succeeds.
check() { local d=$1; shift; if "$@" >"$LOG.out" 2>&1; then ok "$d"; else fail "$d"; sed 's/^/         | /' "$LOG.out" | tail -n 15; fi; }
# expect DESCRIPTION ACTUAL EXPECTED
expect() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1"; echo "         | got '$2', expected '$3'"; fi; }

w() { "$WINVM" -n "$VM" "$@" 2> >(grep -v '^\*\*' >&2); }   # hide OpenSSH's post-quantum notice
json() { w status --json | python3 -I -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
gssh() { w ssh "$@" | tr -d '\r'; }

LOG=$(mktemp -d)/smoke
cleanup() {
    if ((keep)); then echo "kept VM '$VM' (winvm destroy $VM --yes to delete)"
    else "$WINVM" destroy "$VM" --yes >/dev/null 2>&1; fi
    rm -rf "$(dirname "$LOG")"
}
trap cleanup EXIT
trap 'echo; echo interrupted; exit 1' INT

t0=$SECONDS

# --- preconditions: stop here instead of failing every check ----------------
step "preconditions"
[[ -w /dev/kvm ]] || { fail "/dev/kvm accessible"; exit 1; }
"$WINVM" destroy "$VM" --yes >/dev/null 2>&1   # leftover of an earlier run
new_args=()
[[ -n $image ]] && new_args=(--image "$image")
"$WINVM" new "$VM" "${new_args[@]}" >"$LOG.out" 2>&1 || { fail "winvm new $VM"; cat "$LOG.out"; exit 1; }
printf 'VM_RAM="4G"\nVM_CPUS=2\n' >"$("$WINVM" home)/state/vms/$VM/vm.env"
img=$(json 'd["image"]["name"]')
[[ $(json 'd["image"]["built"]') == True ]] || { fail "image $img is built (winvm build${image:+ --image $image})"; exit 1; }
ok "image $img is built, test VM created"

# --- status ------------------------------------------------------------------
step "status"
check "status (text)" w status
expect "status --json: stopped (new creates the disk)" "$(json 'd["state"]')" stopped

# --- start -------------------------------------------------------------------
step "start"
ts=$SECONDS
check "start --headless --wait" w start --headless --wait
ok "booted in $((SECONDS - ts)) s"
expect "status --json: running, guest ready" "$(json 'd["state"], d["guest_ready"]')" "running True"

# --- access ------------------------------------------------------------------
step "ssh / scp"
expect "ssh runs a command" "$(gssh 'Write-Output hello')" hello
check "ssh passes the exit code" bash -c "! '$WINVM' -n $VM ssh 'exit 3' 2>/dev/null"
head -c 100000 /dev/urandom >"$LOG.blob"
check "scp to the VM" w scp "$LOG.blob" vm:C:/Windows/Temp/smoke.bin
check "scp back, identical" bash -c "'$WINVM' -n $VM scp vm:C:/Windows/Temp/smoke.bin '$LOG.back' 2>/dev/null && cmp -s '$LOG.blob' '$LOG.back'"

# --- run ---------------------------------------------------------------------
step "run"
w run --timeout 60 vm:C:/Windows/System32/cmd.exe /c "echo smoke-output& exit 7" >"$LOG.run" 2>&1
rc=$?
expect "run: exit status 7 passed through" "$rc" 7
check "run: stdout collected" grep -q smoke-output "$LOG.run"
w run --timeout 60 vm:C:/Windows/System32/rundll32.exe kernel32.dll,DebugBreak >"$LOG.crash" 2>&1
check "run: crash decoded (breakpoint)" grep -q '0x80000003.*breakpoint' "$LOG.crash"
check "run: crash dump analyzed" grep -q 'FAILURE_BUCKET_ID' "$LOG.crash"
check "run: results saved under runs/" grep -q '^results   : runs/' "$LOG.crash"

# --- inside the VM -----------------------------------------------------------
step "management commands"
check "info" w info
check "ps finds explorer" bash -c "'$WINVM' -n $VM ps explorer 2>/dev/null | grep -qi explorer"
check "service list sshd" bash -c "'$WINVM' -n $VM service list sshd 2>/dev/null | grep -qi running"
check "ports shows :22" bash -c "'$WINVM' -n $VM ports 2>/dev/null | grep -qw 22"
check "screenshot" bash -c "'$WINVM' -n $VM screenshot >'$LOG.shot' 2>&1"

# --- deploy and IDE setup ----------------------------------------------------
step "deploy and IDE setup"
expect "ssh: quotes arrive as typed" "$(gssh "Write-Host \"a 'b' c\"")" "a 'b' c"
if ! command -v dotnet >/dev/null; then
    ok "skipped: no dotnet on PATH (a .NET SDK builds the test app)"
else
    app="$(dirname "$LOG")/SmokeApp"
    mkdir -p "$app"
    cat >"$app/SmokeApp.csproj" <<'EOF'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework></PropertyGroup>
</Project>
EOF
    cat >"$app/Program.cs" <<'EOF'
System.IO.File.WriteAllText(@"C:\Windows\Temp\smoke-app.txt",
    $"args={string.Join(",", args)} debugger={System.Diagnostics.Debugger.IsAttached}");
EOF
    out="$app/bin/Debug/net8.0/win-x64"
    if dotnet build "$app/SmokeApp.csproj" -r win-x64 --self-contained true -p:EnableWindowsTargeting=true >"$LOG.out" 2>&1; then
        ok "test app built (self-contained: the base image has no .NET runtime)"
        marker() { gssh 'Get-Content C:\Windows\Temp\smoke-app.txt -ErrorAction SilentlyContinue'; }
        gssh 'Remove-Item C:\Windows\Temp\smoke-app.txt -ErrorAction SilentlyContinue' >/dev/null
        check "deploy --run with arguments" w deploy "$out" --as SmokeApp --run --args "x y"
        timeout 5 tail -f /dev/null
        expect "app ran on the desktop with its arguments" "$(marker)" "args=x,y debugger=False"
        gssh 'Remove-Item C:\Windows\Temp\smoke-app.txt -ErrorAction SilentlyContinue' >/dev/null
        check "deploy --run --wait" w deploy "$out" --as SmokeApp --run --wait
        timeout 5 tail -f /dev/null
        expect "--wait: running, but waiting before Main" "$(gssh 'if (Get-Process SmokeApp -ErrorAction SilentlyContinue) { if (Test-Path C:\Windows\Temp\smoke-app.txt) { "ran" } else { "waiting" } } else { "gone" }')" waiting
        check "redeploy stops the waiting app" w deploy "$out" --as SmokeApp
        expect "no SmokeApp left running" "$(gssh '@(Get-Process SmokeApp -ErrorAction SilentlyContinue).Count')" 0
        printf 'Microsoft Visual Studio Solution File, Format Version 12.00\nProject("{9A19103F-16F7-4668-BE54-9A1E7A4F7556}") = "SmokeApp", "SmokeApp\\SmokeApp.csproj", "{11111111-2222-3333-4444-555555555555}"\nEndProject\n' >"$(dirname "$app")/Smoke.sln"
        # pwsh comes with the winvm package
        check "vscode setup" w vscode setup "$(dirname "$app")/Smoke.sln"
        check "launch.json has the configurations" grep -q '"winvm smoke-test: SmokeApp on the VM desktop"' "$(dirname "$app")/.vscode/launch.json"
        check "vscode setup --remove deletes what it created" bash -c "'$WINVM' -n $VM vscode setup '$(dirname "$app")/Smoke.sln' --remove >/dev/null 2>&1 && [[ ! -e '$(dirname "$app")/.vscode' ]]"
        check "rider setup" w rider setup "$(dirname "$app")/Smoke.sln"
        expect "rider setup: 4 run configurations" "$(find "$(dirname "$app")/.run" -name '*.run.xml' | wc -l)" 4
        check "rider setup --remove deletes them" bash -c "'$WINVM' -n $VM rider setup '$(dirname "$app")/Smoke.sln' --remove >/dev/null 2>&1 && [[ ! -e '$(dirname "$app")/.run' ]]"
    else
        fail "test app built (dotnet build -r win-x64)"; tail -n 15 "$LOG.out" | sed 's/^/         | /'
    fi
fi

# --- snapshots ---------------------------------------------------------------
step "snapshots (live, with RAM)"
check "snapshot save" w snapshot save smoke1
expect "status lists the snapshot" "$(json '" ".join(d["snapshots"])')" smoke1
gssh 'Set-Content C:\smoke-marker.txt after' >/dev/null
check "snapshot load" w snapshot load smoke1
expect "file written after the snapshot is gone" "$(gssh 'Test-Path C:\smoke-marker.txt')" False

# --- reset -------------------------------------------------------------------
step "stop / reset"
gssh 'Set-Content C:\smoke-marker.txt before-reset' >/dev/null
check "stop" w stop
expect "status --json: stopped" "$(json 'd["state"]')" stopped
check "reset" w reset
check "start again" w start --headless --wait
expect "file written before reset is gone" "$(gssh 'Test-Path C:\smoke-marker.txt')" False
check "stop --force" w stop --force

# --- summary -----------------------------------------------------------------
echo
printf '%s%d passed, %d failed%s in %d s\n' "$B" "$passed" "$failed" "$N" $((SECONDS - t0))
for f in "${failures[@]}"; do printf '   %sFAIL%s  %s\n' "$R" "$N" "$f"; done
((failed == 0))
