Marty  [11:50 AM]
might make sense to figure out my jira task load before the handover. if possible. also i havent really worked on the paletteai side, so this feel like this might be a little choppy on my end
Kevin Reeuwijk  [12:03 PM]
Yes I would expect the content that Venkat cares about most to shift a bit to the PaletteAI side. However as you in this backlog, there is also plenty of infra work to do. A huge item is supporting the AI-RA-Infra profile for Edge Appliance mode, which isn’t even in here. Personally I think that would be a really good one for you to sink your teeth into.
25698 Marty  [12:05 PM]
cool if you wouldnt mind noting that in your handoff to venkat that would be helpful
Kevin Reeuwijk  [12:05 PM]
Buiding an image and ISO for Edge Appliance Mode happens with https://github.com/spectrocloud/CanvOS and the docs are https://docs.spectrocloud.com/clusters/edge/. Note that the Trusted Boot scenario will not be usable, as that’s based on UKI images and those will be way too large when DOCA is installed in them. So we can only do the regular Grub-based immutable image. (edited) 
Marty  [12:05 PM]
i can start looking into it
Kevin Reeuwijk  [12:06 PM]
OK I added a ticket SAT-65 with your name on it
Marty  [12:07 PM]
thanks appreciate it
[12:07 PM]oh yea i remember this a bit
Kevin Reeuwijk  [12:07 PM]
This is the flow to follow https://docs.spectrocloud.com/clusters/edge/edgeforge-workflow/
Marty  [12:07 PM]
i was looking at this at the very beginngin
Kevin Reeuwijk  [12:08 PM]
You can adjust the Dockerfile in there to add extra stuff like the DOCA packages etc. Essentially everything that happens during nodeprep that wouldn’t work on an immutable OS (such as installing packages), will need to be done in the CanvOS Dockerfile instead.
[12:09 PM]Ideally, the hostprep script will then just find all the software preinstalled and run as normal, skipping the install steps.
Marty  [12:09 PM]
yea that make sense, prima facie
Kevin Reeuwijk  [12:15 PM]
You also need to be aware that only certain paths on Kairos are persistent across boots (including /opt) and only /var, /etc and /srv are writable (but not persistent).

Any additional paths on disk that need to become persistent for stuff not to totally break upon a reboot, need to be added to the bind_mounts option of the Kairos agent install user-data.00_rootfs.yaml        PERSISTENT_STATE_PATHS: >-
PERSISTENT_STATE_PATHS: >-
          /etc/cni
          /etc/init.d
          /etc/iscsi
          /etc/k0s
          /etc/kubernetes
          /etc/modprobe.d
          /etc/pwx
          /etc/rancher
          /etc/runlevels
          /etc/ssh
          /etc/ssl/certs
          /etc/sysconfig
          /etc/systemd
          /etc/zfs
          /home
          /opt
          /root
          /usr/libexec
          /var/cores
          /var/lib/ca-certificates
          /var/lib/cni
          /var/lib/containerd
          /var/lib/calico
          /var/lib/dbus
          /var/lib/etcd
          /var/lib/extensions
          /var/lib/k0s
          /var/lib/kubelet
          /var/lib/longhorn
          /var/lib/osd
          /var/lib/rancher
          /var/lib/rook
          /var/lib/tailscale
          /var/lib/wicked
          /var/lib/kairos
          /var/log
