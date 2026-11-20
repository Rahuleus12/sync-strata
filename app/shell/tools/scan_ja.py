"""窓の部品の日本語の残りを洗い出す（11/20 エンジン 2．0.1.3 の i18n の確かめ）．
  py -3 -X utf8 tools/scan_ja.py src            ui/*.html・*.js・*.css と src-tauri/src/*.rs の，コメントを除いた日本語の行
  py -3 -X utf8 tools/scan_ja.py bin <exe|AppImage の中の実行ファイル>...   バイナリの中の UTF-8 の日本語の文字列（4 文字以上）
文の元 i18n/strings.json に入っている文はバイナリにあって当然なので，bin では「表の文」として分けて数える．"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL = os.path.dirname(HERE)
JA = re.compile(r'[぀-ヿ㐀-鿿！-｠]')


def src_scan():
    files = []
    for d, exts in (('ui', ('.html', '.js', '.css')), (os.path.join('src-tauri', 'src'), ('.rs',))):
        for f in sorted(os.listdir(os.path.join(SHELL, d))):
            if f.endswith(exts):
                files.append(os.path.join(d, f))
    n = 0
    for f in files:
        in_block = False
        for i, ln in enumerate(open(os.path.join(SHELL, f), encoding='utf-8'), 1):
            s = ln.strip()
            code = s
            if in_block:
                if '*/' in s:
                    in_block = False
                    code = s.split('*/', 1)[1]
                else:
                    continue
            if code.startswith('/*') and '*/' not in code:
                in_block = True
                continue
            code = re.sub(r'/\*.*?\*/', '', code)
            code = re.sub(r'<!--.*?-->', '', code)
            # 行の終わりのコメント（文字列の外の // だけ．簡単に: 引用符の数が偶数の位置の // ）
            out, q = [], None
            j = 0
            while j < len(code):
                ch = code[j]
                if q:
                    if ch == '\\':
                        out.append(code[j:j + 2]); j += 2; continue
                    if ch == q:
                        q = None
                elif ch in '"\'`':
                    q = ch
                elif code.startswith('//', j):
                    break
                out.append(ch)
                j += 1
            code = ''.join(out)
            if JA.search(code):
                n += 1
                print(f'{f}:{i}: {s[:160]}')
    print(f'== {n} lines with Japanese outside comments')


def bin_scan(paths):
    table = json.load(open(os.path.join(SHELL, 'i18n', 'strings.json'), encoding='utf-8'))['strings']
    known = set()
    for v in table.values():
        for part in re.split(r'\{\d+\}', v['ja']):
            if JA.search(part):
                known.add(part.strip())
    for p in paths:
        data = open(p, 'rb').read()
        found = {}
        for m in re.finditer(rb'(?:[\xe3-\xe9\xef][\x80-\xbf]{2}|[\x20-\x7e])+', data):
            try:
                s = m.group().decode('utf-8')
            except UnicodeDecodeError:
                continue
            if len(JA.findall(s)) >= 4:
                found[s.strip()] = found.get(s.strip(), 0) + 1
        in_table = {s: c for s, c in found.items() if any(k and k in s for k in known)}
        rest = {s: c for s, c in found.items() if s not in in_table}
        print(f'== {p}: {len(found)} Japanese strings, {len(in_table)} from strings.json (the table), {len(rest)} others:')
        for s in sorted(rest):
            print('   ', s[:200])


if __name__ == '__main__':
    if sys.argv[1] == 'src':
        src_scan()
    else:
        bin_scan(sys.argv[2:])
