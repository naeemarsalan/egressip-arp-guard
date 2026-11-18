#!/bin/bash
# FAULT INJECTION (lab only): pause the ovnkube-controller process for $1 seconds at the moment it
# has pointed ovn-controller at the local OVN databases (ovn-remote set) but before it has removed
# stale EgressIP NAT entries. Stands in for a slow startup sync on a large production cluster.
D=${1:-10}
while :; do
  p=$(pgrep -f '^/usr/bin/ovnkube .*--init-ovnkube-controller' | head -1)
  [ -n "$p" ] && break
  sleep 0.05
done
while :; do
  r=$(ovs-vsctl --if-exists get Open_vSwitch . external_ids:ovn-remote 2>/dev/null | tr -d '" ')
  [ -n "$r" ] && break
done
kill -STOP $p; echo "$(date -u +%T.%3N) ovn-remote=$r; paused ovnkube pid $p for ${D}s"
sleep $D
kill -CONT $p; echo "$(date -u +%T.%3N) resumed ovnkube pid $p"
