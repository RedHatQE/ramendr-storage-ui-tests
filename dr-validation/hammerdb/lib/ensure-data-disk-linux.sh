#!/usr/bin/env bash
# Format and mount the DR-protected block data disk on Linux edge VMs.
# Sourced by hammerdb/install-on-vm.sh (not executed directly).

ensure_dr_validation_data_disk() {
  local mount_point="${DR_VALIDATION_DATA_DISK_MOUNT:-/mnt/ramendr-data}"
  local fs_label="${DR_VALIDATION_DATA_DISK_LABEL:-RAMENDR-DATA}"
  local fstab_marker="# ramendr-dr-validation-data-disk"

  if mountpoint -q "$mount_point"; then
    echo "Data disk already mounted at ${mount_point}"
    return 0
  fi

  local root_src root_disk
  root_src="$(findmnt -n -o SOURCE /)"
  root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)"
  if [[ -z "$root_disk" ]]; then
    echo "ERROR: Cannot determine root block device from ${root_src}"
    return 1
  fi

  local candidate_dev=""
  while read -r name type; do
    [[ "$type" == "disk" ]] || continue
    [[ "$name" == "$root_disk" ]] && continue
    candidate_dev="/dev/${name}"
    break
  done < <(lsblk -dn -o NAME,TYPE)

  if [[ -z "$candidate_dev" || ! -b "$candidate_dev" ]]; then
    for dev in /dev/vdb /dev/sdb /dev/xvdb; do
      if [[ -b "$dev" ]]; then
        local pk
        pk="$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)"
        pk="${pk:-$(basename "$dev")}"
        [[ "$pk" == "$root_disk" ]] && continue
        candidate_dev="$dev"
        break
      fi
    done
  fi

  if [[ -z "$candidate_dev" || ! -b "$candidate_dev" ]]; then
    echo "ERROR: DR validation data disk block device not found (root disk: ${root_disk})"
    return 1
  fi

  local target_dev="$candidate_dev"
  local part
  part="$(lsblk -pln -o NAME,TYPE "$candidate_dev" | awk '$2=="part"{print $1; exit}')"
  if [[ -n "$part" && -b "$part" ]]; then
    if ! lsblk -no MOUNTPOINT "$part" 2>/dev/null | grep -q .; then
      target_dev="$part"
    fi
  fi

  echo "Preparing HammerDB data disk ${target_dev} -> ${mount_point}..."
  sudo mkdir -p "$mount_point"

  local uuid fstype
  uuid="$(sudo blkid -s UUID -o value "$target_dev" 2>/dev/null || true)"
  fstype="$(sudo blkid -s TYPE -o value "$target_dev" 2>/dev/null || true)"
  if [[ -z "$uuid" || "$fstype" != "xfs" ]]; then
    sudo mkfs.xfs -L "$fs_label" -f "$target_dev"
    uuid="$(sudo blkid -s UUID -o value "$target_dev")"
  fi

  if ! grep -q "$fstab_marker" /etc/fstab 2>/dev/null; then
    echo "UUID=${uuid} ${mount_point} xfs defaults,nofail 0 2 ${fstab_marker}" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo mount "$mount_point"

  echo "HammerDB data disk ready: ${target_dev} mounted at ${mount_point} (UUID=${uuid})"
}
