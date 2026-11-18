#!/bin/bash
# ploop.sh <node> <node-ip> <runs> : on the lab host. SIGTERM ovnkube-controller on a node while systemd is
# busy emitting unit signals (as in a shutdown); report whether ovnkube panicked. Pod is recreated each run.
export KUBECONFIG=~/install/auth/kubeconfig PATH=~/bin:$PATH
node=$1; ip=$2; N=${3:-10}
for i in $(seq $N); do
  for _ in $(seq 150); do
    p=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [ -n "$p" ] && oc -n openshift-ovn-kubernetes logs $p -c ovnkube-controller 2>/dev/null | grep -q 'Removing flows to drop GARP' && break; sleep 2
  done
  r=$(~/n.sh $ip '
    c=$(crictl ps --state Running --name "^ovnkube-controller$" -q | head -1)
    lp=$(crictl inspect $c | python3 -c "import sys,json;print(json.load(sys.stdin)[\"status\"][\"logPath\"])")
    for k in $(seq 60); do systemd-run --quiet --collect --unit=storm-$k sleep 600 2>/dev/null; done
    pid=$(pgrep -f "^/usr/bin/ovnkube " | head -1)
    systemctl stop "storm-*" "crio-conmon-*.scope" "crio-$c.scope" --no-block
    sleep 3; crictl stop -t 30 $c >/dev/null 2>&1; sleep 0.5
    if grep -q runKubeletRestartTracker $lp; then echo -n "PANIC "; else echo -n "clean "; fi
    echo "sigterm=$(grep -c "Received signal" $lp) nft_block=$(grep -c "Successfully added nftables ARP" $lp) stop_completed=$(grep -c "Stopping ovnkube" $lp) binary=$(crictl exec $(crictl ps --name "^ovn-controller$" -q | head -1) true 2>/dev/null; sha256sum /proc/$(pgrep -f "^/usr/bin/ovnkube " | head -1)/exe 2>/dev/null | cut -c1-12)"')
  echo "$(date -u +%T) $node run=$i $r"
  oc -n openshift-ovn-kubernetes delete pod $p --wait=true >/dev/null 2>&1
done
echo LOOP_DONE
