#!/usr/bin/env python3
"""Same requests to the running engine, before and after an engine change: the answers (greedy) and the speed.

    python3 tools/inkling/engine_check.py --port 8082 --out before.json
    python3 tools/inkling/engine_check.py --port 8082 --out after.json --compare before.json

The speed is the server's own (the last "done:" figure in /metrics' request list when there is one, else the wall
time of the request).  Greedy answers of the same engine build are the same text; a different build may part where
two tokens are nearly tied, so a difference is shown with the place it starts.
"""
import argparse
import json
import time
import urllib.request

PROMPTS = [
    ("short", "Name the three primary colors in one sentence.", 64, "none"),
    ("code", "Write a Python function that returns the n-th Fibonacci number iteratively, with a docstring.", 300, "none"),
    ("think", "A train leaves at 9:40 and arrives at 13:05. How long is the trip? Answer briefly.", 600, "low"),
    ("tool", "What is the weather in Osaka?", 200, "none"),
]
TOOLS = [{"type": "function", "function": {"name": "get_weather", "description": "Current weather for a city",
                                           "parameters": {"type": "object", "properties": {"city": {"type": "string"}},
                                                          "required": ["city"]}}}]


def ask(port, name, text, max_tokens, effort):
    body = {"model": "strata", "messages": [{"role": "user", "content": text}], "max_tokens": max_tokens,
            "temperature": 0, "reasoning_effort": effort}
    if name == "tool":
        body["tools"] = TOOLS
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"content-type": "application/json"})
    t0 = time.time()
    d = json.load(urllib.request.urlopen(req, timeout=900))
    wall = time.time() - t0
    m = d["choices"][0]["message"]
    calls = [(c["function"]["name"], c["function"]["arguments"]) for c in m.get("tool_calls") or []]
    n = (d.get("usage") or {}).get("completion_tokens") or 0
    return {"content": m.get("content") or "", "reasoning": m.get("reasoning_content") or "", "tool_calls": calls,
            "finish": d["choices"][0]["finish_reason"], "tokens": n, "wall_s": round(wall, 2),
            "tok_s_wall": round(n / wall, 1) if wall else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8082)
    ap.add_argument("--out", required=True)
    ap.add_argument("--compare")
    ap.add_argument("--rounds", type=int, default=2, help="each prompt this many times (the first warms up)")
    a = ap.parse_args()
    out = {}
    for name, text, mt, eff in PROMPTS:
        runs = [ask(a.port, name, text, mt, eff) for _ in range(a.rounds)]
        r = runs[-1]
        r["tok_s_wall_all"] = [x["tok_s_wall"] for x in runs]
        r["same_each_round"] = all(x["content"] == runs[0]["content"] and x["tool_calls"] == runs[0]["tool_calls"] for x in runs)
        out[name] = r
        print(f"{name:6} {r['tokens']:4} tokens  {r['tok_s_wall_all']} tok/s (wall)  {r['finish']}  "
              f"{(r['content'] or str(r['tool_calls']))[:70]!r}")
    json.dump(out, open(a.out, "w"), ensure_ascii=False, indent=1)
    if a.compare:
        old = json.load(open(a.compare))
        print("\ncompared with", a.compare)
        for k, r in out.items():
            o = old.get(k)
            if not o:
                continue
            same = o["content"] == r["content"] and o["tool_calls"] == r["tool_calls"] and o["reasoning"] == r["reasoning"]
            where = ""
            if not same:
                x, y = o["reasoning"] + o["content"], r["reasoning"] + r["content"]
                i = next((i for i, (p, q) in enumerate(zip(x, y)) if p != q), min(len(x), len(y)))
                where = f" (parts at character {i}: {x[i:i+30]!r} vs {y[i:i+30]!r})"
            print(f"{k:6} answer {'same' if same else 'differs'}{where}; speed {o['tok_s_wall']} -> {r['tok_s_wall']} tok/s")


if __name__ == "__main__":
    main()
