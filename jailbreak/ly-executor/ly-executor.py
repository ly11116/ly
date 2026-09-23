#!/usr/bin/env python3
import json, os, shlex, subprocess, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST='127.0.0.1'; PORT=int(os.environ.get('LY_EXECUTOR_PORT','8765'))
LOG=Path('/var/mobile/Library/Logs/ly-executor.jsonl')
ALLOW={'pwd','id','uname','df','du','ps','uptime','whoami','ls','find','cat','grep','launchctl'}
MAX=120

def audit(entry):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open('a') as f: f.write(json.dumps(entry, ensure_ascii=False)+'\n')
    except Exception: pass

def run_step(step):
    cmd=step.get('command','').strip(); timeout=min(int(step.get('timeout',30)),MAX)
    if not cmd: return {'ok':False,'error':'empty command'}
    try: argv=shlex.split(cmd)
    except ValueError as e: return {'ok':False,'error':f'parse: {e}'}
    if not argv or argv[0] not in ALLOW:
        return {'ok':False,'error':'command not allowed','allowed':sorted(ALLOW)}
    started=time.time()
    try:
        p=subprocess.run(argv, cwd=step.get('cwd') or '/var/mobile', capture_output=True, text=True, timeout=timeout, env={'PATH':'/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin'})
        out={'ok':p.returncode==0,'exit_code':p.returncode,'stdout':p.stdout[-32768:],'stderr':p.stderr[-32768:],'duration_ms':int((time.time()-started)*1000)}
    except subprocess.TimeoutExpired as e:
        out={'ok':False,'error':'timeout','stdout':(e.stdout or '')[-32768:],'stderr':(e.stderr or '')[-32768:]}
    audit({'ts':time.time(),'command':cmd,'result':out})
    return out

class Handler(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def send_json(self, code, obj):
        raw=json.dumps(obj,ensure_ascii=False).encode(); self.send_response(code); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_GET(self):
        if self.path=='/health': return self.send_json(200,{'ok':True,'service':'ly-executor','version':'0.1.0'})
        self.send_json(404,{'ok':False,'error':'not found'})
    def do_POST(self):
        if self.path!='/v1/task': return self.send_json(404,{'ok':False,'error':'not found'})
        try: body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        except Exception: return self.send_json(400,{'ok':False,'error':'invalid json'})
        steps=body.get('steps');
        if not isinstance(steps,list) or not steps or len(steps)>32: return self.send_json(400,{'ok':False,'error':'steps must contain 1..32 items'})
        results=[]
        for step in steps:
            r=run_step(step); results.append(r)
            if not r.get('ok') and body.get('stop_on_error',True): break
        self.send_json(200,{'ok':all(x.get('ok') for x in results),'task_id':str(uuid.uuid4()),'results':results})

if __name__=='__main__':
    ThreadingHTTPServer((HOST,PORT),Handler).serve_forever()
