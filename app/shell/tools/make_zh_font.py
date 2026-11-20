"""画面の中国語（簡体字）の字体を，文に使う字だけ切り出して ui/SyncStrataSC-subset.ttf に書く（11/20 エンジン 2．0.1.3）．
中国語の字体が無い Linux（WSL など）でも簡体字が抜けないように同梱する（日本語の Zen Kaku を同梱したのと同じ理由）．
  py -3 -X utf8 tools/make_zh_font.py --src <NotoSansSC[wght].ttf>     切り出して書く（字の太さの軸 wght は残す）
  py -3 -X utf8 tools/make_zh_font.py --check                          今の切り出しが strings.json の中国語の字を全部持つか
元: Noto Sans SC（google/fonts の ofl/notosanssc，SIL Open Font License 1.1）．OFL の Reserved Font Name は 'Source' なので，
切り出した物（改変版）は名前を「Sync-Strata SC」に替える．著作権（name 0）・ライセンス（13・14）の欄は元のまま残す．
strings.json の中国語を直したら，これを流し直して組み直す（--check が足りない字を言う）．"""
import argparse
import json
import os
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL = os.path.dirname(HERE)
OUT = os.path.join(SHELL, 'ui', 'SyncStrataSC-subset.ttf')
FAMILY = 'Sync-Strata SC'


def zh_chars():
    s = json.load(open(os.path.join(SHELL, 'i18n', 'strings.json'), encoding='utf-8'))['strings']
    return sorted({c for v in s.values() for c in v['zh'] if ord(c) > 0x7e})


def missing(font_path, chars):
    cmap = TTFont(font_path).getBestCmap()
    return [c for c in chars if ord(c) not in cmap]


ap = argparse.ArgumentParser()
ap.add_argument('--src')
ap.add_argument('--check', action='store_true')
a = ap.parse_args()
chars = zh_chars()
if a.check:
    m = missing(OUT, chars)
    print(f'{len(chars)} non-ASCII characters in the Chinese strings; missing in {os.path.basename(OUT)}: {"".join(m) or "none"}')
    sys.exit(1 if m else 0)
if not a.src:
    sys.exit('--src <NotoSansSC[wght].ttf> or --check')
m = missing(a.src, chars)
if m:
    sys.exit('the source font lacks: ' + ''.join(m))
opt = subset.Options()
opt.name_IDs = ['*']          # 著作権・ライセンス・名前付きの太さ（可変の字体の 256 以上）を残す
opt.name_languages = ['*']
opt.hinting = False
opt.notdef_outline = True
opt.layout_features = ['*']
f = TTFont(a.src)
sub = subset.Subsetter(opt)
sub.populate(unicodes=[ord(c) for c in chars])
sub.subset(f)
name = f['name']
for rec in list(name.names):  # 改変版の名前（OFL: Reserved Font Name を使わない．元の名前とも分ける）
    if rec.nameID in (1, 16):
        rec.string = FAMILY
    elif rec.nameID == 4:
        rec.string = FAMILY
    elif rec.nameID == 6:
        rec.string = FAMILY.replace(' ', '')
    elif rec.nameID == 3:
        rec.string = FAMILY + ' (subset of Noto Sans SC for the Sync-Strata shell)'
f.save(OUT)
m = missing(OUT, chars)
print(f'{OUT}: {os.path.getsize(OUT)} bytes, {len(chars)} characters ({"".join(chars)}), missing: {"".join(m) or "none"}')
print('name 0:', name.getDebugName(0))
print('name 13:', (name.getDebugName(13) or '')[:120])
print('axes:', [ax.axisTag + f' {ax.minValue}-{ax.maxValue}' for ax in f['fvar'].axes] if 'fvar' in f else 'none')
