#!/bin/bash
# summ.sh <trial>: summarise one trial
t=$1; O=~/cap/$t
H=$(awk '/holder=/{sub("holder=","",$2);print $2;exit}' $O/timeline.log); OM=$(awk -v h=$H '$1==h{print $2}' ~/nodes.txt)
echo "##### $t old holder=$H ($OM)"; grep -E 'REBOOT' $O/timeline.log
echo "- gateway ARP entry / holder changes:"; grep gw_arp $O/timeline.log | awk '{print $1,$2,$3}' | uniq -f1 | head -30
echo "- node Ready transitions:"; grep gw_arp $O/timeline.log | awk '{print $1,$NF}' | uniq -f1
[ -f $O/gw-arping.log ] && { echo "- who answered the gateway's broadcast ARP:"; cut -d' ' -f3- $O/gw-arping.log | sort | uniq -c; echo "  first/last answer from old holder:"; grep -i "$OM" $O/gw-arping.log | sed -n '1p;$p' | cut -c1-70; }
echo "- frames from old holder claiming the EgressIP after failover (GARP = Request tell .100):"
awk -v m=$OM '$3==m' $O/arp.txt | cut -c12-170 | sed 's/ethertype ARP (0x0806), //' | awk 'NR>0' | head -${2:-12}
echo "  total: $(awk -v m=$OM '$3==m' $O/arp.txt | wc -l)"
echo "- probe results:"; awk '{print $2}' $O/probe.log | sort | uniq -c; grep TIMEOUT $O/probe.log | sed -n '1p;$p'
[ -f $O/dropflow.log ] && { echo "- drop-flow counters seen on old holder:"; grep -o 'n_packets=[0-9]*, n_bytes=[0-9]*, idle_age=[0-9]*, priority=[0-9]*,arp[^ ]* actions=drop' $O/dropflow.log | sed 's/idle_age=[0-9]*, //' | sort -u; }
