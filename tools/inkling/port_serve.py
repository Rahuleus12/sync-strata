#!/usr/bin/env python3
"""Add Inkling 2 Mini to the app's own server (the `serve` the app ships: upstream Strata 9ae93f7b plus the app's
restart patches), so that one server runs the Qwen packs as before and Inkling.

    python3 tools/inkling/port_serve.py --from <app>/engine/serve --engine-src build/engine-src --out build/serve-unified

It copies the app's serve and changes only what Inkling needs, each change found by its exact text (a server whose text
is not the expected one is refused rather than patched blindly):

  serve/inkling.py            new (Inkling's reply format, effort words, template, forced-call spelling)
  tools/strata_tokenizer.py   the engine's (it adds the inkling2 pre-tokenizer; the Qwen encoding is unchanged - checked
  tools/gguf_reader.py        by tools/inkling/check_tokenizer.py)
  serve/frontend.py           `{% generation %}` in templates (Inkling's wraps its turns in it); use_family() switches the
                              effort words (the Qwen words stay the default)
  serve/server.py             Service.parser_cls / force_text / set_family; the Inkling family when the config's arch is
                              inkling2_loop; its API name and the model card's sampling
With any other arch (the Qwen packs: qwen4exp) the server runs exactly the code it ran before.
"""
import argparse
import shutil
import sys
from pathlib import Path


def edit(path: Path, pairs, label):
    text = path.read_text(encoding="utf-8")
    crlf = "\r\n" in text
    text = text.replace("\r\n", "\n")
    for old, new in pairs:
        n = text.count(old)
        if n != 1:
            sys.exit(f"{label}: expected the text once, found it {n} times:\n{old[:200]}")
        text = text.replace(old, new)
    path.write_text(text.replace("\n", "\r\n") if crlf else text, encoding="utf-8", newline="")


FRONTEND = [
    ("import jinja2\nfrom jinja2.sandbox import ImmutableSandboxedEnvironment\n",
     'import jinja2\nimport jinja2.ext\nfrom jinja2.sandbox import ImmutableSandboxedEnvironment\n\n\n'
     'class GenerationTag(jinja2.ext.Extension):\n'
     '    """transformers\' `{% generation %}...{% endgeneration %}` (it marks the assistant\'s tokens for training masks):\n'
     '    the body is rendered as it is.  Inkling 2\'s template wraps its assistant turns in it."""\n'
     '    tags = {"generation"}\n\n'
     '    def parse(self, parser):\n'
     '        lineno = next(parser.stream).lineno\n'
     '        body = parser.parse_statements(("name:endgeneration",), drop_needle=True)\n'
     '        return jinja2.nodes.Scope(body, lineno=lineno)\n'),
    ('extensions=["jinja2.ext.loopcontrols"])', 'extensions=["jinja2.ext.loopcontrols", GenerationTag])'),
    ('          "low": "low", "medium": "medium", "high": "xhigh", "xhigh": "xhigh", "max": "xhigh", "maximum": "xhigh"}\n',
     '          "low": "low", "medium": "medium", "high": "xhigh", "xhigh": "xhigh", "max": "xhigh", "maximum": "xhigh"}\n'
     '_EFFORT_QWEN = dict(EFFORT)\n\n\n'
     'def use_family(family: str | None) -> None:\n'
     '    """The reasoning-effort words of the model family this server runs (Inkling 2 Mini\'s, or the Qwen ones)."""\n'
     '    EFFORT.clear()\n'
     '    if family == "inkling2_loop":\n'
     '        from serve.inkling import EFFORT_INKLING\n'
     '        EFFORT.update(EFFORT_INKLING)\n'
     '    else:\n'
     '        EFFORT.update(_EFFORT_QWEN)\n'),
]

SERVER = [
    # the parser class and the end tokens become per-family
    ('        self.stop_ids = set(tokenizer.encode(IM_END, parse_special=True) +\n'
     '                            tokenizer.encode("<|endoftext|>", parse_special=True))\n',
     '        self.stop_ids = set(tokenizer.encode(IM_END, parse_special=True) +\n'
     '                            tokenizer.encode("<|endoftext|>", parse_special=True))\n'
     '        self.family = None                              # the model family: set_family() below\n'
     '        self.parser_cls = OutputParser                  # reads the model\'s output (reasoning, content, tool calls)\n'),
    ('    def loaded(self) -> bool:\n',
     '    def set_family(self, family: str | None) -> None:\n'
     '        """Inkling 2 Mini: its turn is messages of control tokens (serve/inkling.py), it ends on\n'
     '        <|content_model_end_sampling|>, and its template knows the effort only.  Any other family keeps the Qwen form."""\n'
     '        self.family = family\n'
     '        if family == "inkling2_loop":\n'
     '            from serve import inkling\n'
     '            eos = (getattr(self.tok, "special_ids", None) or {}).get("tokenizer.ggml.eos_token_id", 200006)\n'
     '            self.stop_ids = {int(eos)}\n'
     '            self.parser_cls = inkling.InklingOutputParser\n'
     '            self._force_text = inkling.to_inkling_force\n'
     '            if not isinstance(self.template, inkling.InklingChatTemplate):\n'
     '                self.template.__class__ = inkling.InklingChatTemplate\n'
     '            self.effort_end = False\n'
     '        import serve.frontend as _frontend\n'
     '        _frontend.use_family(family)\n\n'
     '    _force_text = None\n\n'
     '    def force_text(self, force):\n'
     '        """forced_call\'s opening of the call the reply must make, in this model\'s spelling."""\n'
     '        return self._force_text(force) if self._force_text is not None else force\n\n'
     '    def loaded(self) -> bool:\n'),
    ('        parser = OutputParser(thinking=thinking, tools=tools, stream_tools=True, recover=self.tool_call_recovery)',
     '        parser = self.parser_cls(thinking=thinking, tools=tools, stream_tools=True, recover=self.tool_call_recovery)'),
    ('            force = forced_call(req.get("tool_choice"), tools)      # a bad value is a 400 before anything is sent',
     '            force = svc.force_text(forced_call(req.get("tool_choice"), tools))      # a bad value is a 400 before anything is sent'),
    ('            force = forced_call(req.get("tool_choice"), tools)        # "any" / {"type": "tool", "name": N}',
     '            force = svc.force_text(forced_call(req.get("tool_choice"), tools))        # "any" / {"type": "tool", "name": N}'),
    ('FAMILY_MODEL_NAMES = {"qwen4exp": "qwen3.8-flash-next", "qwen35moe": "qwen3.6-35b-a3b"}',
     'FAMILY_MODEL_NAMES = {"qwen4exp": "qwen3.8-flash-next", "qwen35moe": "qwen3.6-35b-a3b", "inkling2_loop": "inkling-2-mini"}'),
    ('MODEL_CARD_SAMPLING = {\n',
     'MODEL_CARD_SAMPLING = {\n'
     '    # Inkling 2 Mini: temperature 1.0 with no truncation (generation_config.json; Unsloth\'s guide: top_p 1, top_k off)\n'
     '    "inkling2_loop": {"thinking": {"temperature": 1.0, "top_p": 1.0}, "instruct": {"temperature": 1.0, "top_p": 1.0}},\n'),
    ('        svc.model_arch = cfg.get("arch") or "qwen4exp"\n',
     '        svc.model_arch = cfg.get("arch") or "qwen4exp"\n'
     '        if svc.model_arch == "inkling2_loop":\n'
     '            svc.set_family("inkling2_loop")\n'),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="src", required=True, help="the app's engine/serve folder")
    ap.add_argument("--engine-src", required=True, help="the engine source with the Inkling path")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    src, eng, out = Path(a.src), Path(a.engine_src), Path(a.out)
    if not (src / "serve" / "server.py").is_file():
        sys.exit(f"{src}: no serve/server.py")
    if (src / "serve" / "inkling.py").exists():
        sys.exit(f"{src}: already has serve/inkling.py (port from the app's own serve, not from a ported one)")
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy2(eng / "serve" / "inkling.py", out / "serve" / "inkling.py")
    for f in ("strata_tokenizer.py", "gguf_reader.py"):
        shutil.copy2(eng / "tools" / f, out / "tools" / f)
    edit(out / "serve" / "frontend.py", FRONTEND, "serve/frontend.py")
    edit(out / "serve" / "server.py", SERVER, "serve/server.py")
    ver = out / "STRATA_SERVE_VERSION.txt"
    ver.write_text(ver.read_text(encoding="utf-8").strip() + "+inkling2\n", encoding="utf-8")
    print(f"ported: {out}")


if __name__ == "__main__":
    main()
