#!/usr/bin/env python3
from __future__ import annotations
import importlib.util,json,tempfile
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location("merge_daemon",ROOT/"optional/docker/merge_daemon.py")
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

def write_cfg(data):
    td=tempfile.TemporaryDirectory()
    p=Path(td.name)/"daemon.json"
    p.write_text(json.dumps(data),encoding="utf-8")
    return td,p

def test_preserve_custom_docker_fields():
    original={
      "data-root":"/mnt/docker-data",
      "registry-mirrors":["https://mirror.example"],
      "bip":"172.30.0.1/16",
      "runtimes":{"nvidia":{"path":"nvidia-container-runtime"}},
      "log-driver":"local",
      "log-opts":{"max-size":"99m"}
    }
    td,p=write_cfg(original)
    try:
        out=m.merge_config(p)
    finally:
        td.cleanup()
    assert out==original

def test_fill_missing_json_file_rotation_only():
    original={
      "data-root":"/mnt/docker-data",
      "registry-mirrors":["https://mirror.example"],
      "log-driver":"json-file",
      "log-opts":{"max-size":"50m"}
    }
    td,p=write_cfg(original)
    try:
        out=m.merge_config(p)
    finally:
        td.cleanup()
    assert out["data-root"]=="/mnt/docker-data"
    assert out["registry-mirrors"]==["https://mirror.example"]
    assert out["log-opts"]["max-size"]=="50m"
    assert out["log-opts"]["max-file"]=="3"

def test_add_defaults_without_overwriting():
    original={"data-root":"/srv/docker"}
    td,p=write_cfg(original)
    try:
        out=m.merge_config(p)
    finally:
        td.cleanup()
    assert out["data-root"]=="/srv/docker"
    assert out["log-driver"]=="json-file"
    assert out["log-opts"]=={"max-size":"10m","max-file":"3"}

def test_non_object_config_rejected():
    td,p=write_cfg(["bad"])
    try:
        try:
            m.merge_config(p)
        except ValueError:
            pass
        else:
            raise AssertionError("non-object daemon config accepted")
    finally:
        td.cleanup()

if __name__=="__main__":
    test_preserve_custom_docker_fields()
    test_fill_missing_json_file_rotation_only()
    test_add_defaults_without_overwriting()
    test_non_object_config_rejected()
    print("DOCKER_MERGE_OK")
