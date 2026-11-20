"""i18n/strings.json（窓の部品の画面の文の唯一の元）から，本人に見せる表 i18n-table.md を書き出す（11/20 エンジン 2）．
  py -3 -X utf8 tools/i18n_table.py
文を直すときは strings.json を直して，これを流し直し，組み直す．"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SHELL = os.path.dirname(HERE)
src = json.load(open(os.path.join(SHELL, 'i18n', 'strings.json'), encoding='utf-8'))['strings']

# 元の日本語から句読点だけ替えた物（本人の決まり: 画面の文は「、。」）
CHANGED = {'close.gui.note': 'エンジンと dsh は動き続けます．スマホや API からそのまま使えます',
           'status.sep': '，'}


def cell(s):
    return s.replace('|', '\\|').replace('\n', ' ') if s.strip() == s else '「' + s.replace('|', '\\|') + '」'


out = ['# Sync-Strata 0.1.3 の窓の部品（shell）の画面の文',
       '',
       '- 元: `i18n/strings.json`（この表は `tools/i18n_table.py` で書き出した物．直すときは strings.json を直して書き出し直す）．',
       '- 言語の決め方: 環境変数 SYNC_LANG → 起動の道具の設定 ui_lang（`sync settings get --json`）→ auto なら OS の言語'
       '（Windows は UI の言語，Linux は LC_ALL・LC_MESSAGES・LANG）→ en・ja・zh のどれでもなければ英語．',
       '- 英語・中国語の画面では，起動の道具（sync up）に SYNC_LANG=en を渡す．進み具合の途中の行（起動の道具の文）は英語で出る（中国語の文は起動の道具に無い）．',
       '- {0} {1} は差し込む値（モデルの名前・終了コード・理由など）．',
       '- 日本語の句読点: 元の文の「，」「．」を「、」「。」に替えた（本人の決まり: 画面の文は「、。」）．替えた行は「元」の欄に元の文．',
       '- 窓のタイトル・トレイのメニューも下の表から出す．トレイのメニューの言語は枠を起こしたときの物（起動中に言語を替えても次の起動から）．',
       '- 表の外: Linux のアプリの一覧に出る説明（tauri.conf.json の shortDescription．deb・AppImage の .desktop の Comment．1 つの文しか持てない）は'
       '本人の決定（11/20）で英語の「Local LLM Sync-Strata」（元は「ローカル LLM Sync-Strata」）．',
       '',
       '| id | 日本語 | 英語 | 中国語（簡体字） | 出る所 | 元 |',
       '|---|---|---|---|---|---|']
for k, v in src.items():
    out.append(f"| `{k}` | {cell(v['ja'])} | {cell(v['en'])} | {cell(v['zh'])} | {v['where']} | {cell(CHANGED[k]) if k in CHANGED else ''} |")
open(os.path.join(SHELL, 'i18n-table.md'), 'w', encoding='utf-8', newline='\n').write('\n'.join(out) + '\n')
print(len(src), 'strings ->', os.path.join(SHELL, 'i18n-table.md'))
