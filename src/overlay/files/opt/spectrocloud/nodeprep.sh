#!/bin/bash
# Spectro Cloud node preparation for Spectrum-X (AI-RA-Infra)
# Adapted from nodeprep-v102 to support both mutable (MaaS) and immutable (Kairos Edge Appliance) OS.
# Original: https://gist.github.com/kreeuwijk/4bbd2b76586f5f80229ee92aebce3f6c

# Source environment file (profile places it at nodeprep-env.sh on Edge, nodeprep.env on MaaS)
if [ -f /opt/spectrocloud/nodeprep-env.sh ]; then
  source /opt/spectrocloud/nodeprep-env.sh
elif [ -f /opt/spectrocloud/nodeprep.env ]; then
  source /opt/spectrocloud/nodeprep.env
else
  echo "FATAL: No nodeprep environment file found at /opt/spectrocloud/nodeprep-env.sh or /opt/spectrocloud/nodeprep.env"
  exit 1
fi

LOG_FILE="/var/log/sc-nodeprep.log"
exec > >(tee -a ${LOG_FILE}) 2>&1
export KUBECONFIG=/etc/kubernetes/kubelet.conf

declare -A arrBF
total_amount=0

# Detect immutable OS (Kairos/Edge Appliance mode)
# On immutable OS, all packages must be pre-installed via CanvOS Dockerfile.
# apt/dpkg operations are skipped; only hardware operations run at runtime.
IS_IMMUTABLE=false
if [ -d /etc/kairos ]; then
  IS_IMMUTABLE=true
fi

do_log(){
  print_ok() {
    GREEN_COLOR="\033[0;32m"
    DEFAULT="\033[0m"
    echo -e "${GREEN_COLOR}${1:-}${DEFAULT}"
  }
  print_warning() {
    YELLOW_COLOR="\033[33m"
    DEFAULT="\033[0m"
    echo -e "${YELLOW_COLOR}${1:-}${DEFAULT}"
  }
  print_info() {
    BLUE_COLOR="\033[1;34m"
    DEFAULT="\033[0m"
    echo -e "${BLUE_COLOR}${1:-}${DEFAULT}"
  }
  print_fail() {
    RED_COLOR="\033[0;31m"
    DEFAULT="\033[0m"
    echo -e "${RED_COLOR}${1:-}${DEFAULT}"
  }

  type_of_msg=$(echo $*|cut -d" " -f1)
  msg="$(echo $*|cut -d" " -f2-)"
  msg=" [$type_of_msg] `date "+%Y-%m-%d %H:%M:%S %Z"` [$$] $msg "
  case "$type_of_msg" in
    'FATAL') print_fail "$msg" ;;
    'ERROR') print_fail "$msg" ;;
    'WARN') print_warning "$msg" ;;
    'INFO') print_info "$msg" ;;
    'OK') print_ok "$msg" ;;
    *) echo "$msg" ;;
  esac
}

fn_ensure_nodeprep() {
  if systemctl list-units | grep stylus-agent; then
    do_log "INFO Running in Agent/Appliance mode, nodeprep is controlled by Stylus."
  else
    if grep "/opt/spectrocloud/nodeprep.sh" /etc/rc.local &>/dev/null
    then
      do_log "INFO Ensured that nodeprep is called at system startup."
    else
      if $IS_IMMUTABLE; then
        do_log "INFO Immutable OS detected, skipping rc.local configuration (managed by Stylus/cloud-init)."
      else
        do_log "INFO Nodeprep is not yet being called at system startup, configuring..."
        echo '#!/bin/bash' > /etc/rc.local
        echo '/opt/spectrocloud/nodeprep.sh' >> /etc/rc.local
        chmod +x /etc/rc.local
        do_log "OK Ensured that nodeprep is called at system startup."
      fi
    fi
  fi
}

fn_ensure_state() {
  do_log "INFO Checking node state..."
  until [ "$(kubectl get node $(hostname) -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == "True" ]; do
    do_log "INFO Node not yet reporting ready state, will retry in 5s"
    sleep 5
  done
  TEST=$(kubectl get node $(hostname) -o jsonpath="{.metadata.labels.spectrocloud\.com/nodeprep}")
  if [ "$TEST" == "" ]
  then
    do_log "INFO Node state not present, setting new node state..."
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nodeprep=init"
  else
    do_log "OK Node state found, parsing state..."
  fi
  STATE=$(kubectl get node $(hostname) -o jsonpath="{.metadata.labels.spectrocloud\.com/nodeprep}")
  do_log "INFO Nodeprep state is: $STATE"
  if ! systemctl list-units | grep stylus-agent && [ -f /etc/kubernetes/admin.conf ] && [ $STATE == "init" ]; then
    do_log "INFO This is a CAPI node, performing additional verification..."
    if [ $(kubectl get node --kubeconfig /etc/kubernetes/admin.conf --no-headers | wc -l) -eq 1 ]; then
      do_log "INFO This is a fresh control plane node, ensuring cert-manager is installed..."
      kubectl taint nodes $(hostname) spectrocloud.com/nodeprep- --kubeconfig /etc/kubernetes/admin.conf
      while [ $(kubectl get secret -n cert-manager -l owner=helm,name=cert-manager,status=deployed --kubeconfig /etc/kubernetes/admin.conf | wc -l) -eq 0 ]; do
        do_log "INFO Cert-manager not yet deployed, waiting for 3 seconds..."
        sleep 3
      done
      kubectl taint nodes $(hostname) spectrocloud.com/nodeprep:NoSchedule --kubeconfig /etc/kubernetes/admin.conf
    fi
    if kubectl get node $(hostname) -o jsonpath='{.spec.taints}' --kubeconfig /etc/kubernetes/admin.conf | grep "spectrocloud.com/nodeprep"; then
      do_log "INFO This is a control plane node, untainting node and waiting for $CP_DELAY seconds before performing node prep actions..."
      kubectl taint nodes $(hostname) spectrocloud.com/nodeprep- --kubeconfig /etc/kubernetes/admin.conf
      sleep $CP_DELAY
      do_log "INFO Wait over, retainting node"
      kubectl taint nodes $(hostname) spectrocloud.com/nodeprep:NoSchedule --kubeconfig /etc/kubernetes/admin.conf
    fi
    do_log "INFO CAPI node state verified"
  fi
}

fn_update_state() {
  local next_state=$1
  local next_step=$2
  do_log "INFO Setting next stage to $next_state..."
  kubectl label node $(hostname) --overwrite "spectrocloud.com/nodeprep=$next_state"
  if [ "$next_step" == "reboot" ]
  then
    do_log "INFO Reboot requested, scheduling node reboot in 1 minute"
    shutdown -r +1
  fi
}

fn_process_result() {
  if [ $1 -eq 0 ]; then
    do_log "OK Succeeded: $2"
  else
    do_log "FATAL Failed: $2"
    exit 1
  fi
}

fn_inventory_hw() {
  local n=0
  for pci in $(mst status -v | grep -i -E "(bluefield|connectx)" | awk '{print $3}' | grep "\.0"); do
    ((n++))
    arrBF[$n,0]="$pci"
    arrBF[$n,1]="${pci/\.*/}"
    arrBF[$n,2]="0000:${arrBF[$n,0]}"
    arrBF[$n,3]="0000:${arrBF[$n,1]}"

    local DESCR=$(mlxconfig -d "${arrBF[$n,2]}" q INTERNAL_CPU_OFFLOAD_ENGINE | grep "Description:")
    local DEVTYPE=$(mlxconfig -d "${arrBF[$n,2]}" q INTERNAL_CPU_OFFLOAD_ENGINE | grep "Device type:")
    if [ $(echo $DESCR | awk '{print $2}') == "N/A" ]; then local DESCR=$DEVTYPE; fi
    if echo "$DESCR" | grep "SuperNIC" >/dev/null; then
      arrBF[$n,4]="SuperNIC"
    elif echo "$DESCR" | grep "DPU" >/dev/null; then
      arrBF[$n,4]="DPU"
    elif echo "$DESCR" | grep "ConnectX" >/dev/null; then
      arrBF[$n,4]="ConnectX"
    else
      arrBF[$n,4]="Unknown"
    fi

    for dir in $(find /dev -type d -name "rshim*"); do
      local RSHIMPCI=$(cat $dir/misc | grep DEV_NAME | awk '{print $2}' | awk -F "." '{print $1}')
      if [ "$RSHIMPCI" == "pcie-${arrBF[$n,3]}" ]; then
        arrBF[$n,5]="$dir"
      fi
    done

    arrBF[$n,6]=$(ls "/sys/bus/pci/devices/${arrBF[$n,2]}/net/")
    arrBF[$n,7]=$(flint -d "${arrBF[$n,2]}" q | grep "FW Version:" | awk '{print $3}')
    arrBF[$n,8]="$(cat /sys/bus/pci/devices/${arrBF[$n,2]}/current_link_width)x"
    arrBF[$n,9]="$(cat /sys/bus/pci/devices/${arrBF[$n,2]}/max_link_speed | awk '{print $1}')GTs"

    do_log "INFO Detected NIC ${arrBF[$n,6]} on PCI address: ${arrBF[$n,0]} of type ${arrBF[$n,4]} with firmware ${arrBF[$n,7]}"
  done
  total_amount=$n
  do_log "INFO Adding NIC firmware info for ${arrBF[$n,6]} to node labels..."
  for i in $(seq 1 $total_amount); do
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nic-$i-type=${arrBF[$i,4]}" > /dev/null
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nic-$i-fw=${arrBF[$i,7]}" > /dev/null
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nic-$i-addr=${arrBF[$i,1]/:/\.}" > /dev/null
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nic-$i-name=${arrBF[$i,6]}" > /dev/null
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nic-$i-linkwidth=${arrBF[$i,8]}" > /dev/null
    kubectl label node $(hostname) --overwrite "spectrocloud.com/nic-$i-linkspeed=${arrBF[$i,9]}" > /dev/null
  done
  gpu_n=0
  lspci -D | grep -E "3D controller: NVIDIA" | while read device; do
    ((gpu_n++))
    bus=$(echo $device | awk '{print $1}')
    sysfs_path="/sys/bus/pci/devices/$bus"
    if [ -f "$sysfs_path/max_link_speed" ]; then
      gpu_name=$(echo $device | sed 's/.*: //' | sed 's/ (rev.*//')
      speed="$(cat $sysfs_path/max_link_speed | awk '{print $1}')GTs"
      width="$(cat $sysfs_path/current_link_width)x"
      do_log "INFO Detected GPU $gpu_n ($gpu_name) on $width PCI link width and max link speed of $speed"
      do_log "INFO Adding PCIe link info for GPU $gpu_n to to node labels..."
      kubectl label node $(hostname) --overwrite "spectrocloud.com/gpu-${gpu_n}-linkspeed=${speed}" > /dev/null
      kubectl label node $(hostname) --overwrite "spectrocloud.com/gpu-${gpu_n}-linkwidth=${width}" > /dev/null
    fi
  done
}

fn_init_sw_stage() {
  do_log "INFO Init stage: Install prereqs, flash BFB..."

  if $IS_IMMUTABLE; then
    do_log "INFO Immutable OS detected, skipping package installation and download steps."
    do_log "INFO Verifying pre-installed packages..."

    # Verify critical packages are pre-installed
    if which gcc-12 &>/dev/null; then
      do_log "OK GCC-12 is pre-installed"
    else
      do_log "WARN GCC-12 is not pre-installed (may be needed for DOCA DKMS modules)"
    fi

    if dpkg -s doca-all &>/dev/null; then
      do_log "OK DOCA host package is pre-installed"
    else
      do_log "WARN DOCA host package is not pre-installed"
    fi

    if [ -f /opt/spectrocloud/spcx/bfb/$BFB ]; then
      do_log "OK BFB firmware $BFB is pre-staged"
    else
      do_log "WARN BFB firmware $BFB is not pre-staged at /opt/spectrocloud/spcx/bfb/$BFB"
    fi

    # LLDP config is pre-staged via overlay, just enable the service
    do_log "INFO Enable LLDP service"
    systemctl enable lldpd 2>/dev/null || do_log "WARN Could not enable lldpd service"

    # ib_core.conf is pre-staged via overlay, no runtime action needed

    # On immutable OS, GRUB/IOMMU config must be handled via Kairos cloud-init bootargs, not sed
    if [ $NUMVF_EW -gt 0 ] || [ $NUMVF_NS -gt 0 ]; then
      do_log "INFO VFs requested. On immutable OS, ensure IOMMU is configured via Kairos bootargs (cloud-init)."
    fi

  else
    # === Mutable OS path (original MaaS behavior) ===

    if ! [[ -d /bfb && -d /scripts ]]; then
      do_log "INFO Create /opt/spectrocloud/spcx/bfb directory"
      mkdir -p /opt/spectrocloud/spcx/bfb
      fn_process_result $? "Create /opt/spectrocloud/spcx/bfb directory"
    else
      do_log "OK Directory /opt/spectrocloud/spcx/bfb is present"
    fi

    if ! [ -f /opt/spectrocloud/spcx/bfb/$BFB ]; then
      do_log "INFO Download $MAAS/rcp/firmware/bfb/$BFB to /opt/spectrocloud/spcx/bfb/"
      wget --retry-on-host-error --no-verbose -t 5 "$MAAS/rcp/firmware/bfb/$BFB" -O /opt/spectrocloud/spcx/bfb/$BFB.tmp && mv /opt/spectrocloud/spcx/bfb/$BFB.tmp /opt/spectrocloud/spcx/bfb/$BFB
      fn_process_result $? "Download $MAAS/rcp/firmware/bfb/$BFB to /opt/spectrocloud/spcx/bfb/"
    else
      do_log "OK /opt/spectrocloud/spcx/bfb/$BFB is present"
    fi

    if ! [ -f /opt/spectrocloud/spcx/$DOCA_DEB ]; then
      do_log "INFO Retrieve DOCA repo package from $MAAS/rcp/$DOCA_DEB"
      wget --retry-on-host-error --no-verbose -t 5 "$MAAS/rcp/$DOCA_DEB" -O /opt/spectrocloud/spcx/$DOCA_DEB.tmp && mv /opt/spectrocloud/spcx/$DOCA_DEB.tmp /opt/spectrocloud/spcx/$DOCA_DEB
      fn_process_result $? "Retrieve DOCA repo package from $MAAS/rcp/$DOCA_DEB"
    else
      do_log "OK /opt/spectrocloud/spcx/$DOCA_DEB is present"
    fi

    if $APT_UPDATE; then
      do_log "INFO Updating packages to latest..."
      apt-get update; NEEDRESTART_MODE=l apt-get upgrade -qq
    fi

    if ! [ "$(dpkg -s linux-headers-$(uname -r) | grep -e "^Status: " | awk -F ": " '{print $2}')" == "install ok installed" ]; then
      do_log "INFO Linux headers package for current kernel is missing, installing it now"
      NEEDRESTART_MODE=l apt-get install -qq linux-headers-$(uname -r)
      fn_process_result $? "Install Linux headers package for current kernel"
      apt-mark hold linux-headers-$(uname -r)
      fn_process_result $? "Marked Linux headers package for current kernel as held"
    else
      do_log "OK Linux headers package for current kernel is present"
    fi

    if ! which gcc-12; then
      do_log "INFO GCC-12 not present on the system and needed for DOCA, installing GCC-12"
      NEEDRESTART_MODE=l apt install -y gcc-12 libgcc-12-dev
      fn_process_result $? "Install GCC-12"
    else
      do_log "OK GCC-12 is installed"
    fi

    if ! [ "$(dpkg -s doca-host | grep -e "^Status: " | awk -F ": " '{print $2}')" == "install ok installed" ]; then
      do_log "INFO Install DOCA repo package from /opt/spectrocloud/spcx/$DOCA_DEB"
      dpkg -i /opt/spectrocloud/spcx/$DOCA_DEB
      fn_process_result $? "Install DOCA repo package from /opt/spectrocloud/spcx/$DOCA_DEB"
      apt-get -qq update
      fn_process_result $? "Update APT after install DOCA repo package"
    else
      do_log "OK DOCA repo package is installed"
    fi

    if ! [ "$(dpkg -s doca-all | grep -e "^Status: " | awk -F ": " '{print $2}')" == "install ok installed" ]; then
      do_log "INFO Install DOCA host software"
      NEEDRESTART_MODE=l apt-get -qq install doca-all lldpd mft netplan.io pv psmisc
      fn_process_result $? "Install DOCA host software"
      do_log "INFO Host reboot is needed after installing DOCA, rebooting now..."
      fn_update_state inithw reboot
      exit 0
    else
      do_log "OK DOCA host package is installed"
      do_log "INFO Ensuring additional packages are installed"
      NEEDRESTART_MODE=l apt-get -qq install lldpd mft netplan.io pv psmisc
      fn_process_result $? "Ensure additional packages"
    fi

    do_log "INFO Configure LLDP"
    mkdir -p /etc/lldpd.d
    echo "configure system hostname ." > /etc/lldpd.d/rcp-lldpd.conf
    echo "configure lldp portidsubtype iframe" >> /etc/lldpd.d/rcp-lldpd.conf
    chmod 644 /etc/lldpd.d/rcp-lldpd.conf
    systemctl enable lldpd
    fn_process_result $? "Configure LLDP"

    if [ $NUMVF_EW -gt 0 ] || [ $NUMVF_NS -gt 0 ]; then
      local UPDATE_GRUB=false
      do_log "INFO VFs requested, ensuring that SRIOV is enabled on next boot..."
      # Check if CPU is Intel or AMD, set correct IOMMU parameter for each
      if lscpu | grep "Model name" | grep -i intel > /dev/null; then
        if ! cat /etc/default/grub | grep GRUB_CMDLINE_LINUX_DEFAULT | grep intel_iommu=on > /dev/null; then
          do_log "INFO Adding intel_iommu=on to GRUB config..."
          sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&intel_iommu=on /' /etc/default/grub
          UPDATE_GRUB=true
        else
          do_log "INFO intel_iommu=on is present in GRUB config"
        fi
      elif lscpu | grep "Model name" | grep -i amd > /dev/null; then
        if ! cat /etc/default/grub | grep GRUB_CMDLINE_LINUX_DEFAULT | grep amd_iommu=on > /dev/null; then
          do_log "INFO Adding amd_iommu=on to GRUB config..."
          sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&amd_iommu=on /' /etc/default/grub
          UPDATE_GRUB=true
        else
          do_log "INFO amd_iommu=on is present in GRUB config"
        fi
      fi
      # Set IOMMU Passthrough for SRIOV
      if ! cat /etc/default/grub | grep GRUB_CMDLINE_LINUX_DEFAULT | grep iommu=pt > /dev/null; then
        do_log "INFO Adding iommu=pt to GRUB config..."
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&iommu=pt /' /etc/default/grub
        UPDATE_GRUB=true
      else
        do_log "INFO iommu=pt is present in GRUB config"
      fi

      # Enable RDMA namespace awareness for proper SR-IOV isolation
      echo "options ib_core netns_mode=0" > /etc/modprobe.d/ib_core.conf
      do_log "INFO Configured 'options ib_core netns_mode=0' in /etc/modprobe.d/ib_core.conf"

      # Run update-grub if the content of /etc/default/grub changed
      if $UPDATE_GRUB; then
        do_log "INFO GRUB config changed, running update-grub..."
        update-grub
      fi
    fi

    if $APT_UPDATE; then
      do_log "INFO Running APT package cleanup..."
      apt-get autoremove -qq
    fi
  fi

  # These steps run on both mutable and immutable OS
  do_log "INFO Enable and restart rshim"
  systemctl daemon-reload && systemctl enable rshim && systemctl restart rshim
  fn_process_result $? "Enable and restart rshim"
  do_log "INFO Sleeping for 10 seconds to allow rshim to initialize..."
  sleep 10

  do_log "INFO Verify rshim is running"
  systemctl status rshim | grep "Active: active (running)"
  fn_process_result $? "Verify rshim is running"
}

fn_init_hw_stage() {
  do_log "INFO Flash BFB to Bluefield-3 adapters"
  for i in $(seq 1 $total_amount); do
    if [ "${arrBF[$i,4]}" == "SuperNIC" ]; then
      if [ "${arrBF[$i,7]}" == "$BFB_FW" ]; then
        do_log "OK Bluefield-3 firmware already matches expectd version $BFB_FW, skipping flash."
      else
        do_log "INFO Flashing Bluefield-3 firmware to ${arrBF[$i,2]}..."
        rshim_addr="${arrBF[$i,5]/\/dev\//}"
        bfb-install --rshim $rshim_addr --bfb /opt/spectrocloud/spcx/bfb/$BFB --verbose
        fn_process_result $? "Flash BFB to Bluefield-3 adapter ${arrBF[$i,2]} on $rshim_addr"
          NEEDREBOOT=true
      fi
    elif [ "${arrBF[$i,4]}" == "DPU" ]; then
      if $CONTROLDPU; then
        if [ "${arrBF[$i,7]}" == "$BFB_FW" ]; then
          do_log "OK Bluefield-3 firmware already matches expectd version $BFB_FW, skipping flash."
        else
          do_log "INFO Flashing Bluefield-3 firmware to ${arrBF[$i,2]}..."
          rshim_addr="${arrBF[$i,5]/\/dev\//}"
          bfb-install --rshim $rshim_addr --bfb /opt/spectrocloud/spcx/bfb/$BFB --verbose
          fn_process_result $? "Flash BFB to Bluefield-3 adapter ${arrBF[$i,2]} on $rshim_addr"
          NEEDREBOOT=true
        fi
      else
        do_log "INFO Control of DPUs is not allowed by policy, skipping DPU ${arrBF[$i,2]}"
      fi
    elif [ "${arrBF[$i,4]}" == "ConnectX" ]; then
      do_log "INFO Firmware flashing of ConnectX adapters is not implemented, skipping ConnectX NIC ${arrBF[$i,2]}"
    fi
  done
}

fn_config_stage(){
  do_log "INFO Configure network adapter firmware"
  if [ $NUMVF_EW -gt 1 ]; then CNX_NUM_OF_VFS=$NUMVF_EW; else CNX_NUM_OF_VFS=1; fi
  if [ $NUMVF_NS -gt 1 ]; then DPU_NUM_OF_VFS=$NUMVF_NS; else DPU_NUM_OF_VFS=1; fi
  for i in $(seq 1 $total_amount); do
    if [ "${arrBF[$i,4]}" == "SuperNIC" ]; then
      /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y reset
      if /usr/bin/mlxconfig -d "${arrBF[$i,2]}" q LINK_TYPE_P2 >/dev/null; then
        /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y set \
          LINK_TYPE_P1=$LINKTYPE_EW LINK_TYPE_P2=$LINKTYPE_EW \
          ROCE_RTT_RESP_DSCP_P1=48 ROCE_RTT_RESP_DSCP_MODE_P1=1 \
          ROCE_RTT_RESP_DSCP_P2=48 ROCE_RTT_RESP_DSCP_MODE_P2=1 \
          ROCE_ADAPTIVE_ROUTING_EN=$ROCECC USER_PROGRAMMABLE_CC=$ROCECC \
          TX_SCHEDULER_LOCALITY_MODE=2 ROCE_CC_STEERING_EXT=2 MULTIPATH_DSCP=0 \
          ADVANCED_PCI_SETTINGS=1 SRIOV_EN=1 NUM_OF_VFS=$CNX_NUM_OF_VFS
      else
        /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y set \
          LINK_TYPE_P1=$LINKTYPE_EW \
          ROCE_RTT_RESP_DSCP_P1=48 ROCE_RTT_RESP_DSCP_MODE_P1=1 \
          ROCE_ADAPTIVE_ROUTING_EN=$ROCECC USER_PROGRAMMABLE_CC=$ROCECC \
          TX_SCHEDULER_LOCALITY_MODE=2 ROCE_CC_STEERING_EXT=2 MULTIPATH_DSCP=0 \
          ADVANCED_PCI_SETTINGS=1 SRIOV_EN=1 NUM_OF_VFS=$CNX_NUM_OF_VFS
      fi
      fn_process_result $? "Configure Bluefield-3 adapter firmware for ${arrBF[$i,0]}"
    elif [ "${arrBF[$i,4]}" == "ConnectX" ]; then
      /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y reset
      if /usr/bin/mlxconfig -d "${arrBF[$i,2]}" q LINK_TYPE_P2 >/dev/null; then
        /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y set \
          LINK_TYPE_P1=$LINKTYPE_EW LINK_TYPE_P2=$LINKTYPE_EW \
          ROCE_RTT_RESP_DSCP_P1=48 ROCE_RTT_RESP_DSCP_MODE_P1=1 \
          ROCE_RTT_RESP_DSCP_P2=48 ROCE_RTT_RESP_DSCP_MODE_P2=1 \
          ROCE_ADAPTIVE_ROUTING_EN=$ROCECC USER_PROGRAMMABLE_CC=$ROCECC \
          TX_SCHEDULER_LOCALITY_MODE=2 ROCE_CC_STEERING_EXT=2 \
          ADVANCED_PCI_SETTINGS=1 SRIOV_EN=1 NUM_OF_VFS=$CNX_NUM_OF_VFS
      else
        /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y set \
          LINK_TYPE_P1=$LINKTYPE_EW \
          ROCE_RTT_RESP_DSCP_P1=48 ROCE_RTT_RESP_DSCP_MODE_P1=1 \
          ROCE_ADAPTIVE_ROUTING_EN=$ROCECC USER_PROGRAMMABLE_CC=$ROCECC \
          TX_SCHEDULER_LOCALITY_MODE=2 ROCE_CC_STEERING_EXT=2 \
          ADVANCED_PCI_SETTINGS=1 SRIOV_EN=1 NUM_OF_VFS=$CNX_NUM_OF_VFS
      fi
      fn_process_result $? "Configure ConnectX adapter firmware for ${arrBF[$i,0]}"
    elif [ "${arrBF[$i,4]}" == "DPU" ]; then
      if $CONTROLDPU; then
        /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y reset
        if /usr/bin/mlxconfig -d "${arrBF[$i,2]}" q LINK_TYPE_P2 >/dev/null; then
          /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y set \
            LINK_TYPE_P1=$LINKTYPE_NS LINK_TYPE_P2=$LINKTYPE_NS \
            ROCE_RTT_RESP_DSCP_P1=48 ROCE_RTT_RESP_DSCP_MODE_P1=1 \
            ROCE_RTT_RESP_DSCP_P2=48 ROCE_RTT_RESP_DSCP_MODE_P2=1 \
            ROCE_ADAPTIVE_ROUTING_EN=$ROCECC USER_PROGRAMMABLE_CC=$ROCECC \
            TX_SCHEDULER_LOCALITY_MODE=2 ROCE_CC_STEERING_EXT=2 \
            ADVANCED_PCI_SETTINGS=1 SRIOV_EN=1 NUM_OF_VFS=$DPU_NUM_OF_VFS \
            INTERNAL_CPU_OFFLOAD_ENGINE=$DPUOFFLOAD
        else
          /usr/bin/mlxconfig -d "${arrBF[$i,2]}" -y set \
            LINK_TYPE_P1=$LINKTYPE_NS \
            ROCE_RTT_RESP_DSCP_P1=48 ROCE_RTT_RESP_DSCP_MODE_P1=1 \
            ROCE_ADAPTIVE_ROUTING_EN=$ROCECC USER_PROGRAMMABLE_CC=$ROCECC \
            TX_SCHEDULER_LOCALITY_MODE=2 ROCE_CC_STEERING_EXT=2 \
            ADVANCED_PCI_SETTINGS=1 SRIOV_EN=1 NUM_OF_VFS=$DPU_NUM_OF_VFS \
            INTERNAL_CPU_OFFLOAD_ENGINE=$DPUOFFLOAD
        fi
        fn_process_result $? "Configure Bluefield-3 adapter firmware for ${arrBF[$i,0]}"
      else
        do_log "INFO Control of DPUs is not allowed by policy, skipping DPU ${arrBF[$i,2]}"
      fi
    fi
  done
}

fn_disable_acs(){
  do_log "INFO Disable ACS on all PCIe switches"
  for BDF in `lspci -d "*:*:*" | awk '{print $1}'`; do
    setpci -v -s ${BDF} ECAP_ACS+0x6.w > /dev/null 2>&1
    if [ $? -ne 0 ]; then
      do_log "INFO ${BDF} does not support ACS, skipping"
      continue
    fi
    do_log "OK Disabling ACS on ${BDF}"
    setpci -v -s ${BDF} ECAP_ACS+0x6.w=0000
    if [ $? -ne 0 ]; then
      do_log "ERROR ${BDF} Error disabling ACS on ${BDF}"
      continue
    fi
    local NEW_VAL=`setpci -v -s ${BDF} ECAP_ACS+0x6.w | awk '{print $NF}'`
    if [ "${NEW_VAL}" != "0000" ]; then
      do_log "ERROR Failed to disable ACS on ${BDF}"
      continue
    fi
  done
}

fn_set_vfs(){
  if [ $NUMVF_EW -gt 0 ] || [ $NUMVF_NS -gt 0 ]; then
    do_log "INFO Create VFs on network adapters"

    # Cordon node during procedure
    do_log "INFO Cordoning node for VF configuration..."
    kubectl cordon $(hostname)

    for i in $(seq 1 $total_amount); do
      if [ "${arrBF[$i,4]}" == "SuperNIC" ] || [ "${arrBF[$i,4]}" == "ConnectX" ] || [ "${arrBF[$i,4]}" == "DPU" ]; then
        local netif="${arrBF[$i,6]}"

        if ! [ "$(ip -br link show dev $netif | awk '{print $2}')" == "UP" ]; then
          do_log "INFO Interface $netif is not in UP state, setting link to UP..."
          ip link set $netif up
          fn_process_result $? "Set interface $netif to UP state"
        fi

        if ([ "${arrBF[$i,4]}" == "SuperNIC" ] || [ "${arrBF[$i,4]}" == "ConnectX" ]) && [ $NUMVF_EW -gt 0 ]; then
          do_log "INFO Setting sriov_numvfs to $NUMVF_EW for ${arrBF[$i,4]} $netif"
          echo "$NUMVF_EW" > "/sys/class/net/$netif/device/sriov_numvfs"
          fn_process_result $? "Create $NUMVF_EW VFs for ${arrBF[$i,4]} $netif"
        elif [ "${arrBF[$i,4]}" == "DPU" ] && [ $NUMVF_NS -gt 0 ]; then
          do_log "INFO Setting sriov_numvfs to $NUMVF_NS for DPU $netif"
          echo "$NUMVF_NS" > "/sys/class/net/$netif/device/sriov_numvfs"
          fn_process_result $? "Create $NUMVF_NS VFs for DPU $netif"
        fi

        # Wait for VFs to be created
        sleep 2

        if ([ "${arrBF[$i,4]}" == "SuperNIC" ] || [ "${arrBF[$i,4]}" == "ConnectX" ]) ; then
          if [ "$LINKTYPE_EW" == "1" ]; then
            LINKTYPE="IB"
          else
            LINKTYPE="ETH"
          fi
          LINKVFS=$NUMVF_EW
        elif [ "${arrBF[$i,4]}" == "DPU" ] ; then
          if [ "$LINKTYPE_NS" == "1" ]; then
            LINKTYPE="IB"
          else
            LINKTYPE="ETH"
          fi
          LINKVFS=$NUMVF_NS
        fi

        if [ $LINKVFS -gt 0 ]; then
          # VFs requested, we need to do additional port configuration...
          do_log "INFO VFs requested, proceding to configure VF GUIDs..."

          # Find InfiniBand device name
          local ib_dev=""
          if [ -d "/sys/class/net/$netif/device/infiniband" ]; then
            ib_dev=$(ls "/sys/class/net/$netif/device/infiniband" | head -n1)
            do_log "INFO InfiniBand device for $netif is $ib_dev"
          else
            do_log "ERROR Could not find InfiniBand device for $netif"
            continue
          fi

          local nic_guid_src=$(cat /sys/class/net/$netif/device/infiniband/$ib_dev/node_guid)
          local nic_guid_raw=${nic_guid_src//:/}

          # Configure GUIDs for each VF
          for vf in $(seq 0 $((LINKVFS - 1))); do
            local vf_hex=$(printf "%02x" $vf)
            local node_guid=$(echo "${nic_guid_raw:0:7}f1${vf_hex}${nic_guid_raw:11:16}" | sed 's/../&:/g; s/:$//')
            local port_guid=$(echo "${nic_guid_raw:0:7}f2${vf_hex}${nic_guid_raw:11:16}" | sed 's/../&:/g; s/:$//')
            local mac_addr=$(echo "f2${vf_hex}${nic_guid_raw:8:8}" | sed 's/../&:/g; s/:$//')
            local sriov_path="/sys/class/infiniband/$ib_dev/device/sriov/$vf"

            if [ ! -d "$sriov_path" ]; then
              do_log "ERROR sriov path $sriov_path does not exist for VF $vf"
              continue
            fi

            # Set Node GUID
            do_log "INFO Setting Node GUID for $ib_dev VF $vf to $node_guid"
            echo "$node_guid" > "$sriov_path/node"
            if [ $? -eq 0 ]; then
              do_log "OK Node GUID set successfully"
            else
              do_log "ERROR Failed to set Node GUID for VF $vf"
              continue
            fi

            # Set Port GUID or MAC address, depending on linktype
            if [ "$LINKTYPE" == "IB" ]; then
              do_log "INFO Setting Port GUID for $ib_dev VF $vf to $port_guid"
              echo "$port_guid" > "$sriov_path/port"
              if [ $? -eq 0 ]; then
                do_log "OK Port GUID set successfully"
              else
                do_log "ERROR Failed to set Port GUID for VF $vf"
                continue
              fi
            else
              do_log "INFO Setting MAC address for $ib_dev VF $vf to $mac_addr"
              echo "$mac_addr" > "$sriov_path/mac"
              if [ $? -eq 0 ]; then
                do_log "OK MAC address set successfully"
              else
                do_log "ERROR Failed to set MAC address for VF $vf"
                continue
              fi
            fi

            # Set policy to Follow (mirror physical port state) for IB devices
            if [ "$LINKTYPE" == "IB" ]; then
              do_log "INFO Setting policy to Follow for $ib_dev VF $vf"
              echo "Follow" > "$sriov_path/policy"
              if [ $? -eq 0 ]; then
                do_log "OK Policy set to Follow"
              else
                do_log "WARN Failed to set policy for VF $vf (non-critical)"
              fi
            fi

            # Unbind and rebind VF to make GUID changes active
            do_log "INFO Unbinding and rebinding VF $vf on $ib_dev to activate new GUIDs"
            local VF_PCI_ADDR=$(cat /sys/class/infiniband/$ib_dev/device/virtfn$vf/uevent | grep PCI_SLOT_NAME | awk -F '=' '{print $2}')
            echo "$VF_PCI_ADDR" > /sys/bus/pci/drivers/mlx5_core/unbind
            echo "$VF_PCI_ADDR" > /sys/bus/pci/drivers/mlx5_core/bind

            # Verify GUIDs were set
            local set_node_guid=$(cat "$sriov_path/node" 2>/dev/null)
            if [ "$LINKTYPE" == "IB" ]; then
              local set_port_guid=$(cat "$sriov_path/port" 2>/dev/null)
              do_log "INFO VF $vf verification - Node: $set_node_guid, Port: $set_port_guid"
            else
              local set_mac_addr=$(cat "$sriov_path/mac" 2>/dev/null)
              do_log "INFO VF $vf verification - Node: $set_node_guid, Mac: $set_mac_addr"
            fi
          done
          do_log "OK Configured GUIDs for $LINKVFS VFs on $netif ($ib_dev)"
        fi
      fi
    done

    # Restart SRIOV Device Plugin to ensure VFs get inventoried correctly and uncordon node
    do_log "INFO Restarting SRIOV Device Plugin to ensure VFs get inventoried correctly..."
    kubectl delete pod -n nvidia-network-operator --field-selector="spec.nodeName=$(hostname)" -l 'app=sriov-device-plugin'
    do_log "INFO Uncordoning node..."
    kubectl uncordon $(hostname)
  fi
}

fn_setup_nfsrdma(){
  if [ "$NFSORDMA_ENABLED" != "true" ]; then
    do_log "INFO NFSoRDMA not enabled, skipping..."
    return
  fi

  if $IS_IMMUTABLE; then
    do_log "INFO Immutable OS: skipping nfs-common and mlnx-nfsrdma-dkms installation (must be pre-installed)"
    if ! dpkg -s nfs-common &>/dev/null; then
      do_log "WARN nfs-common is not pre-installed"
    fi
    if ! dpkg -s mlnx-nfsrdma-dkms &>/dev/null; then
      do_log "WARN mlnx-nfsrdma-dkms is not pre-installed"
    fi
  else
    do_log "INFO Installing nfs-common package"
    apt install -y nfs-common

    # Install OFED-compatible NFSoRDMA DKMS package
    if ! dpkg -s mlnx-nfsrdma-dkms &>/dev/null; then
      do_log "INFO Installing mlnx-nfsrdma-dkms..."
      NEEDRESTART_MODE=l apt-get install -y mlnx-nfsrdma-dkms
      fn_process_result $? "Install mlnx-nfsrdma-dkms"
    else
      do_log "OK mlnx-nfsrdma-dkms is already installed"
    fi
  fi

  # These steps run on both mutable and immutable OS
  do_log "INFO Configuring NFSoRDMA kernel module support..."

  # Load NFSoRDMA kernel modules
  do_log "INFO Loading NFSoRDMA kernel modules..."
  modprobe rpcrdma 2>/dev/null || true
  modprobe xprtrdma 2>/dev/null || true
  modprobe svcrdma 2>/dev/null || true

  if lsmod | grep -q rpcrdma; then
    do_log "OK rpcrdma module loaded"
  else
    do_log "WARN rpcrdma module not loaded - may need reboot"
  fi

  # Module auto-load config (pre-staged via overlay on immutable OS, written here on mutable)
  if ! $IS_IMMUTABLE; then
    do_log "INFO Configuring NFSoRDMA module auto-load"
    echo "rpcrdma" > /etc/modules-load.d/nfsrdma.conf
    echo "xprtrdma" >> /etc/modules-load.d/nfsrdma.conf
    echo "svcrdma" >> /etc/modules-load.d/nfsrdma.conf
  fi

  do_log "OK NFSoRDMA configuration complete"
}

do_log "OK Spectro Cloud node preparation for Spectrum-X"
fn_ensure_nodeprep
fn_ensure_state

case "$STATE" in
  "inithw")
    ;&
  "init")
    NEEDREBOOT=false
    fn_init_sw_stage
    fn_inventory_hw
    fn_init_hw_stage
    if $NEEDREBOOT; then
      fn_update_state config reboot
    else
      fn_update_state config
      fn_config_stage
      fn_update_state precomplete reboot
    fi ;;

  "config")
    do_log "INFO Config stage: set NIC configs with mlxconfig..."
    fn_inventory_hw
    fn_config_stage
    fn_update_state precomplete reboot ;;

  "precomplete")
    ;&
  "complete")
    do_log "INFO Complete stage: inventory HW and set VFs if requested..."
    if $DISABLE_ACS; then fn_disable_acs; fi
    fn_inventory_hw
    fn_set_vfs
    fn_setup_nfsrdma
    # Temporary workaround for GDS bug in GPU Operator 25.10
    mkdir -p /run/mellanox/drivers
    touch /run/mellanox/drivers/.driver-ready
    # End workaround
    if [ -f /etc/kubernetes/admin.conf ]; then
      # This is a control plane node, it can untaint itself
      kubectl taint nodes $(hostname) spectrocloud.com/nodeprep- --kubeconfig /etc/kubernetes/admin.conf
    fi
    fn_update_state complete
    do_log "OK Nodeprep complete." ;;

  *)
    do_log "ERROR Unknown state: $STATE, aborting..." ;;
esac
