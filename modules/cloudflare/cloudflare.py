#!/usr/bin/env python3
from __future__ import annotations
import argparse,json,os,re,sys,urllib.error,urllib.parse,urllib.request
from pathlib import Path
TOKEN_FILE=Path('/root/.secrets/cloudflare.ini')
API='https://api.cloudflare.com/client/v4'

def token():
    env=os.environ.get('CLOUDFLARE_API_TOKEN','').strip()
    if env: return env
    if not TOKEN_FILE.exists(): raise RuntimeError(f'missing {TOKEN_FILE}')
    m=re.search(r'^\s*dns_cloudflare_api_token\s*=\s*(.+?)\s*$',TOKEN_FILE.read_text(),re.M)
    if not m: raise RuntimeError('dns_cloudflare_api_token not found')
    return m.group(1).strip()

def call(method,path,body=None):
    data=None if body is None else json.dumps(body,separators=(',',':')).encode()
    req=urllib.request.Request(API+path,data=data,method=method,headers={'Authorization':'Bearer '+token(),'Content-Type':'application/json','User-Agent':'vps-init/1'})
    try:
      with urllib.request.urlopen(req,timeout=20) as r: out=json.loads(r.read().decode())
    except urllib.error.HTTPError as e: raise RuntimeError(f'Cloudflare HTTP {e.code}: {e.read()[:500]!r}') from None
    if not out.get('success'): raise RuntimeError('Cloudflare API error: '+json.dumps(out.get('errors'),ensure_ascii=False))
    return out

def zone_id(name):
    out=call('GET','/zones?'+urllib.parse.urlencode({'name':name,'status':'active','per_page':50}))
    rows=out.get('result') or []
    if len(rows)!=1: raise RuntimeError(f'active zone not uniquely found for {name}')
    return rows[0]['id']

def upsert(zone,name,ip,typ='A'):
    q=urllib.parse.urlencode({'type':typ,'name':name,'per_page':100})
    rows=(call('GET',f'/zones/{zone}/dns_records?{q}').get('result') or [])
    payload={'type':typ,'name':name,'content':ip,'ttl':1,'proxied':False}
    if rows:
      rid=rows[0]['id']; call('PUT',f'/zones/{zone}/dns_records/{rid}',payload)
      for extra in rows[1:]: call('DELETE',f"/zones/{zone}/dns_records/{extra['id']}")
    else: call('POST',f'/zones/{zone}/dns_records',payload)

def main():
    ap=argparse.ArgumentParser(); sp=ap.add_subparsers(dest='cmd',required=True)
    p=sp.add_parser('verify'); p.add_argument('--zone',required=True)
    p=sp.add_parser('upsert'); p.add_argument('--zone',required=True); p.add_argument('--name',required=True); p.add_argument('--ip',required=True); p.add_argument('--type',default='A')
    args=ap.parse_args()
    try:
      if args.cmd=='verify':
        zid=zone_id(args.zone)
        print(json.dumps({'ok':True,'zone':args.zone,'zone_id':zid}))
      else:
        zid=zone_id(args.zone); upsert(zid,args.name,args.ip,args.type); print(json.dumps({'ok':True,'zone_id':zid,'name':args.name,'type':args.type}))
      return 0
    except Exception as e: print(f'cloudflare error: {e}',file=sys.stderr); return 2
if __name__=='__main__': raise SystemExit(main())
