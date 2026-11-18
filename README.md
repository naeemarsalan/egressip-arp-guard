# egressip-arp-guard

Lab reproduction of, and an interim mitigation for, an OVN-Kubernetes EgressIP problem on
OpenShift 4.20: a node that used to hold an EgressIP keeps answering or announcing ARP for it
while it reboots, after the EgressIP has already failed over to another node. The upstream
router then sends return traffic for the EgressIP to the wrong node, and every pod using that
EgressIP loses outbound connectivity until the router's ARP entry is corrected.

> **Status: lab only, unsupported.** This is not a Red Hat product or a supported fix. The
> guard was hand-installed on two nodes of a six-node lab cluster. The MachineConfig passed a
> server-side dry run but has never been rolled out through the Machine Config Operator. Review
> and test it yourself before using it anywhere that matters.

## The problem

There are two separate windows in which the old holder can claim the EgressIP.

**1. Boot (stale gratuitous ARP).** Each node keeps its OVN databases on disk. After a reboot
they still say "this node holds the EgressIP". When `ovn-controller` connects, OVN sends a
gratuitous ARP for the EgressIP about one second later, unless OVN-Kubernetes has removed the
stale entry first. OpenShift 4.20.44 carries a workaround that installs an OpenFlow rule on
`br-ex` to drop those ARPs, but:

- it is a background shell function (`wait-and-add-garp-drop-flow`), described in its own
  comments as best-effort;
- it polls every 2 seconds for a patch port that only exists after `ovn-controller` has
  connected;
- in every measured reboot in this lab the rule landed 1.2–1.4 seconds after the connect,
  which is after OVN's first gratuitous ARP.

On a small cluster the stale entry is removed about 0.2–0.3 seconds after the connect, so
nothing leaks. If that cleanup takes longer than about a second, the ARP goes out.

**2. Shutdown (old holder keeps answering).** The EgressIP is also a `/32` kernel address on
`br-ex`. During a slow graceful shutdown the old node can keep answering ARP requests for it
after the EgressIP has moved. This is
[OCPBUGS-77068](https://issues.redhat.com/browse/OCPBUGS-77068), fixed upstream in
[ovn-kubernetes#6238](https://github.com/ovn-kubernetes/ovn-kubernetes/pull/6238).

## What the lab showed

OpenShift 4.20.44, three control-plane and three worker nodes as libvirt VMs on one bare-metal
host, with the host bridge acting as the upstream gateway. A pod on a third worker curls a
server on the gateway once a second through EgressIP `192.168.130.100`.

| Trial | Scenario | Result |
|---|---|---|
| `t1` | Graceful reboot | Clean |
| `t3` | Graceful reboot | Old holder answered ARP for the EgressIP for about 75 seconds during shutdown |
| `h1` | Hard power-off | Clean; stale entry removed before OVN's first ARP |
| `s2` | Hard power-off, whole process paused | Clean (pause was too early to matter) |
| `s3` | Hard power-off, cleanup delayed 10 s | **Stale gratuitous ARP sent 174 ms before the drop rule; gateway ARP entry flipped to the old node; probes timed out until the gateway re-probed about 10 s later** |
| `s4` | Same, gateway set not to re-probe | **Same leak; gateway stayed on the old node; probes timed out until the end of the run** |
| `f1`, `f2` | Same as `s4`, guard installed | No stale ARP, gateway entry correct, only the normal 2–3 s failover gap |
| `g1` | Graceful reboot, first guard version | ARP silenced, but the shutdown rule was too broad and `crio` hung 3 min 20 s on stop |
| `g2` | Graceful reboot, final guard | Old node silent 0.4 s into shutdown, zero probe failures, `crio` stopped normally |

The boot-time leak only reproduced with the delay injected (2 of 2 with, 0 of 2 without). The
lab does not show that any real cluster is slow enough to hit it unaided. The shutdown window
appeared without injection, in one of the unguarded graceful reboots.

Raw captures for each trial are in [`evidence/`](evidence/): `timeline.log` (EgressIP holder,
gateway ARP entry, node readiness), `arp.txt` (decoded ARP for the EgressIP on the gateway
bridge), `dropflow.log` (the workaround's flow counters on the old holder), `probe.log`.
`f1-invalid-unit-bug` is a discarded run, kept because it documents a mistake: an earlier unit
file had `Wants=ovs-configuration.service`, and enabling it on a live node re-ran
`configure-ovs` and broke that node's OVN connection.

## The fix

**Proper fix (product):** backport the upstream shutdown fix to 4.20.z, and install the
boot-time drop rule before `ovn-controller` is pointed at the database instead of polling for
it afterwards.

**Interim mitigation (this repo):** a small script and two systemd units, in [`fix/`](fix/).

| File | Purpose |
|---|---|
| `egressip-arp-guard.sh` | The logic: `stop`, `start`, `release` |
| `egressip-arp-guard.service` | Runs `stop` at the very start of shutdown, before kubelet and CRI-O stop |
| `egressip-arp-guard-boot.service` | Runs `start` before kubelet at boot, then `release` |
| `99-worker-egressip-arp-guard.machineconfig.yaml` | The three files above packaged for the `worker` pool |

- **At shutdown** it adds an nftables `netdev` ingress rule on the uplink that drops ARP
  requests for the EgressIPs this node holds. The node can no longer answer for them, from the
  kernel or from OVN. The rule vanishes with the reboot.
- **At boot** it adds OpenFlow rules on `br-ex` (cookie `0x0e1b`) that allow ARP from the host,
  from the wire, or sourced from the node's own IP, and drop all other ARP, which is anything
  OVN emits for another address. These are in place before kubelet starts, so they do not
  depend on the patch port existing.
- **Release** waits for OVN-Kubernetes' own drop rules (cookie `0x0305`, priority 498) to
  appear and be removed, which happens only after its sync, then deletes the guard's rules.

Assumptions baked into the script: the external bridge is `br-ex`, the uplink is its first
non-patch port, and EgressIPs are on the primary network. API and ingress VIPs are excluded by
matching `/etc/keepalived/keepalived.conf`. Secondary-network EgressIPs, bonded or VLAN
uplinks, and IPv6 were not tested.

## Reproducing it

Scripts are in [`lab/`](lab/). They expect a RHEL 9 bare-metal host with instance NVMe disks
and your pull secret at `~/pull-secret.txt`. Cloud-native installs cannot reproduce this,
because cloud EgressIP moves through the provider API and involves no ARP.

1. `host-setup.sh` builds the libvirt network and VMs and starts an agent-based install.
2. `lab-test-setup.sh` creates the EgressIP, the probe pod and the echo server on the gateway.
3. Install `inject/ovnkube-slow-sync.{sh,service}` on the egress nodes. It pauses
   `ovnkube-controller` for 10 seconds at the moment it has pointed `ovn-controller` at the
   database. **Fault injection; never install it outside a lab.**
4. `sudo sysctl net.ipv4.neigh.virbr-ocp.delay_first_probe_time=600` makes the Linux gateway
   trust its ARP entry the way a hardware router does.
5. `HARD=1 trial.sh <label>` powers off the current holder and records the result;
   `summ.sh <label>` summarises it; `margins.sh` prints how late the drop rule was.
