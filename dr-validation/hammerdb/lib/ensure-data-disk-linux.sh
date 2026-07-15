#!/usr/bin/env bash
# Format and mount the DR-protected block data disk on Linux edge VMs.
# Sourced by hammerdb/install-on-vm.sh (not executed directly).

# KubeVirt/Velero backups run virt-freezer pre-hooks that call guest-fsfreeze on
# every mounted filesystem. A freshly formatted XFS root is unlabeled_t under
# SELinux, so qemu-guest-agent cannot open the mount point (Permission denied).
# Label only the mount-point inode (non-recursive) so PGDATA labels are untouched.
prepare_dr_validation_data_disk_mount_for_fsfreeze() {
  local mount_point="$1"

  [[ -n "$mount_point" ]] || return 0
  if ! mountpoint -q "$mount_point"; then
    return 0
  fi

  sudo chown root:root "$mount_point"
  sudo chmod 0755 "$mount_point"

  if ! command -v getenforce >/dev/null 2>&1; then
    return 0
  fi
  local selinux_state
  selinux_state="$(getenforce 2>/dev/null || echo Disabled)"
  [[ "$selinux_state" == "Disabled" ]] && return 0

  if command -v semanage >/dev/null 2>&1; then
    if ! sudo semanage fcontext -l 2>/dev/null | grep -qF "${mount_point} "; then
      sudo semanage fcontext -a -t mnt_t "${mount_point}"
    fi
  else
    echo "ERROR: semanage is required while SELinux is enabled" >&2
    return 1
  fi

  if ! command -v restorecon >/dev/null 2>&1; then
    echo "ERROR: restorecon is required while SELinux is enabled" >&2
    return 1
  fi
  sudo restorecon -v "$mount_point"

  local mount_ctx
  mount_ctx="$(ls -Zd "$mount_point" 2>/dev/null | awk '{print $4}' || true)"
  if [[ -z "$mount_ctx" || "$mount_ctx" == "unlabeled_t" ]]; then
    echo "ERROR: ${mount_point} SELinux context is not labeled (got: ${mount_ctx:-unknown})" >&2
    return 1
  fi

  if command -v getsebool >/dev/null 2>&1 && command -v setsebool >/dev/null 2>&1; then
    if ! getsebool virt_qemu_ga_read_nonsecurity_files 2>/dev/null | grep -Eq ' on$'; then
      echo "Enabling virt_qemu_ga_read_nonsecurity_files for KubeVirt fsfreeze on ${mount_point}..."
      sudo setsebool -P virt_qemu_ga_read_nonsecurity_files 1
    fi
    if ! getsebool virt_qemu_ga_read_nonsecurity_files 2>/dev/null | grep -Eq ' on$'; then
      echo "ERROR: virt_qemu_ga_read_nonsecurity_files is not enabled" >&2
      return 1
    fi
  else
    echo "ERROR: getsebool/setsebool are required while SELinux is enabled" >&2
    return 1
  fi
}

ensure_dr_validation_data_disk() {
  local mount_point="${DR_VALIDATION_DATA_DISK_MOUNT:-/mnt/ramendr-data}"
  local fs_label="${DR_VALIDATION_DATA_DISK_LABEL:-RAMENDR-DATA}"
  local fstab_marker="# ramendr-dr-validation-data-disk"

  if mountpoint -q "$mount_point"; then
    echo "Data disk already mounted at ${mount_point}"
    prepare_dr_validation_data_disk_mount_for_fsfreeze "$mount_point"
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
  sudo chown root:root "$mount_point"
  sudo chmod 0755 "$mount_point"

  local uuid fstype
  uuid="$(sudo blkid -s UUID -o value "$target_dev" 2>/dev/null || true)"
  fstype="$(sudo blkid -s TYPE -o value "$target_dev" 2>/dev/null || true)"
  if [[ -z "$uuid" || "$fstype" != "xfs" ]]; then
    sudo mkfs.xfs -L "$fs_label" -f "$target_dev"
    uuid="$(sudo blkid -s UUID -o value "$target_dev")"
  fi
  if [[ -z "$uuid" ]]; then
    echo "ERROR: Failed to read UUID for ${target_dev}" >&2
    return 1
  fi

  if ! grep -q "$fstab_marker" /etc/fstab 2>/dev/null; then
    echo "UUID=${uuid} ${mount_point} xfs defaults,nofail 0 2 ${fstab_marker}" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo mount "$mount_point"
  prepare_dr_validation_data_disk_mount_for_fsfreeze "$mount_point"

  echo "HammerDB data disk ready: ${target_dev} mounted at ${mount_point} (UUID=${uuid})"
}
