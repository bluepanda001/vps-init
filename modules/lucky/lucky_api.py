#!/usr/bin/env python3
"""Lucky v2.27.2 loopback automation helper for vps-init."""
from __future__ import annotations
import argparse,base64,json,sys,urllib.error,urllib.parse,urllib.request
from pathlib import Path


def request(base,method,path,token='',body=None,query=None):
    if query: path += ('&' if '?' in path else '?')+urllib.parse.urlencode(query)
    data=None if body is None else json.dumps(body,separators=(',',':')).encode()
    h={'Accept':'application/json','User-Agent':'vps-init/1'}
    if token: h['Authorization']=token
    if data is not None: h['Content-Type']='application/json'
    r=urllib.request.Request(base.rstrip('/')+path,data=data,headers=h,method=method)
    try:
      with urllib.request.urlopen(r,timeout=20) as resp: raw=resp.read()
    except urllib.error.HTTPError as e: raise RuntimeError(f'HTTP {e.code}: {e.read()[:400]!r}') from None
    try: out=json.loads(raw.decode())
    except Exception: raise RuntimeError(f'non-json: {raw[:300]!r}') from None
    if not isinstance(out,dict) or out.get('ret') != 0: raise RuntimeError(str(out.get('msg') if isinstance(out,dict) else out))
    return out

def login(base,user,password): return request(base,'POST','/api/login',body={'Account':user,'Password':password})['token']

def subrule(domain,location,remark):
    return {'Enable':True,'Key':'','Remark':remark,'Domains':[domain],'Locations':[location],
      'EnableAccessLog':True,'LogLevel':4,'LogOutputToConsole':False,'AccessLogMaxNum':1000,'WebListShowLastLogMaxCount':10,
      'RequestInfoLogFormat':'[#{clientIP}][#{remoteIP}]#{tab}[#{method}][#{host}#{url}]','ForwardedByClientIP':False,
      'TrustedCIDRsStrList':[],'RemoteIPHeaders':[],'AddRemoteIPToHeader':False,'AddRemoteIPHeaderKey':'',
      'EnableBasicAuth':False,'BasicAuthUser':'','BasicAuthPasswd':'','SafeIPMode':'blacklist','SafeUserAgentMode':'blacklist',
      'UserAgentfilter':[],'CustomRobotTxt':False,'RobotTxt':'User-agent: *\nDisallow: /'}

def default_proxy(location):
    return {'Key':'default','Locations':[location] if location else [],'EnableAccessLog':True,'LogLevel':4,'LogOutputToConsole':False,
      'AccessLogMaxNum':500,'WebListShowLastLogMaxCount':10,'RequestInfoLogFormat':'[#{clientIP}][#{remoteIP}]#{tab}[#{method}][#{host}#{url}]',
      'ForwardedByClientIP':False,'TrustedCIDRsStrList':[],'RemoteIPHeaders':[],'AddRemoteIPToHeader':False,'AddRemoteIPHeaderKey':'',
      'EnableBasicAuth':False,'BasicAuthUser':'','BasicAuthPasswd':'','SafeIPMode':'blacklist','SafeUserAgentMode':'blacklist','UserAgentfilter':[],
      'CustomRobotTxt':False,'RobotTxt':'User-agent: *\nDisallow: /'}

def sync_cert(base,token,cert,key,remark='vps-init-wildcard'):
    rows=request(base,'GET','/api/ssl',token).get('list') or []
    for row in rows:
      if isinstance(row,dict) and row.get('Remark')==remark and row.get('Key'):
        request(base,'DELETE','/api/ssl',token,query={'key':row['Key']})
    cert_b64=base64.b64encode(Path(cert).read_bytes()).decode(); key_b64=base64.b64encode(Path(key).read_bytes()).decode()
    request(base,'POST','/api/ssl',token,body={'Key':'','Enable':True,'Remark':remark,'CertBase64':cert_b64,'KeyBase64':key_b64,'AddTime':''})

def configure_rule(base,token,panel_domain,node_domain,panel_port,sub_port,landing_port):
    name='vps-init-https'
    rows=request(base,'GET','/api/reverseproxyrules',token).get('list') or []
    for row in rows:
      if isinstance(row,dict) and row.get('RuleName')==name and row.get('RuleKey'):
        request(base,'DELETE','/api/reverseproxyrule',token,query={'key':row['RuleKey']})
    body={'RuleName':name,'RuleKey':'','Enable':True,'Network':'tcp4','ListenIP':'127.0.0.1','ListenPort':8443,'EnableTLS':True,
          'DefaultProxy':default_proxy(f'http://127.0.0.1:{landing_port}'),
          'ProxyList':[subrule(panel_domain,f'http://127.0.0.1:{panel_port}','3x-ui-panel'),subrule(node_domain,f'http://127.0.0.1:{sub_port}','subscription')]}
    request(base,'POST','/api/reverseproxyrule',token,body=body)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--base',default='http://127.0.0.1:16601')
    ap.add_argument('--user')
    ap.add_argument('--password')
    sp=ap.add_subparsers(dest='cmd',required=True)
    p=sp.add_parser('set-admin'); p.add_argument('--new-user',required=True); p.add_argument('--new-password',required=True)
    p=sp.add_parser('sync-cert'); p.add_argument('--cert',required=True); p.add_argument('--key',required=True)
    p=sp.add_parser('configure-web'); p.add_argument('--panel-domain',required=True); p.add_argument('--node-domain',required=True); p.add_argument('--panel-port',type=int,required=True); p.add_argument('--sub-port',type=int,required=True); p.add_argument('--landing-port',type=int,default=18080)
    sp.add_parser('status')
    a=ap.parse_args()
    try:
      if not a.user or not a.password:
        raise RuntimeError('--user and --password are required for this command')
      tok=login(a.base,a.user,a.password)
      if a.cmd=='set-admin':
        cfg=request(a.base,'GET','/api/baseconfigure',tok)['baseconfigure']; cfg['AdminAccount']=a.new_user; cfg['AdminPassword']=a.new_password; cfg['AllowInternetaccess']=False
        request(a.base,'PUT','/api/baseconfigure',tok,body=cfg); print(json.dumps({'ok':True}))
      elif a.cmd=='sync-cert': sync_cert(a.base,tok,a.cert,a.key); print(json.dumps({'ok':True}))
      elif a.cmd=='configure-web': configure_rule(a.base,tok,a.panel_domain,a.node_domain,a.panel_port,a.sub_port,a.landing_port); print(json.dumps({'ok':True}))
      else: print(json.dumps(request(a.base,'GET','/api/status',tok),separators=(',',':')))
      return 0
    except Exception as e: print(f'lucky_api error: {e}',file=sys.stderr); return 2
if __name__=='__main__': raise SystemExit(main())
