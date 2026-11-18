# Apply the same script change as fix/0002 to the live ovnkube-script-lib configmap (lab only).
import json,sys,re
cm=json.load(open(sys.argv[1])); patch=open(sys.argv[2]).read()
added=[l[1:] for l in patch.splitlines() if l.startswith('+') and not l.startswith('+++')]
# first hunk = new function (up to blank line before anchor), second hunk = new call site
i=next(k for k,l in enumerate(added) if 'On boot, block ARP from OVN synchronously' in l)
fn=[l[4:] if l.startswith('    ') else l for l in added[:i]]
key=[k for k,v in cm['data'].items() if 'wait-and-add-garp-drop-flow()' in v][0]
s=cm['data'][key]
anchor='# Wait for patch port to exist and add GARP drop flow.\nwait-and-add-garp-drop-flow() {'
assert s.count(anchor)==1, 'anchor'
s=s.replace(anchor,'\n'.join(fn).rstrip()+'\n\n'+anchor)
m=re.search(r'( *)\(wait-and-add-garp-drop-flow br-ex &\)\n',s); assert m
ind=m.group(1)[:-2] if len(m.group(1))>=2 else ''
new=(m.group(1)+'if ! add_early_arp_drop_flows br-ex; then\n'+m.group(1)+'  (wait-and-add-garp-drop-flow br-ex &)\n'+m.group(1)+'fi\n')
s=s[:m.start()]+new+s[m.end():]
cm['data'][key]=s
for k in ('resourceVersion','uid','creationTimestamp','managedFields'): cm['metadata'].pop(k,None)
json.dump(cm,open(sys.argv[3],'w'))
open(sys.argv[3]+'.sh','w').write(s)
