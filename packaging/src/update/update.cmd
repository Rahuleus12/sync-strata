@echo off
rem Sync-Strata: update (only the changed parts; the previous version is kept for rollback.cmd).
rem Made by pack\tools\make_update_tools.py from pack\src\update\update_core.py: edit that file, not this one.
rem Usage: update.cmd [-Source <release zip | unpacked folder | URL>] [-AppDir DIR] [-SyncHome DIR] [-NoStop]
rem Everything runs in one block: cmd has read it all before the update replaces this file.
setlocal EnableDelayedExpansion
(
  set "SSU_TMP=%TEMP%\SyncStrata-update-%RANDOM%%RANDOM%"
  mkdir "!SSU_TMP!" >nul 2>nul
  copy /y "%~f0" "!SSU_TMP!\update.cmd" >nul
  set "SSU_SELF=!SSU_TMP!\update.cmd"
  set "SSU_PY="
  if exist "%~dp0app\python\python.exe" set "SSU_PY=%~dp0app\python\python.exe"
  if not defined SSU_PY if defined SYNC_APP_DIR if exist "%SYNC_APP_DIR%\app\python\python.exe" set "SSU_PY=%SYNC_APP_DIR%\app\python\python.exe"
  if not defined SSU_PY if exist "%LOCALAPPDATA%\Programs\SyncStrata\app\python\python.exe" set "SSU_PY=%LOCALAPPDATA%\Programs\SyncStrata\app\python\python.exe"
  if not defined SSU_PY (
    echo Sync-Strata update: the app's Python was not found. Is Sync-Strata installed? Run setup.cmd from the download first.
    set "SSU_RC=2"
  ) else (
    rem Step 1 prepare by Python: manifest, the new installer, stop the app, write run.ps1.  Step 2 run.ps1 replaces the parts
    rem while no Python runs from the app: the installer counts any exe under app\ as the app running.  Step 3 report by Python.
    "!SSU_PY!" -s -X utf8 -c "import os; t = open(os.environ['SSU_SELF'], encoding='utf-8').read(); exec(compile(t[t.index(chr(10) + '#PY' + '-BEGIN') + 1:], os.environ['SSU_SELF'], 'exec'))" prepare "%~dp0." %*
    set "SSU_RC=!ERRORLEVEL!"
    if exist "!SSU_TMP!\run.ps1" (
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!SSU_TMP!\run.ps1"
      set "SSU_RC=!ERRORLEVEL!"
      "!SSU_PY!" -s -X utf8 -c "import os; t = open(os.environ['SSU_SELF'], encoding='utf-8').read(); exec(compile(t[t.index(chr(10) + '#PY' + '-BEGIN') + 1:], os.environ['SSU_SELF'], 'exec'))" report "%~dp0." !SSU_RC! %*
      set "SSU_RC=!ERRORLEVEL!"
    )
  )
  cd /d "%TEMP%"
  rmdir /s /q "!SSU_TMP!" >nul 2>nul
  if not "%SS_NOPAUSE%"=="1" pause
  exit /b !SSU_RC!
)
#PY-BEGIN
# Sync-Strata の更新（update.cmd・update.sh の中身．11/17 strata-engine2-desktop．H）
# update.cmd（Windows）と update.sh（Linux）は，この Python を中に持つ包み．包みは tools/make_update_tools.py が作る（直すのはこのファイル）．
# 流れ: 入れた先を見つける → この OS の一覧（manifest-<OS>.json）を取る（URL → gh → 手で置いた zip）→ 新しい部品 pack の
# 配布の道具（installer.ps1・setup.sh）を取り出して sha256 を確かめる → 版が変わるならアプリを止める（sync down --all）→
# その道具の update（変わった部品だけ落として sha256 を確かめ，前の版を app/.prev に残して入れ替える．rollback で戻せる）→ 版を出す．
# 触らない物: 設定・会話（SYNC_HOME），モデル，保存済みのトークン．モデルは落とさない．
# 終了コード: 0 済んだ（最新だったも含む），2 置き場が見つからない・入っていない（何もしていない），5 断った（sha256・一覧の誤り），
# 6 失敗（前の版のまま），7 動いているので入れ替えなかった．
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import ssl
import urllib.error
import urllib.request
import zipfile

WIN = os.name == 'nt'
PLAT = 'windows-x64' if WIN else 'linux-x64'
MANIFESTS = (f'manifest-{PLAT}.json', 'manifest.json')   # 新しい名前（OS ごと）→ 0.1.0-1115 までの名前
REPO_RE = re.compile(r'^https://github\.com/([^/]+)/([^/]+)/releases/(?:latest/download|download/([^/]+))/?$')


def _ja():
    v = os.environ.get('SYNC_LANG') or ''
    if v:
        return v.startswith('ja')
    if WIN:
        try:
            import ctypes
            return (ctypes.windll.kernel32.GetUserDefaultUILanguage() & 0x3ff) == 0x11
        except Exception:
            return True
    return (os.environ.get('LC_ALL') or os.environ.get('LC_MESSAGES') or os.environ.get('LANG') or '').startswith('ja')


JA = _ja()


QUIET = False          # --check・--local: 文は標準エラーに出し（LOG にも残す），標準出力は JSON 1 行だけにする（11/18 W9）
LOG = []
FETCH_TIMEOUT = 120    # --check は短く（画面が待つので）


def say(ja, en=None):
    s = ja if JA or en is None else en
    if QUIET:
        LOG.append(s)
        print(s, file=sys.stderr, flush=True)
        return
    print(s, flush=True)


def ver_key(v):
    """'0.1.0-1115' のような版を比べる鍵（数は数で，ほかは文字で．'-' の後が無い方が新しい扱いはしない）"""
    out = []
    for p in re.split(r'[.\-+]', v or ''):
        out.append((0, int(p), '') if p.isdigit() else (1, 0, p))
    return out


def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for b in iter(lambda: f.read(1 << 23), b''):
            h.update(b)
    return h.hexdigest()


def read_json(p):
    with open(p, encoding='utf-8-sig') as f:
        return json.load(f)


# ---------------------------------------------------------------- 取り寄せ（URL → gh）
def gh_path():
    return shutil.which('gh')


_SSL = None


def ssl_context():
    """11/19 0.1.2: OS の証明書に，同梱の Python の certifi の証明書も足す．Windows の Python は OS が後から取り寄せる根の
    証明書を取り寄せられず，GitHub に CERTIFICATE_VERIFY_FAILED になることがあった（届かない扱いになり，更新できなかった）"""
    global _SSL
    if _SSL is None:
        _SSL = ssl.create_default_context()
        try:
            import certifi
            _SSL.load_verify_locations(certifi.where())
        except Exception:
            pass
    return _SSL


def fetch(url, out, tmp):
    """url を out に落とす．URL で落ちなければ（GitHub のリリースが非公開のあいだは 404），gh があれば gh release download で．
    どちらもだめなら理由の文を返す（落ちたら None）"""
    why = []
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'sync-strata-update'})
        with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT, context=ssl_context()) as r, open(out + '.part', 'wb') as f:
            shutil.copyfileobj(r, f, 1 << 23)
        os.replace(out + '.part', out)
        return None
    except (urllib.error.URLError, OSError, ValueError) as e:
        why.append(f'URL: {e}')
        try:
            os.remove(out + '.part')
        except OSError:
            pass
    base, name = url.rsplit('/', 1)
    m = REPO_RE.match(base + '/')
    gh = gh_path()
    if m and gh:
        d = tempfile.mkdtemp(prefix='gh-', dir=tmp)
        cmd = [gh, 'release', 'download'] + ([m.group(3)] if m.group(3) else []) + ['-R', f'{m.group(1)}/{m.group(2)}', '-p', name, '-D', d]
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace', stdin=subprocess.DEVNULL,
                               timeout=None if FETCH_TIMEOUT >= 120 else FETCH_TIMEOUT)
        except subprocess.TimeoutExpired:
            r = subprocess.CompletedProcess(cmd, 1, '', 'timed out')
        f = os.path.join(d, name)
        if r.returncode == 0 and os.path.isfile(f):
            shutil.move(f, out)
            shutil.rmtree(d, ignore_errors=True)
            return None
        why.append('gh: ' + ((r.stderr or r.stdout).strip().splitlines() or ['?'])[-1])
        shutil.rmtree(d, ignore_errors=True)
    elif m:
        why.append('gh: ' + ('ありません' if JA else 'not installed'))
    return '; '.join(why)


# ---------------------------------------------------------------- 置き場
class Feed:
    """kind: 'url'（GitHub のリリースなど）か 'dir'（フォルダー）．place は配布の道具の update に --source で渡す物"""
    def __init__(self, kind, place, manifest, base, how):
        self.kind, self.place, self.m, self.base, self.how = kind, place, manifest, base, how


def check_manifest(m, where):
    if not isinstance(m, dict) or m.get('product') != 'sync-strata' or m.get('schema') != 1:
        say(f'!! Sync-Strata の版の一覧ではありません: {where}', f'!! not a Sync-Strata manifest: {where}')
        sys.exit(5)
    if m.get('platform', PLAT) != PLAT:
        say(f'!! この一覧は別の OS 用です（{m.get("platform")}．この PC は {PLAT}）: {where}',
            f'!! this manifest is for another OS ({m.get("platform")}; this PC is {PLAT}): {where}')
        sys.exit(5)
    return m


def feed_from_dir(d, how):
    d = os.path.abspath(d)
    if os.path.isfile(d) and d.endswith('.json'):
        return Feed('dir', d, check_manifest(read_json(d), d), os.path.dirname(d), how)
    for cand in (d, os.path.join(d, 'feed')):
        for n in MANIFESTS:
            p = os.path.join(cand, n)
            if os.path.isfile(p):       # 別の OS の一覧なら check_manifest が理由を出して断る
                return Feed('dir', p, check_manifest(read_json(p), p), cand, how)
    return None


def feed_from_url(url, tmp, how):
    """url はリリースの置き場（…/releases/latest/download など）か一覧の URL．取れなければ (None, 理由)"""
    names = [url.rsplit('/', 1)[1]] if url.endswith('.json') else MANIFESTS
    base = url.rsplit('/', 1)[0] if url.endswith('.json') else url.rstrip('/')
    whys = []
    for n in names:
        out = os.path.join(tmp, 'm-' + n)
        why = fetch(f'{base}/{n}', out, tmp)
        if why:
            whys.append(f'{n}: {why}')
            continue
        try:
            m = read_json(out)
        except ValueError:
            whys.append(f'{n}: not JSON')
            continue
        if m.get('platform', PLAT) != PLAT and n == 'manifest.json':
            whys.append(f'{n}: {m.get("platform")}')
            continue
        return Feed('url', f'{base}/{n}', check_manifest(m, f'{base}/{n}'), base, how), None
    return None, ' / '.join(whys)


def latest_of(u):
    """版の名前の入った GitHub のリリースの置き場 → いちばん新しい版の置き場"""
    m = re.match(r'^(https://github\.com/[^/]+/[^/]+/releases)/download/[^/]+(/.*)?$', u or '')
    return m.group(1) + '/latest/download' if m else (u or '')


def zip_release(fn):
    """11/19 0.1.2: 版は数を「.」でつないだ形（と「-」の後の英数字）だけ．「SyncStrata-0.1.1 (1).zip」（ブラウザーが同じ名前の
    2 つ目に付ける名前）を版「0.1.1 (1)」と読んで 0.1.1 より新しいと見ていた（GitHub の Issue #1）"""
    m = re.match(r'^SyncStrata-(.+?)(-linux)?\.zip$', fn)
    if not m or bool(m.group(2)) == WIN:
        return None
    if not re.fullmatch(r'\d+(\.\d+)+(-[0-9A-Za-z]+)*', m.group(1)):
        return None
    return m.group(1)


def download_dirs(here, app):
    """配布元に届かないとき，手で置いた配布物の zip を探す場所．11/19 0.1.2: ダウンロードのフォルダーは探さない（GitHub の
    Issue #1: ブラウザーがほかの用で落とした名前の合うファイルを，確かめずに入れ替えの道具として流してしまう）．
    ダウンロードのフォルダーの zip は --source で指す"""
    ds = [here, app, os.path.dirname(app)]
    out = []
    for d in ds:
        if d and os.path.isdir(d) and os.path.abspath(d) not in out:
            out.append(os.path.abspath(d))
    return out


def find_zip(dirs):
    best = None
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for fn in names:
            rel = zip_release(fn)
            if rel and (best is None or ver_key(rel) > ver_key(best[0])):
                best = (rel, os.path.join(d, fn))
    return best


def unpack_zip(zp, tmp):
    """手で置いた配布物の zip を展開する．zip の隣（同じドライブ）に作業場を作り，書けなければ一時フォルダーに"""
    work = None
    for parent in (os.path.dirname(zp), tmp):
        try:
            work = tempfile.mkdtemp(prefix='.SyncStrata-update-', dir=parent)
            break
        except OSError:
            continue
    say(f'   展開しています: {zp}', f'   unpacking {zp}')
    with zipfile.ZipFile(zp) as z:
        for n in z.namelist():
            if n.startswith('/') or '..' in n.replace('\\', '/').split('/'):
                say(f'!! zip に置き場の外を指す名前があります: {n}', f'!! the zip has a name outside its folder: {n}')
                sys.exit(5)
        z.extractall(work)
    return work


# ---------------------------------------------------------------- 本体
def parse(argv):
    o = {'source': None, 'app_dir': None, 'sync_home': None, 'no_stop': False, 'pause': False, 'force': False, 'check': False, 'local': False}
    i = 0
    while i < len(argv):
        a = argv[i]
        k = a.lstrip('-').lower().replace('-', '_')
        if k in ('source', 'app_dir', 'appdir', 'sync_home', 'synchome', 'lang') and i + 1 < len(argv):
            k = {'appdir': 'app_dir', 'synchome': 'sync_home'}.get(k, k)
            o[k] = argv[i + 1]
            i += 2
            continue
        if k in ('no_stop', 'nostop'):
            o['no_stop'] = True
        elif k == 'pause':
            o['pause'] = True
        elif k == 'check':        # 入れ替えずに，いまの版と新しい版・変わる部品を JSON 1 行で出す（画面の「更新を確かめる」．11/18 W9）
            o['check'] = True
        elif k == 'local':        # --check のうち，ネットを見ずにいまの版だけ
            o['check'] = o['local'] = True
        elif k == 'force':        # rollback で戻した版も，もう一度入れる（配布の道具の update --force に渡す）
            o['force'] = True
        elif k in ('h', 'help'):
            say('使い方: update [--source 置き場] [--app-dir 入れた先] [--sync-home 設定の置き場] [--no-stop] [--force] [--check [--local]]\n'
                '  置き場: 配布物の zip・展開したフォルダー・GitHub のリリースの URL（無ければ いちばん新しい版を探す）\n'
                '  --check: 入れ替えずに，新しい版と変わる部品を JSON 1 行で出す（--local はネットを見ない）',
                'usage: update [--source PLACE] [--app-dir DIR] [--sync-home DIR] [--no-stop] [--force] [--check [--local]]\n'
                '  PLACE: the release zip, its unpacked folder, or a GitHub release URL (default: the newest release)\n'
                '  --check: replace nothing; print the new version and the parts that would change as one JSON line (--local: no network)')
            sys.exit(0)
        else:
            say(f'!! 分からない引数: {a}', f'!! unknown argument: {a}')
            sys.exit(2)
        i += 1
    return o


def locate_app(o, here):
    """入れた先（--app-dir → この道具の隣 → SYNC_APP_DIR → 既定の場所）"""
    app = o['app_dir']
    if not app:
        if here and os.path.isfile(os.path.join(here, 'state', 'state.json')):
            app = here
        elif os.environ.get('SYNC_APP_DIR'):
            app = os.environ['SYNC_APP_DIR']
        elif WIN:
            app = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', 'SyncStrata')
        else:
            app = os.path.join(os.environ.get('XDG_DATA_HOME') or os.path.expanduser('~/.local/share'), 'SyncStrata')
    return os.path.abspath(app)


def settings_feed(home, state):
    """settings.json の update_feed（無い・auto なら入れた先の記録の feed）→ いちばん新しい版の置き場"""
    url = ''
    try:
        url = (read_json(os.path.join(home, 'settings.json')).get('update_feed') or '')
    except (OSError, ValueError):
        pass
    if not url or url == 'auto':
        url = state.get('feed') or ''
    return latest_of(url)


def plan_components(m, state, force=False):
    """入れ替わる部品の一覧（配布の道具 installer.ps1 の Get-Plan と同じ決め方．ただしファイルは調べず，入れた先の記録（state.json）と比べる）"""
    have_all = state.get('components') or {}
    skip = state.get('skip') or {}
    out = []
    for c in m.get('components') or []:
        cid = c.get('id')
        if not cid:
            continue
        have = have_all.get(cid)
        if c.get('variant') and not have:     # 入れていない世代のエンジンは数えない（入れるのは PC に合う 1 つだけ）
            continue
        action, why = None, ''
        if not have:
            action, why = 'new', ''
        else:
            hv, nv = have.get('version') or '', str(c.get('version') or '')
            a, b = ver_key(hv), ver_key(nv)
            if a < b:
                if skip.get(cid) == nv and not force:
                    continue                  # rollback で戻した版は入れない
                action = 'update'
            elif a == b and have.get('files_sha256') and c.get('files_sha256') and have['files_sha256'] != c['files_sha256']:
                action, why = 'rebuild', 'same version, rebuilt'
        if action:
            out.append({'id': cid, 'name': c.get('name') or cid, 'action': action, 'from': (have or {}).get('version'), 'to': c.get('version'),
                        'download_bytes': int(c.get('size') or 0), 'installed_bytes': int(c.get('installed_bytes') or 0)})
    return out


def check(here, o):
    """--check: 落とさず入れ替えず，いまの版・新しい版・変わる部品を dict で返す（呼ぶ側が JSON 1 行にする）．11/18 W9
    kind: local（いまの版だけ）／feed（一覧を読めた）／zip（手で置いた zip が見つかった）／unreachable（置き場に届かない）／
          not_installed／bad_manifest（一覧の形か OS が違う）／error"""
    global QUIET, FETCH_TIMEOUT
    QUIET, FETCH_TIMEOUT = True, 20
    app = locate_app(o, here)
    out = {'ok': False, 'kind': 'error', 'platform': PLAT, 'app': app}
    state_p = os.path.join(app, 'state', 'state.json')
    if not os.path.isfile(state_p):
        out['kind'] = 'not_installed'
        return out
    try:
        state = read_json(state_p)
    except (OSError, ValueError) as e:
        out['detail'] = f'state.json: {e}'
        return out
    cur = state.get('release') or '?'
    home = o['sync_home'] or os.environ.get('SYNC_HOME') or state.get('sync_home') or (
        os.path.join(os.environ.get('LOCALAPPDATA', ''), 'SyncStrata') if WIN else
        os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'SyncStrata'))
    out.update(current=cur, last_update=(state.get('last_update') or {}).get('at'))
    if o['local']:
        out.update(ok=True, kind='local')
        return out
    tmp = tempfile.mkdtemp(prefix='syncstrata-check-')
    try:
        feed, whys, zipinfo = None, [], None
        src = o['source']
        url = ''
        try:
            if src:
                if re.match(r'^https?://', src):
                    feed, why = feed_from_url(src, tmp, 'URL')
                    if not feed:
                        whys.append(why)
                elif src.lower().endswith('.zip') and os.path.isfile(src):
                    rel = zip_release(os.path.basename(src))
                    zipinfo = (rel or '?', os.path.abspath(src))       # 大きな zip は展開せず，版の名前だけ読む
                else:
                    feed = feed_from_dir(src, 'folder')
                    if not feed:
                        whys.append('no manifest')
            else:
                url = settings_feed(home, state)
                if re.match(r'^https?://', url):
                    feed, why = feed_from_url(url, tmp, 'URL')
                    if not feed:
                        whys.append(why)
                elif url and os.path.isdir(url):
                    feed = feed_from_dir(url, 'folder')
                    if not feed:
                        whys.append('no manifest')
                else:
                    whys.append('update_feed is not set')
                if not feed:
                    z = find_zip(download_dirs(here, app))
                    if z and ver_key(z[0]) > ver_key(cur):
                        zipinfo = z
        except SystemExit:                    # check_manifest が断った（一覧の形か OS が違う）
            out.update(kind='bad_manifest', detail=' '.join(LOG[-2:]))
            return out
        if feed:
            m = feed.m
            new = m.get('release') or '?'
            comps = plan_components(m, state, o['force'])
            newer = ver_key(new) > ver_key(cur)
            notes = m.get('notes') or m.get('release_notes')
            page = re.sub(r'/releases/.*$', '/releases', feed.place) if feed.place.startswith('https://github.com/') else ''
            out.update(ok=True, kind='feed', how=feed.how, release=new, newer=newer, older=ver_key(new) < ver_key(cur),
                       available=bool(newer or comps), components=comps,
                       download_bytes=sum(c['download_bytes'] for c in comps), installed_bytes=sum(c['installed_bytes'] for c in comps),
                       built=m.get('built'), page=page)
            if isinstance(notes, (str, dict)):
                out['notes'] = notes if isinstance(notes, str) else {str(k): str(v) for k, v in notes.items()}
            return out
        if zipinfo:
            out.update(ok=True, kind='zip', release=zipinfo[0], newer=ver_key(zipinfo[0]) > ver_key(cur), available=ver_key(zipinfo[0]) > ver_key(cur),
                       zip=zipinfo[1], components=None)
            return out
        # 置き場に届かない．手で置く方法を添える
        dirs = download_dirs(here, app)
        page = re.sub(r'/releases/.*$', '/releases', url) if url.startswith('https://github.com/') else ''
        out.update(kind='unreachable', detail=' / '.join(w for w in whys if w)[:400], page=page, folders=dirs,
                   zip_name='SyncStrata-<version>.zip' if WIN else 'SyncStrata-<version>-linux.zip', feed=url or src or '')
        return out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(here, argv):
    o = parse(argv)
    global JA
    if o.get('lang'):
        JA = o['lang'].startswith('ja')
    if o['check']:
        try:
            res = check(here, o)
        except Exception as e:                # 確かめは落ちずに理由を返す
            res = {'ok': False, 'kind': 'error', 'detail': f'{type(e).__name__}: {e}'[:300]}
        print(json.dumps(res, ensure_ascii=True), flush=True)
        return 0
    # 1. 入れた先
    app = locate_app(o, here)
    state_p = os.path.join(app, 'state', 'state.json')
    if not os.path.isfile(state_p):
        setup = "setup.cmd" if WIN else "setup.sh"
        if os.path.isdir(os.path.join(app, 'app', 'launcher')):
            # 11/21 0.1.4（GitHub Issue #6）: 部品はあるのに記録だけが無い（0.1.3 までの setup が英語などの Windows で最後まで行かなかった）
            say(f'!! Sync-Strata は入っていますが、入れた記録（state\\state.json）がありません（{app}）。'
                f'新しい版の zip を展開して {setup} をもう一度流すと直ります（設定・会話・モデルは残ります）。',
                f'!! Sync-Strata is installed in {app}, but its install record (state\\state.json) is missing. '
                f'Unpack the zip of the new version and run {setup} once more to fix it (your settings, chats and models are kept).')
            return 2
        say(f'!! Sync-Strata が入っていません（{app}）。はじめて入れるときは、配布物の {setup} を流してください。',
            f'!! Sync-Strata is not installed in {app}. For a first install, run {setup} from the download.')
        return 2
    state = read_json(state_p)
    cur = state.get('release') or '?'
    home = o['sync_home'] or os.environ.get('SYNC_HOME') or state.get('sync_home') or (
        os.path.join(os.environ.get('LOCALAPPDATA', ''), 'SyncStrata') if WIN else
        os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.expanduser('~/.config'), 'SyncStrata'))
    say(f'Sync-Strata の更新: 入れた先 {app}（いまの版 {cur}）', f'Sync-Strata update: {app} (now {cur})')
    # 一時の置き場は包み（update.cmd・update.sh）が作って最後に消す（SSU_TMP）．ここで落とした物・配布の道具・流す命令を置く
    tmp = os.environ.get('SSU_TMP') or tempfile.mkdtemp(prefix='syncstrata-update-')
    work = None
    planned = False
    try:
        # 2. 置き場と一覧
        feed = None
        src = o['source']
        if src:
            if re.match(r'^https?://', src):
                feed, why = feed_from_url(src, tmp, 'URL')
                if not feed:
                    say(f'!! 置き場から一覧を取れませんでした: {src}（{why}）', f'!! could not get the manifest from {src} ({why})')
                    return 2
            elif src.lower().endswith('.zip') and os.path.isfile(src):
                work = unpack_zip(os.path.abspath(src), tmp)
                feed = feed_from_dir(next((os.path.join(work, d) for d in os.listdir(work)), work), 'zip')
            else:
                feed = feed_from_dir(src, 'folder')
            if not feed:
                say(f'!! 版の一覧が見つかりません: {src}', f'!! no manifest in {src}')
                return 2
        else:
            url = ''
            try:
                url = (read_json(os.path.join(home, 'settings.json')).get('update_feed') or '')
            except (OSError, ValueError):
                pass
            if not url or url == 'auto':
                url = state.get('feed') or ''
            url = latest_of(url)
            whys = []
            if re.match(r'^https?://', url):
                say(f'   新しい版を探しています: {url}', f'   looking for a new version: {url}')
                feed, why = feed_from_url(url, tmp, 'URL')
                if not feed:
                    whys.append(why)
            elif url and os.path.isdir(url):
                feed = feed_from_dir(url, 'folder')
            if not feed:
                dirs = download_dirs(here, app)
                z = find_zip(dirs)
                if z and ver_key(z[0]) > ver_key(cur):
                    say(f'   手で置いた配布物の zip を使います: {z[1]}', f'   using the release zip found at {z[1]}')
                    work = unpack_zip(z[1], tmp)
                    feed = feed_from_dir(next((os.path.join(work, d) for d in os.listdir(work)), work), 'zip')
                if not feed:
                    page = re.sub(r'/releases/.*$', '/releases', url) if url.startswith('https://github.com/') else ''
                    zname = 'SyncStrata-<版>.zip' if WIN else 'SyncStrata-<版>-linux.zip'
                    zname_en = 'SyncStrata-<version>.zip' if WIN else 'SyncStrata-<version>-linux.zip'
                    say('')
                    say('!! 新しい版の置き場に届きませんでした。', '!! could not reach the place of new versions.')
                    if whys:
                        say(f'   （{whys[0]}）', f'   ({whys[0]})')
                    say(f'   手で置く方法: {page or "リリースのページ"} から {zname} を落として、次のどれかのフォルダーに置き、'
                        f'もう一度 {"update.cmd" if WIN else "update.sh"} を流してください（展開しなくて大丈夫です）。',
                        f'   by hand: download {zname_en} from {page or "the release page"}, put it in one of these folders, '
                        f'and run {"update.cmd" if WIN else "update.sh"} again (no need to unpack it):')
                    for d in dirs:
                        say(f'     {d}')
                    if z:
                        say(f'   （見つかった zip は いまと同じか古い版です: {z[1]}）', f'   (the zip found is not newer: {z[1]})')
                    say(f'   置き場を直接指すこともできます: {"update.cmd" if WIN else "update.sh"} --source <zip か 展開したフォルダー>',
                        f'   or point to it: {"update.cmd" if WIN else "update.sh"} --source <zip or unpacked folder>')
                    return 2
        new = feed.m.get('release') or '?'
        say(f'   置き場の版 {new}（{feed.how}: {feed.place}）', f'   version there: {new} ({feed.how}: {feed.place})')
        # 3. 新しい配布の道具（部品 pack の installer.ps1・setup.sh）
        pc = next((c for c in feed.m.get('components', []) if c.get('id') == 'pack'), None)
        if not pc:
            say('!! 一覧に部品 pack がありません', '!! the manifest has no pack component')
            return 5
        name = pc['archive'].rsplit('/', 1)[-1]
        zp = None
        if feed.kind == 'dir':
            for cand in (os.path.join(feed.base, *pc['archive'].split('/')), os.path.join(feed.base, name)):
                if os.path.isfile(cand):
                    zp = cand
                    break
        if not zp:
            zp = os.path.join(tmp, name)
            rf = feed.m.get('release_feed') or ''
            bases = [feed.base] if feed.kind == 'url' else []
            bases += [b for b in (rf, latest_of(rf)) if b and b not in bases]
            why = 'no place'
            for b in bases:
                why = fetch(f'{b.rstrip("/")}/{name}', zp, tmp)
                if not why:
                    break
            if why:
                say(f'!! 配布の道具（{name}）を落とせませんでした（{why}）', f'!! could not download {name} ({why})')
                return 6
        if os.path.getsize(zp) != int(pc['size']) or sha256(zp) != pc['sha256']:
            say(f'!! 配布の道具（{name}）の大きさか sha256 が一覧と違います。入れ替えません。', f'!! {name}: size or sha256 differs from the manifest; nothing replaced.')
            return 5
        tool = 'installer.ps1' if WIN else 'setup.sh'
        with zipfile.ZipFile(zp) as z:
            with z.open(tool) as r, open(os.path.join(tmp, tool), 'wb') as w:
                shutil.copyfileobj(r, w)
        # 4. 止める（版が変わるときだけ．同じ版なら確かめだけで，直す物があれば配布の道具が「動いている」と知らせる）
        if (new != cur or o['force']) and not o['no_stop']:
            py = os.path.join(app, 'app', 'python', 'python.exe' if WIN else os.path.join('bin', 'python3'))
            sy = os.path.join(app, 'app', 'launcher', 'sync.py')
            if os.path.isfile(py) and os.path.isfile(sy):
                say('   アプリを止めています（sync down --all）', '   stopping the app (sync down --all)')
                env = dict(os.environ, SYNC_HOME=home)
                try:
                    r = subprocess.run([py, '-s', '-X', 'utf8', sy, 'down', '--all'], env=env, capture_output=True, text=True,
                                       encoding='utf-8', errors='replace', timeout=300)
                    for line in (r.stdout + r.stderr).strip().splitlines()[-4:]:
                        say('     ' + line)
                except (OSError, subprocess.TimeoutExpired) as e:
                    say(f'     止められませんでした: {e}', f'     could not stop it: {e}')
        elif new == cur:
            say('   いまと同じ版です。入っている部品を確かめます（rollback で戻した部品は入れません。入れるときは --force）。',
                '   same version: checking the installed parts (parts you rolled back stay as they are; use --force to install them).')
        # 5. 入れ替えは包みが流す（この Python は入れた先の app/python のことがあり，動いたままだと配布の道具が
        #    「アプリが動いている」と数えて入れ替えない．11/17 の試しで見つけた）．ここでは流す命令と記録を書いて終わる
        if WIN:
            ps_q = lambda x: "'" + str(x).replace("'", "''") + "'"
            args = ['update', '-AppDir', app, '-Source', feed.place]
            if o['sync_home'] or os.environ.get('SYNC_HOME'):
                args += ['-SyncHome', home]
            if o['force']:
                args += ['-Force']
            line = ('& powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' + ps_q(os.path.join(tmp, tool)) + ' ' +
                    ' '.join(a if a.startswith('-') or a == 'update' else ps_q(a) for a in args))
            with open(os.path.join(tmp, 'run.ps1'), 'w', encoding='utf-8-sig', newline='\r\n') as f:
                f.write(line + '\nexit $LASTEXITCODE\n')
        else:
            import shlex
            args = ['update', '--app-dir', app, '--source', feed.place, '--sync-home', home]
            if o.get('lang'):
                args += ['--lang', o['lang']]
            if o['force']:
                args += ['--force']
            with open(os.path.join(tmp, 'run.sh'), 'w', encoding='utf-8', newline='\n') as f:
                f.write('exec sh ' + ' '.join(shlex.quote(x) for x in [os.path.join(tmp, tool)] + args) + '\n')
        with open(os.path.join(tmp, 'plan.json'), 'w', encoding='utf-8') as f:
            json.dump({'cur': cur, 'new': new, 'state': state_p, 'work': work}, f, ensure_ascii=False)
        planned = True
        say('')
        return 0
    finally:
        if not planned:
            if work:
                shutil.rmtree(work, ignore_errors=True)
            if not os.environ.get('SSU_TMP'):
                shutil.rmtree(tmp, ignore_errors=True)


def report(rc):
    """6. 版を出す（配布の道具が済んだ後に包みが呼ぶ）．手で置いた zip を展開した作業場もここで消す"""
    tmp = os.environ.get('SSU_TMP') or ''
    try:
        plan = read_json(os.path.join(tmp, 'plan.json'))
    except (OSError, ValueError):
        return rc
    if plan.get('work'):
        shutil.rmtree(plan['work'], ignore_errors=True)
    cur, new, state_p = plan['cur'], plan['new'], plan['state']
    after = (read_json(state_p).get('release') or '?') if os.path.isfile(state_p) else '?'
    say('')
    if rc == 0 and after == new and new != cur:
        say(f'Sync-Strata を {cur} から {new} に更新しました。前の版に戻すときは {"rollback.cmd" if WIN else "rollback.sh"} を流してください。',
            f'Sync-Strata updated from {cur} to {new}. To go back, run {"rollback.cmd" if WIN else "rollback.sh"}.')
    elif rc == 0:
        say(f'Sync-Strata は {after} です（終了コード 0）。', f'Sync-Strata is at {after} (exit 0).')
    elif rc == 7:
        say('!! アプリが動いているので入れ替えませんでした。アプリを閉じてから、もう一度流してください。',
            '!! the app is running, so nothing was replaced. Close it and run the update again.')
    else:
        say(f'!! 更新は済みませんでした（終了コード {rc}。版は {after}）。上の「失敗」「断った」の行を見てください。',
            f'!! the update did not finish (exit {rc}; version {after}). See the lines above.')
    return rc


def run(argv):
    """包みから: prepare <ここ> [引数…] → （包みが run.ps1・run.sh を流す）→ report <ここ> <終了コード> [引数…]"""
    phase = argv[0] if argv else ''
    if phase not in ('prepare', 'report'):
        say('update_core は update.cmd・update.sh から流してください。', 'run update.cmd or update.sh, not update_core directly.')
        return 2
    here = argv[1] if len(argv) > 1 else ''
    rest = argv[2:]
    if phase == 'report':
        try:
            rc = int(rest[0])
        except (IndexError, ValueError):
            rc = 6
        rest = rest[1:]
    global JA
    for i, x in enumerate(rest):
        if x.lstrip('-').lower() == 'lang' and i + 1 < len(rest):
            JA = rest[i + 1].startswith('ja')
    try:
        rc = main(here, rest) if phase == 'prepare' else report(rc)
    except KeyboardInterrupt:
        rc = 130
    ran = os.path.isfile(os.path.join(os.environ.get('SSU_TMP') or '', 'run.ps1' if WIN else 'run.sh'))
    if '--pause' in rest and (phase == 'report' or not ran):
        try:
            input('\n' + ('Enter で閉じます…' if JA else 'Press Enter to close…'))
        except EOFError:
            pass
    return rc


if __name__ == '__main__':
    sys.exit(run(sys.argv[1:]))
