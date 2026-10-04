#!/usr/bin/env python3
from __future__ import annotations
import copy,importlib.util
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location("lucky_api",ROOT/"modules/lucky/lucky_api.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def managed_web_rule():
    row=m._rule_template("vps-init-web-only","0.0.0.0",443,18080)
    row["RuleKey"]="rule-old"
    row["GlobalBasicAuthUserList"]="alice:custom"
    row["CorazaWAFInstance"]="user-waf"
    user=m.subrule("ql.example.com","http://127.0.0.1:5700","user-qinglong")
    user["Key"]="proxy-user"
    user["EnableBasicAuth"]=True
    user["BasicAuthUser"]="alice"
    user["BasicAuthPasswd"]="secret-hash"
    admin=m.subrule("lucky.example.com","http://127.0.0.1:16601","lucky-admin")
    admin["Key"]="proxy-managed"
    row["ProxyList"]=[admin,user]
    return row

def test_preserve_user_rule_and_auth():
    existing=managed_web_rule()
    posted=[]
    def fake(base,method,path,token="",body=None,query=None):
        if method=="GET":
            return {"ruleList":[copy.deepcopy(existing)]}
        if method=="DELETE":
            return {"ok":True}
        if method=="POST":
            posted.append(copy.deepcopy(body)); return {"ok":True}
        raise AssertionError((method,path))
    old=m.request; m.request=fake
    try:
        m.configure_web_only("http://x","tok","lucky.example.com",18080)
    finally:
        m.request=old
    assert len(posted)==1
    body=posted[0]
    assert body["GlobalBasicAuthUserList"]=="alice:custom"
    assert body["CorazaWAFInstance"]=="user-waf"
    users=[p for p in body["ProxyList"] if p.get("Remark")=="user-qinglong"]
    assert len(users)==1
    assert users[0]["Domains"]==["ql.example.com"]
    assert users[0]["EnableBasicAuth"] is True
    assert users[0]["BasicAuthUser"]=="alice"
    assert len([p for p in body["ProxyList"] if p.get("Remark")=="lucky-admin"])==1

def test_profile_switch_preserves_user_proxy():
    existing=managed_web_rule()
    posted=[]
    def fake(base,method,path,token="",body=None,query=None):
        if method=="GET": return {"ruleList":[copy.deepcopy(existing)]}
        if method=="DELETE": return {"ok":True}
        if method=="POST": posted.append(copy.deepcopy(body)); return {"ok":True}
        raise AssertionError((method,path))
    old=m.request; m.request=fake
    try:
        m.configure_rule("http://x","tok","xui.example.com","node.example.com",34556,2096,18080)
    finally:
        m.request=old
    body=posted[0]
    assert body["RuleName"]=="vps-init-https"
    remarks=[p.get("Remark") for p in body["ProxyList"]]
    assert "user-qinglong" in remarks
    assert "lucky-admin" not in remarks
    assert "3x-ui-panel" in remarks
    assert "subscription" in remarks

def test_failed_replacement_restores_original():
    existing=managed_web_rule()
    posts=[]; first=True
    def fake(base,method,path,token="",body=None,query=None):
        nonlocal first
        if method=="GET": return {"ruleList":[copy.deepcopy(existing)]}
        if method=="DELETE": return {"ok":True}
        if method=="POST":
            posts.append(copy.deepcopy(body))
            if first:
                first=False
                raise RuntimeError("simulated add failure")
            return {"ok":True}
        raise AssertionError((method,path))
    old=m.request; m.request=fake
    try:
        try:
            m.configure_web_only("http://x","tok","lucky.example.com",18080)
        except RuntimeError as e:
            assert "original rule was restored" in str(e)
        else:
            raise AssertionError("replacement failure did not propagate")
    finally:
        m.request=old
    assert len(posts)==2
    assert posts[1]==existing

def test_cert_upload_happens_before_old_delete():
    events=[]
    before=[{"Key":"old-cert","Remark":"vps-init-wildcard"}]
    after=before+[{"Key":"new-cert","Remark":"vps-init-wildcard"}]
    gets=0
    def fake(base,method,path,token="",body=None,query=None):
        nonlocal gets
        if method=="GET":
            gets+=1
            return {"list":copy.deepcopy(before if gets==1 else after)}
        if method=="POST":
            events.append(("POST",path)); return {"ok":True}
        if method=="DELETE":
            events.append(("DELETE",query["key"])); return {"ok":True}
        raise AssertionError((method,path))
    old_req=m.request; old_val=m._validated_cert_pair
    m.request=fake; m._validated_cert_pair=lambda c,k:(b"cert",b"key")
    try:
        m.sync_cert("http://x","tok","unused-cert","unused-key")
    finally:
        m.request=old_req; m._validated_cert_pair=old_val
    assert events==[("POST","/api/ssl"),("DELETE","old-cert")]

def test_invalid_cert_never_touches_api():
    calls=[]
    old_req=m.request; old_val=m._validated_cert_pair
    m.request=lambda *a,**k: calls.append((a,k))
    m._validated_cert_pair=lambda c,k: (_ for _ in ()).throw(RuntimeError("bad cert"))
    try:
        try:
            m.sync_cert("http://x","tok","bad","bad")
        except RuntimeError:
            pass
        else:
            raise AssertionError("invalid certificate unexpectedly accepted")
    finally:
        m.request=old_req; m._validated_cert_pair=old_val
    assert calls==[]

if __name__=="__main__":
    test_preserve_user_rule_and_auth()
    test_profile_switch_preserves_user_proxy()
    test_failed_replacement_restores_original()
    test_cert_upload_happens_before_old_delete()
    test_invalid_cert_never_touches_api()
    print("LUCKY_BEHAVIOR_OK")
