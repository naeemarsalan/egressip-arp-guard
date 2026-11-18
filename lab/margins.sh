#!/bin/bash
# For each ovnkube-node pod on the egress nodes: when did ovn-controller attach to the (stale) local SB DB,
# and when did the GARP drop flow get installed? Negative margin = race lost.
export KUBECONFIG=~/install/auth/kubeconfig PATH=~/bin:$PATH
for n in worker0 worker1; do
  P=$(oc -n openshift-ovn-kubernetes get pod -l app=ovnkube-node --field-selector spec.nodeName=$n -o name)
  sb=$(oc -n openshift-ovn-kubernetes logs $P -c ovn-controller --timestamps | grep -m1 'ovnsb_db.sock: connected' | awk '{print $1}')
  fl=$(oc -n openshift-ovn-kubernetes logs $P -c ovnkube-controller --timestamps | grep -m1 'Added GARP drop flow' | awk '{print $1}')
  st=$(oc -n openshift-ovn-kubernetes logs $P -c ovnkube-controller --timestamps | grep -m1 'wait-and-add-garp-drop-flow' | awk '{print $1}')
  python3 -c "
import sys,datetime as d
p=lambda s:d.datetime.fromisoformat(s[:26])
sb,fl,st=sys.argv[1:4]
print('$n sb_connected=%s dropflow_added=%s margin=%+.3fs (workaround script started %s)'%(sb[11:23],fl[11:23],(p(sb)-p(fl)).total_seconds(),st[11:23]))" "$sb" "$fl" "$st" 2>/dev/null || echo "$n sb=$sb flow=$fl start=$st"
done
