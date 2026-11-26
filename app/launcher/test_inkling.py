"""Inkling 2 Mini in the launcher: the catalog entries, the choice of the model and the server config (no GPU, no engine).

    python -m unittest test_inkling -v      (in app/launcher)
"""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

_TMP = tempfile.TemporaryDirectory()
os.environ["SYNC_HOME"] = _TMP.name
os.environ.pop("SYNC_CATALOG", None)

import sync_home as H  # noqa: E402
import sync_launch as SL  # noqa: E402

DIST = Path(__file__).resolve().parents[1] / "chat" / "models" / "models.dist.json"
UNC = "inkling-2-mini-uncensored"


def sparse(path, size):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.truncate(size)


class InklingLauncherTest(unittest.TestCase):
    def setUp(self):
        tmp = self.enterContext(tempfile.TemporaryDirectory())
        self.root = Path(tmp)
        self.models = self.root / "models"
        self.enterContext(patch.dict(os.environ, SYNC_HOME=str(self.root / "home")))
        self.enterContext(patch.object(H.OS, "default_models_dir", return_value=str(self.models)))
        self.kit = self.root / "kit"
        (self.kit / "bin").mkdir(parents=True)
        (self.kit / "bin" / ("strata" + H.X)).write_text("")
        (self.kit / "serve" / "serve").mkdir(parents=True)
        (self.kit / "serve" / "serve" / "server.py").write_text("")
        self.enterContext(patch.dict(H.LAYOUT, catalog=None, catalog_dist=str(DIST), inkling_kit=str(self.kit)))
        self.enterContext(patch.object(SL, "ROOT", str(self.root / "run")))
        self.enterContext(patch.object(SL, "PACKS", []))

    def entry(self, mid):
        return next(m for m in H.catalog()["models"] if m["id"] == mid)

    def place_model(self, mid=UNC):
        m = self.entry(mid)
        sparse(Path(m["local_dir"]) / m["files"][0]["path"], m["files"][0]["bytes"])
        return m

    def place_dspark(self):
        d = next(s for s in H.catalog()["shared"] if s["id"] == "inkling2-dspark")
        p = Path(d["local_dir"]) / d["files"][0]["path"]
        sparse(p, d["files"][0]["bytes"])
        return p

    def test_catalog_entries(self):
        cat = H.catalog()
        ink = [m for m in cat["models"] if m.get("engine") == "inkling2"]
        self.assertEqual({m["id"] for m in ink}, {UNC, "inkling-2-mini"})
        for m in ink:
            self.assertEqual(m["needs"], ["inkling2-dspark"])
            self.assertEqual(len(m["files"]), 1)
            self.assertEqual(len(m["files"][0]["sha256"]), 64)
            self.assertNotIn("experts_gib", m)        # never one of the Qwen packs
        d = next(s for s in cat["shared"] if s["id"] == "inkling2-dspark")
        self.assertTrue(d["optional"])
        self.assertEqual(set(d["only_for"]), {m["id"] for m in ink})
        for m in cat["models"]:
            if not m.get("engine"):
                self.assertNotIn("inkling2-dspark", m.get("needs") or [])
        self.assertNotIn(UNC, [p["id"] for p in SL.load_packs()])

    def test_choice(self):
        self.assertEqual(SL.inkling_model(UNC)["id"], UNC)
        self.assertIsNone(SL.inkling_model("sync-s"))
        self.assertIsNone(SL.inkling_model("auto"))           # not on this PC yet
        self.place_model()
        self.assertEqual(SL.inkling_model("auto")["id"], UNC)   # no Qwen pack here: auto starts Inkling
        with patch.object(SL, "PACKS", [{"dir": str(self.root)}]), patch.object(SL.os.path, "exists", return_value=True):
            self.assertIsNone(SL.inkling_model("auto"))       # a Qwen pack is here: auto stays with the packs

    def test_context(self):
        self.assertEqual(SL.inkling_context(None), 262144)
        self.assertEqual(SL.inkling_context("128k"), 131072)
        self.assertEqual(SL.inkling_context("65536"), 65536)
        with patch.object(H, "settings_raw", return_value={"context": 32768}):
            self.assertEqual(SL.inkling_context(None), 32768)

    def test_config(self):
        m = self.place_model()
        dspark = self.place_dspark()
        tok = Path(H.path("engine-data", f"tokenizer-{UNC}", "tokenizer", "vocab.json"))
        tok.parent.mkdir(parents=True, exist_ok=True)
        tok.write_text("{}")                                  # the tokenizer is read from the GGUF only once
        with patch("subprocess.run") as run:
            cfg, log = SL.inkling_config(self.entry(UNC), SL.inkling_engine(), 262144, ["STRATA_INK2_CPU_THREADS=6"])
            run.assert_not_called()
        c = json.loads(Path(cfg).read_text(encoding="utf-8"))
        a = c["args"]
        self.assertEqual(a[a.index("--native") + 1], os.path.join(m["local_dir"], m["files"][0]["path"]))
        self.assertEqual(a[a.index("--max-context") + 1], "262144")
        self.assertEqual(a[a.index("--dspark") + 1], str(dspark))
        self.assertEqual(a[a.index("--dspark-n") + 1], "3")
        self.assertEqual(c["arch"], "inkling2_loop")
        self.assertEqual(c["exe"], os.path.join(str(self.kit), "bin", "strata" + H.X))
        self.assertEqual(c["cwd"], os.path.join(str(self.kit), "serve"))
        self.assertEqual(c["model_name"], UNC)
        self.assertEqual(c["tokenizer"], str(tok.parent))
        self.assertEqual(c["env"], {"STRATA_INK2_CPU_THREADS": "6"})
        self.assertIn(os.path.join(str(self.kit), "bin"), c["lib_dirs"])

    def test_config_without_dspark(self):
        self.place_model()
        tok = Path(H.path("engine-data", f"tokenizer-{UNC}", "tokenizer", "vocab.json"))
        tok.parent.mkdir(parents=True, exist_ok=True)
        tok.write_text("{}")
        cfg, _ = SL.inkling_config(self.entry(UNC), SL.inkling_engine(), 65536, [])
        self.assertNotIn("--dspark", json.loads(Path(cfg).read_text(encoding="utf-8"))["args"])

    def test_unified_engine_first(self):
        eng_dir = self.root / "engine" / "bin"
        eng_dir.mkdir(parents=True)
        for f in ("strata", "strata-ink2"):
            (eng_dir / (f + H.X)).write_text("")
        sv = self.root / "engine" / "serve" / "serve"
        sv.mkdir(parents=True)
        (sv / "server.py").write_text("")
        with patch.object(SL, "ENGINE", str(eng_dir / ("strata" + H.X))), patch.object(SL, "SERVER_PY", str(sv / "server.py")):
            self.assertEqual(SL.inkling_engine()["exe"], str(self.kit / "bin" / ("strata" + H.X)))   # no inkling.py: the kit
            (sv / "inkling.py").write_text("")
            e = SL.inkling_engine()
            self.assertEqual(e["exe"], str(eng_dir / ("strata" + H.X)))
            self.assertEqual(e["server_py"], str(sv / "server.py"))
            self.assertEqual(e["tools"], str(self.root / "engine" / "serve" / "tools"))

    def test_head_name(self):
        SL.write_head_name("Inkling 2 Mini Uncensored")
        self.assertEqual(Path(SL.ROOT, "head-model-name.txt").read_text(encoding="utf-8"), "Inkling 2 Mini Uncensored\n")
        SL.write_head_name("Sync-S")
        self.assertEqual(Path(SL.ROOT, "head-model-name.txt").read_text(encoding="utf-8"), "Qwen3.8-Flash-Next Sync-S\n")


if __name__ == "__main__":
    unittest.main()
