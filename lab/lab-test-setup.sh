#!/bin/bash
set -euo pipefail
export KUBECONFIG=~/install/auth/kubeconfig PATH=~/bin:$PATH
EIP=192.168.130.100
mkdir -p ~/cap

# "external" server on the gateway/host: returns the client source IP
cat > ~/echo.py <<'PY'
import http.server, datetime, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        b=(s.client_address[0]+"\n").encode(); s.send_response(200); s.send_header("Content-Length",str(len(b))); s.end_headers(); s.wfile.write(b)
    def log_message(s,*a): pass
http.server.ThreadingHTTPServer(("192.168.130.1",8080),H).serve_forever()
PY
pgrep -f echo.py >/dev/null || nohup python3 ~/echo.py >/dev/null 2>&1 &
sudo firewall-cmd --zone=libvirt --add-port=8080/tcp 2>/dev/null || true

# continuous evidence capture on the gateway side
pgrep -f "tcpdump.*eip-arp" >/dev/null || sudo nohup tcpdump -U -tttt -e -nn -i virbr-ocp "arp and host $EIP" -w ~/cap/eip-arp.pcap >/dev/null 2>&1 &
pgrep -f "ip -ts monitor neigh" >/dev/null || nohup ip -ts monitor neigh dev virbr-ocp > ~/cap/neigh-monitor.log 2>&1 &

oc label node worker0 worker1 k8s.ovn.org/egress-assignable="" --overwrite
oc apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: egress-test
  labels: {egress: test}
---
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressips-test
spec:
  egressIPs: [$EIP]
  namespaceSelector:
    matchLabels: {egress: test}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: probe, namespace: egress-test}
spec:
  replicas: 1
  selector: {matchLabels: {app: probe}}
  template:
    metadata: {labels: {app: probe}}
    spec:
      nodeSelector: {kubernetes.io/hostname: worker2}
      terminationGracePeriodSeconds: 1
      containers:
      - name: probe
        image: registry.access.redhat.com/ubi9/ubi-minimal
        command: ["/bin/bash","-c","while true; do r=\$(curl -s -m 2 http://192.168.130.1:8080 || echo TIMEOUT); echo \"\$(date -u +%FT%T.%3NZ) \$r\"; sleep 1; done"]
YAML
oc -n egress-test rollout status deploy/probe --timeout=180s
sleep 5
oc get egressip
oc -n egress-test logs deploy/probe --tail=3
ip neigh show dev virbr-ocp | sort
