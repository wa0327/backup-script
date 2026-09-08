# backup 與 restore 共用的定義。由 backup.sh 與 restore.sh source，不單獨執行。
#
# 原本 host（實體主機）與 container（lxc 容器）為兩個獨立環境，各有一份家目錄，
# 備份分存於 ext4 下的 host/ 與 container/。container 升級後兩者已融合為單一
# 主機，故不再區分：本機直接對應 container，備份一律寫入 container/。
# 目錄名沿用 container 是因為它代表角色而非發行版名稱，升級不改變其歸屬。
#
# ext4 下的 host/ 保留為舊實體主機的歷史備份，本腳本不再讀寫。
#
# 呼叫端須先設定 RSYNC_MODE：
#   backup  → 備份為本機的鏡像，用 --delete 使備份不致堆積已刪除的檔案
#   restore → 只補不刪，用 --update 且不加 --delete，避免蓋掉本機較新的工作

case "$RSYNC_MODE" in
    backup)  rsync_flags=(--delete) ;;
    restore) rsync_flags=(--update) ;;
    *) echo "common.sh: 未設定 RSYNC_MODE（backup|restore）" >&2; exit 1 ;;
esac

# 備份根目錄。此碟依系統而掛載於兩處其一，兩者只會出現一個，故逐一嘗試。
# 不寫死單一路徑：寫死會在掛載點改變時，靜默把備份寫進系統碟上一個新建的
# 同名目錄，與碟上既有備份完全脫節。
# 以 mountpoint 判斷而非僅檢查目錄存在，否則碟未掛載時會誤選到空的掛載點。
BACKUP_ROOT=""
for d in /media/jack/ext4 /run/media/jack/ext4; do
    if mountpoint -q "$d" 2>/dev/null; then
        BACKUP_ROOT="$d"
        break
    fi
done
if [ -z "$BACKUP_ROOT" ]; then
    echo "common.sh: 備份碟未掛載於 /media/jack/ext4 或 /run/media/jack/ext4" >&2
    exit 1
fi

BACKUP="$BACKUP_ROOT/container/home/jack"   # 本機唯一的備份目的地
HOME_DIR=/home/jack                          # 本機唯一的家目錄

# ── 備份分類 ────────────────────────────────────────────────────────
# 每類可獨立選取。未給任何參數時由 backup.sh 互動式詢問。
CATEGORIES=(system app claude repos personal)

category_desc() {
    case "$1" in
        system)   echo "系統與 shell 設定（/etc、dotfiles、SSH／GPG 金鑰、字型）" ;;
        app)      echo "應用程式狀態（Chrome／VS Code 登入狀態、keyring、Tilix）" ;;
        claude)   echo "Claude Code（專案紀錄與 memory、settings.json）" ;;
        repos)    echo "程式碼與開發環境（repos、飛控、ROS workspace、conda、Omniverse 快取）" ;;
        personal) echo "個人資料（Documents、Downloads、Pictures、Videos…）" ;;
    esac
}

# 選取的分類，由呼叫端填入
selected=()

want() {
    local c
    for c in "${selected[@]}"; do
        [ "$c" = "$1" ] && return 0
    done
    return 1
}

# 記錄失敗項目，由呼叫端在結尾統一回報
failed=()

# 記錄需人工還原的檔案，由 report 在結尾列出
manual=()

# sync_dir <源根目錄> <目標根目錄> <子目錄> [排除路徑...]
# 排除路徑為相對於 <子目錄> 的 rsync --exclude 樣式，用於保護由其他行負責的子路徑
sync_dir() {
    local src_root="$1"
    local dst_root="$2"
    local sub="$3"
    shift 3

    # 傳輸的是 "$src_root/$sub"（不帶結尾斜線），故 rsync 的傳輸根目錄是 sub
    # 的上層，樣式中的路徑須從 sub 本身算起。開頭的 / 表示錨定，
    # 不加則會匹配到任何層級的同名項目（例如 src/某套件/build）。
    local excludes=()
    local e
    for e in "$@"; do
        case "$e" in
            /*) excludes+=(--exclude "/$sub${e}") ;;
            *)  excludes+=(--exclude "$e") ;;
        esac
    done

    if [ ! -e "$src_root/$sub" ]; then
        echo "[$sub] 來源不存在，略過"
        return
    fi

    if [ ! -e "$dst_root/$sub" ]; then
        # 目標不存在：第一次，全量搬遷
        echo "[$sub] 目標不存在，執行全量搬遷"
        mkdir -p "$dst_root"
        local tar_excludes=()
        for e in "$@"; do
            # rsync 以開頭的 / 表示錨定於傳輸根目錄；tar 的樣式本就相對於
            # 打包根目錄，故去掉該斜線後接在 sub 之後即為等效的錨定寫法
            tar_excludes+=(--exclude "$sub/${e#/}")
        done
        # PIPESTATUS 檢查打包端，管線末端的解壓成功不代表來源全部讀得到
        tar -cf - "${tar_excludes[@]}" -C "$src_root" "$sub" | tar -xpf - -C "$dst_root"
        local rc=("${PIPESTATUS[@]}")
        if [ "${rc[0]}" != 0 ] || [ "${rc[1]}" != 0 ]; then
            echo "[$sub] !! 全量搬遷失敗（tar 打包=${rc[0]} 解壓=${rc[1]}）"
            failed+=("$sub")
        fi
    else
        echo "[$sub] 目標已存在，執行增量同步"
        # sub 可能含中間目錄（如 default/grub），須連同層級一起放，
        # 否則會被平鋪到 dst_root 下而與 tar 分支的結果不一致
        local dst_parent="$dst_root/$(dirname "$sub")"
        mkdir -p "$dst_parent"
        if ! rsync -aHAX --numeric-ids "${rsync_flags[@]}" "${excludes[@]}" \
                  "$src_root/$sub" "$dst_parent/"; then
            echo "[$sub] !! 增量同步失敗"
            failed+=("$sub")
        fi
    fi
}

# sync_files <源根目錄> <目標根目錄> <檔案...>
sync_files() {
    local src_root="$1"
    local dst_root="$2"
    shift 2

    local f
    for f in "$@"; do
        sync_dir "$src_root" "$dst_root" "$f"
    done
}

# ── 登入狀態（Chrome／VS Code／keyring）─────────────────────────────
# 這些資料只在「金鑰 + 資料」齊備時才有意義：
#   Chrome cookie 為 v11 加密，解密金鑰存於 gnome-keyring，不在設定目錄內；
#   VS Code 的 token 同樣經 Secret Service 存入 keyring。
# 因此 keyrings/ 必須與應用程式資料一併備份，缺一則還原後等同未登入。
#
# 執行中的 SQLite 直接複製可能取到寫入中的殘缺狀態，故以 SQLite 備份 API
# 取一致性快照；其餘為 JSON 或二進位檔，直接同步即可。

# Chrome 設定檔根目錄下（非 Default/）
chrome_root_plain=("Local State")
# Chrome Default/ 之下
chrome_profile_sqlite=("Cookies" "Login Data" "Login Data For Account" "Web Data")
chrome_profile_plain=("Preferences")
# VS Code globalStorage 之下
vscode_state_sqlite=(state.vscdb)

CHROME_DIR=/home/jack/.config/google-chrome
VSCODE_STATE_DIR=/home/jack/.config/Code/User/globalStorage

# 以 SQLite 備份 API 取一致性快照（來源可為使用中的資料庫）。
#
# 逾時是必要的：程式執行中會持有寫入鎖，backup() 遇鎖會不斷重試且無上限，
# 曾因此卡住整輪備份十餘分鐘而毫無徵兆。逾時後視為該項失敗，不影響其餘項目。
#
# 先寫入暫存檔再原子移動，確保逾時或中斷不會在備份端留下殘缺的資料庫 ——
# 半寫入的檔案大小看似正常，卻要到還原時才會發現壞掉。
SQLITE_SNAPSHOT_TIMEOUT=60

backup_sqlite() {
    local src="$1" dst="$2" tmp rc
    if [ ! -e "$src" ]; then
        echo "[$(basename "$src")] 來源不存在，略過"
        return
    fi
    mkdir -p "$(dirname "$dst")"
    tmp="$dst.tmp.$$"

    timeout "$SQLITE_SNAPSHOT_TIMEOUT" python3 - "$src" "$tmp" <<'PY' 2>/dev/null
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
# timeout 讓取鎖失敗時拋出例外而非無限重試；sleep 縮短重試間隔
s = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=10)
d = sqlite3.connect(dst, timeout=10)
s.backup(d, sleep=0.1)
d.close(); s.close()
PY
    rc=$?

    if [ "$rc" = 0 ]; then
        # python 建檔套用預設 umask，須比照來源收緊：內含 session token
        chmod --reference="$src" "$tmp" 2>/dev/null || chmod 600 "$tmp"
        mv -f "$tmp" "$dst"
        echo "[$(basename "$src")] 已取一致性快照"
    else
        rm -f "$tmp"
        if [ "$rc" = 124 ]; then
            echo "[$(basename "$src")] !! 逾時 ${SQLITE_SNAPSHOT_TIMEOUT}s（資料庫被鎖住，請關閉對應程式），保留既有備份"
        else
            echo "[$(basename "$src")] !! SQLite 快照失敗（rc=$rc），保留既有備份"
        fi
        failed+=("$(basename "$src")")
    fi
}

# 登入狀態的備份。還原不自動執行，理由見 restore_session_state。
backup_session_state() {
    local f
    # gnome-keyring：Chrome／VS Code 的解密金鑰所在，缺此則其餘備份無效
    sync_dir /home/jack/.local/share "$BACKUP/.local/share" keyrings

    for f in "${chrome_root_plain[@]}"; do
        sync_dir "$CHROME_DIR" "$BACKUP/.config/google-chrome" "$f"
    done
    for f in "${chrome_profile_plain[@]}"; do
        sync_dir "$CHROME_DIR/Default" "$BACKUP/.config/google-chrome/Default" "$f"
    done
    for f in "${chrome_profile_sqlite[@]}"; do
        backup_sqlite "$CHROME_DIR/Default/$f" \
                      "$BACKUP/.config/google-chrome/Default/$f"
    done
    for f in "${vscode_state_sqlite[@]}"; do
        backup_sqlite "$VSCODE_STATE_DIR/$f" \
                      "$BACKUP/.config/Code/User/globalStorage/$f"
    done
}

# 直接以備份端覆蓋，不保留原檔。
# 刻意不使用 --update：使用者既已明示要還原，即應以備份端為準。
_force_restore() {
    local src="$1" dst="$2"
    [ -e "$src" ] || { echo "  [$(basename "$dst")] 備份不存在，略過"; return; }
    mkdir -p "$(dirname "$dst")"
    if rsync -aHAX --numeric-ids --delete "$src" "$(dirname "$dst")/"; then
        echo "  [$(basename "$dst")] 已還原"
    else
        echo "  [$(basename "$dst")] !! 還原失敗"
        failed+=("$(basename "$dst")")
    fi
}

# 還原登入狀態。選取 app 分類即為明確授權，但仍會擋下執行中的程式 ——
# keyring 覆蓋會連帶清掉本機自己的密碼，資料庫在程式執行中被覆寫會損毀設定。
restore_session_state() {
    local do_chrome=1 do_vscode=1 running

    # 程式執行中覆寫資料庫會損毀設定，先擋下。
    # 樣式錨定於 command line 開頭，否則任何「提到」該路徑的指令（含本腳本
    # 自身與一般 shell 操作）都會被誤判為程式執行中。
    if [ "$do_chrome" = 1 ]; then
        running=$(pgrep -c -f '^/opt/google/chrome/chrome' || true)
        if [ "${running:-0}" -gt 0 ]; then
            echo "!! Chrome 執行中（$running 個 process），請先完全關閉再重跑"
            failed+=("chrome：執行中")
            do_chrome=0
        fi
    fi
    if [ "$do_vscode" = 1 ]; then
        running=$(pgrep -c -f '^/usr/share/code/' || true)
        if [ "${running:-0}" -gt 0 ]; then
            echo "!! VS Code 執行中（$running 個 process），請先完全關閉再重跑"
            failed+=("vscode：執行中")
            do_vscode=0
        fi
    fi
    [ "$do_chrome" = 0 ] && [ "$do_vscode" = 0 ] && return 0

    echo "還原登入狀態（直接覆蓋，不保留原檔）"

    # keyring 是 Chrome 與 VS Code 共用的解密金鑰來源，兩者任一都需要它
    _force_restore "$BACKUP/.local/share/keyrings" \
                   /home/jack/.local/share/keyrings

    if [ "$do_chrome" = 1 ]; then
        _force_restore "$BACKUP/.config/google-chrome/Local State" \
                       "$CHROME_DIR/Local State"
        local f
        for f in "${chrome_profile_plain[@]}" "${chrome_profile_sqlite[@]}"; do
            _force_restore "$BACKUP/.config/google-chrome/Default/$f" \
                           "$CHROME_DIR/Default/$f"
        done
    fi

    if [ "$do_vscode" = 1 ]; then
        _force_restore "$BACKUP/.config/Code/User/globalStorage/state.vscdb" \
                       "$VSCODE_STATE_DIR/state.vscdb"
    fi

    echo "登入狀態還原完成。keyring 已更換，須登出桌面重新登入才會生效。"
    return 0
}

# ── 個人資料與系統設定的還原 ────────────────────────────────────────
# 個人資料量大且可能已在本機編輯過，故沿用一般還原語意（只補不刪、
# 目標較新者不覆蓋），而非登入狀態那種整組覆寫。
restore_personal() {
    sync_files "$BACKUP" "$HOME_DIR" "${personal_dirs[@]}"
}

# /etc 需 root 才能寫入，且會影響開機與權限。
# lxc 容器定義檔不在此處理：它是指向 repos/lxc-config/jammy 的符號連結，
# 實檔隨 repos 還原即可，只需重建該連結。
restore_etc() {
    local f src

    if ! sudo -n true 2>/dev/null; then
        echo "!! 還原 /etc 需要 root 權限，請以可 sudo 的身分執行"
        failed+=("etc：無 root 權限")
        return 0
    fi

    echo "還原系統設定（直接覆蓋，不保留原檔）"
    for f in "${etc_files[@]}"; do
        src="$BACKUP_ROOT/container/etc/$f"
        if [ ! -e "$src" ]; then
            echo "  [$f] 備份不存在，略過"
            continue
        fi
        if sudo install -D -m "$(stat -c %a "$src")" -o root -g root "$src" "/etc/$f"; then
            echo "  [$f] 已還原"
        else
            echo "  [$f] !! 還原失敗"
            failed+=("etc/$f")
        fi
    done

    echo "系統設定還原完成。fstab／grub 變更需重開機，sudoers 立即生效。"
}

# ── dconf 設定 ─────────────────────────────────────────────────────
# dconf 的資料存在二進位資料庫中，無法用 rsync 逐項同步，故匯出為文字檔備份。
# 還原不自動執行：dconf load 會立即改變執行中的桌面設定，且不同機器的
# 硬體相關項目常需調整，故僅提示指令，由人工決定是否套用。
backup_dconf() {
    local path="$1" out="$2" tmp
    if ! command -v dconf >/dev/null 2>&1; then
        echo "[$(basename "$out")] 無 dconf 指令，略過"
        return
    fi
    tmp=$(mktemp) || return
    if dconf dump "$path" >"$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        mkdir -p "$(dirname "$out")"
        mv "$tmp" "$out"
        echo "[$(basename "$out")] 已匯出 dconf $path"
    else
        rm -f "$tmp"
        echo "[$(basename "$out")] dconf $path 無內容，略過"
    fi
}

# 選取 app 分類即為授權，直接套用至執行中的桌面
restore_dconf() {
    local path="$1" file="$2"
    if [ ! -e "$file" ]; then
        echo "[$(basename "$file")] 備份不存在，略過"
        return
    fi
    if dconf load "$path" <"$file" 2>/dev/null; then
        echo "[$(basename "$file")] 已套用 dconf $path"
    else
        echo "[$(basename "$file")] !! dconf 套用失敗"
        failed+=("$(basename "$file")")
    fi
}

# 結尾統一回報，有失敗則以非 0 離開
report() {
    local action="$1" m

    if [ ${#manual[@]} -gt 0 ]; then
        echo
        echo "以下檔案不自動還原，請自行比對後決定是否套用："
        for m in "${manual[@]}"; do
            echo "  $m"
        done
        echo
    fi

    if [ ${#failed[@]} -gt 0 ]; then
        echo "!! ${action}未完全成功，以下項目失敗：${failed[*]}"
        exit 1
    fi
    echo "${action}完成"
}

# ── 家目錄設定檔清單 ────────────────────────────────────────────────
# 環境融合後家目錄只有一份，全部備份到 container/，無須裁決歸屬。
#
# 刻意不備份：.cargo/.rustup/.local/bin（可重裝）、
#             .config/Code 與 .config/google-chrome（GB 級快取）、.ros/.mavproxy（多為 log）

# 家目錄設定檔，依分類拆開。
# system 類：shell 與作業系統層級的設定
system_files=(
    .ssh                              # 私鑰，遺失無法重建
    .gnupg                            # GPG 私鑰，遺失無法重建
    .config/fontconfig/conf.d         # 中日韓字型優先序（99-prefer-cjk-tc.conf），
                                      # 缺此漢字會被日文字型取代
    .bashrc .profile .bash_aliases .inputrc .xinputrc .selected_editor
    .gitconfig .git-credentials
    .condarc                          # conda channel/solver 設定
    .bash_history .python_history
    .colcon                           # ROS colcon 設定
    set_governor.sh                   # 家目錄下自己寫的腳本
)

# claude 類：Claude Code 的家目錄設定
claude_files=(
    .claude/settings.json
)

# 供還原判斷用的完整清單
home_files=("${system_files[@]}" "${claude_files[@]}")

# VS Code 個人設定（只取設定本體，避開 3GB 級的快取與 globalStorage）
vscode_user=(settings.json keybindings.json snippets)

personal_dirs=(Desktop Documents Downloads Music Pictures Videos)

# ROS 2 workspace。整個目錄都備，僅排除編譯產物 —— 採排除法
# 而非列舉 src/，是因為根目錄還有 gimbal-middleware、autorun 等非 git 且
# 無其他副本的內容，列舉法漏掉不會有任何跡象，寧可多備也不要靜默漏備。
ros_workspaces=(ws_avix ws_base ws_gimbal ws_hawkeye)

# 開頭的 / 表示只排除 workspace 頂層的同名目錄，
# 以免誤刪 src/ 內某個套件自己的 build/ 或 log/
ros_ws_excludes=(/build /install /log)

# 系統設定檔。備份到 container/etc/，還原須自行以 root 放回。
etc_files=(
    fstab                             # 分割區與掛載設定
    default/grub                      # 開機參數
    locale.conf                       # 系統語系（default/locale 僅為其符號連結）
    sudoers.d/jack                    # sudo 權限設定
)

# 一律只備份、絕不自動還原（--all 亦然），僅提示備份檔位置供人工複製。
# 這兩個檔幾乎必定含該機專屬內容（PATH、conda 初始化、硬體相關設定），
# 整份覆蓋等於把另一台機器的環境搬過來，得逐段比對才安全。
never_restore=(
    .bashrc .profile
)

is_never_restore() {
    local f="$1" w
    for w in "${never_restore[@]}"; do
        [ "$f" = "$w" ] && return 0
    done
    return 1
}

# 預設不自動還原，但 --all 時會一併還原。
no_auto_restore=(
    .bash_aliases
)

is_no_auto_restore() {
    local f="$1" w
    for w in "${no_auto_restore[@]}"; do
        [ "$f" = "$w" ] && return 0
    done
    return 1
}

# ── 家目錄設定檔的同步 ──────────────────────────────────────────────
# $1 為方向：to_backup（備份）或 to_home（還原）
# $2 起為要處理的檔案清單，未給則沿用完整的 home_files
sync_home_files() {
    local dir="$1" f
    shift
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && files=("${home_files[@]}")

    for f in "${files[@]}"; do
        _sync_one "$dir" "$HOME_DIR" "$BACKUP" "$f"
    done
}

# VS Code 的個人設定另外處理：其路徑在 .config/Code/User 之下，
# 與家目錄頂層的檔案不同層
sync_vscode_user() {
    _sync_vscode "$1" "$HOME_DIR" "$BACKUP"
}

_sync_one() {
    local dir="$1" home="$2" backup="$3" f="$4"
    if [ "$dir" = to_backup ]; then
        sync_dir "$home" "$backup" "$f"
    elif is_never_restore "$f"; then
        # 選了分類也不還原；僅在備份端確實有東西可複製時才提示
        [ -e "$backup/$f" ] && manual+=("（一律手動）$backup/$f  →  $home/$f")
    elif is_no_auto_restore "$f"; then
        # 選取分類即為明確授權，故直接以備份端覆蓋
        _force_restore "$backup/$f" "$home/$f"
    else
        sync_dir "$backup" "$home" "$f"
    fi
}

_sync_vscode() {
    local dir="$1" home="$2/.config/Code/User" backup="$3/.config/Code/User" f
    for f in "${vscode_user[@]}"; do
        _sync_one "$dir" "$home" "$backup" "$f"
    done
}
