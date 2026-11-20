// 画面の文の言語（11/20 エンジン 2．0.1.3．GitHub Issue #5）．
// 文の元は shell/i18n/strings.json の 1 つだけ（組み立て時に読み込む）．言語の決め方は main.rs の resolve_lang
// （環境変数 SYNC_LANG → 起動の道具の設定 ui_lang → auto なら OS の言語 → どれでもなければ英語）．
// 画面（ui/*.html）へは，窓を作るときの初期化の台本で選んだ言語の分だけを window.__SYNC_I18N として渡す．
use serde_json::Value;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Lang {
    Ja,
    En,
    Zh,
}

impl Lang {
    pub fn code(self) -> &'static str {
        match self {
            Lang::Ja => "ja",
            Lang::En => "en",
            Lang::Zh => "zh",
        }
    }
    /// html の lang（CSS の :lang() で字体を選ぶ．中国語は簡体字の字形で描く）．
    fn html(self) -> &'static str {
        match self {
            Lang::Ja => "ja",
            Lang::En => "en",
            Lang::Zh => "zh-CN",
        }
    }
    /// ja・en・zh（ja_JP.UTF-8・zh-TW・en-US なども）．言語の部分（_ - . @ の前）がこの 3 つでなければ None（C・POSIX も）．
    pub fn parse(s: &str) -> Option<Lang> {
        let head = s.trim().split(|c| c == '_' || c == '-' || c == '.' || c == '@').next().unwrap_or("").to_ascii_lowercase();
        match head.as_str() {
            "ja" => Some(Lang::Ja),
            "en" => Some(Lang::En),
            "zh" => Some(Lang::Zh),
            _ => None,
        }
    }
    fn from_u8(v: u8) -> Lang {
        match v {
            1 => Lang::En,
            2 => Lang::Zh,
            _ => Lang::Ja,
        }
    }
    fn to_u8(self) -> u8 {
        match self {
            Lang::Ja => 0,
            Lang::En => 1,
            Lang::Zh => 2,
        }
    }
}

/// 決める前は日本語（起動の道具に SYNC_LANG を渡さない．最初の settings get --json は言語に関わらない）．
static CUR: AtomicU8 = AtomicU8::new(0);

pub fn set(l: Lang) {
    CUR.store(l.to_u8(), Ordering::SeqCst);
}

pub fn cur() -> Lang {
    Lang::from_u8(CUR.load(Ordering::SeqCst))
}

fn table() -> &'static Value {
    static T: OnceLock<Value> = OnceLock::new();
    T.get_or_init(|| serde_json::from_str(include_str!("../../i18n/strings.json")).unwrap_or(Value::Null))
}

/// その言語の文（無ければ日本語，それも無ければ id）．
fn text_in(l: Lang, id: &str) -> String {
    let e = table().get("strings").and_then(|s| s.get(id));
    e.and_then(|e| e.get(l.code())).or_else(|| e.and_then(|e| e.get("ja"))).and_then(Value::as_str).map(str::to_string).unwrap_or_else(|| id.to_string())
}

/// 今の言語の文．
pub fn t(id: &str) -> String {
    text_in(cur(), id)
}

/// 今の言語の文の {0} {1} … に値を入れる．
pub fn tf(id: &str, args: &[&str]) -> String {
    let mut s = t(id);
    for (i, a) in args.iter().enumerate() {
        s = s.replace(&format!("{{{i}}}"), a);
    }
    s
}

/// 窓の初期化の台本: 今の言語の文をすべて window.__SYNC_I18N に入れる（画面の i18n.js が読む）．
pub fn page_script() -> String {
    let l = cur();
    let mut s = serde_json::Map::new();
    if let Some(m) = table().get("strings").and_then(Value::as_object) {
        for k in m.keys() {
            s.insert(k.clone(), Value::String(text_in(l, k)));
        }
    }
    let v = serde_json::json!({ "lang": l.code(), "html": l.html(), "s": s });
    format!("window.__SYNC_I18N = {};", v)
}

/// OS の言語．Windows は UI の言語（GetUserDefaultUILanguage の主言語），Linux は LC_ALL → LC_MESSAGES → LANG の最初の値．
pub fn os_lang() -> Option<Lang> {
    #[cfg(windows)]
    {
        #[link(name = "kernel32")]
        extern "system" {
            fn GetUserDefaultUILanguage() -> u16;
        }
        // 主言語の番号（LANGID の下 10 ビット）: 0x11 日本語，0x09 英語，0x04 中国語
        match unsafe { GetUserDefaultUILanguage() } & 0x3ff {
            0x11 => Some(Lang::Ja),
            0x09 => Some(Lang::En),
            0x04 => Some(Lang::Zh),
            _ => None,
        }
    }
    #[cfg(not(windows))]
    {
        for k in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let Some(v) = std::env::var(k).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty()) {
                return Lang::parse(&v);
            }
        }
        None
    }
}
