#!/usr/bin/env python3
from __future__ import annotations
import argparse,json
from pathlib import Path

def merge_config(src: Path | None) -> dict:
    if src is None or not src.exists():
        cfg={}
    else:
        cfg=json.loads(src.read_text(encoding='utf-8'))
        if not isinstance(cfg,dict):
            raise ValueError('daemon.json root must be an object')

    driver=cfg.get('log-driver')
    if driver is None:
        cfg['log-driver']='json-file'
        opts=cfg.setdefault('log-opts',{})
        if not isinstance(opts,dict):
            raise ValueError('log-opts must be an object')
        opts.setdefault('max-size','10m')
        opts.setdefault('max-file','3')
    elif driver == 'json-file':
        opts=cfg.setdefault('log-opts',{})
        if not isinstance(opts,dict):
            raise ValueError('log-opts must be an object')
        opts.setdefault('max-size','10m')
        opts.setdefault('max-file','3')
    return cfg

def main() -> int:
    ap=argparse.ArgumentParser()
    ap.add_argument('--input')
    ap.add_argument('--output',required=True)
    a=ap.parse_args()
    src=Path(a.input) if a.input else None
    out=Path(a.output)
    cfg=merge_config(src)
    out.write_text(json.dumps(cfg,ensure_ascii=False,indent=2,sort_keys=True)+'\n',encoding='utf-8')
    return 0

if __name__=='__main__':
    raise SystemExit(main())
