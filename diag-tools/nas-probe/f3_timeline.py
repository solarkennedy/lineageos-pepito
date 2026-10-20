import re, sys, datetime, collections
F=sys.argv[1]
EPOCH=datetime.datetime(1980,1,6)
def ts(h):
    v=int(h,16)>>16          # 1.25 ms units since 1980-01-06 (QC diag timestamp)
    return EPOCH+datetime.timedelta(milliseconds=v*1.25)
rows=[]
pat=re.compile(r'\[(0x[0-9a-f]{16})\]\s+(\S+)\s+(.*)')
for l in open(F,errors='replace'):
    m=pat.search(l)
    if not m: continue
    rows.append((ts(m.group(1)),m.group(2),m.group(3).strip()))
rows.sort(key=lambda r:r[0])
print("span", rows[0][0], "->", rows[-1][0], "lines", len(rows))
# per-30s: last Srxlev, last rsrp, last srv_status
buckets=collections.OrderedDict()
for t,src,txt in rows:
    k=t.replace(second=(t.second//30)*30, microsecond=0)
    b=buckets.setdefault(k,{})
    m=re.search(r'Srxlev (-?[0-9.]+)',txt)
    if m and 'S thresh' in txt: b['srx']=float(m.group(1))
    m=re.search(r'cmss_report_rssi\(\), rsrp=(-?\d+)',txt)
    if m: b['rsrp']=int(m.group(1))
    m=re.search(r'srv_status:(\d)',txt)
    if m: b['srv']=m.group(1)
    if 'cmss_report_rssi(), rsrp' in txt or 'S thresh' in txt or 'ss event cb' in txt: pass
print("\n== timeline (30 s buckets): srxlev / rsrp / srv_status")
last=None
for k,b in buckets.items():
    s=(b.get('srx'),b.get('rsrp'),b.get('srv'))
    if s!=last: print(k.strftime('%H:%M:%S'), "srxlev=%s rsrp=%s srv=%s"%s); last=s
# events
EV=re.compile(r'OOS|out of service|Out of Service|PLMN not found|Forbidden|forbidden|emc_attached|emergency only|LIMITED|limited|Camped|camped|Acquis|acq |ACQ |Suitable|suitable|resel|Resel|T310|T311|RLF|radio link|Radio Link|out of sync|Out of sync|OUT_OF_SYNC|REG_REQ|REGISTERED|DEREG|ATTACH|Attach|backoff|Backoff|unblock|BPLMN|srv_status:[013]|NO_SRV|no service|No service|cell selection|Cell Selection|CELL_SEL|power save|Power save|pwr_save|lte_disable|Disabling LTE|voice is not|voice not available|domestic_voice|IMS_REG_STATUS|not avail',re.I)
SKIP=re.compile(r'qipcall|qpdpl|ims_task|ho_mgr|ds_3gpp_bearer|RAB reestab|Using resel metric|S thresh check|drb_reestab',re.I)
print("\n== events (dedup per 10 s on text)")
seen=set(); n=0
for t,src,txt in rows:
    if not EV.search(txt) or SKIP.search(txt): continue
    key=(t.replace(second=(t.second//10)*10,microsecond=0), txt[:70])
    if key in seen: continue
    seen.add(key); n+=1
    if n<=400: print(t.strftime('%H:%M:%S.%f')[:12], src, txt[:150])
print("events shown", min(n,400), "of", n)
