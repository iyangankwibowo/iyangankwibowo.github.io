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
mkdir -p "$EFI" "$WIN" "$REC" "$TOOLS"
mountpoint -q "$EFI" || mount -o ro /dev/nvme0n1p1 "$EFI"
mountpoint -q "$WIN" || mount -t ntfs3 -o ro /dev/nvme0n1p3 "$WIN"
mountpoint -q "$REC" || mount -t ntfs3 -o ro /dev/nvme0n1p4 "$REC"
lsblk -o NAME,SIZE,FSTYPE,PARTUUID,UUID,PARTLABEL,MOUNTPOINTS
efibootmgr -v || true
for f in "$EFI"/EFI/Microsoft/Boot/BCD*; do [ -f "$f" ] && sha256sum "$f"; done
for f in winload.efi winresume.efi ntoskrnl.exe hal.dll ci.dll bootvid.dll; do
 p="$WIN/Windows/System32/$f"; [ -f "$p" ] && { ls -lh "$p"; sha256sum "$p"; } || echo "MISSING $p"
done
ls -lh "$WIN/Windows/bootstat.dat" "$WIN/hiberfil.sys" 2>/dev/null || true
ls -lh "$REC/Recovery/WindowsRE/Winre.wim" 2>/dev/null || true
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
echo DEEPBOOT_READONLY_DONE
