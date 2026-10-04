#!/usr/bin/env python3
"""Lucky v2.27.2 loopback automation helper for vps-init."""
from __future__ import annotations
import argparse,base64,copy,json,subprocess,sys,time,urllib.error,urllib.parse,urllib.request
from pathlib import Path


def lucky_nonce() -> str:
    # Lucky 2.27.2's current web client appends a decisecond timestamp plus
    # a one-digit checksum to every API request. Requests without it may be
    # rejected as bad credentials even when the account/password are correct.
    base=str(int(time.time()*1000))[:-1]
    return base+str(sum(int(ch) for ch in base)%8)

def request(base,method,path,token='',body=None,query=None):
    q=dict(query or {})
    q['_']=lucky_nonce()
    path += ('&' if '?' in path else '?')+urllib.parse.urlencode(q)
    data=None if body is None else json.dumps(body,separators=(',',':')).encode()
    h={'Accept':'application/json','User-Agent':'vps-init/1'}
    if token: h['Lucky-Admin-Token']=token
    if data is not None: h['Content-Type']='application/json'
    r=urllib.request.Request(base.rstrip('/')+path,data=data,headers=h,method=method)
    try:
      with urllib.request.urlopen(r,timeout=20) as resp: raw=resp.read()
    except urllib.error.HTTPError as e: raise RuntimeError(f'HTTP {e.code}: {e.read()[:400]!r}') from None
    try: out=json.loads(raw.decode())
    except Exception: raise RuntimeError(f'non-json: {raw[:300]!r}') from None
    if not isinstance(out,dict) or out.get('ret') != 0: raise RuntimeError(str(out.get('msg') if isinstance(out,dict) else out))
    return out

def login(base,user,password): return request(base,'POST','/api/login',body={'Account':user,'Password':password,'TwoFA':''})['token']

def proxy_common(location=None):
    return {
      'WebServiceType':'reverseproxy','CorazaWAFInstance':'',
      'Locations':[] if location is None else [location],
      'LocationInsecureSkipVerify':False,
      'EnableAccessLog':False,'LogLevel':4,'LogOutputToConsole':False,
      'AccessLogMaxNum':256,'WebListShowLastLogMaxCount':10,
      'RequestInfoLogFormat':'[#{clientIP}][#{remoteIP}]#{tab}[#{method}][#{host}#{url}]',
      'ForwardedByClientIP':False,'TrustedCIDRsStrList':[],
      'UseRuleGlobalAuthSettings':True,'UseTargetHost':False,'DisableLongConnection':False,
      'CustomCrossDomain':'','CustomCrossMethods':'',
      'RemoteIPHeaders':['X-Forwarded-For','X-Real-IP'],
      'AddRemoteIPToHeader':False,'AddRemoteIPHeaderKey':'',
      'EnableCrossDomain':False,'EnableBasicAuth':False,'BasicAuthRegConf':'',
      'BasicAuthUser':'','BasicAuthPasswd':'','BasicAuthUserList':'',
      'BasicAuthMaxLoginErrorCount':0,
      'SafeIPMode':'blacklist','SafeUserAgentMode':'blacklist','UserAgentfilter':[''],
      'CustomRobotTxt':False,'RobotTxt':'User-agent:  *\nDisallow:  /',
      'AddProtoToHeader':False,'ProtoHeaderKey':'','EasyLucky':False,
      'FileServerShowDir':True,'CacheBodyOnlyPath':'',
      'FileServerIndexNames':'index.html\n','FileServerHideFiles':'',
      'FileServerForbiddenPaths':'','FileServerMountList':[],
      'fileServerCollapsectiveName':0,'NginxConf':'','CustomOutputText':'',
      'DisableHTTP3':False,'MaxContinuous404Count':0,'MaxCorazaInterceptionCount':0,
      'HttpClientNetwork':'tcp','DisableKeepAlives':True,'HttpClientTimeout':10,
      'ProxyType':'','ProxyAddr':'','ProxyUser':'','ProxyPassword':'',
      'AutoProxyLocation':False,'AutoProxyLocationWithoutSameHost':False,
      'CacheEnabled':False,'CachePath':'','CacheKey':'','CacheLimit':0,
      'CacheBodyMinLimit':0,'CacheBodyMaxLimit':0,'CacheOnlyKeyReg':'',
      'CacheValidityPeriod':0,'DealCacheBeforeReverseProxy':True,
      'GRPCSecureConnection':False,'CertificateSyncToken':'',
      'OtherParams':{
        'ProxyProtocolV2':True,'SpeedTestFrontSource':'','OauthType':'github',
        'OauthClientID':'','OauthClientSecret':'','OauthClientKey':'',
        'OauthRedirectURI':'','OauthServer':'','HttpClientProxyType':'',
        'HttpClientProxyAddr':'','HttpClientProxyUser':'','HttpClientProxyPassword':'',
        'WebAuth':False,'AllowAllThirdAuthUsers':False,'AllowThirdUserList':[],
        'AllowThirdUserSkipTwoFA':False
      }
    }

def subrule(domain,location,remark):
    row=proxy_common(location)
    row.update({'Enable':True,'Key':'','Remark':remark,'GroupKey':'','Domains':[domain]})
    return row

def default_proxy(location):
    row=proxy_common(location)
    row.update({'Key':'default'})
    return row

def _validated_cert_pair(cert,key):
    cert_path=Path(cert); key_path=Path(key)
    if not cert_path.is_file() or cert_path.stat().st_size == 0:
      raise RuntimeError(f'certificate missing/empty: {cert}')
    if not key_path.is_file() or key_path.stat().st_size == 0:
      raise RuntimeError(f'private key missing/empty: {key}')

    def run(*args):
      p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
      if p.returncode != 0:
        raise RuntimeError(f'openssl failed: {args}: {p.stderr[:300]!r}')
      return p.stdout

    run('openssl','x509','-in',str(cert_path),'-noout','-checkend','86400')
    cert_pub=run('openssl','x509','-in',str(cert_path),'-pubkey','-noout')
    key_pub=run('openssl','pkey','-in',str(key_path),'-pubout')
    if cert_pub != key_pub:
      raise RuntimeError('certificate/private key mismatch')
    return cert_path.read_bytes(),key_path.read_bytes()

def sync_cert(base,token,cert,key,remark='vps-init-wildcard'):
    # Validate new material before touching Lucky. Add and confirm the new
    # certificate first; only then remove the previous managed copies.
    cert_raw,key_raw=_validated_cert_pair(cert,key)
    before=request(base,'GET','/api/ssl',token).get('list') or []
    old=[row for row in before if isinstance(row,dict) and row.get('Remark')==remark and row.get('Key')]
    before_keys={str(row.get('Key')) for row in before if isinstance(row,dict) and row.get('Key')}

    request(base,'POST','/api/ssl',token,body={
      'Key':'','MappingToPath':False,'MappingPath':'','MappingChangeScript':'',
      'Enable':True,'Remark':remark,
      'CertBase64':base64.b64encode(cert_raw).decode(),
      'KeyBase64':base64.b64encode(key_raw).decode(),
      'IssuerCertificate':'','AddFrom':'file','ExtParams':{},
      'AllSyncClient':False,'SyncClientList':[]
    })

    after=request(base,'GET','/api/ssl',token).get('list') or []
    new=[row for row in after
         if isinstance(row,dict) and row.get('Remark')==remark and row.get('Key')
         and str(row.get('Key')) not in before_keys]
    if not new and not (not old and any(isinstance(row,dict) and row.get('Remark')==remark for row in after)):
      raise RuntimeError('new Lucky certificate was not confirmed after upload')

    for row in old:
      request(base,'DELETE','/api/ssl',token,query={'key':row['Key']})

MANAGED_RULE_NAMES={'vps-init-web-only','vps-init-https'}
MANAGED_PROXY_REMARKS={'lucky-admin','3x-ui-panel','subscription'}

def _rule_template(name,listen_ip,listen_port,landing_port):
    return {
      'RuleName':name,'RuleKey':'','DiaglogShowMode':'simple','Enable':True,
      'Network':'tcp4','CorazaWAFInstance':'','ListenIP':listen_ip,'ListenPort':listen_port,
      'AutoOptionsFirewall':False,'EnableTLS':True,'TLSMinVersion':2,
      'MaxHeaderKBytes':32,'IPFilterRule':'disable',
      'MaxContinuous404Count':0,'MaxCorazaInterceptionCount':0,
      'SendRateLimitEnabled':False,'SendRateLimit':0,
      'ReceRateLimitEnabled':False,'ReceRateLimit':0,
      'SingleConnSendRateLimitEnabled':False,'SingleConnSendRateLimit':0,
      'SingleConnReceRateLimitEnabled':False,'SingleConnReceRateLimit':0,
      'GlobalAllowAllThirdAuthUsers':False,'GlobalThirdAuthLoginUserList':[],
      'GlobalAllowThirdUserSkipTwoFA':False,
      'SingleIPSendRateLimitEnabled':False,'SingleIPSendRateLimit':0,
      'SingleIPReceRateLimitEnabled':False,'SingleIPReceRateLimit':0,
      'Http3':False,'GlobalBasicAuthUserList':'','ECH':False,'ECHDomain':'',
      'ECDHPrivateKey':'','ECHConfigList':'',
      'DefaultProxy':default_proxy(f'http://127.0.0.1:{landing_port}'),
      'ProxyList':[]
    }

def _dedupe_user_proxy_rules(managed_rows):
    out=[]; seen=set()
    for row in managed_rows:
      for proxy in row.get('ProxyList') or []:
        if not isinstance(proxy,dict) or proxy.get('Remark') in MANAGED_PROXY_REMARKS:
          continue
        ident=proxy.get('Key') or json.dumps({
          'Domains':proxy.get('Domains') or [],
          'Locations':proxy.get('Locations') or [],
          'Remark':proxy.get('Remark','')
        },sort_keys=True,ensure_ascii=False)
        if ident in seen: continue
        seen.add(ident)
        out.append(copy.deepcopy(proxy))
    return out

def _merged_rule(rows,name,listen_ip,listen_port,landing_port,managed_proxies):
    managed_rows=[r for r in rows if isinstance(r,dict) and r.get('RuleName') in MANAGED_RULE_NAMES]
    preferred=next((r for r in managed_rows if r.get('RuleName')==name),None)
    existing=preferred or (managed_rows[0] if managed_rows else None)
    body=_rule_template(name,listen_ip,listen_port,landing_port)

    # Preserve user-tunable top-level settings already known by the rule schema
    # (auth, WAF, limits, HTTP3, etc.). Only vps-init-owned transport/routing
    # fields are overwritten below.
    if existing:
      owned={'RuleName','RuleKey','ListenIP','ListenPort','EnableTLS','TLSMinVersion','DefaultProxy','ProxyList','Enable'}
      for key in list(body):
        if key not in owned and key in existing:
          body[key]=copy.deepcopy(existing[key])
      body['RuleKey']=existing.get('RuleKey','')
      # Preserve a user-changed default proxy. Replace it only when absent.
      if isinstance(existing.get('DefaultProxy'),dict) and existing['DefaultProxy'].get('Locations'):
        body['DefaultProxy']=copy.deepcopy(existing['DefaultProxy'])

    body['RuleName']=name
    body['Enable']=True
    body['ListenIP']=listen_ip
    body['ListenPort']=listen_port
    body['EnableTLS']=True
    body['TLSMinVersion']=max(2,int(body.get('TLSMinVersion') or 2))
    body['ProxyList']=_dedupe_user_proxy_rules(managed_rows)+managed_proxies
    return managed_rows,body

def _replace_managed_rule(base,token,body,old_rows):
    # Current Lucky API uses delete+add for this automation path. Keep the
    # complete old managed rows in memory and restore them if the new write
    # fails, so a rerun cannot silently destroy user configuration.
    deleted=[]
    try:
      for row in old_rows:
        key=row.get('RuleKey')
        if key:
          request(base,'DELETE','/api/webservice/rule/'+str(key),token)
          deleted.append(row)
      request(base,'POST','/api/webservice/rules',token,body=body)
    except Exception as primary:
      restore_errors=[]
      for row in deleted:
        try: request(base,'POST','/api/webservice/rules',token,body=row)
        except Exception as e: restore_errors.append(str(e))
      if restore_errors:
        raise RuntimeError(f'Lucky rule update failed: {primary}; rollback also failed: {restore_errors}') from None
      raise RuntimeError(f'Lucky rule update failed and original rule was restored: {primary}') from None

def configure_web_only(base,token,lucky_domain,landing_port):
    rows=request(base,'GET','/api/webservice/rules',token).get('ruleList') or []
    old_rows,body=_merged_rule(
      rows,'vps-init-web-only','0.0.0.0',443,landing_port,
      [subrule(lucky_domain,'http://127.0.0.1:16601','lucky-admin')]
    )
    _replace_managed_rule(base,token,body,old_rows)

def configure_rule(base,token,panel_domain,node_domain,panel_port,sub_port,landing_port):
    rows=request(base,'GET','/api/webservice/rules',token).get('ruleList') or []
    old_rows,body=_merged_rule(
      rows,'vps-init-https','127.0.0.1',8443,landing_port,
      [
        subrule(panel_domain,f'http://127.0.0.1:{panel_port}','3x-ui-panel'),
        subrule(node_domain,f'http://127.0.0.1:{sub_port}','subscription')
      ]
    )
    _replace_managed_rule(base,token,body,old_rows)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--base',default='http://127.0.0.1:16601')
    ap.add_argument('--user')
    ap.add_argument('--password')
    sp=ap.add_subparsers(dest='cmd',required=True)
    p=sp.add_parser('set-admin'); p.add_argument('--new-user',required=True); p.add_argument('--new-password',required=True)
    p=sp.add_parser('sync-cert'); p.add_argument('--cert',required=True); p.add_argument('--key',required=True)
    p=sp.add_parser('configure-web'); p.add_argument('--panel-domain',required=True); p.add_argument('--node-domain',required=True); p.add_argument('--panel-port',type=int,required=True); p.add_argument('--sub-port',type=int,required=True); p.add_argument('--landing-port',type=int,default=18080)
    p=sp.add_parser('configure-web-only'); p.add_argument('--lucky-domain',required=True); p.add_argument('--landing-port',type=int,default=18080)
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
      elif a.cmd=='configure-web-only': configure_web_only(a.base,tok,a.lucky_domain,a.landing_port); print(json.dumps({'ok':True}))
      else: print(json.dumps(request(a.base,'GET','/api/status',tok),separators=(',',':')))
      return 0
    except Exception as e: print(f'lucky_api error: {e}',file=sys.stderr); return 2
if __name__=='__main__': raise SystemExit(main())
