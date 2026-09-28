#!/usr/bin/env bash
set -u
TOPIC=iybd-928-7f3a9c1e2d4b
LOG=/tmp/deepboot-readonly.log
EFI=/mnt/efi
WIN=/mnt/windows
REC=/mnt/recovery
TOOLS=/tmp/fixbcd
relay(){ curl -sS -T "$LOG" -H "Filename: deepboot-readonly.log" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true; }
trap relay EXIT
exec > >(tee "$LOG") 2>&1

echo "=== DEEPBOOT READ-ONLY ==="
date -Is
mkdir -p "$EFI" "$WIN" "$REC" "$TOOLS"
mountpoint -q "$EFI" || mount -o ro /dev/nvme0n1p1 "$EFI"
mountpoint -q "$WIN" || mount -t ntfs3 -o ro /dev/nvme0n1p3 "$WIN"
mountpoint -q "$REC" || mount -t ntfs3 -o ro /dev/nvme0n1p4 "$REC"

echo "=== DISK / GPT IDENTITY ==="
lsblk -o NAME,SIZE,FSTYPE,PARTUUID,UUID,PARTLABEL,MOUNTPOINTS
blkid /dev/nvme0n1p1 /dev/nvme0n1p3 /dev/nvme0n1p4 || true

echo "=== UEFI NVRAM ==="
efibootmgr -v || true

echo "=== EFI BOOT FILES / BCD COPIES ==="
find "$EFI/EFI/Microsoft/Boot" -maxdepth 1 -type f \( -name 'BCD*' -o -iname '*.efi' \) -printf '%p %s bytes\n' 2>/dev/null | sort
for f in "$EFI"/EFI/Microsoft/Boot/BCD*; do [ -f "$f" ] && sha256sum "$f"; done
for f in "$EFI/EFI/Microsoft/Boot/bootmgfw.efi" "$EFI/EFI/Microsoft/Boot/bootmgr.efi"; do [ -f "$f" ] && sha256sum "$f"; done

echo "=== WINDOWS CRITICAL FILES ==="
for f in winload.efi winload.exe winresume.efi ntoskrnl.exe hal.dll ci.dll bootvid.dll; do
 p="$WIN/Windows/System32/$f"
 [ -f "$p" ] && { ls -lh "$p"; file "$p" || true; sha256sum "$p"; } || echo "MISSING $p"
done
for f in "$WIN/Windows/System32/config/SYSTEM" "$WIN/Windows/System32/config/SOFTWARE" "$WIN/Windows/System32/Config/BCD-Template"; do
 [ -f "$f" ] && { ls -lh "$f"; sha256sum "$f"; } || echo "MISSING $f"
done

echo "=== BOOT STATUS / HIBERNATION ==="
ls -lh "$WIN/Windows/bootstat.dat" "$WIN/hiberfil.sys" 2>/dev/null || true
[ -f "$WIN/Windows/bootstat.dat" ] && sha256sum "$WIN/Windows/bootstat.dat" || true

echo "=== WINRE / REAGENT ==="
ls -lh "$REC/Recovery/WindowsRE/Winre.wim" 2>/dev/null || true
sha256sum "$REC/Recovery/WindowsRE/Winre.wim" 2>/dev/null || true
find "$WIN/Windows/System32/Recovery" "$REC/Recovery/WindowsRE" -maxdepth 1 -type f -printf '%p %s bytes\n' 2>/dev/null | sort
for f in "$WIN/Windows/System32/Recovery/ReAgent.xml" "$REC/Recovery/WindowsRE/ReAgent.xml"; do
 [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; } || true
done

echo "=== BCD SEMANTIC DEVICE SCAN ==="
cd "$TOOLS"
curl -fsSL https://raw.githubusercontent.com/garloff/Fix_BCD/main/fix_boot_bcd.py -o fix_boot_bcd.py
curl -fsSL https://raw.githubusercontent.com/garloff/Fix_BCD/main/registry_dict.py -o registry_dict.py
python3 - <<'PY'
import sys
sys.path.insert(0,'/tmp/fixbcd')
import fix_boot_bcd as f
f.select_uuid=lambda:None
rc=f.main(['fix_boot_bcd.py','-n','/mnt/efi/EFI/Microsoft/Boot/BCD'])
print('BCD_SCAN_RC=',rc)
PY

echo "=== BCD OBJECT INVENTORY ==="
python3 - <<'PY'
import sys
sys.path.insert(0,'/tmp/fixbcd')
import registry_dict
b=registry_dict.RegDict('/mnt/efi/EFI/Microsoft/Boot/BCD')
for oid,obj in b['Objects'].items():
    el=obj.get('Elements',{})
    desc=el.get('12000004',{}).get('Element','')
    path=el.get('12000002',{}).get('Element','')
    print('OBJECT',oid,'DESC=',repr(desc),'PATH=',repr(path))
    for k,v in sorted(el.items()):
        x=v.get('Element') if isinstance(v,dict) else None
        if isinstance(x,(str,int)):
            print(' ',k,repr(x))
PY

echo DEEPBOOT_READONLY_DONE
