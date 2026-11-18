#!/bin/bash
# egressip-arp-guard: stop a node that is shutting down or booting from answering or
# announcing ARP for EgressIPs it may no longer own (they fail over while it is down).
#
#   stop     run at the very start of shutdown. Drops, on the physical uplink, incoming ARP
#            requests for the EgressIPs this node holds. From that point the node can no longer
#            answer ARP for them, whether the answer would come from the kernel (the EgressIP is
#            an address on br-ex) or from OVN's flows. Same approach as upstream ovn-kubernetes
#            PR 6238. The rule lives in nftables and disappears with the reboot.
#   start    run at boot before kubelet. Drops ARP that OVN emits on br-ex unless it is sourced
#            from the node's own IP, so ovn-controller cannot announce or answer for an EgressIP
#            from the OVN database saved on disk.
#   release  removes the boot-time flows once ovnkube-node has synced.
set -u
BR=br-ex
TABLE=egressip-arp-guard
COOKIE=0x0e1b
log() { echo "egressip-arp-guard: $*"; }

node_ip() { ip -4 -o addr show dev "$BR" scope global | awk '$4 !~ /\/32$/ && $4 !~ /^169\.254\./ {sub(/\/.*/,"",$4); print $4; exit}'; }
uplink()  { ovs-vsctl list-ports "$BR" | grep -v '^patch-' | head -1; }
# EgressIPs currently held by this node: the /32 addresses ovnkube-node put on br-ex, minus any
# keepalived-managed VIP (API/ingress VIPs are also /32 on br-ex on on-prem platforms).
egress_ips() {
  local a out=""
  for a in $(ip -4 -o addr show dev "$BR" | awk '$4 ~ /\/32$/ {sub(/\/.*/,"",$4); print $4}'); do
    grep -qsF "$a" /etc/keepalived/keepalived.conf && continue
    out="${out:+$out, }$a"
  done
  echo "$out"
}

case "${1:-}" in
stop)
  UP=$(uplink); EIPS=$(egress_ips)
  [[ -z "$UP" ]] && { log "shutdown: cannot determine uplink of $BR; not installing"; exit 0; }
  [[ -z "$EIPS" ]] && { log "shutdown: no EgressIP on $BR; nothing to do"; exit 0; }
  if printf '%s\n' \
      "table netdev $TABLE" \
      "delete table netdev $TABLE" \
      "table netdev $TABLE {" \
      "  chain ingress {" \
      "    type filter hook ingress device \"$UP\" priority filter; policy accept;" \
      "    arp operation request arp daddr ip { $EIPS } counter drop" \
      "  }" \
      "}" | nft -f -; then
    log "shutdown: dropping ARP requests on $UP for EgressIPs: $EIPS"
  else
    log "shutdown: failed to install nftables rule"
  fi
  ;;
start)
  nft delete table netdev $TABLE 2>/dev/null
  IP=""
  for _ in $(seq 60); do IP=$(node_ip); [[ -n "$IP" ]] && break; sleep 1; done
  UP=$(uplink)
  [[ -z "$IP" || -z "$UP" ]] && { log "boot: cannot determine node IP ($IP) or uplink ($UP); not installing"; exit 0; }
  UPP=$(ovs-vsctl get interface "$UP" ofport)
  # The OVN patch port does not exist yet at boot (ovn-controller recreates it when it connects),
  # so allow ARP only from the host (LOCAL), from the wire (uplink) or sourced from the node IP,
  # and drop ARP from every other port, i.e. anything OVN emits for another address.
  ovs-ofctl add-flow "$BR" "cookie=$COOKIE,table=0,priority=601,arp,arp_spa=$IP,actions=NORMAL"
  ovs-ofctl add-flow "$BR" "cookie=$COOKIE,table=0,priority=600,in_port=LOCAL,arp,actions=NORMAL"
  ovs-ofctl add-flow "$BR" "cookie=$COOKIE,table=0,priority=600,in_port=$UPP,arp,actions=NORMAL"
  ovs-ofctl add-flow "$BR" "cookie=$COOKIE,table=0,priority=599,arp,actions=drop"
  log "boot: dropping ARP from OVN on $BR (anything not from $IP) until ovnkube-node has synced"
  ;;
release)
  # Wait for ovnkube-node's own GARP drop flows (cookie 0x0305, priority 498) to appear and then
  # be removed: ovnkube removes them only after OVN has synced and stale NAT entries are gone.
  seen=0
  for _ in $(seq 1800); do
    if ovs-ofctl dump-flows "$BR" "cookie=0x0305/-1" 2>/dev/null | grep -q 'priority=498'; then seen=1
    elif [[ $seen == 1 ]]; then break; fi
    sleep 0.5
  done
  sleep 2
  d=$(ovs-ofctl dump-flows "$BR" "cookie=$COOKIE/-1" 2>/dev/null | grep 'priority=599' | grep -o 'n_packets=[0-9]*')
  ovs-ofctl del-flows "$BR" "cookie=$COOKIE/-1" 2>/dev/null
  log "boot: released (ovnkube sync seen=$seen, stale ARP dropped while guarding: ${d:-flows already replaced by ovnkube-node})"
  ;;
*) echo "usage: $0 start|stop|release"; exit 2 ;;
esac
exit 0
