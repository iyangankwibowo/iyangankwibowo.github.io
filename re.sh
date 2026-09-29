#!/usr/bin/env bash
set -Eeuo pipefail

DISK=/dev/sda
P2=/dev/sda2
P3=/dev/sda3
DATA_UUID_EXPECTED="8E2EC0B92EC09B99"
DISK_SERIAL_EXPECTED="WD-WX81A6998NP1"

fail(){ echo; echo "STOP: $*" >&2; exit 1; }

echo "=== RESTORE E: PARTITION BOUNDARY ==="
date -Is

[[ $EUID -eq 0 ]] || fail "run as root"
[[ -b "$DISK" && -b "$P2" && -b "$P3" ]] || fail "expected /dev/sda2 and /dev/sda3"

SERIAL="$(udevadm info --query=property --name="$DISK" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2; exit}')"
[[ "$SERIAL" == "$DISK_SERIAL_EXPECTED" ]] || fail "disk serial mismatch: $SERIAL"

DATA_UUID="$(blkid -s UUID -o value "$P2" 2>/dev/null || true)"
DATA_TYPE="$(blkid -s TYPE -o value "$P2" 2>/dev/null || true)"
[[ "$DATA_UUID" == "$DATA_UUID_EXPECTED" ]] || fail "DATA UUID mismatch: $DATA_UUID"
[[ "$DATA_TYPE" == "ntfs" ]] || fail "DATA partition is not NTFS: $DATA_TYPE"

P2_START="$(cat /sys/class/block/sda2/start)"
P2_SIZE="$(cat /sys/class/block/sda2/size)"
P3_START="$(cat /sys/class/block/sda3/start)"
P2_END=$((P2_START + P2_SIZE - 1))
MAX_END=$((P3_START - 1))
GAP_SECTORS=$((MAX_END - P2_END))
GAP_BYTES=$((GAP_SECTORS * 512))

python3 - "$P2" "$P2_SIZE" "$P2_START" "$MAX_END" "$GAP_BYTES" <<'PY'
import struct,sys
p=sys.argv[1]
part_sectors=int(sys.argv[2])
part_start=int(sys.argv[3])
max_end=int(sys.argv[4])
gap_bytes=int(sys.argv[5])
with open(p,'rb',buffering=0) as f:
    bs=f.read(512)
if len(bs)<512 or bs[3:11] != b'NTFS    ':
    raise SystemExit("STOP: NTFS boot sector signature not found")
bps=struct.unpack_from('<H',bs,11)[0]
total=struct.unpack_from('<Q',bs,40)[0]
fs_bytes=total*bps
req_disk_sectors=(fs_bytes+511)//512
req_end=part_start+req_disk_sectors-1
GiB=1024**3
print(f"CURRENT_PARTITION_GIB={part_sectors*512/GiB:.3f}")
print(f"NTFS_FILESYSTEM_GIB={fs_bytes/GiB:.3f}")
print(f"CONTIGUOUS_FREE_AFTER_GIB={gap_bytes/GiB:.3f}")
print(f"SAFE_MAX_END_SECTOR={max_end}")
print(f"REQUIRED_END_SECTOR={req_end}")
if fs_bytes <= part_sectors*512:
    raise SystemExit("STOP: NTFS is not larger than current partition; refusing resize")
if req_end > max_end:
    raise SystemExit("STOP: free space is insufficient to contain NTFS")
if not (90*GiB <= gap_bytes <= 110*GiB):
    raise SystemExit("STOP: free-space gap is not the expected ~100 GiB")
print("GEOMETRY_CHECK_PASS")
PY

if findmnt -S "$P2" >/dev/null 2>&1; then
  umount "$P2" || fail "could not unmount DATA partition"
fi

BACKUP_DIR="/run/archiso/bootmnt/partition-table-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
parted -s "$DISK" unit s print free > "$BACKUP_DIR/parted-before.txt"
if command -v sfdisk >/dev/null 2>&1; then
  sfdisk --dump "$DISK" > "$BACKUP_DIR/sfdisk-before.txt" || true
fi
if command -v sgdisk >/dev/null 2>&1; then
  sgdisk --backup="$BACKUP_DIR/gpt-before.bin" "$DISK"
fi
sync
echo "PARTITION_TABLE_BACKUP=$BACKUP_DIR"

echo "Extending DATA partition to sector immediately before Microsoft Reserved partition..."
parted -s "$DISK" unit s resizepart 2 "${MAX_END}s"
partprobe "$DISK" || true
udevadm settle || true
sleep 2

NEW_START="$(cat /sys/class/block/sda2/start)"
NEW_SIZE="$(cat /sys/class/block/sda2/size)"
NEW_END=$((NEW_START + NEW_SIZE - 1))
[[ "$NEW_START" == "$P2_START" ]] || fail "partition start changed unexpectedly"
[[ "$NEW_END" -ge "$MAX_END" ]] || fail "partition did not extend to expected boundary"

echo "PARTITION_BOUNDARY_RESTORED"

CHK=/mnt/e-check
mkdir -p "$CHK"
umount "$CHK" 2>/dev/null || true
if mount -t ntfs3 -o ro "$P2" "$CHK"; then
  :
elif command -v ntfs-3g >/dev/null 2>&1 && mount -t ntfs-3g -o ro "$P2" "$CHK"; then
  :
else
  fail "boundary restored but NTFS still cannot mount read-only; DO NOT FORMAT"
fi

echo "READ_ONLY_MOUNT_PASS"
df -h "$CHK"
echo "TOPLEVEL:"
find "$CHK" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort | sed -n '1,40p'
umount "$CHK"
sync

echo
echo "DATA_PARTITION_RESTORE_PASS"
echo "Power off Omarchy, boot Windows, and click Cancel if any format prompt appears."
echo "Then run as Administrator: chkdsk E: /f"
