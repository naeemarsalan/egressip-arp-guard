#!/bin/bash
# Lab host setup: libvirt L2 network + 6 VMs for an agent-based OCP 4.20.44 install.
# The host bridge (virbr-ocp, 192.168.130.1) plays the role of the upstream gateway.
set -euxo pipefail

CLUSTER=egresslab
DOMAIN=lab.local
NET=192.168.130
OCPVER=4.20.44

sudo dnf -y -q install libvirt qemu-kvm virt-install tcpdump jq nmstate tmux bind-utils mdadm

# Instance-store NVMe -> one RAID0 volume for VM disks
if ! mountpoint -q /var/lib/libvirt/images; then
  DISKS=$(lsblk -dn -o NAME,MODEL | awk '/Instance Storage/{print "/dev/"$1}')
  sudo mdadm --create /dev/md0 --level=0 --raid-devices=$(echo $DISKS | wc -w) $DISKS --run
  sudo mkfs.xfs -q -f /dev/md0
  sudo mkdir -p /var/lib/libvirt/images
  sudo mount /dev/md0 /var/lib/libvirt/images
  sudo restorecon -R /var/lib/libvirt/images
fi

sudo systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket 2>/dev/null || sudo systemctl enable --now libvirtd

# name  mac  ip  vcpu  memMB
cat > ~/nodes.txt <<EOF
master0 52:54:00:13:00:10 $NET.10 8 20480
master1 52:54:00:13:00:11 $NET.11 8 20480
master2 52:54:00:13:00:12 $NET.12 8 20480
worker0 52:54:00:13:00:20 $NET.20 8 16384
worker1 52:54:00:13:00:21 $NET.21 8 16384
worker2 52:54:00:13:00:22 $NET.22 8 16384
EOF

{
cat <<EOF
<network xmlns:dnsmasq='http://libvirt.org/schemas/network/dnsmasq/1.0'>
  <name>ocp</name>
  <forward mode='nat'/>
  <bridge name='virbr-ocp' stp='off' delay='0'/>
  <domain name='$CLUSTER.$DOMAIN' localOnly='no'/>
  <dns>
    <host ip='$NET.5'><hostname>api.$CLUSTER.$DOMAIN</hostname><hostname>api-int.$CLUSTER.$DOMAIN</hostname></host>
EOF
while read n mac ip c m; do echo "    <host ip='$ip'><hostname>$n.$CLUSTER.$DOMAIN</hostname></host>"; done < ~/nodes.txt
cat <<EOF
  </dns>
  <ip address='$NET.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$NET.200' end='$NET.250'/>
EOF
while read n mac ip c m; do echo "      <host mac='$mac' name='$n.$CLUSTER.$DOMAIN' ip='$ip'/>"; done < ~/nodes.txt
cat <<EOF
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value='address=/apps.$CLUSTER.$DOMAIN/$NET.6'/>
  </dnsmasq:options>
</network>
EOF
} > ~/ocp-net.xml

if ! sudo virsh net-info ocp >/dev/null 2>&1; then
  sudo virsh net-define ~/ocp-net.xml
  sudo virsh net-autostart ocp
  sudo virsh net-start ocp
fi

# Host resolves cluster names through the libvirt dnsmasq
sudo resolvectl dns virbr-ocp $NET.1 2>/dev/null || true
sudo resolvectl domain virbr-ocp "~$CLUSTER.$DOMAIN" 2>/dev/null || true
grep -q "api.$CLUSTER.$DOMAIN" /etc/hosts || echo "$NET.5 api.$CLUSTER.$DOMAIN api-int.$CLUSTER.$DOMAIN
$NET.6 console-openshift-console.apps.$CLUSTER.$DOMAIN oauth-openshift.apps.$CLUSTER.$DOMAIN" | sudo tee -a /etc/hosts

mkdir -p ~/bin ~/install
cd ~/bin
[ -x openshift-install ] || curl -sfL --retry 5 --retry-all-errors https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$OCPVER/openshift-install-linux.tar.gz | tar xz openshift-install
[ -x oc ] || curl -sfL --retry 5 --retry-all-errors https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$OCPVER/openshift-client-linux.tar.gz | tar xz oc kubectl
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519

cat > ~/install/install-config.yaml <<EOF
apiVersion: v1
baseDomain: $DOMAIN
metadata:
  name: $CLUSTER
controlPlane:
  name: master
  replicas: 3
compute:
- name: worker
  replicas: 3
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: $NET.0/24
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
platform:
  baremetal:
    apiVIPs: [$NET.5]
    ingressVIPs: [$NET.6]
pullSecret: '$(cat ~/pull-secret.txt)'
sshKey: '$(cat ~/.ssh/id_ed25519.pub)'
EOF

{
cat <<EOF
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: $CLUSTER
rendezvousIP: $NET.10
hosts:
EOF
while read n mac ip c m; do
  role=worker; [[ $n == master* ]] && role=master
  cat <<EOF
- hostname: $n
  role: $role
  interfaces:
  - name: enp1s0
    macAddress: $mac
EOF
done < ~/nodes.txt
} > ~/install/agent-config.yaml

cp -a ~/install ~/install.orig
~/bin/openshift-install agent create image --dir ~/install
sudo cp ~/install/agent.x86_64.iso /var/lib/libvirt/images/agent.iso

while read n mac ip c m; do
  sudo virsh dominfo $n >/dev/null 2>&1 && continue
  sudo virt-install --name $n --vcpus $c --memory $m --cpu host-passthrough \
    --disk path=/var/lib/libvirt/images/$n.qcow2,size=120,bus=virtio,cache=none \
    --cdrom /var/lib/libvirt/images/agent.iso \
    --network network=ocp,mac=$mac,model=virtio \
    --os-variant rhel9.4 --boot hd,cdrom --graphics none --noautoconsole --wait 0
done < ~/nodes.txt
sudo virsh list --all
