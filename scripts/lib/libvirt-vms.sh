#!/usr/bin/env bash
# shellcheck shell=bash
# Compact 3-node libvirt VMs for agent-based OpenShift install.

libvirt_disk_path() {
  local vm="$1" kind="$2"
  echo "${LIBVIRT_IMAGE_DIR}/${vm}-${kind}.qcow2"
}

libvirt_iso_path() {
  echo "${LIBVIRT_IMAGE_DIR}/ramendr-agent-${1}.iso"
}

libvirt_ensure_vm() {
  local cluster="$1" idx="$2"
  local vm net mac os_disk osd_disk iso osd_gib vcpus memory_mib
  vm="$(libvirt_vm_name "$cluster" "$idx")"
  net="$(libvirt_network_name "$cluster")"
  mac="$(libvirt_node_mac "$cluster" "$idx")"
  os_disk="$(libvirt_disk_path "$vm" os)"
  osd_disk="$(libvirt_disk_path "$vm" osd)"
  iso="$(libvirt_iso_path "$cluster")"
  osd_gib="$(libvirt_osd_gib "$cluster")"
  vcpus="$(libvirt_cluster_vcpus "$cluster")"
  memory_mib="$(libvirt_cluster_memory_mib "$cluster")"

  if libvirt_ssh virsh dominfo "$vm" >/dev/null 2>&1; then
    _lv_log "VM $vm already defined."
    libvirt_ssh virsh start "$vm" >/dev/null 2>&1 || true
    return 0
  fi

  _lv_log "Creating VM $vm (${vcpus} vCPU, ${memory_mib} MiB, OS ${LIBVIRT_OS_DISK_GIB} GiB, OSD ${osd_gib} GiB)..."
  libvirt_ssh mkdir -p "$LIBVIRT_IMAGE_DIR"
  libvirt_ssh qemu-img create -f qcow2 "$os_disk" "${LIBVIRT_OS_DISK_GIB}G" >/dev/null
  libvirt_ssh qemu-img create -f qcow2 "$osd_disk" "${osd_gib}G" >/dev/null

  # Boot hd,cdrom: empty OS disk falls through to the agent ISO; after RHCOS
  # is on /dev/vda, reboot boots the installed system (not the live ISO).
  # Attach the ISO as a cdrom disk (not --cdrom) so virt-install keeps hd-first.
  # Do not put comments inside the \-continued argv — they truncate the command.
  libvirt_ssh virt-install \
    --name "$vm" \
    --memory "$memory_mib" \
    --vcpus "$vcpus" \
    --cpu host-passthrough \
    --boot hd,cdrom \
    --disk "path=${os_disk},format=qcow2,bus=virtio,cache=none" \
    --disk "path=${osd_disk},format=qcow2,bus=virtio,cache=none" \
    --disk "path=${iso},device=cdrom,readonly=on" \
    --network "network=${net},mac=${mac},model=virtio" \
    --os-variant "$LIBVIRT_OS_VARIANT" \
    --graphics none \
    --noautoconsole \
    --wait 0
}

libvirt_ensure_cluster_vms() {
  local cluster="$1" i
  for i in 0 1 2; do
    libvirt_ensure_vm "$cluster" "$i"
  done
}

# Destroy + redefine so a re-run boots the freshly generated agent ISO
# (stuck installs otherwise keep the old live OS and never re-pull).
libvirt_recreate_cluster_vms() {
  local cluster="$1" i vm
  _lv_log "Recreating VMs for $cluster (fresh agent boot)..."
  for i in 0 1 2; do
    vm="$(libvirt_vm_name "$cluster" "$i")"
    libvirt_destroy_vm "$vm"
  done
  libvirt_ensure_cluster_vms "$cluster"
}

# Eject the agent ISO (live + persistent). Target is typically sda (SATA cdrom).
# Safe while the live OS is still running (rootfs is in RAM). Do not reset VMs
# here — that kills the rendezvous assisted-service / bootstrap coordination.
libvirt_eject_agent_iso() {
  local cluster="$1" i vm out rc=0
  for i in 0 1 2; do
    vm="$(libvirt_vm_name "$cluster" "$i")"
    out="$(libvirt_ssh virsh change-media "$vm" sda --eject --config --live --force 2>&1)" && {
      _lv_log "Ejected agent ISO from $vm"
      continue
    }
    out="$(libvirt_ssh virsh change-media "$vm" hdc --eject --config --live --force 2>&1)" && {
      _lv_log "Ejected agent ISO from $vm (hdc)"
      continue
    }
    # Already empty is fine; anything else is worth a warning.
    if libvirt_ssh virsh domblklist "$vm" 2>/dev/null | grep -E 'sda|hdc' | grep -q 'ramendr-agent'; then
      _lv_warn "Failed to eject agent ISO from $vm: $out"
      rc=1
    else
      _lv_log "Agent ISO already absent on $vm"
    fi
  done
  return "$rc"
}

# After bootstrap-complete the rendezvous host is still on the live ISO: the
# agent only reboots it once "Waiting for controller" succeeds, and that stage
# often never completes on platform.none (dead apps VIP / stuck COs). Force a
# disk boot once the ISO is ejected — hd,cdrom then lands on /dev/vda.
libvirt_reboot_rendezvous_onto_disk() {
  local cluster="$1"
  local vm ip deadline
  vm="$(libvirt_vm_name "$cluster" 0)"
  ip="$(libvirt_node_ip "$cluster" 0)"

  if libvirt_ssh virsh domblklist "$vm" 2>/dev/null | grep -q ramendr-agent; then
    _lv_log "Ejecting agent ISO from $cluster before rendezvous reboot..."
    libvirt_eject_agent_iso "$cluster" || true
  fi

  _lv_log "Rebooting rendezvous $vm onto disk (ISO ejected; no live bootstrap needed)..."
  # reset: live RHCOS often has no qemu-ga, so virsh reboot may no-op.
  libvirt_ssh virsh reset "$vm"

  # Wait for SSH to drop (reboot started), then come back.
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if ! libvirt_ssh bash -c "timeout 1 bash -c 'echo >/dev/tcp/${ip}/22'" >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  deadline=$((SECONDS + 600))
  while (( SECONDS < deadline )); do
    if libvirt_ssh bash -c "timeout 2 bash -c 'echo >/dev/tcp/${ip}/22'" >/dev/null 2>&1; then
      # Kubelet on the installed system is a strong disk-boot signal; live
      # rendezvous after bootstrap tear-down only had :22.
      if libvirt_ssh bash -c "timeout 2 bash -c 'echo >/dev/tcp/${ip}/10250'" >/dev/null 2>&1; then
        _lv_log "Rendezvous $vm appears on disk boot ($ip :22+:10250)"
        return 0
      fi
    fi
    sleep 5
  done
  _lv_warn "Timed out waiting for $vm disk boot markers; continuing install-complete anyway"
  return 0
}

libvirt_destroy_vm() {
  local vm="$1"
  _lv_log "Destroying VM $vm..."
  libvirt_ssh virsh destroy "$vm" >/dev/null 2>&1 || true
  # Do not use --remove-all-storage: the shared agent ISO is attached as a
  # cdrom disk, and that flag deletes it along with the VM disks.
  libvirt_ssh virsh undefine "$vm" --nvram >/dev/null 2>&1 || \
    libvirt_ssh virsh undefine "$vm" >/dev/null 2>&1 || true
  libvirt_ssh rm -f \
    "$(libvirt_disk_path "$vm" os)" \
    "$(libvirt_disk_path "$vm" osd)" >/dev/null 2>&1 || true
}

libvirt_destroy_owned_vms() {
  local vm
  while IFS= read -r vm; do
    [[ -n "$vm" ]] || continue
    libvirt_destroy_vm "$vm"
  done < <(libvirt_owned_vms)
  local cluster
  for cluster in "${LIBVIRT_CLUSTERS[@]}"; do
    libvirt_ssh rm -f "$(libvirt_iso_path "$cluster")" >/dev/null 2>&1 || true
  done
}

libvirt_destroy_legacy_vms() {
  local vm
  for vm in "${LIBVIRT_LEGACY_VMS[@]}"; do
    libvirt_destroy_vm "$vm"
  done
}
