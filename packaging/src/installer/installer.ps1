<#
Sync-Strata の配布物の本体．setup.cmd・update.cmd・uninstall.cmd から呼ばれ，同じ「調べて足りない物だけ入れる」処理を共有する．

  setup     : 版の一覧（manifest.json）の部品を 1 つずつ調べ，無い物・古い物・壊れた物だけ入れる．
              アイコン（デスクトップとスタートメニュー）を作り，モデルの置き場を探して SYNC_HOME の settings.json に書く．
  update    : 置き場（-Source，無ければ settings.json の update_feed，無ければ一覧の update_feed）の新しい一覧を見て，
              変わった部品だけ落として入れ替える．入れ替える前の版を 1 つ残す．モデルと SYNC_HOME には触れない．
  rollback  : 直前の update で入れ替えた部品を，残してある 1 つ前の版に戻す．
  uninstall : アプリと作ったアイコンを消す．モデルと SYNC_HOME は聞いてから（既定は残す）．
  status    : 入っている部品と版を出す．

置き場は 3 つ: アプリ（-AppDir．更新で入れ替える）／モデル（settings.json の models_dir．落とし直さない）／
利用者の物（SYNC_HOME．設定と会話．update と rollback は触らない）．
管理者の権限は使わない（PATH・レジストリ・Program Files に触れない）．何度流しても同じ結果になる．
終了コード: 0 済んだ（何もすることが無かったも含む），5 断った（sha256 の不一致・一覧の誤り），6 失敗（前の版のまま），7 動いているので入れ替えない．
#>
param(
    [Parameter(Position = 0)][ValidateSet('setup', 'update', 'rollback', 'uninstall', 'status')][string]$Command = 'setup',
    [string]$Source,        # 版の一覧の置き場（フォルダーか http(s) の URL）
    [string]$AppDir,        # アプリを入れる先（既定 %LOCALAPPDATA%\Programs\SyncStrata）
    [string]$SyncHome,      # 利用者の物の置き場（既定 $env:SYNC_HOME，無ければ %LOCALAPPDATA%\SyncStrata）
    [string]$ModelsDir,     # モデルの置き場を利用者が指す（setup だけ）
    [string]$ShortcutDir,   # 試し用: アイコンをデスクトップとスタートメニューではなく，このフォルダーの下に作る
    [switch]$NoShortcuts,   # アイコンを作らない
    [switch]$NoModelSearch, # モデルの置き場を探さない
    [switch]$Full,          # 入っている部品の全ファイルの sha256 を計り直す（既定は大きさか時刻が変わった物だけ）
    [switch]$Force,         # rollback で戻した版も，もう一度入れる
    [switch]$Yes,           # uninstall で聞かない（-RemoveData が無ければモデルと SYNC_HOME は残す）
    [switch]$RemoveData,    # uninstall でモデルと SYNC_HOME も消す
    [string]$Report         # 結果を JSON でこのファイルに書く（試し用）
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'     # PowerShell 5.1 の進み具合の表示は Invoke-WebRequest をとても遅くする
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8 = New-Object Text.UTF8Encoding $false   # 書くファイルは BOM なしの UTF-8（Python の json.load が BOM で止まるため）
$Clock = [Diagnostics.Stopwatch]::StartNew()
$Sha = [Security.Cryptography.SHA256]::Create()
$Results = New-Object Collections.ArrayList    # 最後に 1 行ずつ出す結果
$Comps = New-Object Collections.ArrayList      # -Report 用の部品ごとの数字

# ---------------------------------------------------------------- 置き場
if (-not $AppDir) { $AppDir = if ($env:SYNC_APP_DIR) { $env:SYNC_APP_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\SyncStrata' } }
$AppDir = [IO.Path]::GetFullPath($AppDir).TrimEnd('\')
if (-not $SyncHome) { $SyncHome = if ($env:SYNC_HOME) { $env:SYNC_HOME } else { Join-Path $env:LOCALAPPDATA 'SyncStrata' } }
$SyncHome = [IO.Path]::GetFullPath($SyncHome).TrimEnd('\')
$AppBin = Join-Path $AppDir 'app'              # 部品ごとに app\<id>\
$PrevDir = Join-Path $AppBin '.prev'           # 入れ替える前の版（部品ごとに 1 つ）
$StageDir = Join-Path $AppBin '.stage'         # 展開と確かめの作業場（確かめてから名前を変えて入れる）
$StateDir = Join-Path $AppDir 'state'
$StatePath = Join-Path $StateDir 'state.json'
$SettingsPath = Join-Path $SyncHome 'settings.json'

function Say([string]$s) { Write-Host $s }
function Add-Result([string]$tag, [string]$what) { [void]$Results.Add(('  [{0}] {1}' -f $tag, $what)) }
function Read-JsonFile([string]$p) { [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json }
function Write-JsonFile($obj, [string]$p) {
    $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
    [IO.File]::WriteAllText("$p.tmp", ($obj | ConvertTo-Json -Depth 30), $Utf8)
    Move-Item -LiteralPath "$p.tmp" $p -Force
}
function Get-Sha256([string]$p) {
    $fs = [IO.File]::OpenRead($p)
    try { return ([BitConverter]::ToString($Sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() } finally { $fs.Dispose() }
}
function Remove-Tree([string]$p) {
    # Remove-Item -Recurse は数万ファイルで遅いので rmdir を使う（node_modules で 10 倍以上違う）
    if (Test-Path -LiteralPath $p) { cmd.exe /c "rmdir /s /q `"$p`"" | Out-Null }
    if (Test-Path -LiteralPath $p) { throw "消せなかった（使われているファイルがある）: $p" }
}
function Get-Prop($o, [string]$name, $default = $null) {
    if ($null -ne $o -and $o.PSObject.Properties[$name]) { return $o.$name } else { return $default }
}
function Set-Prop($o, [string]$name, $value) { $o | Add-Member -Force -NotePropertyName $name -NotePropertyValue $value }
function Fmt-MB([double]$b) { return ('{0:N0} MB' -f ($b / 1MB)) }

# 版の比べ: "0.2.0-rc.2" のような文字列を数の並びで比べる．数でない部分は文字で比べる．
function Compare-Version([string]$a, [string]$b) {
    $pa = ($a -split '[.\-+]'); $pb = ($b -split '[.\-+]')
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { '' }; $y = if ($i -lt $pb.Count) { $pb[$i] } else { '' }
        if ($x -eq $y) { continue }
        $nx = 0; $ny = 0
        if ([int64]::TryParse($x, [ref]$nx) -and [int64]::TryParse($y, [ref]$ny)) { return [Math]::Sign($nx - $ny) }
        if ($x -eq '') { return 1 }   # 1.0 は 1.0-rc より新しい
        if ($y -eq '') { return -1 }
        return [Math]::Sign([string]::CompareOrdinal($x, $y))
    }
    return 0
}

# ---------------------------------------------------------------- 記録（state.json）
function Read-State {
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $s = Read-JsonFile $StatePath
            if ((Get-Prop $s 'product') -eq 'sync-strata') {
                foreach ($k in 'components', 'prev', 'skip') { if ($null -eq (Get-Prop $s $k)) { Set-Prop $s $k ([pscustomobject]@{}) } }
                foreach ($k in 'last_update', 'release', 'feed') { if (-not $s.PSObject.Properties[$k]) { Set-Prop $s $k $null } }
                if ($null -eq (Get-Prop $s 'shortcuts')) { Set-Prop $s 'shortcuts' @() }
                return $s
            }
        } catch { }
    }
    return [pscustomobject]@{ product = 'sync-strata'; schema = 1; release = ''; components = [pscustomobject]@{}; prev = [pscustomobject]@{};
        last_update = $null; skip = [pscustomobject]@{}; shortcuts = @(); feed = ''
    }
}
$State = Read-State

# ---------------------------------------------------------------- 取り寄せ（11/17 H）
# GitHub のリリースが非公開のあいだは URL では落ちない（404）．gh（GitHub CLI）があり，その人に見える置き場なら gh release download で落とす．
function Get-GhRelease([string]$u) {
    if ($u -match '^https://github\.com/([^/]+)/([^/]+)/releases/(latest/download|download/([^/]+))/([^/?#]+)$') {
        return [pscustomobject]@{ repo = "$($Matches[1])/$($Matches[2])"; tag = $Matches[4]; name = [Uri]::UnescapeDataString($Matches[5]) }
    }
    return $null
}
function Invoke-Download([string]$u, [string]$out) {
    try { Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing; return } catch { $why = $_.Exception.Message }
    $g = Get-GhRelease $u
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $g -or -not $gh) { throw "落とせなかった: $u（$why）" }
    $d = Join-Path ([IO.Path]::GetTempPath()) ('syncstrata-gh-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $d | Out-Null
    try {
        $a = @('release', 'download')
        if ($g.tag) { $a += $g.tag }
        $a += @('-R', $g.repo, '-p', $g.name, '-D', $d)
        $ErrorActionPreference = 'Continue'      # gh の stderr を PowerShell 5.1 の止まる誤りにしない（この関数の中だけ）
        $msg = & $gh.Source @a 2>&1 | ForEach-Object { "$_" }
        $rc = $LASTEXITCODE
        $f = Join-Path $d $g.name
        if ($rc -ne 0 -or -not (Test-Path -LiteralPath $f)) { throw "落とせなかった: $u（URL: $why．gh: $((@($msg) + '?')[0])）" }
        Move-Item -LiteralPath $f $out -Force
    } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- 版の一覧
# 11/17 H: 一覧の名前は OS ごと（manifest-windows-x64.json．GitHub のリリースは平らな置き場で，Linux の一覧とぶつかるため）．
# 無ければ 0.1.0-1115 までの manifest.json．別の OS の一覧は断る（前は確かめが無く，Linux の部品を入れてしまう作りだった）．
$Platform = 'windows-x64'
function Open-Feed([string]$src) {
    $isUrl = $src -match '^https?://'
    $names = @("manifest-$Platform.json", 'manifest.json')
    if ($isUrl) {
        $cands = if ($src -match '\.json$') { @($src) } else { @($names | ForEach-Object { $src.TrimEnd('/') + '/' + $_ }) }
        $tmpm = Join-Path ([IO.Path]::GetTempPath()) ('syncstrata-m-' + [Guid]::NewGuid().ToString('N') + '.json')
        $whys = @(); $murl = $null
        foreach ($c in $cands) {
            try { Invoke-Download $c $tmpm; $murl = $c; break } catch { $whys += $_.Exception.Message }
        }
        if (-not $murl) { throw ($whys -join ' / ') }
        try { $m = [IO.File]::ReadAllText($tmpm, [Text.Encoding]::UTF8) | ConvertFrom-Json } finally { Remove-Item -LiteralPath $tmpm -Force -ErrorAction SilentlyContinue }
        $base = $murl.Substring(0, $murl.LastIndexOf('/') + 1)
    } else {
        $mp = if ($src -match '\.json$') { $src } else { @($names | ForEach-Object { Join-Path $src $_ } | Where-Object { Test-Path -LiteralPath $_ }) + @(Join-Path $src 'manifest.json') | Select-Object -First 1 }
        if (-not (Test-Path -LiteralPath $mp)) { throw "版の一覧が無い: $mp" }
        $base = [IO.Path]::GetFullPath((Split-Path -Parent $mp)).TrimEnd('\') + '\'
        $m = Read-JsonFile $mp
    }
    if ((Get-Prop $m 'product') -ne 'sync-strata' -or (Get-Prop $m 'schema') -ne 1) { $script:Refused = $true; throw "Sync-Strata の版の一覧ではない（product・schema が違う）: $src" }
    $pf = [string](Get-Prop $m 'platform' '')
    if ($pf -and $pf -ne $Platform) { $script:Refused = $true; throw "この一覧は別の OS 用（$pf．この PC は $Platform）: $src" }
    return [pscustomobject]@{ url = $isUrl; base = $base; m = $m; where = $src }
}

# 部品の zip を手元に用意して，大きさと sha256 を確かめる．フォルダーの置き場ならその場で確かめる（写さない）．
function Get-Archive($feed, $c) {
    $rel = [string]$c.archive
    if ($feed.url) {
        # 11/16 S2: URL の置き場（GitHub のリリース）は平らなので，ファイルの名前だけで取る
        $u = if ($rel -match '^https?://') { $rel } else { [string](New-Object Uri ((New-Object Uri $feed.base), [IO.Path]::GetFileName($rel))) }
        $dl = Join-Path $StateDir 'download'
        New-Item -ItemType Directory -Force $dl | Out-Null
        $p = Join-Path $dl ([IO.Path]::GetFileName(([Uri]$u).AbsolutePath))
        if (-not ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -eq [int64]$c.size -and (Get-Sha256 $p) -eq $c.sha256)) {
            Invoke-Download $u $p
        }
    } else {
        $p = [IO.Path]::GetFullPath((Join-Path $feed.base ($rel -replace '/', '\')))
        if (-not $p.StartsWith($feed.base, [StringComparison]::OrdinalIgnoreCase)) { throw "一覧が置き場の外のファイルを指している: $rel" }
        if (-not (Test-Path -LiteralPath $p)) {
            # 11/16 S2: 手で落とした部品の zip を setup の隣（展開したフォルダーか，その 1 つ上）に置けば，それを使う（ネットに出られない人・取りこぼし）
            foreach ($dd in @($script:DistRoot, $(if ($script:DistRoot) { Split-Path -Parent $script:DistRoot }))) {
                if ($dd -and (Test-Path -LiteralPath (Join-Path $dd ([IO.Path]::GetFileName($rel))))) { $p = Join-Path $dd ([IO.Path]::GetFileName($rel)); break }
            }
        }
        if (-not (Test-Path -LiteralPath $p)) {
            $uf = [string](Get-Prop $feed.m 'release_feed' '')     # この版の zip の置き場（無ければ update_feed）
            if (-not $uf) { $uf = [string](Get-Prop $feed.m 'update_feed' '') }
            if ($uf -match '^https?://') {
                $u = $uf.TrimEnd('/') + '/' + [IO.Path]::GetFileName($rel)     # GitHub のリリースは平らな置き場（components\ の段が無い）
                $dl = Join-Path $StateDir 'download'
                New-Item -ItemType Directory -Force $dl | Out-Null
                $p = Join-Path $dl ([IO.Path]::GetFileName($rel))
                Say ('   {0} は手元に無いので更新の置き場から取ります（{1:N0} MB）' -f $c.id, ([double]$c.size / 1MB))
                if (-not ((Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).Length -eq [int64]$c.size)) { Invoke-Download $u $p }
            } else { throw "部品の zip が無い: $p（更新の置き場も決まっていない）" }
        }
    }
    $len = (Get-Item -LiteralPath $p).Length
    if ($len -ne [int64]$c.size) { $script:Refused = $true; throw "$($c.id): zip の大きさが一覧と違う（$len，一覧 $($c.size)）" }
    $h = Get-Sha256 $p
    if ($h -ne $c.sha256) { $script:Refused = $true; throw "$($c.id): zip の sha256 が一覧と違う（$h）" }
    return $p
}

# ---------------------------------------------------------------- 部品を調べる
# 部品のフォルダー（app\<id>）には _pkg\component.json（id・版・files_sha256）と _pkg\files.tsv（道のり・大きさ・sha256）がある．
# 入れた直後の大きさと時刻を state\<id>.scan.tsv に控え，次からは大きさか時刻が変わったファイルだけ sha256 を計る（-Full で全部）．
function Read-Scan([string]$path) {
    $h = @{}
    if ($path -and (Test-Path -LiteralPath $path)) { foreach ($l in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) { $i = $l.IndexOf("`t"); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) } } }
    return $h
}
function Write-Scan([string]$dir, [string]$path) {
    $list = [IO.File]::ReadAllLines((Join-Path $dir '_pkg\files.tsv'), [Text.Encoding]::UTF8)
    $out = New-Object Collections.Generic.List[string]
    foreach ($l in $list) {
        $f = $l.Split("`t"); $fi = New-Object IO.FileInfo (Join-Path $dir $f[0])
        if ($fi.Exists) { $out.Add(('{0}{1}{2}{1}{3}' -f $f[0], "`t", $fi.Length, $fi.LastWriteTimeUtc.Ticks)) }
    }
    New-Item -ItemType Directory -Force (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllLines($path, $out, $Utf8)
}
# $sizesOnly: 展開した直後に使う．zip の sha256 は一覧と照らし済みで，展開の誤りは zip の CRC で tar が止めるので，
# 大きさだけ見る（書いたばかりの数万ファイルを読み直すと，ウイルス対策の検査が乗って dsh で約 170 秒かかった）．
function Test-Component([string]$dir, [string]$scanPath, [bool]$full, [bool]$sizesOnly = $false) {
    $r = [pscustomobject]@{ state = 'missing'; version = ''; files_sha256 = ''; files = 0; bad = @(); hashed = 0; bytes = 0 }
    $meta = Join-Path $dir '_pkg\component.json'; $list = Join-Path $dir '_pkg\files.tsv'
    if (-not (Test-Path -LiteralPath $dir)) { return $r }
    if (-not ((Test-Path -LiteralPath $meta) -and (Test-Path -LiteralPath $list))) { $r.state = 'broken'; $r.bad = @('_pkg'); return $r }
    $m = Read-JsonFile $meta
    $r.version = [string]$m.version; $r.files_sha256 = [string]$m.files_sha256
    if ((Get-Sha256 $list) -ne $r.files_sha256) { $r.state = 'broken'; $r.bad = @('_pkg\files.tsv'); return $r }
    $scan = if ($full) { @{} } else { Read-Scan $scanPath }
    $bad = New-Object Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($list, [Text.Encoding]::UTF8)) {
        $f = $l.Split("`t"); $r.files++
        $fi = New-Object IO.FileInfo (Join-Path $dir $f[0])
        if (-not $fi.Exists -or $fi.Length -ne [int64]$f[1]) { $bad.Add($f[0]); continue }
        $r.bytes += $fi.Length
        if ($sizesOnly) { continue }
        if ($scan[$f[0]] -eq ('{0}{1}{2}' -f $fi.Length, "`t", $fi.LastWriteTimeUtc.Ticks)) { continue }
        $r.hashed++
        if ((Get-Sha256 $fi.FullName) -ne $f[2]) { $bad.Add($f[0]) }
    }
    $r.bad = @($bad); $r.state = if ($bad.Count) { 'broken' } else { 'ok' }
    return $r
}

# 調べた結果と一覧から，何をするかを決める．
function Get-Plan($c, $have) {
    $id = [string]$c.id
    if ($have.state -eq 'missing') { return @('install', '新規') }
    if ($have.state -eq 'broken') {
        if ($have.version -eq $c.version) { return @('repair', ('壊れていた {0} ファイルを含めて入れ直す' -f $have.bad.Count)) }
        return @('install', ('壊れていた {0} を {1} に' -f $have.version, $c.version))
    }
    $cmp = Compare-Version $have.version ([string]$c.version)
    if ($cmp -gt 0) { return @('skip', ('入っている {0} の方が新しい' -f $have.version)) }
    if ($cmp -lt 0) {
        if ((Get-Prop $State.skip $id) -eq $c.version -and -not $Force) { return @('skip', ('{0} は戻した版なので入れない（-Force で入れる）' -f $c.version)) }
        return @('install', ('{0} → {1}' -f $have.version, $c.version))
    }
    if ($have.files_sha256 -ne $c.files_sha256) { return @('install', ('同じ版 {0} の作り直し' -f $c.version)) }
    return @('skip', 'そろっている')
}

# 確かめてから入れる: zip を作業場に展開 → 一覧の files_sha256 と全ファイルの sha256 → 前の版を .prev へ（同じ版の修理なら捨てる）→ 名前を変えて入れる．
function Install-Component($c, [string]$zip, [bool]$keepPrev) {
    $id = [string]$c.id
    $stage = Join-Path $StageDir $id
    Remove-Tree $stage
    New-Item -ItemType Directory -Force $stage | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xf $zip -C $stage
    if ($LASTEXITCODE -ne 0) { throw "$id の展開に失敗（tar $LASTEXITCODE）" }
    $t = Test-Component $stage '' $false $true
    if ($t.state -ne 'ok' -or $t.files_sha256 -ne $c.files_sha256 -or $t.version -ne $c.version) {
        Remove-Tree $stage; $script:Refused = $true
        throw "$id の中身が一覧と合わない（$($t.state)，違うファイル $($t.bad.Count)）"
    }
    $dest = Join-Path $AppBin $id
    if (Test-Path -LiteralPath $dest) {
        if ($keepPrev) {
            $p = Join-Path $PrevDir $id
            New-Item -ItemType Directory -Force $PrevDir | Out-Null
            Remove-Tree $p
            [IO.Directory]::Move($dest, $p)
            $ps = Join-Path $StateDir "$id.scan.tsv"
            if (Test-Path -LiteralPath $ps) { Move-Item -LiteralPath $ps (Join-Path $StateDir "prev-$id.scan.tsv") -Force }
        } else { Remove-Tree $dest }
    }
    [IO.Directory]::Move($stage, $dest)
    Write-Scan $dest (Join-Path $StateDir "$id.scan.tsv")
    return $t
}

# アプリの部品（app\ の下の exe）から動いているプロセスを探す（エンジン・dsh・中継・アプリの枠）．
function Get-AppProcesses {
    $root = $AppBin + '\'
    @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })
}
function Assert-NotRunning([string]$what) {
    $ps = @(Get-AppProcesses)     # 1 つだけのときも数えられるよう配列にする
    if ($ps.Count) {
        Say ''
        Say "!! Sync-Strata が動いているので$($what)ません（使っているファイルは入れ替えられない）:"
        foreach ($p in $ps) { Say ('     {0}（番号 {1}）{2}' -f $p.Name, $p.ProcessId, $p.ExecutablePath.Substring($AppBin.Length + 1)) }
        Say '   アプリの画面を「全て閉じる」で閉じるか，sync down --all で止めてから，もう一度流してください．'
        $script:ExitCode = 7
        return $false
    }
    return $true
}

# ---------------------------------------------------------------- 部品をそろえる（setup と update が共有する）
# 11/15 夜: 世代ごとのエンジン（一覧の部品に variant がある物．engine-cuda13・engine-cuda12・engine-hip-*）は，この PC の GPU に合う 1 つだけ入れる．
# 1 回目は variant の無い部品（Python と起動の道具を含む）．その後に起動の道具の sync env で GPU を調べ（表は sync_env.py の 1 か所），
# 2 回目にその variant の部品だけを入れる．合う物が無い（対応外）ときは入れない（最後の一覧に理由が出る）．
$script:EngineVariant = $null
function Get-EngineVariant {
    $py = Join-Path $AppBin 'python\python.exe'; $sy = Join-Path $AppBin 'launcher\sync.py'
    if (-not ((Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $sy))) { return $null }
    try {
        $env:SYNC_HOME = $SyncHome
        $j = (& $py -s -X utf8 $sy env --json --ascii 2>$null | Select-Object -Last 1) | ConvertFrom-Json
        return [string]$j.engine
    } catch { return $null }
}
function Sync-Components($feed, [bool]$isUpdate, [bool]$variants = $false) {
    $plans = @()
    foreach ($c in $feed.m.components) {
        $v = [string](Get-Prop $c 'variant' '')
        if ($variants) { if (-not $v -or $v -ne $script:EngineVariant) { continue } } elseif ($v) { continue }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $have = Test-Component (Join-Path $AppBin $c.id) (Join-Path $StateDir "$($c.id).scan.tsv") ([bool]$Full)
        $p = Get-Plan $c $have
        $plans += [pscustomobject]@{ c = $c; have = $have; action = $p[0]; why = $p[1]; check_s = $sw.Elapsed.TotalSeconds }
    }
    $todo = @($plans | Where-Object { $_.action -ne 'skip' })
    if ($todo.Count -and -not (Assert-NotRunning '入れ替え')) {
        foreach ($x in $plans) { Add-Result ($(if ($x.action -eq 'skip') { '飛ばした' } else { '止めた' })) ('{0} {1}（{2}）' -f $x.c.id, $x.c.version, $x.why) }
        return
    }
    $changed = @(); $from = [pscustomobject]@{}; $to = [pscustomobject]@{}
    foreach ($x in $plans) {
        $c = $x.c; $id = [string]$c.id
        $rec = [ordered]@{ id = $id; action = $x.action; from = $x.have.version; to = [string]$c.version; check_s = [Math]::Round($x.check_s, 2);
            hashed_on_check = $x.have.hashed; files = [int]$c.files; bytes = [int64]$c.installed_bytes; install_s = 0
        }
        if ($x.action -eq 'skip') {
            # 11/21 0.1.4（#6）: 記録（state.json）が無い入れ先に setup を流し直したとき，入れ替えずに済んだ部品も記録に載せる
            # （載せないと，更新の道具が「入っていない」と見て全部を落とし直す）．中身は入っている物の版と files_sha256
            if ($null -eq (Get-Prop $State.components $id) -and $x.have.version) {
                Set-Prop $State.components $id ([pscustomobject]@{ version = [string]$x.have.version; files_sha256 = [string]$x.have.files_sha256;
                    sha256 = $(if ($x.have.files_sha256 -eq $c.files_sha256) { [string]$c.sha256 } else { '' }); at = (Get-Date).ToString('s') })
            }
            Add-Result '飛ばした' ('{0} {1}（{2}．調べ {3:N1} 秒）' -f $id, $c.version, $x.why, $x.check_s)
            [void]$Comps.Add([pscustomobject]$rec); continue
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            Say ('== {0}（{1}）: {2}' -f $id, $c.name, $x.why)
            $zip = Get-Archive $feed $c
            $keep = ($x.action -eq 'install' -and $x.have.state -ne 'missing')   # 版が変わるときだけ前の版を残す
            [void](Install-Component $c $zip $keep)
            if ($feed.url) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
            if ($keep) {
                Set-Prop $State.prev $id ([pscustomobject]@{ version = $x.have.version; files_sha256 = $x.have.files_sha256 })
                $changed += $id; Set-Prop $from $id $x.have.version; Set-Prop $to $id ([string]$c.version)
            }
            Set-Prop $State.components $id ([pscustomobject]@{ version = [string]$c.version; files_sha256 = [string]$c.files_sha256; sha256 = [string]$c.sha256; at = (Get-Date).ToString('s') })
            $tag = @{ install = '入れた'; repair = '直した' }[$x.action]
            $rec.install_s = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
            Add-Result $tag ('{0} {1}（{2}．{3:N0} ファイル {4}．{5:N1} 秒）' -f $id, $c.version, $x.why, [int]$c.files, (Fmt-MB ([double]$c.installed_bytes)), $sw.Elapsed.TotalSeconds)
        } catch {
            $rec.action = 'failed'
            Add-Result '失敗' ('{0} {1}: {2}（前の版のまま）' -f $id, $c.version, $_.Exception.Message)
            if (-not $script:ExitCode) { $script:ExitCode = $(if ($script:Refused) { 5 } else { 6 }) }
        }
        [void]$Comps.Add([pscustomobject]$rec)
    }
    if ($changed.Count) {
        $State.last_update = [pscustomobject]@{ at = (Get-Date).ToString('s'); ids = $changed; from = $from; to = $to; command = $Command }
    }
    $State.release = [string]$feed.m.release
    Remove-Tree $StageDir
}

# ---------------------------------------------------------------- アイコン
function Get-ShortcutDirs {
    if ($ShortcutDir) { return @{ desktop = (Join-Path $ShortcutDir 'Desktop'); startmenu = (Join-Path $ShortcutDir 'StartMenu\Sync-Strata') } }
    return @{ desktop = [Environment]::GetFolderPath('Desktop'); startmenu = (Join-Path ([Environment]::GetFolderPath('Programs')) 'Sync-Strata') }
}
# 11/21 0.1.4（GitHub Issue #6）: アイコンの名前と説明は Windows の表示の言語で選ぶ（ja・zh．ほかは en）．
# 一覧の name・description が日本語，name_en・name_zh・description_en・description_zh が訳（無ければ日本語のまま）．
# 試しでは $env:SYNC_SHORTCUT_LANG（ja・en・zh）で選べる
function Get-ShortcutLang {
    $l = [string]$env:SYNC_SHORTCUT_LANG
    if ($l -in @('ja', 'en', 'zh')) { return $l }
    $n = ''; try { $n = [string](Get-UICulture).Name } catch { }
    if ($n -like 'ja*') { return 'ja' }
    if ($n -like 'zh*') { return 'zh' }
    return 'en'
}
function Get-ShortcutText($s, [string]$key, [string]$lang, [string]$fallback) {
    $t = ''
    if ($lang -ne 'ja') {
        $t = [string](Get-Prop $s ($key + '_' + $lang) '')
        if (-not $t) { $t = [string](Get-Prop $s ($key + '_en') '') }
    }
    if (-not $t) { $t = [string](Get-Prop $s $key $fallback) }
    return $t
}
function Test-Ansi([string]$t) { $e = [Text.Encoding]::Default; return ($e.GetString($e.GetBytes($t)) -eq $t) }
function Set-Shortcuts($m) {
    $dirs = Get-ShortcutDirs
    $lang = Get-ShortcutLang
    $made = @(); $had = 0; $ws = New-Object -ComObject WScript.Shell
    foreach ($s in @(Get-Prop $m 'shortcuts' @())) {
        $name = Get-ShortcutText $s 'name' $lang ([string]$s.name)
        $target = Join-Path $AppDir (([string]$s.target) -replace '/', '\')
        if (-not (Test-Path -LiteralPath $target)) { Add-Result '飛ばした' ('アイコン「{0}」（行き先 {1} がまだ無い）' -f $name, $s.target); continue }
        # 説明の欄も WScript.Shell がシステムの ANSI の文字コードに落とす（無い字は「?」になる）．落ちる字があれば英語の説明に，それも落ちれば空に
        $desc = Get-ShortcutText $s 'description' $lang $name
        if (-not (Test-Ansi $desc)) {
            $desc = [string](Get-Prop $s 'description_en' (Get-Prop $s 'name_en' ''))
            if (-not (Test-Ansi $desc)) { $desc = '' }
        }
        foreach ($w in @($s.where)) {
            $d = $dirs[[string]$w]; if (-not $d) { continue }
            New-Item -ItemType Directory -Force $d | Out-Null
            $lnk = Join-Path $d ($name + '.lnk')
            if (Test-Path -LiteralPath $lnk) { $had++ }
            # WScript.Shell は道のりもシステムの ANSI の文字コードに落とすので，英語などの Windows では日本語の名前が「?」になり，
            # Save() が失敗して setup が最後まで行かなかった（#6）．英数字の仮の名前で作ってから，Unicode のまま扱える PowerShell で名前を変える．
            # 1 つ作れなくても setup は止めない（注意に出す）
            $tmp = Join-Path $d ('~sync-strata-' + [Guid]::NewGuid().ToString('N') + '.lnk')
            try {
                $sc = $ws.CreateShortcut($tmp)
                $sc.TargetPath = $target; $sc.Arguments = [string](Get-Prop $s 'args' ''); $sc.WorkingDirectory = (Split-Path -Parent $target)
                $icon = Get-Prop $s 'icon'; if ($icon) { $sc.IconLocation = (Join-Path $AppDir ($icon -replace '/', '\')) }
                if ($desc) { $sc.Description = $desc }
                $sc.Save()
                Move-Item -LiteralPath $tmp -Destination $lnk -Force
                $made += $lnk
            } catch {
                Add-Result '注意' ('アイコン「{0}」を作れなかった: {1}' -f $name, $_.Exception.Message)
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $State.shortcuts = @(@($State.shortcuts) + $made | Select-Object -Unique)
    if ($made.Count) { Add-Result $(if ($had -eq $made.Count) { 'そろえた' } else { '作った' }) ('アイコン {0} 個（うち前からあった {1} 個は同じ中身で書き直した: {2}）' -f $made.Count, $had, (($made | ForEach-Object { Split-Path -Leaf $_ }) -join '，')) }
}

# ---------------------------------------------------------------- モデルの置き場
# 11/15 S2: 並びはモデルの一覧（入れた chat の部品の models\models.dist.json）から読む: pack は models の local_dir のフォルダー
# （pending は除く．MANIFEST.json の大きさまで確かめる），共通の部品は shared の（任意でない）ファイルを models_dir からの道のりで．
# 一覧が無いとき（古い版）は下の既定の並び（一覧と同じ: native-gguf\・mtp-rt\・tokenizer\）．
$DefaultPacks = @('sync-s-sb', 'sync-r1q2-sb')
$SharedParts = @(
    @{ name = 'native-gguf'; files = @('native-gguf\Qwen3.8-Flash-Next-Sync-common.gguf') },
    @{ name = 'mtp-rt'; files = @('mtp-rt\experts.bin', 'mtp-rt\dense.bin', 'mtp-rt\draft_vocab.bin') },
    @{ name = 'tokenizer'; files = @('tokenizer\vocab.json') }
)
function Get-ModelLayout {
    $cat = Join-Path $AppBin 'chat\models\models.dist.json'
    if (-not (Test-Path -LiteralPath $cat)) { return @{ packs = $DefaultPacks; shared = $SharedParts } }
    $c = Read-JsonFile $cat
    $packs = @($c.models | Where-Object { -not (Get-Prop $_ 'pending' $false) } | ForEach-Object { [string]$_.local_dir })
    $shared = @($c.shared | Where-Object { -not (Get-Prop $_ 'optional' $false) } | ForEach-Object {
        $e = $_
        @{ name = [string]$e.id; files = @($e.files | ForEach-Object { (Join-Path ([string]$e.local_dir) ([string]$_.path)) -replace '/', '\' -replace '^\.\\', '' }) }
    })
    return @{ packs = $packs; shared = $shared }
}
function Test-ModelsDir([string]$d) {
    $r = [pscustomobject]@{ dir = $d; packs = @(); missing_shared = @() }
    if (-not $d -or -not (Test-Path -LiteralPath $d -PathType Container)) { return $r }
    $lay = Get-ModelLayout
    foreach ($pk in $lay.packs) {
        $mp = Join-Path $d "$pk\MANIFEST.json"
        if (-not (Test-Path -LiteralPath $mp)) { continue }
        $ok = $true
        try {
            $files = (Read-JsonFile $mp).files
            foreach ($pr in $files.PSObject.Properties) {
                $fp = Join-Path $d "$pk\$($pr.Name)"
                if (-not (Test-Path -LiteralPath $fp)) { $ok = $false; break }
                $b = Get-Prop $pr.Value 'bytes'
                if ($null -ne $b -and (Get-Item -LiteralPath $fp).Length -ne [int64]$b) { $ok = $false; break }
            }
        } catch { $ok = $false }
        if ($ok) { $r.packs += $pk }
    }
    foreach ($s in $lay.shared) {
        foreach ($f in $s.files) { if (-not (Test-Path -LiteralPath (Join-Path $d $f))) { $r.missing_shared += $s.name; break } }
    }
    return $r
}
function Get-ModelCandidates {
    $c = New-Object Collections.Generic.List[string]
    if ($env:SYNC_MODELS) { $c.Add($env:SYNC_MODELS) }
    if ($script:DistRoot) { $c.Add((Join-Path $script:DistRoot 'models')); $c.Add((Join-Path (Split-Path -Parent $script:DistRoot) 'models')) }
    $c.Add((Join-Path $SyncHome 'models')); $c.Add((Join-Path $AppDir 'models'))
    foreach ($u in 'Downloads', 'Desktop', 'Documents', '') {
        $b = if ($u) { Join-Path $env:USERPROFILE $u } else { $env:USERPROFILE }
        foreach ($x in @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction SilentlyContinue)) { $c.Add((Join-Path $x.FullName 'models')) }
    }
    $skip = '^(Windows|Program Files.*|ProgramData|\$.*|System Volume Information|Recovery|PerfLogs|Users)$'
    foreach ($dr in [IO.DriveInfo]::GetDrives()) {
        if ($dr.DriveType -ne 'Fixed' -or -not $dr.IsReady) { continue }
        $root = $dr.RootDirectory.FullName
        $c.Add((Join-Path $root 'models'))
        foreach ($a in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skip })) {
            $c.Add((Join-Path $a.FullName 'models'))
            foreach ($b in @(Get-ChildItem -LiteralPath $a.FullName -Directory -ErrorAction SilentlyContinue)) { $c.Add((Join-Path $b.FullName 'models')) }
        }
    }
    return $c
}
# 11/15 夜: 対応環境の調べ（入れること自体は止めない．結果を最後の一覧に出す）．中身は起動の道具の sync env（sync_env.py）
function Show-EnvCheck {
    $py = Join-Path $AppBin 'python\python.exe'; $sy = Join-Path $AppBin 'launcher\sync.py'
    if (-not ((Test-Path -LiteralPath $py) -and (Test-Path -LiteralPath $sy))) { return }
    try {
        $env:SYNC_HOME = $SyncHome
        $line = & $py -s -X utf8 $sy env --json --ascii 2>$null | Select-Object -Last 1
        $j = $line | ConvertFrom-Json
        if ($j.ok) { Add-Result '対応' 'この PC で使えます' } else { Add-Result '対応外' 'この PC では使えません（アプリは入れました）' }
        foreach ($b in @($j.blockers)) { if ($b) { Add-Result '対応外' ([string]$b.text) } }
        foreach ($w in @($j.warnings) + @($j.notes)) { if ($w) { Add-Result '注意' ([string]$w.text) } }
    } catch { Add-Result '注意' ('対応環境を調べられませんでした: ' + $_.Exception.Message) }
}
function Find-Models {
    $settings = if (Test-Path -LiteralPath $SettingsPath) { Read-JsonFile $SettingsPath } else { [pscustomobject]@{} }
    $cur = [string](Get-Prop $settings 'models_dir' 'auto')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($ModelsDir) {
        $found = Test-ModelsDir ([IO.Path]::GetFullPath($ModelsDir))
        if (-not $found.packs.Count) { Add-Result '注意' ('指したモデルの置き場 {0} にはまだモデルが無い（書いておくので，アプリの案内で落とせる）' -f $found.dir) }
    } elseif ($cur -ne 'auto' -and (Test-ModelsDir $cur).packs.Count) {
        $t = Test-ModelsDir $cur
        Add-Result '飛ばした' ('モデルの置き場（設定のまま {0}．pack: {1}）' -f $cur, ($t.packs -join '，'))
        return
    } elseif ($NoModelSearch) {
        Add-Result '飛ばした' 'モデルの置き場を探す（-NoModelSearch）'; return
    } else {
        $found = $null; $n = 0
        foreach ($d in (Get-ModelCandidates | Select-Object -Unique)) {
            $n++
            if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
            $t = Test-ModelsDir $d
            if ($t.packs.Count) { $found = $t; break }
        }
        if (-not $found) {
            Add-Result 'なし' ('モデルの置き場は見つからなかった（{0} か所を {1:N1} 秒で見た．アプリの最初の画面の案内で落とす）' -f $n, $sw.Elapsed.TotalSeconds)
            return
        }
    }
    if ($cur -ne $found.dir) {
        Set-Prop $settings 'models_dir' $found.dir
        Write-JsonFile $settings $SettingsPath
    }
    $miss = if ($found.missing_shared.Count) { '．足りない共通の部品: ' + ($found.missing_shared -join '，') } else { '' }
    Add-Result '見つけた' ('モデルの置き場 {0}（pack: {1}{2}．settings.json の models_dir に書いた．落とし直さない）' -f $found.dir, ($(if ($found.packs.Count) { $found.packs -join '，' } else { 'なし' })), $miss)
}

# ---------------------------------------------------------------- dsh の設定のひな形（無いときだけ作る．ある物は触らない）
function Set-DshProfile {
    $tpl = Join-Path $AppBin 'pack\dsh-profile'
    if (-not (Test-Path -LiteralPath $tpl)) { return }
    $dst = Join-Path $SyncHome 'dsh-home\profiles\web'
    $made = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $tpl -File)) {
        $name = $f.Name -replace '\.template$', ''
        $p = Join-Path $dst $name
        if (Test-Path -LiteralPath $p) { continue }
        New-Item -ItemType Directory -Force $dst | Out-Null
        $text = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($p, $text, $Utf8)
        $made += $name
    }
    if ($made.Count) { Add-Result '作った' ('dsh の設定 {0}（{1}）' -f ($made -join '，'), $dst) } else { Add-Result '飛ばした' 'dsh の設定（もうある．触らない）' }
}

# ---------------------------------------------------------------- 入口（update.cmd・uninstall.cmd）
# 入れた先の update.cmd と uninstall.cmd は，入れ替えの途中で自分が書き換わらないよう，本体の写しを %TEMP% に置いて流す．
$StubTemplate = @'
@echo off
rem Sync-Strata: {0}. Runs a copy of the installer from %TEMP%, so that it can replace (or remove) this folder.
rem Everything is in one block: cmd has read it all before the installer changes or removes this file.
setlocal EnableDelayedExpansion
(
  set "SS_TMP=%TEMP%\SyncStrata-installer-%RANDOM%%RANDOM%"
  cd /d "%TEMP%"
  mkdir "!SS_TMP!" >nul 2>nul
  copy /y "%~dp0app\pack\installer.ps1" "!SS_TMP!\installer.ps1" >nul
  if errorlevel 1 (
    echo The installer is missing: run setup.cmd from the downloaded folder again.
    if not "%SS_NOPAUSE%"=="1" pause
    exit /b 1
  )
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!SS_TMP!\installer.ps1" {1} -AppDir "%~dp0." %*
  set "SS_RC=!ERRORLEVEL!"
  rmdir /s /q "!SS_TMP!" >nul 2>nul
  if not "%SS_NOPAUSE%"=="1" pause
  exit /b !SS_RC!
)
'@
function Set-Stubs {
    $made = @()
    foreach ($x in @(@('update', 'update (only the changed parts)'), @('uninstall', 'uninstall'), @('rollback', 'go back to the version before the last update'))) {
        $p = Join-Path $AppDir ($x[0] + '.cmd')
        # 11/17 H: update.cmd は部品 pack の update.cmd（1 本で動く更新の道具．新しい一覧と新しい配布の道具を取ってから入れ替える）をそのまま写す
        $packUpd = Join-Path $AppBin 'pack\update.cmd'
        if ($x[0] -eq 'update' -and (Test-Path -LiteralPath $packUpd)) {
            $bytes = [IO.File]::ReadAllBytes($packUpd)
            if ((Test-Path -LiteralPath $p) -and ([Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) -eq [Convert]::ToBase64String($bytes))) { continue }
            [IO.File]::WriteAllBytes($p, $bytes)
            $made += 'update.cmd'
            continue
        }
        $text = ($StubTemplate -replace '\{0\}', $x[1] -replace '\{1\}', $x[0]) -replace "`r?`n", "`r`n"
        if ((Test-Path -LiteralPath $p) -and ([IO.File]::ReadAllText($p) -eq $text)) { continue }
        [IO.File]::WriteAllText($p, $text, (New-Object Text.ASCIIEncoding))
        $made += ($x[0] + '.cmd')
    }
    if ($made.Count) { Add-Result '作った' ('入口 {0}' -f ($made -join '，')) }
}

# ---------------------------------------------------------------- 命令
function Write-Summary {
    Say ''
    Say ('結果（{0}．{1:N1} 秒）:' -f $Command, $Clock.Elapsed.TotalSeconds)
    foreach ($l in $Results) { Say $l }
    if ($Report) {
        $o = [ordered]@{ command = $Command; exit = [int]$script:ExitCode; seconds = [Math]::Round($Clock.Elapsed.TotalSeconds, 2); lines = @($Results); components = @($Comps) }
        Write-JsonFile ([pscustomobject]$o) $Report
    }
}

$script:ExitCode = 0; $script:Refused = $false; $script:DistRoot = $null
try {
    if ($AppDir.Length -gt 80) { Say "注意: 入れる先の道のりが長い（$($AppDir.Length) 字）．dsh の部品は Windows の 260 字の上限に近いので，短い場所を勧める．" }
    switch ($Command) {
        'setup' {
            if (-not $Source) { throw 'setup には -Source（版の一覧の置き場）が要る．setup.cmd から流してください．' }
            if ($Source -notmatch '^https?://') { $script:DistRoot = Split-Path -Parent ([IO.Path]::GetFullPath($Source).TrimEnd('\')) }
            Say "Sync-Strata の setup: 入れる先 $AppDir"
            $feed = Open-Feed $Source
            New-Item -ItemType Directory -Force $AppBin, $StateDir | Out-Null
            # 11/21 0.1.4（GitHub Issue #6）: 部品を入れた後の仕上げ（アイコン・dsh の設定・モデル探し・対応環境の調べ）のどれかが失敗しても，
            # 更新・前の版に戻す・消すが見る記録（state.json）は必ず書く．前は最後の 1 行だったので，英語などの Windows でアイコンの作成が
            # 失敗すると記録が残らず，入れたのに update.cmd と画面の「更新」が「入っていない」と言っていた．
            # 何も入れずに終わった（動いているので止めた）入れ先で記録が無かったときは，空の記録を作らない（作ると全部を落とし直す更新になる）
            try {
                Sync-Components $feed $false
                $script:EngineVariant = Get-EngineVariant
                if ($script:EngineVariant -and $script:ExitCode -ne 7) { Sync-Components $feed $false $true }
                elseif (-not $script:EngineVariant) { Add-Result '飛ばした' 'エンジン（この PC の GPU に合う物が無い．下の「対応外」を見る）' }
                if ($script:ExitCode -ne 7) {
                    Set-Stubs
                    $State.feed = Get-Prop $feed.m 'update_feed' ''
                    if (-not $NoShortcuts) { Set-Shortcuts $feed.m }
                    New-Item -ItemType Directory -Force $SyncHome | Out-Null
                    Set-DshProfile
                    Find-Models
                    Show-EnvCheck
                }
            } finally {
                if ($script:ExitCode -ne 7 -or @($State.components.PSObject.Properties).Count -gt 0 -or (Test-Path -LiteralPath $StatePath)) { Write-JsonFile $State $StatePath }
            }
        }
        'update' {
            if (-not (Test-Path -LiteralPath $StatePath)) { throw "Sync-Strata が入っていない（$AppDir）．先に setup.cmd を流してください．" }
            if (-not $Source) {
                $s = if (Test-Path -LiteralPath $SettingsPath) { Read-JsonFile $SettingsPath } else { $null }
                $Source = [string](Get-Prop $s 'update_feed' 'auto')
                if (-not $Source -or $Source -eq 'auto') { $Source = [string]$State.feed }
            }
            if (-not $Source) { throw '更新の置き場が決まっていない: settings.json の update_feed にフォルダーか URL を書くか，update.cmd -Source <置き場> で．' }
            Say "Sync-Strata の update: 置き場 $Source"
            $feed = Open-Feed $Source
            Sync-Components $feed $true
            $script:EngineVariant = Get-EngineVariant
            if ($script:EngineVariant -and $script:ExitCode -ne 7) { Sync-Components $feed $true $true }
            if ($script:ExitCode -ne 7) { Set-Stubs }      # 11/17 H: 新しい部品 pack の update.cmd を入れた先へ（前は setup のときだけ）
            Write-JsonFile $State $StatePath
        }
        'rollback' {
            $lu = $State.last_update
            if (-not $lu -or -not @($lu.ids).Count) { Say '戻せる物が無い（直前の update で入れ替えた部品が無い）．'; break }
            if (-not (Assert-NotRunning '戻し')) { break }
            foreach ($id in @($lu.ids)) {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $cur = Join-Path $AppBin $id; $prev = Join-Path $PrevDir $id
                $t = Test-Component $prev '' $true
                if ($t.state -ne 'ok') { Add-Result '失敗' ('{0}: 前の版が残っていない・壊れている（{1}）' -f $id, $t.state); $script:ExitCode = 6; continue }
                $now = (Test-Component $cur '' $false)
                $tmp = Join-Path $StageDir "swap-$id"
                New-Item -ItemType Directory -Force $StageDir | Out-Null
                Remove-Tree $tmp
                [IO.Directory]::Move($cur, $tmp); [IO.Directory]::Move($prev, $cur); [IO.Directory]::Move($tmp, $prev)
                Write-Scan $cur (Join-Path $StateDir "$id.scan.tsv"); Write-Scan $prev (Join-Path $StateDir "prev-$id.scan.tsv")
                Set-Prop $State.skip $id $now.version
                Set-Prop $State.prev $id ([pscustomobject]@{ version = $now.version; files_sha256 = $now.files_sha256 })
                Set-Prop $State.components $id ([pscustomobject]@{ version = $t.version; files_sha256 = $t.files_sha256; at = (Get-Date).ToString('s') })
                [void]$Comps.Add([pscustomobject]@{ id = $id; action = 'rollback'; from = $now.version; to = $t.version; install_s = [Math]::Round($sw.Elapsed.TotalSeconds, 2) })
                Add-Result '戻した' ('{0} {1} → {2}（{3:N1} 秒．{1} は次の update でも入れない．入れるときは update -Force）' -f $id, $now.version, $t.version, $sw.Elapsed.TotalSeconds)
            }
            $State.last_update = $null
            Remove-Tree $StageDir
            Write-JsonFile $State $StatePath
        }
        'uninstall' {
            if (-not (Test-Path -LiteralPath $StatePath)) { throw "Sync-Strata の記録（state\state.json）が無いので消さない: $AppDir" }
            if (-not (Assert-NotRunning '消し')) { break }
            $settings = if (Test-Path -LiteralPath $SettingsPath) { Read-JsonFile $SettingsPath } else { $null }
            $md = [string](Get-Prop $settings 'models_dir' '')
            $dropModels = $false; $dropHome = $false
            if ($RemoveData) { $dropModels = $true; $dropHome = $true }
            elseif (-not $Yes) {
                if ($md -and $md -ne 'auto' -and (Test-Path -LiteralPath $md)) { $dropModels = (Read-Host "モデル（$md）も消しますか？ 消すと次は落とし直しになります [y/N]") -match '^[yY]' }
                if (Test-Path -LiteralPath $SyncHome) { $dropHome = (Read-Host "設定と会話（$SyncHome）も消しますか？ [y/N]") -match '^[yY]' }
            }
            foreach ($l in @($State.shortcuts)) { if ($l -and (Test-Path -LiteralPath $l)) { Remove-Item -LiteralPath $l -Force } }
            Add-Result '消した' ('アイコン {0} 個' -f @($State.shortcuts).Count)
            foreach ($d in (Get-ShortcutDirs).Values) {
                if ((Split-Path -Leaf $d) -eq 'Sync-Strata' -and (Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }
            }
            # 流れている uninstall.cmd（cmd が読み続ける）だけを残して消し，cmd が終わった後に隠れた窓で残りを消す
            $stub = Join-Path $AppDir 'uninstall.cmd'
            $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" | ForEach-Object { Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" }
            $later = ($parent -and $parent.Name -eq 'cmd.exe' -and (Test-Path -LiteralPath $stub))
            foreach ($x in @(Get-ChildItem -LiteralPath $AppDir -Force)) {
                if ($later -and $x.FullName -eq $stub) { continue }
                if ($x.PSIsContainer) { Remove-Tree $x.FullName } else { Remove-Item -LiteralPath $x.FullName -Force }
            }
            if ($later) {
                $cmdline = "Wait-Process -Id $($parent.ProcessId) -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500; cmd.exe /c rmdir /s /q `"$AppDir`""
                Start-Process -WindowStyle Hidden -FilePath powershell.exe -ArgumentList @('-NoProfile', '-Command', $cmdline) | Out-Null
                Add-Result '消した' "アプリ $AppDir（最後の uninstall.cmd は，この窓を閉じた後に消える）"
            } else {
                Remove-Tree $AppDir
                Add-Result '消した' "アプリ $AppDir"
            }
            if ($dropModels -and $md) { Remove-Tree $md; Add-Result '消した' "モデル $md" } elseif ($md) { Add-Result '残した' "モデル $md" }
            if ($dropHome) { Remove-Tree $SyncHome; Add-Result '消した' "設定と会話 $SyncHome" } elseif (Test-Path -LiteralPath $SyncHome) { Add-Result '残した' "設定と会話 $SyncHome" }
        }
        'status' {
            foreach ($d in @(Get-ChildItem -LiteralPath $AppBin -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.*' })) {
                $t = Test-Component $d.FullName (Join-Path $StateDir "$($d.Name).scan.tsv") ([bool]$Full)
                $pv = Get-Prop $State.prev $d.Name
                Add-Result $t.state ('{0} {1}（{2:N0} ファイル{3}）' -f $d.Name, $t.version, $t.files, $(if ($pv) { "．前の版 $($pv.version) を残している" } else { '' }))
            }
        }
    }
} catch {
    Add-Result '失敗' $_.Exception.Message
    if (-not $script:ExitCode) { $script:ExitCode = $(if ($script:Refused) { 5 } else { 6 }) }
}
Write-Summary
exit $script:ExitCode
