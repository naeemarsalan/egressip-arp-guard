# egressip-arp-guard

Root-cause analysis, lab reproduction and fixes for an OVN-Kubernetes EgressIP problem on
OpenShift 4.20.44: a node that used to hold an EgressIP keeps answering or announcing ARP for
it while it reboots, after the EgressIP has already failed over to another node. The upstream
router then sends return traffic for the EgressIP to the wrong node, and every pod using that
EgressIP loses outbound connectivity until the router's ARP entry is corrected.

> **Status: lab only, unsupported.** Nothing here is a Red Hat product or a supported fix. The
> patches were tested on one six-node lab cluster, with a locally built `ovnkube` binary and a
> hand-edited script ConfigMap, not through a product build. Review and test before relying on
> any of it.

## Root cause

OpenShift 4.20.44 already contains a guard for each of the two windows in which the old holder
can claim the EgressIP. Each guard has a defect.

### 1. Shutdown: the guard is skipped when `ovnkube` panics on SIGTERM

On SIGTERM, `ovnkube` installs an nftables rule that drops ARP requests for the node's
EgressIPs (`addEgressIPARPBlockRules`, shipped in 4.20 by
[openshift/ovn-kubernetes#3506](https://github.com/openshift/ovn-kubernetes/pull/3506)).
That code never runs if the process crashes first, and it can:

- `runKubeletRestartTracker` in `pkg/node/udn_isolation.go` reads systemd signals from a
  channel in a `select` loop alongside `ctx.Done()`.
- The D-Bus connection is opened with `dbus.WithContext(ctx)`, so cancelling the context closes
  the connection, and `godbus` then closes the signal channel.
- A receive from the closed channel yields a nil `*dbus.Signal`, and the next line dereferences
  it. The process dies with a nil-pointer panic about 2 ms after `Received signal terminated`.

When that happens the ARP block is not installed, the stale EgressIP NAT stays in the node's OVN
database, and the node keeps answering ARP for the EgressIP for as long as its shutdown takes.

- **Seen in the lab:** 1 of 5 stock graceful reboots panicked this way, and that was the one
  reboot in which the old holder kept answering ARP (for about 75 seconds). The exit trace is in
  [`evidence/panic/t3-ovnkube-controller-exit.txt`](evidence/panic/t3-ovnkube-controller-exit.txt).
- **Reproduced on demand:** 2 of 12 runs when systemd stops the container scopes, as it does in
  a reboot. 0 of 24 when the signal was sent directly instead of by systemd.
- **Already fixed upstream** by
  [ovn-kubernetes#5902](https://github.com/ovn-kubernetes/ovn-kubernetes/pull/5902) (issue
  #5878). The fix is in `release-4.21` and later, and absent from `release-4.20`.

### 2. Boot: the GARP drop flow can only be added after it is needed

Each node keeps its OVN databases on disk, so after a reboot they still say "this node holds
the EgressIP". `ovn-controller` sends a gratuitous ARP for it about one second after connecting,
unless `ovnkube` has removed the stale entry first. The 4.20 workaround
(`wait-and-add-garp-drop-flow` in the operator's `ovnkube-script-lib`) drops those ARPs with a
flow matched on the `br-ex` patch port. The ordering defeats it:

1. The patch port does not exist at boot. `ovn-controller` creates it only after it connects.
2. `ovn-controller` can only connect once `ovnkube` has set `ovn-remote`.
3. The workaround runs in the background and polls every 2 seconds for the patch port.

So the flow cannot exist before `ovn-controller` is already running against the stale database.
In every stock reboot measured it landed 1.2–1.5 seconds after the connect. A small cluster is
saved only because `ovnkube` removes the stale entry in about 0.2–0.3 seconds. If that cleanup
takes more than about a second, the ARP goes out.

## The fix

### Product patches ([`fix/product-patches/`](fix/product-patches/))

| Patch | Repository | Change |
|---|---|---|
| `0001-ovnk-4.20-udn-isolation-shutdown-panic.patch` | `openshift/ovn-kubernetes`, `release-4.20` | Backport of upstream #5902: check the channel receive and return on a closed channel |
| `0002-cno-4.20-early-arp-drop-before-ovnkube.patch` | `openshift/cluster-network-operator`, `release-4.20` | Install the ARP drop synchronously before `ovnkube` starts, without needing the patch port |

Patch 0002 adds `add_early_arp_drop_flows`. When `br-ex` has no patch port yet (node boot), it
allows ARP from the host, from the uplink and with a node IP as sender, and drops all other ARP,
which can only come from OVN. `ovnkube` replaces these flows with its own on its first flow
sync. When a patch port already exists (container restart), it falls back to the existing
per-port flow, so workloads on other OVN ports of `br-ex` are not affected.

### Interim mitigation ([`fix/interim-machineconfig/`](fix/interim-machineconfig/))

A script and two systemd units, packaged as a MachineConfig, that do the same two jobs from
outside the product: an nftables ARP block at the start of shutdown and an OpenFlow ARP drop
before kubelet at boot. It does not depend on `ovnkube` exiting cleanly. The MachineConfig
passed a server-side dry run but was never rolled out through the Machine Config Operator.

## Lab results

OpenShift 4.20.44, three control-plane and three worker nodes as libvirt VMs on one bare-metal
host, with the host bridge acting as the upstream gateway. A pod on a third worker curls a
server on the gateway once a second through EgressIP `192.168.130.100`. "Delay" means a
10-second pause injected into `ovnkube`'s startup cleanup, standing in for a slow sync.

| Trial | Scenario | Result |
|---|---|---|
| `t1` | Stock, graceful reboot | Clean |
| `t3` | Stock, graceful reboot | **`ovnkube` panicked on SIGTERM; old holder answered ARP for about 75 s** |
| `h1` | Stock, hard power-off | Clean; stale entry removed before OVN's first ARP |
| `s3` | Stock, hard power-off, delay | **Stale ARP sent 174 ms before the drop flow; gateway entry flipped to the old node** |
| `s4` | Same, gateway set not to re-probe | **Same leak; probes timed out until the end of the run** |
| `p1`, `p2` | Product patches, hard power-off, delay | Drop in place 0.78 s before the connect; 4 stale ARPs dropped; none on the wire; 2–3 s failover gap only |
| `q1`, `q2` | Product patches, graceful reboot, delay | No panic; ARP block installed; old holder silent after failover; zero probe failures |
| `f1`, `f2` | Interim MachineConfig, hard power-off, delay | No stale ARP; gateway entry correct |
| `g2` | Interim MachineConfig, graceful reboot | Old node silent 0.4 s into shutdown; zero probe failures |

Shutdown panic rate, systemd stopping the scopes: stock 2 of 12, patched 0 of 25
([`evidence/panic/`](evidence/panic/)).

Limits of these results:

- The boot-time leak only reproduced with the delay injected. The lab does not show that any
  real cluster is slow enough to hit it unaided.
- The patched `ovnkube` was a local `go build` of the 4.20.44 commit plus patch 0001, mounted
  over the shipped binary. Patch 0002 was applied by editing the live ConfigMap with the
  operator scaled down, not by building the operator.
- Bonded or VLAN uplinks, secondary-network EgressIPs and IPv6 were not tested.

Raw captures for each trial are in [`evidence/`](evidence/): `timeline.log` (EgressIP holder,
gateway ARP entry, node readiness), `arp.txt` (decoded ARP for the EgressIP on the gateway
bridge), `dropflow.log` (drop-flow counters on the old holder), `probe.log`. `g1` and
`f1-invalid-unit-bug` are discarded runs kept because they document mistakes in early versions
of the interim guard.

## Checking a real cluster

On the node that held the EgressIP, the `ovnkube-controller` container logs under
`/var/log/pods/openshift-ovn-kubernetes_ovnkube-node-*/ovnkube-controller/` survive reboots.

- **Shutdown defect:** in the log that ends at the reboot, look for `Received signal terminated`
  followed by `panic:` and `runKubeletRestartTracker`, and for the absence of
  `Adding nftables ARP/NDP block rules`.
- **Boot defect:** in the log that starts after the reboot, compare `ovnsb_db.sock: connected`
  (the `ovn-controller` container), `Added GARP drop flow` and `syncStaleSNATRules will delete`.
  If the cleanup line is more than about a second after the connect and the drop flow is later
  than the connect, the stale ARP went out.

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
   `summ.sh <label>` summarises it; `margins.sh` prints how late the drop flow was.
6. `evidence/panic/ploop3.sh <node> <node-ip> <runs>` measures the shutdown panic rate. It
   stops every container scope on that node each run.
