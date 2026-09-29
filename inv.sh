#!/usr/bin/env bash
set -Eeuo pipefail

WINDEV="/dev/nvme0n1p3"
DATADEV="/dev/sda2"
WIN_UUID_EXPECTED="7ECA1EEFCA1EA405"
DATA_UUID_EXPECTED="8E2EC0B92EC09B99"
WIN="/mnt/windows"
DATA="/mnt/data"
STAMP="$(date +%Y%m%d_%H%M%S)"
DEST="$DATA/PreReinstallInventory/$STAMP"
TMPLOG="/tmp/pre-reinstall-inventory-$STAMP.log"

exec > >(tee "$TMPLOG") 2>&1

fail(){ echo "STOP: $*" >&2; exit 1; }
warn(){ echo "WARN: $*" >&2; }

echo "=== PRE-REINSTALL WINDOWS ENVIRONMENT INVENTORY ==="
date -Is
echo "READ-ONLY source: $WINDEV"
echo "WRITE destination: $DATADEV"

[[ $EUID -eq 0 ]] || fail "run as root"
[[ -b "$WINDEV" ]] || fail "$WINDEV missing"
[[ -b "$DATADEV" ]] || fail "$DATADEV missing"

WIN_UUID="$(blkid -s UUID -o value "$WINDEV" 2>/dev/null || true)"
DATA_UUID="$(blkid -s UUID -o value "$DATADEV" 2>/dev/null || true)"
[[ "$WIN_UUID" == "$WIN_UUID_EXPECTED" ]] || fail "Windows UUID mismatch ($WIN_UUID)"
[[ "$DATA_UUID" == "$DATA_UUID_EXPECTED" ]] || fail "DATA UUID mismatch ($DATA_UUID)"
echo "DISK_IDENTITY_OK"

mkdir -p "$WIN" "$DATA"
if mountpoint -q "$WIN"; then
  [[ "$(findmnt -no SOURCE "$WIN")" == "$WINDEV" ]] || fail "$WIN mounted from unexpected device"
else
  mount -t ntfs3 -o ro "$WINDEV" "$WIN" 2>/dev/null || mount -t ntfs-3g -o ro "$WINDEV" "$WIN"
fi

if mountpoint -q "$DATA"; then
  [[ "$(findmnt -no SOURCE "$DATA")" == "$DATADEV" ]] || fail "$DATA mounted from unexpected device"
else
  mount -t ntfs3 -o rw "$DATADEV" "$DATA" 2>/dev/null || mount -t ntfs-3g -o rw "$DATADEV" "$DATA"
fi

[[ -d "$WIN/Windows/System32" ]] || fail "Windows directory not found"
mkdir -p "$DEST"/{hardware,windows,registry/raw,registry/exports,profiles,drivers,scheduled_tasks,developer,project_manifests}

echo "DEST=$DEST"
df -h "$DATA"

echo "=== HARDWARE + DISK INVENTORY ==="
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,UUID,PARTUUID,MODEL,SERIAL,TRAN,RM > "$DEST/hardware/lsblk.txt" 2>&1 || true
blkid > "$DEST/hardware/blkid.txt" 2>&1 || true
lspci -nnk > "$DEST/hardware/lspci-nnk.txt" 2>&1 || true
lsusb -v > "$DEST/hardware/lsusb-verbose.txt" 2>&1 || lsusb > "$DEST/hardware/lsusb.txt" 2>&1 || true
efibootmgr -v > "$DEST/hardware/efibootmgr.txt" 2>&1 || true
uname -a > "$DEST/hardware/live-linux-uname.txt" 2>&1 || true

echo "=== WINDOWS FILESYSTEM INVENTORY ==="
{
  echo "Generated: $(date -Is)"
  echo
  echo "## Users"
  find "$WIN/Users" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
  echo
  echo "## Program Files"
  find "$WIN/Program Files" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
  echo
  echo "## Program Files (x86)"
  find "$WIN/Program Files (x86)" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
  echo
  echo "## ProgramData"
  find "$WIN/ProgramData" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
} > "$DEST/windows/top-level-software-folders.txt"

find "$WIN/Program Files" "$WIN/Program Files (x86)" -maxdepth 4 -type f \( -iname '*.exe' -o -iname '*.cmd' -o -iname '*.bat' \) -printf '%p\n' 2>/dev/null | sed "s#^$WIN#C:#" | sort > "$DEST/windows/program-executables.txt" || true

{
  for d in "$WIN/Users"/*; do
    [[ -d "$d" ]] || continue
    [[ -f "$d/NTUSER.DAT" ]] || continue
    n="$(basename "$d")"
    echo "[$n]"
    for sub in Desktop Documents Downloads Pictures Videos Music OneDrive; do
      if [[ -d "$d/$sub" ]]; then
        du -sh --apparent-size "$d/$sub" 2>/dev/null || true
      fi
    done
    echo
  done
} > "$DEST/windows/profile-common-folder-sizes.txt"

echo "=== RAW REGISTRY HIVE BACKUP (LOCAL DATA DRIVE ONLY) ==="
for h in SOFTWARE SYSTEM SAM SECURITY DEFAULT; do
  src="$WIN/Windows/System32/config/$h"
  [[ -f "$src" ]] && cp -a "$src" "$DEST/registry/raw/$h" || warn "missing hive $h"
done

echo "=== OPTIONAL REGISTRY TEXT EXPORTS ==="
if ! command -v reged >/dev/null 2>&1; then
  echo "Installing chntpw/reged into live Omarchy RAM only..."
  if curl -fL --retry 4 https://geo.mirror.pkgbuild.com/extra/os/x86_64/chntpw-140201-5-x86_64.pkg.tar.zst -o /tmp/chntpw.zst && pacman -U --noconfirm /tmp/chntpw.zst; then
    echo "REGED_INSTALLED"
  else
    warn "reged install failed; raw hives are still backed up"
  fi
fi

REGED_OK=0
if command -v reged >/dev/null 2>&1; then
  REGED_OK=1
  SOFT="$WIN/Windows/System32/config/SOFTWARE"
  SYS="$WIN/Windows/System32/config/SYSTEM"
  reged -x "$SOFT" 'HKEY_LOCAL_MACHINE\SOFTWARE' 'Microsoft\Windows\CurrentVersion\Uninstall' "$DEST/registry/exports/hklm-uninstall-64.reg" >/dev/null 2>&1 || true
  reged -x "$SOFT" 'HKEY_LOCAL_MACHINE\SOFTWARE' 'WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' "$DEST/registry/exports/hklm-uninstall-32.reg" >/dev/null 2>&1 || true
  reged -x "$SOFT" 'HKEY_LOCAL_MACHINE\SOFTWARE' 'Microsoft\Windows NT\CurrentVersion' "$DEST/registry/exports/windows-currentversion.reg" >/dev/null 2>&1 || true
  reged -x "$SOFT" 'HKEY_LOCAL_MACHINE\SOFTWARE' 'Microsoft\Windows\CurrentVersion\Run' "$DEST/registry/exports/hklm-run.reg" >/dev/null 2>&1 || true
  reged -x "$SYS" 'HKEY_LOCAL_MACHINE\SYSTEM' 'Select' "$DEST/registry/exports/system-select.reg" >/dev/null 2>&1 || true
  reged -x "$SYS" 'HKEY_LOCAL_MACHINE\SYSTEM' 'ControlSet001\Control\Session Manager\Environment' "$DEST/registry/exports/system-env-cs001.reg" >/dev/null 2>&1 || true
  reged -x "$SYS" 'HKEY_LOCAL_MACHINE\SYSTEM' 'ControlSet002\Control\Session Manager\Environment' "$DEST/registry/exports/system-env-cs002.reg" >/dev/null 2>&1 || true
  reged -x "$SYS" 'HKEY_LOCAL_MACHINE\SYSTEM' 'ControlSet001\Services' "$DEST/registry/exports/services-cs001.reg" >/dev/null 2>&1 || true
fi

echo "=== USER PROFILES + DEV CONFIGS ==="
SENSITIVE_FOUND=0
PROFILE_COUNT=0
for p in "$WIN/Users"/*; do
  [[ -d "$p" && -f "$p/NTUSER.DAT" ]] || continue
  user="$(basename "$p")"
  case "$user" in Default|"Default User"|"All Users") continue;; esac
  PROFILE_COUNT=$((PROFILE_COUNT+1))
  out="$DEST/profiles/$user"
  mkdir -p "$out"/{raw-hives,configs,sensitive-local-only,lists}

  cp -a "$p/NTUSER.DAT" "$out/raw-hives/NTUSER.DAT" 2>/dev/null || true
  [[ -f "$p/AppData/Local/Microsoft/Windows/UsrClass.dat" ]] && cp -a "$p/AppData/Local/Microsoft/Windows/UsrClass.dat" "$out/raw-hives/UsrClass.dat" || true

  for f in .gitconfig .npmrc .yarnrc .yarnrc.yml .condarc .wslconfig .bashrc .bash_profile .profile .zshrc .python-version .node-version .nvmrc .tool-versions; do
    [[ -f "$p/$f" ]] && cp -a "$p/$f" "$out/configs/" || true
  done

  for d in "Documents/PowerShell" "Documents/WindowsPowerShell" ".pip" ".cargo"; do
    if [[ -d "$p/$d" ]]; then
      mkdir -p "$out/configs/$(dirname "$d")"
      cp -a "$p/$d" "$out/configs/$d" 2>/dev/null || true
    fi
  done
  if [[ -f "$p/.gradle/gradle.properties" ]]; then
    mkdir -p "$out/configs/.gradle"
    cp -a "$p/.gradle/gradle.properties" "$out/configs/.gradle/"
  fi

  CODEUSER="$p/AppData/Roaming/Code/User"
  if [[ -d "$CODEUSER" ]]; then
    mkdir -p "$out/configs/Code/User"
    for x in settings.json keybindings.json argv.json locale.json snippets profiles; do
      [[ -e "$CODEUSER/$x" ]] && cp -a "$CODEUSER/$x" "$out/configs/Code/User/" 2>/dev/null || true
    done
  fi

  if [[ -d "$p/.ssh" ]]; then
    cp -a "$p/.ssh" "$out/sensitive-local-only/.ssh"
    SENSITIVE_FOUND=1
  fi
  if [[ -f "$p/.docker/config.json" ]]; then
    mkdir -p "$out/sensitive-local-only/.docker"
    cp -a "$p/.docker/config.json" "$out/sensitive-local-only/.docker/config.json"
    SENSITIVE_FOUND=1
  fi
  if [[ -f "$p/.kube/config" ]]; then
    mkdir -p "$out/sensitive-local-only/.kube"
    cp -a "$p/.kube/config" "$out/sensitive-local-only/.kube/config"
    SENSITIVE_FOUND=1
  fi

  if [[ -d "$p/.vscode/extensions" ]]; then
    find "$p/.vscode/extensions" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort > "$out/lists/vscode-extensions.txt"
  fi

  [[ -d "$p/AppData/Roaming/npm/node_modules" ]] && find "$p/AppData/Roaming/npm/node_modules" -mindepth 1 -maxdepth 2 -type d -printf '%P\n' | sort > "$out/lists/npm-global-node-modules.txt" || true
  [[ -d "$p/AppData/Local/Yarn/Data/global/node_modules" ]] && find "$p/AppData/Local/Yarn/Data/global/node_modules" -mindepth 1 -maxdepth 2 -type d -printf '%P\n' | sort > "$out/lists/yarn-global-node-modules.txt" || true
  [[ -d "$p/.cargo/bin" ]] && find "$p/.cargo/bin" -maxdepth 1 -type f -printf '%f\n' | sort > "$out/lists/cargo-bin.txt" || true
  [[ -d "$p/go/bin" ]] && find "$p/go/bin" -maxdepth 1 -type f -printf '%f\n' | sort > "$out/lists/go-bin.txt" || true

  find "$p/AppData/Local/Programs" -maxdepth 4 -type f \( -iname 'python.exe' -o -iname 'node.exe' -o -iname 'code.exe' -o -iname 'php.exe' -o -iname 'java.exe' \) -printf '%p\n' 2>/dev/null | sed "s#^$WIN#C:#" | sort > "$out/lists/local-runtime-executables.txt" || true

  if (( REGED_OK )); then
    NT="$p/NTUSER.DAT"
    reged -x "$NT" 'HKEY_CURRENT_USER' 'Software\Microsoft\Windows\CurrentVersion\Uninstall' "$out/lists/hkcu-uninstall.reg" >/dev/null 2>&1 || true
    reged -x "$NT" 'HKEY_CURRENT_USER' 'Environment' "$out/lists/hkcu-environment.reg" >/dev/null 2>&1 || true
    reged -x "$NT" 'HKEY_CURRENT_USER' 'Software\Microsoft\Windows\CurrentVersion\Run' "$out/lists/hkcu-run.reg" >/dev/null 2>&1 || true
  fi
done

echo "PROFILE_COUNT=$PROFILE_COUNT"

echo "=== INSTALLED APP SUMMARY FROM REGISTRY EXPORTS ==="
python3 - "$DEST" <<'PY'
import os,re,sys,csv
dest=sys.argv[1]
files=[('machine64',os.path.join(dest,'registry','exports','hklm-uninstall-64.reg')),('machine32',os.path.join(dest,'registry','exports','hklm-uninstall-32.reg'))]
profiles=os.path.join(dest,'profiles')
if os.path.isdir(profiles):
    for user in os.listdir(profiles):
        files.append((f'user:{user}',os.path.join(profiles,user,'lists','hkcu-uninstall.reg')))
def read_text(p):
    b=open(p,'rb').read()
    for enc in ('utf-8-sig','utf-16','latin-1'):
        try: return b.decode(enc)
        except Exception: pass
    return b.decode('latin-1','replace')
rows=[]
for scope,p in files:
    if not os.path.isfile(p): continue
    section=''; vals={}
    def flush():
        if vals.get('DisplayName'):
            rows.append({'scope':scope,'key':section,'name':vals.get('DisplayName',''),'version':vals.get('DisplayVersion',''),'publisher':vals.get('Publisher',''),'install_location':vals.get('InstallLocation',''),'uninstall':vals.get('UninstallString','')})
    for line in read_text(p).splitlines()+['[END]']:
        line=line.strip()
        if line.startswith('[') and line.endswith(']'):
            flush(); vals={}; section=line[1:-1]; continue
        m=re.match(r'^"([^"]+)"="(.*)"$',line)
        if m: vals[m.group(1)]=m.group(2)
out=os.path.join(dest,'windows','installed-apps.tsv')
with open(out,'w',encoding='utf-8',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['scope','name','version','publisher','install_location','uninstall','key'],delimiter='\t')
    w.writeheader()
    for r in sorted(rows,key=lambda x:(x['name'].lower(),x['scope'])): w.writerow(r)
print(f"INSTALLED_APPS_PARSED={len(rows)}")
PY

echo "=== SCHEDULED TASKS ==="
if [[ -d "$WIN/Windows/System32/Tasks" ]]; then
  cp -a "$WIN/Windows/System32/Tasks/." "$DEST/scheduled_tasks/" 2>/dev/null || true
fi

echo "=== DRIVER INVENTORY ==="
find "$WIN/Windows/System32/DriverStore/FileRepository" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort > "$DEST/drivers/driverstore-folders.txt" || true
find "$WIN/Windows/INF" -maxdepth 1 -type f -iname 'oem*.inf' -printf '%f\n' 2>/dev/null | sort > "$DEST/drivers/oem-inf-list.txt" || true
mkdir -p "$DEST/drivers/oem-inf"
cp -a "$WIN/Windows/INF"/oem*.inf "$DEST/drivers/oem-inf/" 2>/dev/null || true
cp -a "$WIN/Windows/INF/setupapi.dev.log" "$DEST/drivers/" 2>/dev/null || true

echo "=== PROJECT MANIFESTS + DEPENDENCY FILES ==="
python3 - "$WIN" "$DEST" <<'PY'
import os,sys,shutil,fnmatch
win,dest=sys.argv[1:]
out=os.path.join(dest,'project_manifests'); os.makedirs(out,exist_ok=True)
names={'package.json','package-lock.json','pnpm-lock.yaml','pnpm-workspace.yaml','yarn.lock','composer.json','composer.lock','pyproject.toml','poetry.lock','Pipfile','Pipfile.lock','environment.yml','environment.yaml','Cargo.toml','Cargo.lock','go.mod','go.sum','Gemfile','Gemfile.lock','pom.xml','build.gradle','build.gradle.kts','gradle.properties','Dockerfile','docker-compose.yml','docker-compose.yaml','.tool-versions','.nvmrc','.node-version','.python-version','requirements.txt','requirements-dev.txt','requirements-prod.txt','requirements-test.txt','artisan'}
patterns=['requirements*.txt','docker-compose*.yml','docker-compose*.yaml','*.csproj','*.sln','*.fsproj']
prune={'.git','node_modules','vendor','dist','build','.next','.nuxt','target','.venv','venv','__pycache__','.cache'}
roots=[]
users=os.path.join(win,'Users')
if os.path.isdir(users):
    for u in os.listdir(users):
        p=os.path.join(users,u)
        if not os.path.isfile(os.path.join(p,'NTUSER.DAT')): continue
        for rel in ('Downloads/Projects','Projects','Documents','Desktop','source/repos'):
            r=os.path.join(p,rel)
            if os.path.isdir(r): roots.append(r)
seen=set(); count=0; envpaths=[]; venvs=[]
for root in roots:
    for base,dirs,files in os.walk(root):
        dirs[:]=[d for d in dirs if d not in prune and not d.startswith('.git')]
        for f in files:
            if f.startswith('.env'): envpaths.append(os.path.relpath(os.path.join(base,f),win))
            match=f in names or any(fnmatch.fnmatch(f,p) for p in patterns)
            if not match: continue
            src=os.path.join(base,f); rel=os.path.relpath(src,win)
            if rel in seen: continue
            seen.add(rel); dst=os.path.join(out,rel); os.makedirs(os.path.dirname(dst),exist_ok=True)
            try: shutil.copy2(src,dst); count+=1
            except OSError: pass
        if 'pyvenv.cfg' in files: venvs.append(os.path.relpath(os.path.join(base,'pyvenv.cfg'),win))
with open(os.path.join(dest,'developer','project-roots.txt'),'w',encoding='utf-8') as f:
    for r in roots: f.write(os.path.relpath(r,win)+'\n')
with open(os.path.join(dest,'developer','env-file-paths-NO-CONTENTS.txt'),'w',encoding='utf-8') as f:
    for p in sorted(set(envpaths)): f.write(p+'\n')
with open(os.path.join(dest,'developer','python-venv-pyvenv-paths.txt'),'w',encoding='utf-8') as f:
    for p in sorted(set(venvs)): f.write(p+'\n')
print(f"PROJECT_MANIFESTS_COPIED={count}")
print(f"ENV_FILES_LISTED_NO_CONTENTS={len(set(envpaths))}")
print(f"PYVENV_CFG_FOUND={len(set(venvs))}")
PY

echo "=== LARGE VIRTUAL DISK / WSL / DOCKER INVENTORY ==="
: > "$DEST/developer/virtual-disk-images.txt"
VHDX_COUNT=0
while IFS= read -r -d '' f; do
  VHDX_COUNT=$((VHDX_COUNT+1))
  bytes="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  printf '%s\t%s\n' "$bytes" "${f#$WIN/}" >> "$DEST/developer/virtual-disk-images.txt"
done < <(find "$WIN/Users" -type f \( -iname '*.vhdx' -o -iname '*.vhd' -o -iname '*.vdi' -o -iname '*.vmdk' \) -print0 2>/dev/null)
echo "VIRTUAL_DISK_IMAGES_FOUND=$VHDX_COUNT"
if (( VHDX_COUNT > 0 )); then
  cat > "$DEST/NEEDS_LARGE_VM_WSL_BACKUP.txt" <<'EOF'
One or more VHD/VHDX/VDI/VMDK files were found.
These may contain WSL, Docker Desktop, or VM data.
They were INVENTORIED but NOT copied by this inventory script.
Do not wipe the Windows NVMe until you decide whether these files need a full backup.
See developer/virtual-disk-images.txt.
EOF
fi

echo "=== CODEX HANDOFF ==="
APP_COUNT="$(awk 'END{print NR>0?NR-1:0}' "$DEST/windows/installed-apps.tsv" 2>/dev/null || echo 0)"
MANIFEST_COUNT="$(find "$DEST/project_manifests" -type f 2>/dev/null | wc -l)"
cat > "$DEST/CODEX_HANDOFF.md" <<EOF
# Windows Pre-Reinstall Environment Inventory

Generated: $(date -Is)

## Disk authority
- Broken Windows installation source: $WINDEV
- Windows filesystem UUID: $WIN_UUID_EXPECTED
- Persistent backup destination: $DATADEV
- DATA filesystem UUID: $DATA_UUID_EXPECTED
- Inventory folder: PreReinstallInventory/$STAMP

## What Codex should use after reinstall
1. windows/installed-apps.tsv — registry-derived installed application list (${APP_COUNT} parsed rows).
2. windows/top-level-software-folders.txt and windows/program-executables.txt — filesystem cross-check.
3. profiles/*/lists/vscode-extensions.txt — VS Code extensions.
4. profiles/*/configs/ — shell/dev configuration snapshots.
5. project_manifests/ — package/dependency manifests and lockfiles (${MANIFEST_COUNT} files).
6. drivers/ and hardware/ — driver/hardware reconstruction references.
7. registry/exports/ — machine uninstall/current-version/services/environment exports when reged succeeded.
8. registry/raw/ and profiles/*/raw-hives/ — raw forensic registry hives.

## Sensitive local-only data
Directories named sensitive-local-only may contain SSH or other credentials.
Do NOT upload or print their contents. Restore them locally with correct permissions only.

## Important
This inventory is descriptive. Do not blindly reinstall every historical component.
After Windows reinstall, reconstruct the toolchain in dependency order, verify versions against project lockfiles,
and use current vendor installers unless a project explicitly requires an older version.
EOF

if (( SENSITIVE_FOUND )); then
  cat > "$DEST/SENSITIVE_LOCAL_ONLY.txt" <<'EOF'
Sensitive developer configuration was copied locally into profiles/*/sensitive-local-only.
This script did NOT upload the inventory anywhere.
Keep this folder private.
EOF
fi

echo "=== INTEGRITY MANIFEST ==="
(
  cd "$DEST"
  find . -type f ! -name 'SHA256SUMS.txt' ! -path './profiles/*/sensitive-local-only/*' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt
)

cp -a "$TMPLOG" "$DEST/run.log" 2>/dev/null || true

echo "=== FINAL SUMMARY ==="
echo "INVENTORY_PATH=$DEST"
echo "INSTALLED_APPS_PARSED=$APP_COUNT"
echo "PROJECT_MANIFESTS_COPIED=$MANIFEST_COUNT"
echo "VIRTUAL_DISK_IMAGES_FOUND=$VHDX_COUNT"
echo "SENSITIVE_LOCAL_ONLY=$SENSITIVE_FOUND"
echo
if (( VHDX_COUNT > 0 )); then
  echo "INVENTORY_PASS_WITH_VM_WSL_WARNING"
  echo "Read: $DEST/NEEDS_LARGE_VM_WSL_BACKUP.txt"
else
  echo "INVENTORY_PASS"
fi
sync
