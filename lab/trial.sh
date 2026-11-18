#!/bin/bash
# usage: trial.sh <label> [watch-seconds]   Reboot the current EgressIP holder and record what the gateway sees.
export KUBECONFIG=~/install/auth/kubeconfig PATH=~/bin:$PATH
L=$1; W=${2:-420}; EIP=192.168.130.100; O=~/cap/$L; mkdir -p $O
ts(){ date -u +%FT%T.%3NZ; }
H=$(oc get egressip egressips-test -o jsonpath='{.status.items[0].node}')
echo "$(ts) holder=$H mac_table:" > $O/timeline.log
grep -E 'worker' ~/nodes.txt | awk '{print "   "$1" "$2}' >> $O/timeline.log
sudo tcpdump -U -e -nn -i virbr-ocp "arp and host $EIP" -w $O/arp.pcap >/dev/null 2>&1 &
TP=$!
sleep 2
echo "$(ts) REBOOT $H" >> $O/timeline.log
if [ "${HARD:-0}" = 1 ]; then sudo virsh destroy $H >/dev/null; else ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR core@$(awk -v h=$H '$1==h{print $3}' ~/nodes.txt) sudo systemctl reboot; fi
if [ "${GWARP:-0}" = 1 ]; then  # emulate an upstream gateway that refreshes its ARP entry by broadcast
( e=$((SECONDS+W)); while [ $SECONDS -lt $e ]; do
    r=$(sudo arping -c1 -w1 -I virbr-ocp $EIP 2>/dev/null | grep -o '\[[0-9A-Fa-f:]*\]' | tr '\n' ' ')
    echo "$(ts) replies: $r" >> $O/gw-arping.log; sleep 1
  done ) &
fi
NIP=$(awk -v h=$H '$1==h{print $3}' ~/nodes.txt)
( pf=""; e=$((SECONDS+W)); while [ $SECONDS -lt $e ]; do
    f=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=1 core@$NIP "sudo ovs-ofctl dump-flows br-ex 'cookie=0x0305/-1' 2>&1 | grep -o 'n_packets=[0-9]*.*' | tr '\n' ';'" 2>/dev/null || echo unreachable)
    [ "$f" != "$pf" ] && echo "$(ts) $f" >> $O/dropflow.log; pf=$f; sleep 0.3
  done ) &
end=$((SECONDS+W)); prev=""
while [ $SECONDS -lt $end ]; do
  h=$(oc get egressip egressips-test --request-timeout=3s -o jsonpath='{.status.items[0].node}' 2>/dev/null)
  n=$(ip neigh show dev virbr-ocp $EIP | awk '{print $3" "$4}')
  r=$(oc get node $H --request-timeout=3s -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  cur="eip_holder=$h gw_arp=$n ${H}_ready=$r"
  [ "$cur" != "$prev" ] && echo "$(ts) $cur" >> $O/timeline.log
  prev=$cur; sleep 0.5
done
sudo kill $TP; sleep 1
sudo tcpdump -tttt -e -nn -r $O/arp.pcap 2>/dev/null > $O/arp.txt
oc -n egress-test logs deploy/probe --since=$((W+30))s > $O/probe.log
echo "$(ts) DONE" >> $O/timeline.log
