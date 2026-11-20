#!/usr/bin/env python3
"""11/19: 上げる前の 2 つの確かめ（0.1.1-1119 の事故の再発防止．本人「二度と起こさないようにして」）．

  py -3 -X utf8 release_checks.py versions --new <新しい release の置き場> --base <前の目録 or 置き場> [--base ...]
  py -3 -X utf8 release_checks.py update-sim --new-dist <新しい Windows の配布物の置き場> (--from-feed <前の配布物の置き場> | --from-app <入れた先>) [--work <作業の置き場>]

versions:   新しい目録（manifest-windows-x64.json・manifest-linux-x64.json）の各部品の版を，前の目録の同じ部品と，
            配布の道具（installer.ps1・setup.sh の Compare-Version）と更新の確認（update_core.ver_key）の 2 つの比べ方で比べる．
            次のどれかで失敗（終了コード 1）:
              - 配布の道具が「前の版の方が新しい」と見て，中身（files_sha256）が違う部品＝更新で飛ばされる
              - 2 つの比べ方の向きが食い違う部品＝画面は「更新あり」なのに入らない（またはその逆）
              - release の版が前より古い
update-sim: 前の版を入れた置き場（前の配布物から setup で作る か，入れた先を写す）に，新しい配布物の update.cmd で更新を流し，
            state.json の全部の部品の版と files_sha256 が新しい目録と同じかを見る．違えば失敗．作業の置き場は終わったら消す．
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


def cmp_installer(a, b):
    """installer.ps1・setup.sh の Compare-Version と同じ（a が新しければ 1）．無い区切りの方を新しいと見る（1.0 は 1.0-rc より新しい）"""
    pa = re.split(r'[.\-+]', a or ''); pb = re.split(r'[.\-+]', b or '')
    for i in range(max(len(pa), len(pb))):
        x = pa[i] if i < len(pa) else ''; y = pb[i] if i < len(pb) else ''
        if x == y:
            continue
        if x.isdigit() and y.isdigit():
            return (int(x) > int(y)) - (int(x) < int(y))
        if x == '':
            return 1
        if y == '':
            return -1
        return (x > y) - (x < y)
    return 0


def ver_key(v):
    """update_core.ver_key と同じ"""
    out = []
    for p in re.split(r'[.\-+]', v or ''):
        out.append((0, int(p), '') if p.isdigit() else (1, 0, p))
    return out


def cmp_check(a, b):
    ka, kb = ver_key(a), ver_key(b)
    return (ka > kb) - (ka < kb)


def load_manifests(p):
    """置き場（release の平らな置き場・配布物の feed）か目録の 1 ファイルから {platform: manifest}"""
    out = {}
    if os.path.isfile(p):
        m = json.load(open(p, encoding='utf-8-sig')); out[m.get('platform', '?')] = m
        return out
    for cand in (p, os.path.join(p, 'feed')):
        for n in ('manifest-windows-x64.json', 'manifest-linux-x64.json', 'manifest.json'):
            f = os.path.join(cand, n)
            if os.path.isfile(f):
                m = json.load(open(f, encoding='utf-8-sig'))
                out.setdefault(m.get('platform', '?'), m)
    return out


def versions(a):
    new = load_manifests(a.new)
    if not new:
        print('新しい目録が見つからない:', a.new); return 1
    bad = 0
    for bp in a.base:
        base = load_manifests(bp)
        for plat, m in new.items():
            b = base.get(plat)
            if not b:
                continue
            r_new, r_old = m.get('release', ''), b.get('release', '')
            if cmp_installer(r_new, r_old) < 0:
                print(f'[失敗] {plat}: release {r_new} が前の {r_old} より古い（{bp}）'); bad += 1
            old = {c['id']: c for c in b.get('components', [])}
            for c in m.get('components', []):
                o = old.get(c['id'])
                if not o:
                    continue
                vi = cmp_installer(c['version'], o['version']); vc = cmp_check(c['version'], o['version'])
                differs = c.get('files_sha256') != o.get('files_sha256')
                if differs and vi < 0:
                    print(f'[失敗] {plat} {c["id"]}: {o["version"]} → {c["version"]} は配布の道具が「前の方が新しい」と見て飛ばす（中身は違う）'); bad += 1
                if vi != vc and differs:   # 中身が同じなら，どちらの判断でも入る物は同じ（番号だけの違い）
                    print(f'[失敗] {plat} {c["id"]}: {o["version"]} → {c["version"]} の向きが食い違う（配布の道具 {vi}・更新の確認 {vc}）'); bad += 1
    print('版の確かめ:', '通った' if bad == 0 else f'{bad} 件の失敗')
    return 1 if bad else 0


def run(cmd, env=None, cwd=None, timeout=1800):
    r = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, timeout=timeout)
    out = (r.stdout or b'').decode('utf-8', 'replace') + (r.stderr or b'').decode('utf-8', 'replace')
    return r.returncode, out


def update_sim(a):
    new_dist = os.path.abspath(a.new_dist)
    nm = load_manifests(new_dist).get('windows-x64')
    if not nm:
        print('新しい配布物の目録が見つからない:', new_dist); return 1
    work = a.work or tempfile.mkdtemp(prefix='sync-update-sim-')
    app, home, models = os.path.join(work, 'app'), os.path.join(work, 'home'), os.path.join(work, 'models')
    os.makedirs(models, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('SYNC_', 'DSH_', 'STRATA_'))}
    env['SYNC_HOME'] = home; env['SS_NOPAUSE'] = '1'
    try:
        if a.from_feed:
            ps = os.path.join(a.from_feed, 'installer', 'installer.ps1')
            rc, out = run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps, 'setup', '-Source', os.path.join(a.from_feed, 'feed'),
                           '-AppDir', app, '-SyncHome', home, '-ModelsDir', models, '-ShortcutDir', os.path.join(work, 'sc')], env=env)
            print('前の版を入れた:', 'rc', rc)
            if rc != 0:
                print(out[-1500:]); return 1
        else:
            shutil.copytree(a.from_app, app, symlinks=True)
            print('入れた先を写した:', a.from_app)
        before = json.load(open(os.path.join(app, 'state', 'state.json'), encoding='utf-8'))
        print('前:', before.get('release'), {k: v.get('version') for k, v in before['components'].items()})
        upd = os.path.join(new_dist, 'update.cmd') if os.path.exists(os.path.join(new_dist, 'update.cmd')) else None
        if a.repair:
            # 11/21 0.1.4（GitHub Issue #6）: 0.1.3 までの setup は英語などの Windows で最後まで行かず，記録（state.json）だけが無い入れ先が残る．
            # 記録を消してから新しい配布物の setup を流し直し，全部の部品（入れ替えなかった物も）が新しい記録に載るかを見る
            os.remove(os.path.join(app, 'state', 'state.json'))
            print('記録（state.json）を消した（壊れた入れ先の形）')
            ps = os.path.join(new_dist, 'installer', 'installer.ps1')
            cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps, 'setup', '-Source', os.path.join(new_dist, 'feed'),
                   '-AppDir', app, '-SyncHome', home, '-ModelsDir', models, '-ShortcutDir', os.path.join(work, 'sc')]
        elif upd:
            cmd = ['cmd', '/c', upd, '--source', new_dist, '--app-dir', app, '--sync-home', home, '--no-stop']
        else:
            ps = os.path.join(new_dist, 'installer', 'installer.ps1')
            cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ps, 'update', '-Source', os.path.join(new_dist, 'feed'), '-AppDir', app, '-SyncHome', home]
        rc, out = run(cmd, env=env)
        print('更新:', 'rc', rc, '（' + ' '.join(os.path.basename(x) for x in cmd[:3]) + '）')
        after = json.load(open(os.path.join(app, 'state', 'state.json'), encoding='utf-8'))
        bad = 0
        for c in nm.get('components', []):
            s = after['components'].get(c['id'])
            if s is None:
                if before['components'].get(c['id']) is not None:   # 前は入っていたのに消えた（GPU 別の部品で前も無い物は，この PC には入れない物）
                    print(f'[失敗] {c["id"]}: 前は入っていたのに入っていない'); bad += 1
                continue
            if s.get('version') != c['version'] or s.get('files_sha256') != c.get('files_sha256'):
                print(f'[失敗] {c["id"]}: 入っているのは {s.get("version")}（files {str(s.get("files_sha256"))[:10]}）・目録は {c["version"]}（files {str(c.get("files_sha256"))[:10]}）'); bad += 1
        if after.get('release') != nm.get('release'):
            print(f'[失敗] release: {after.get("release")} ・目録は {nm.get("release")}'); bad += 1
        if bad:
            print(out[-2500:])
        print('更新の試し:', '通った' if bad == 0 else f'{bad} 件の失敗', '（後:', after.get('release'), '）')
        return 1 if bad else 0
    finally:
        if not a.keep:
            shutil.rmtree(work, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)
    v = sp.add_parser('versions'); v.add_argument('--new', required=True); v.add_argument('--base', action='append', required=True)
    u = sp.add_parser('update-sim'); u.add_argument('--new-dist', required=True)
    g = u.add_mutually_exclusive_group(required=True); g.add_argument('--from-feed'); g.add_argument('--from-app')
    u.add_argument('--work'); u.add_argument('--keep', action='store_true')
    u.add_argument('--repair', action='store_true', help='11/21 #6: 記録を消してから新しい setup を流し直す（更新の代わり）')
    a = ap.parse_args()
    return versions(a) if a.cmd == 'versions' else update_sim(a)


if __name__ == '__main__':
    sys.exit(main())
