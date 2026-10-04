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

def _patch_cert(fp):
    old_req,old_val,old_fp=m.request,m._validated_cert_pair,m._cert_sha256
    m._validated_cert_pair=lambda c,k:(b"cert",b"key")
    m._cert_sha256=lambda cert:(fp)
    return old_req,old_val,old_fp

def _restore_cert(old_req,old_val,old_fp):
    m.request,m._validated_cert_pair,m._cert_sha256=old_req,old_val,old_fp

def test_same_certificate_is_not_uploaded_again():
    events=[]
    fp="a"*64
    before=[{"Key":"old-cert","Remark":"vps-init-wildcard","CertsInfo":{"SHA256":fp.upper()}}]
    def fake(base,method,path,token="",body=None,query=None):
        events.append(method)
        if method=="GET": return {"list":copy.deepcopy(before)}
        raise AssertionError(method)
    old=_patch_cert(fp); m.request=fake
    try:
        m.sync_cert("http://x","tok","unused-cert","unused-key")
    finally:
        _restore_cert(*old)
    assert events==["GET"]

def test_changed_certificate_is_confirmed_before_old_delete():
    events=[]; posted=[]
    old_fp="a"*64; new_fp="b"*64
    before=[{"Key":"old-cert","Remark":"vps-init-wildcard","CertsInfo":{"SHA256":old_fp}}]
    def fake(base,method,path,token="",body=None,query=None):
        if method=="GET":
            if not posted:
                return {"list":copy.deepcopy(before)}
            return {"list":before+[{
                "Key":"new-cert","Remark":posted[-1]["Remark"],"CertsInfo":{"SHA256":new_fp}
            }]}
        if method=="POST":
            posted.append(copy.deepcopy(body))
            events.append(("POST",body["Remark"]))
            if body["Remark"]=="vps-init-wildcard":
                raise RuntimeError("CertificateRemarkNameConflict")
            return {"ok":True}
        if method=="DELETE":
            events.append(("DELETE",query["key"])); return {"ok":True}
        raise AssertionError(method)
    old=_patch_cert(new_fp); m.request=fake
    try:
        m.sync_cert("http://x","tok","unused-cert","unused-key")
    finally:
        _restore_cert(*old)
    assert events[0][0]=="POST"
    assert events[0][1]==f"vps-init-wildcard-{new_fp[:12]}"
    assert events[-1]==("DELETE","old-cert")

def test_failed_certificate_upload_keeps_old_certificate():
    deletes=[]
    before=[{"Key":"old-cert","Remark":"vps-init-wildcard","CertsInfo":{"SHA256":"a"*64}}]
    def fake(base,method,path,token="",body=None,query=None):
        if method=="GET": return {"list":copy.deepcopy(before)}
        if method=="POST": raise RuntimeError("simulated post failure")
        if method=="DELETE": deletes.append(query["key"]); return {"ok":True}
        raise AssertionError(method)
    old=_patch_cert("b"*64); m.request=fake
    try:
        try:
            m.sync_cert("http://x","tok","unused-cert","unused-key")
        except RuntimeError as exc:
            assert "simulated post failure" in str(exc)
        else:
            raise AssertionError("upload failure did not propagate")
    finally:
        _restore_cert(*old)
    assert deletes==[]

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
    test_same_certificate_is_not_uploaded_again()
    test_changed_certificate_is_confirmed_before_old_delete()
    test_failed_certificate_upload_keeps_old_certificate()
    test_invalid_cert_never_touches_api()
    print("LUCKY_BEHAVIOR_OK")
