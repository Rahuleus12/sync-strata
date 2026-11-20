r"""11/21 0.1.4（GitHub Issue #6）の試し: installer.ps1 の setup が，システムの ANSI の文字コードに無い字のアイコンの名前でも
最後まで行き，記録（state\state.json）を書くか．部品の無い小さな版の一覧で，アイコンだけを作らせる（数秒）．

- 日本語の Windows（cp932）でも英語の Windows の『かな → ?』を再現できるよう，日本語の名前に cp932 に無い字（한）を混ぜる
- SYNC_SHORTCUT_LANG で ja・en・zh を選び，それぞれの名前のアイコンができるかを見る（zh の「载」も cp932 に無い）
- --installer で別の installer.ps1（たとえば直す前の控え）を指すと，直す前は失敗することを確かめられる

使い方: py -3 -X utf8 pack\tools\test_installer_shortcuts.py [--installer PATH]   終了コード 0 で全部通った
"""
import argparse, json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.join(os.path.dirname(HERE), 'src', 'installer', 'installer.ps1')

SHORTCUTS = [
    {"name": "Sync-Strata", "name_en": "Sync-Strata", "name_zh": "Sync-Strata", "target": "app/shell/Sync-Strata.exe",
     "where": ["desktop", "startmenu"], "description": "Sync-Strata（ローカルの LLM）한",
     "description_en": "Local LLM Sync-Strata", "description_zh": "本地 LLM Sync-Strata"},
    {"name": "Sync-Strata の更新 한", "name_en": "Update Sync-Strata", "name_zh": "更新 Sync-Strata", "target": "update.cmd", "where": ["startmenu"]},
    {"name": "Sync-Strata を前の版に戻す 한", "name_en": "Roll back Sync-Strata", "name_zh": "Sync-Strata 回退到上一版", "target": "rollback.cmd",
     "where": ["startmenu"]},
    {"name": "Sync-Strata を消す 한", "name_en": "Uninstall Sync-Strata", "name_zh": "卸载 Sync-Strata", "target": "uninstall.cmd", "where": ["startmenu"]},
]


def run_case(installer, lang):
    root = tempfile.mkdtemp(prefix='ss-sc-test-')
    try:
        feed = os.path.join(root, 'feed'); app = os.path.join(root, 'app'); home = os.path.join(root, 'home'); sc = os.path.join(root, 'sc')
        os.makedirs(feed); os.makedirs(os.path.join(app, 'app', 'shell'))
        open(os.path.join(app, 'app', 'shell', 'Sync-Strata.exe'), 'wb').write(b'MZ')     # アイコンの行き先だけ（中身は見ない）
        m = {"product": "sync-strata", "schema": 1, "platform": "windows-x64", "release": "0.0.0-test", "update_feed": "",
             "components": [], "shortcuts": SHORTCUTS}
        json.dump(m, open(os.path.join(feed, 'manifest.json'), 'w', encoding='utf-8'), ensure_ascii=False)
        env = dict(os.environ, SYNC_SHORTCUT_LANG=lang)
        env.pop('SYNC_HOME', None)
        r = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', installer, 'setup', '-Source', feed,
                            '-AppDir', app, '-SyncHome', home, '-ShortcutDir', sc, '-NoModelSearch'],
                           env=env, capture_output=True, timeout=300)
        out = (r.stdout or b'').decode('utf-8', 'replace') + (r.stderr or b'').decode('utf-8', 'replace')
        made = sorted(os.path.relpath(os.path.join(dp, f), sc) for dp, _, fs in os.walk(sc) for f in fs) if os.path.isdir(sc) else []
        want = []
        for s in SHORTCUTS:
            n = s['name'] if lang == 'ja' else s.get('name_' + lang) or s['name_en']
            for w in s['where']:
                want.append(os.path.join('Desktop' if w == 'desktop' else os.path.join('StartMenu', 'Sync-Strata'), n + '.lnk'))
        state = os.path.join(app, 'state', 'state.json')
        probs = []
        if not os.path.isfile(state):
            probs.append('記録（state.json）が無い')
        else:
            st = json.load(open(state, encoding='utf-8-sig'))
            if len(st.get('shortcuts') or []) != len(want):
                probs.append(f'記録のアイコンが {len(st.get("shortcuts") or [])} 個（{len(want)} 個のはず）')
        miss = [w for w in want if w not in made]
        if miss:
            probs.append('アイコンが無い: ' + '，'.join(miss))
        left = [x for x in made if os.path.basename(x).startswith('~sync-strata-')]
        if left:
            probs.append('仮の名前のファイルが残った: ' + '，'.join(left))
        print(f'== {lang}: 終了コード {r.returncode}，アイコン {len(made)} 個，' + ('通った' if not probs else '落ちた: ' + '／'.join(probs)), flush=True)
        if probs:
            print('   ' + '\n   '.join(out.strip().splitlines()[-12:]), flush=True)
        return not probs
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--installer', default=INSTALLER)
    a = ap.parse_args()
    print('installer:', a.installer, flush=True)
    ok = all([run_case(a.installer, lang) for lang in ('ja', 'en', 'zh')])
    print('結果:', '全部通った' if ok else '落ちたものがある', flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
