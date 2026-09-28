#!/usr/bin/env bash
set -euo pipefail

echo "=== Windows BCD diagnostic stage 1 (READ-ONLY) ==="

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root"
  exit 1
fi

EFI_DEV="/dev/nvme0n1p1"
EFI_MNT="/mnt/efi"
BCD_PATH="${EFI_MNT}/EFI/Microsoft/Boot/BCD"
BCD_COPY="/tmp/BCD.before-fix"
WORK="/tmp/fixbcd"

mkdir -p "${EFI_MNT}"

if ! mountpoint -q "${EFI_MNT}"; then
  mount -o ro "${EFI_DEV}" "${EFI_MNT}"
fi

if [[ ! -f "${BCD_PATH}" ]]; then
  echo "ERROR: BCD not found at ${BCD_PATH}"
  exit 2
fi

cp -a "${BCD_PATH}" "${BCD_COPY}"

echo
echo "BCD backup hash check:"
sha256sum "${BCD_PATH}" "${BCD_COPY}"

if ! command -v reged >/dev/null 2>&1; then
  echo
  echo "reged missing; installing chntpw from official Arch mirror..."
  curl -fL "https://geo.mirror.pkgbuild.com/extra/os/x86_64/chntpw-140201-5-x86_64.pkg.tar.zst" -o /tmp/chntpw.zst
  pacman -U --noconfirm /tmp/chntpw.zst
fi

mkdir -p "${WORK}"
cd "${WORK}"

curl -fL "https://raw.githubusercontent.com/garloff/Fix_BCD/main/fix_boot_bcd.py" -o fix_boot_bcd.py
curl -fL "https://raw.githubusercontent.com/garloff/Fix_BCD/main/registry_dict.py" -o registry_dict.py

echo
echo "Current disks/partitions:"
lsblk -o NAME,SIZE,FSTYPE,PARTUUID,UUID,PARTLABEL

echo
echo "=== DRY RUN ONLY: BCD will NOT be modified ==="
set +e
python3 fix_boot_bcd.py -n "${BCD_COPY}" | tee /tmp/bcd-dryrun.txt
rc=${PIPESTATUS[0]}
set -e

echo
echo "Dry-run exit code: ${rc}"
echo "Output saved to /tmp/bcd-dryrun.txt"
echo "Original BCD remains untouched."
exit 0
