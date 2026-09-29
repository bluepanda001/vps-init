#!/usr/bin/env python3
"""Small 3x-ui API helper used by vps-init.

The helper only talks to the loopback-only panel with a Bearer API token.
It never prints the token or Reality private key.
"""
from __future__ import annotations
import argparse, json, os, sys, urllib.error, urllib.request
from typing import Any


def req(base: str, token: str, method: str, path: str, body: Any | None = None) -> dict[str, Any]:
    data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    headers = {"Accept":"application/json", "Authorization":f"Bearer {token}", "User-Agent":"vps-init/1"}
    if data is not None: headers["Content-Type"]="application/json"
    r = urllib.request.Request(base.rstrip("/")+"/"+path.lstrip("/"), data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw=resp.read()
    except urllib.error.HTTPError as e:
        raw=e.read()
        raise RuntimeError(f"HTTP {e.code}: {raw[:400]!r}") from None
    try: out=json.loads(raw.decode())
    except Exception: raise RuntimeError(f"non-JSON response: {raw[:400]!r}") from None
    if not isinstance(out, dict): raise RuntimeError("unexpected response")
    if out.get("success") is False: raise RuntimeError(str(out.get("msg") or "3x-ui API failed"))
    return out


def get_obj(base: str, token: str, method: str, path: str, body: Any | None = None) -> Any:
    return req(base, token, method, path, body).get("obj")


def patch_settings(base: str, token: str, patch: dict[str, Any]) -> None:
    cur=get_obj(base,token,"POST","panel/api/setting/all")
    if not isinstance(cur,dict): raise RuntimeError("setting/all returned no object")
    cur.update(patch)
    req(base,token,"POST","panel/api/setting/update",cur)


def list_inbounds(base: str, token: str) -> list[dict[str, Any]]:
    obj=get_obj(base,token,"GET","panel/api/inbounds/list")
    if isinstance(obj,list): return [x for x in obj if isinstance(x,dict)]
    if isinstance(obj,dict):
        for k in ("inbounds","list"):
            if isinstance(obj.get(k),list): return [x for x in obj[k] if isinstance(x,dict)]
    return []


def select_target(base: str, token: str, mode: str, manual: str, candidates: str) -> tuple[str,str,dict[str,Any] | None]:
    if mode == "manual":
        target=manual.strip()
        if not target: raise RuntimeError("manual Reality target is empty")
        if ":" not in target: target += ":443"
        host=target.rsplit(":",1)[0].strip("[]")
        return target,host,None
    obj=get_obj(base,token,"POST","panel/api/server/scanRealityTargets",{"targets":candidates})
    rows=obj if isinstance(obj,list) else []
    feasible=[x for x in rows if isinstance(x,dict) and x.get("feasible") is True and not x.get("privateTarget")]
    if not feasible:
        summary=[{"target":x.get("target"),"feasible":x.get("feasible"),"reason":x.get("reason")} for x in rows if isinstance(x,dict)]
        raise RuntimeError("no feasible Reality target: "+json.dumps(summary,ensure_ascii=False))
    best=feasible[0]
    target=str(best.get("target") or "").strip()
    host=str(best.get("host") or "").strip()
    if not target or not host: raise RuntimeError("Reality scanner returned incomplete best result")
    return target,host,best


def create_reality(args: argparse.Namespace) -> dict[str,Any]:
    existing=next((x for x in list_inbounds(args.base,args.token) if x.get("remark")==args.remark),None)
    if existing:
        st=existing.get("streamSettings")
        if isinstance(st,str):
            try: st=json.loads(st)
            except Exception: st={}
        st=st if isinstance(st,dict) else {}
        rs=st.get("realitySettings") if isinstance(st.get("realitySettings"),dict) else {}
        target=str(rs.get("target") or rs.get("dest") or "")
        names=rs.get("serverNames") if isinstance(rs.get("serverNames"),list) else []
        client_side=rs.get("settings") if isinstance(rs.get("settings"),dict) else {}
        public_key=str(client_side.get("publicKey") or "")
        settings=existing.get("settings")
        if isinstance(settings,str):
            try: settings=json.loads(settings)
            except Exception: settings={}
        settings=settings if isinstance(settings,dict) else {}
        clients=settings.get("clients") if isinstance(settings.get("clients"),list) else []
        cl=clients[0] if clients and isinstance(clients[0],dict) else {}
        existing_id=existing.get("id")
        existing_listen=str(existing.get("listen") or "")
        existing_port=int(existing.get("port") or 0)
        if existing.get("protocol") != "vless":
            raise RuntimeError(f"existing {args.remark} is not VLESS; refusing automatic migration")
        migrated=False
        if existing_port != args.port or existing_listen != args.listen:
            sniffing=existing.get("sniffing")
            if isinstance(sniffing,str):
                try: sniffing=json.loads(sniffing)
                except Exception: sniffing={}
            payload={
              "enable":True,
              "remark":args.remark,
              "listen":args.listen,
              "port":args.port,
              "protocol":"vless",
              "expiryTime":int(existing.get("expiryTime") or 0),
              "total":int(existing.get("total") or 0),
              "settings":settings,
              "streamSettings":st,
              "sniffing":sniffing if isinstance(sniffing,dict) else {},
              "disableFlow":bool(existing.get("disableFlow") or False),
              "subSortIndex":int(existing.get("subSortIndex") or 1),
              "shareAddrStrategy":str(existing.get("shareAddrStrategy") or "node"),
              "shareAddr":str(existing.get("shareAddr") or "")
            }
            req(args.base,args.token,"POST",f"panel/api/inbounds/update/{existing_id}",payload)
            migrated=True
        if existing_id:
            fallbacks=[]
            if args.fallback:
                fallbacks=[{"childId":0,"name":"","alpn":"","path":"","dest":args.fallback,"xver":0,"sortOrder":0}]
            req(args.base,args.token,"POST",f"panel/api/inbounds/{existing_id}/fallbacks",{"fallbacks":fallbacks})
        return {"created":False,"migrated":migrated,"id":existing_id,"remark":args.remark,"message":"existing inbound kept",
                "target":target,"serverName":str(names[0]) if names else "","uuid":cl.get("id",""),
                "publicKey":public_key,"subId":cl.get("subId",""),"shortId":(rs.get("shortIds") or [""])[0] if isinstance(rs.get("shortIds"),list) else ""}
    target,host,scan=select_target(args.base,args.token,args.target_mode,args.target,args.candidates)
    uuid=get_obj(args.base,args.token,"GET","panel/api/server/getNewUUID")
    if isinstance(uuid,dict): uuid=uuid.get("uuid") or uuid.get("id")
    uuid=str(uuid or "").strip()
    kp=get_obj(args.base,args.token,"GET","panel/api/server/getNewX25519Cert")
    if not isinstance(kp,dict): raise RuntimeError("getNewX25519Cert failed")
    priv=str(kp.get("privateKey") or "").strip(); pub=str(kp.get("publicKey") or "").strip()
    if not uuid or not priv or not pub: raise RuntimeError("UUID/X25519 generation incomplete")
    short_id=args.short_id
    payload={
      "enable":True,"remark":args.remark,"listen":args.listen,"port":args.port,"protocol":"vless",
      "expiryTime":0,"total":0,
      "settings":{"clients":[{"id":uuid,"email":args.email,"flow":"xtls-rprx-vision","limitIp":0,"totalGB":0,"expiryTime":0,"enable":True,"tgId":0,"subId":args.sub_id,"comment":"","reset":0}],"decryption":"none","encryption":"none","fallbacks":[]},
      "streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":False,"xver":0,"target":target,"serverNames":[host],"privateKey":priv,"minClientVer":"","maxClientVer":"","maxTimediff":0,"shortIds":[short_id],"mldsa65Seed":"","settings":{"publicKey":pub,"fingerprint":"chrome","serverName":"","spiderX":"/","mldsa65Verify":""}},"tcpSettings":{"acceptProxyProtocol":False,"header":{"type":"none"}}},
      "sniffing":{"enabled":True,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":False,"routeOnly":False,"ipsExcluded":[],"domainsExcluded":[]}
    }
    req(args.base,args.token,"POST","panel/api/inbounds/add",payload)
    created=next((x for x in list_inbounds(args.base,args.token) if x.get("remark")==args.remark),None)
    inbound_id=created.get("id") if isinstance(created,dict) else None
    if args.fallback:
        if not inbound_id: raise RuntimeError("created inbound id unavailable for fallback setup")
        req(args.base,args.token,"POST",f"panel/api/inbounds/{inbound_id}/fallbacks",{"fallbacks":[{"childId":0,"name":"","alpn":"","path":"","dest":args.fallback,"xver":0,"sortOrder":0}]})
    return {"created":True,"id":inbound_id,
            "uuid":uuid,"publicKey":pub,"shortId":short_id,"subId":args.sub_id,
            "target":target,"serverName":host,"scan":scan}



def list_hosts(base: str, token: str) -> list[dict[str, Any]]:
    obj=get_obj(base,token,"GET","panel/api/hosts/list")
    return [x for x in obj if isinstance(x,dict)] if isinstance(obj,list) else []


def ensure_host(base: str, token: str, inbound_id: int, remark: str, address: str,
                port: int, sni: str, fingerprint: str) -> dict[str,Any]:
    body={
      "inboundIds":[inbound_id],
      "remark":remark,
      "hosts":[f"{address}:{port}"],
      "port":port,
      "security":"same",
      "sni":sni,
      "fingerprint":fingerprint,
    }
    existing=next((x for x in list_hosts(base,token) if x.get("remark")==remark),None)
    if existing and existing.get("groupId"):
        obj=get_obj(base,token,"POST",f"panel/api/hosts/update/{existing['groupId']}",body)
        return {"created":False,"groupId":existing["groupId"],"rows":obj}
    obj=get_obj(base,token,"POST","panel/api/hosts/add",body)
    group_id=""
    if isinstance(obj,list) and obj and isinstance(obj[0],dict):
        group_id=str(obj[0].get("groupId") or "")
    return {"created":True,"groupId":group_id,"rows":obj}


def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument("--base",required=True); ap.add_argument("--token",required=True)
    sp=ap.add_subparsers(dest="cmd",required=True)
    p=sp.add_parser("patch-settings"); p.add_argument("--json",required=True)
    p=sp.add_parser("scan"); p.add_argument("--candidates",required=True)
    p=sp.add_parser("create-reality")
    p.add_argument("--remark",default="VPSINIT-Reality"); p.add_argument("--listen",required=True); p.add_argument("--port",type=int,required=True)
    p.add_argument("--email",required=True); p.add_argument("--sub-id",required=True); p.add_argument("--short-id",required=True)
    p.add_argument("--target-mode",choices=["auto","manual"],required=True); p.add_argument("--target",default=""); p.add_argument("--candidates",default="")
    p.add_argument("--fallback",default="")
    sp.add_parser("list-inbounds")
    sp.add_parser("list-hosts")
    p=sp.add_parser("ensure-host")
    p.add_argument("--inbound-id",type=int,required=True)
    p.add_argument("--remark",required=True)
    p.add_argument("--address",required=True)
    p.add_argument("--port",type=int,required=True)
    p.add_argument("--sni",default="")
    p.add_argument("--fingerprint",default="chrome")
    sp.add_parser("all-links")
    args=ap.parse_args()
    try:
      if args.cmd=="patch-settings": patch_settings(args.base,args.token,json.loads(args.json)); out={"ok":True}
      elif args.cmd=="scan": out=get_obj(args.base,args.token,"POST","panel/api/server/scanRealityTargets",{"targets":args.candidates})
      elif args.cmd=="create-reality": out=create_reality(args)
      elif args.cmd=="list-inbounds": out=list_inbounds(args.base,args.token)
      elif args.cmd=="list-hosts": out=list_hosts(args.base,args.token)
      elif args.cmd=="ensure-host": out=ensure_host(args.base,args.token,args.inbound_id,args.remark,args.address,args.port,args.sni,args.fingerprint)
      elif args.cmd=="all-links": out=get_obj(args.base,args.token,"GET","panel/api/inbounds/allLinks")
      else: raise RuntimeError("unknown command")
      print(json.dumps(out,ensure_ascii=False,separators=(",",":")))
      return 0
    except Exception as e:
      print(f"xui_api error: {e}",file=sys.stderr); return 2
if __name__=="__main__": raise SystemExit(main())
