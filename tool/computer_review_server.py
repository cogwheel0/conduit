"""Loopback-only synthetic site for exercising the real remote browser.

Run in an empty review workspace. No user data or external assets are read.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"step": 0, "running": False, "clicks": 0}

PAGE = """<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fieldnotes — Workshop board</title><style>
*{box-sizing:border-box}body{margin:0;background:#f4f3ef;color:#25382e;font:16px -apple-system,BlinkMacSystemFont,sans-serif}
header{display:flex;align-items:center;justify-content:space-between;padding:25px 36px;border-bottom:1px solid #dddeda;background:#fafaf7}
.brand{font-weight:750;font-size:23px;letter-spacing:-1px}.badge{font-size:12px;background:#e3ebe2;padding:8px 13px;border-radius:30px}
main{max-width:1000px;margin:auto;padding:36px}.eyebrow{font-size:12px;letter-spacing:2px;color:#657369;font-weight:650}
h1{font:500 44px Georgia,serif;margin:14px 0 10px;letter-spacing:-1px}p{color:#68746b;line-height:1.6;margin:0}
.heading{display:flex;justify-content:space-between;align-items:end}.button{border:0;border-radius:12px;padding:13px 18px;font:600 14px -apple-system,BlinkMacSystemFont,sans-serif;background:#294f3b;color:white;cursor:pointer}
.stats{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin:30px 0}.stat{background:#fff;border:1px solid #e1e5dc;padding:19px 22px;border-radius:16px}.stat b{display:block;font-size:29px;font-weight:500;margin-bottom:6px}.stat span{color:#7a837b;font-size:13px}
.board{background:white;border:1px solid #dfe3db;border-radius:20px;padding:25px}.boardtop{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px}
input.title{border:0;background:none;font:650 21px -apple-system,BlinkMacSystemFont,sans-serif;color:#25382e;width:75%;padding:6px 0;outline-color:#97b99c}
.row{display:flex;align-items:center;padding:18px 0;border-top:1px solid #eef0e9;gap:16px}.check{width:24px;height:24px;border:1.5px solid #b8c3b8;background:white;border-radius:8px;cursor:pointer;color:white}.check.done{background:#618868;border-color:#618868}.check.done:after{content:'✓'}
.detail{flex:1}.detail b{font-size:15px;font-weight:600}.detail span{display:block;font-size:13px;color:#879087;margin-top:5px}.tag{font-size:11px;padding:6px 10px;background:#f0f1ec;border-radius:20px;color:#748071}
footer{display:flex;align-items:center;gap:8px;margin-top:20px;color:#7b867d;font-size:12px}.dot{width:6px;height:6px;border-radius:50%;background:#76a77e}
@media(max-width:600px){header{padding:20px}main{padding:26px 20px}h1{font-size:36px}.stats{gap:8px}.stat{padding:15px}.heading{display:block}.heading .button{margin-top:16px}.board{padding:20px}.tag{display:none}}
</style></head><body><header><div class="brand">fieldnotes<span style="color:#91ad86">.</span></div><span class="badge">Creative workspace</span></header>
<main><div class="eyebrow">MAKE ROOM FOR GOOD IDEAS</div><div class="heading"><div><h1>A little room to create.</h1><p>A thoughtful plan for a hands-on weekend.</p></div><button class="button" onclick="fetch('/run',{method:'POST'})">Build the plan ↗</button></div>
<div class="stats"><div class="stat"><b>04</b><span>Workshop ideas</span></div><div class="stat"><b>12</b><span>Open places</span></div><div class="stat"><b id="ready">0 / 4</b><span>Details ready</span></div></div>
<section class="board"><div class="boardtop"><input aria-label="Board title" class="title" value="Weekend workshop"><span class="badge">Draft</span></div>
<div id="rows"></div></section><footer><span class="dot"></span><span id="status">Your next good idea starts here</span></footer></main>
<script>const titles=['Clay & coffee','Printmaking in the studio','A small garden, indoors','Paper, color & play'];let current=-1;
document.querySelector('#rows').innerHTML=titles.map((t,i)=>`<div class="row"><button aria-label="Complete ${t}" class="check" id="c${i}" onclick="this.classList.toggle('done');fetch('/click',{method:'POST'})"></button><div class="detail"><b>${t}</b><span id="d${i}">Gathering the details</span></div><span class="tag">Creative session</span></div>`).join('');
setInterval(async()=>{const s=await(await fetch('/state')).json();if(s.step!==current){current=s.step;document.querySelector('#ready').textContent=s.step+' / 4';for(let i=0;i<4;i++){document.querySelector('#d'+i).textContent=i<s.step?['Saturday · 10:00 AM · Materials included','Saturday · 2:00 PM · Beginner friendly','Sunday · 10:30 AM · Take home your creation','Sunday · 1:00 PM · All ages welcome'][i]:'Gathering the details';document.querySelector('#c'+i).classList.toggle('done',i<s.step)}}document.querySelector('#status').textContent=s.running?'Adding a few thoughtful details…':s.step===4?'All set. Make it your own.':'Ready when you are.'},400);</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        content = json.dumps(state).encode() if self.path == '/state' else PAGE.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json' if self.path == '/state' else 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_POST(self):
        if self.path == '/pause':
            state['running'] = False
        elif self.path == '/click':
            state['clicks'] += 1
        elif self.path == '/run':
            state.update(step=0, running=True)
        self.send_response(204)
        self.end_headers()


def advance():
    while True:
        time.sleep(5)
        if state['running']:
            state['step'] = min(4, state['step'] + 1)
            if state['step'] == 4:
                state['running'] = False


if __name__ == '__main__':
    threading.Thread(target=advance, daemon=True).start()
    ThreadingHTTPServer(('127.0.0.1', 8767), Handler).serve_forever()
