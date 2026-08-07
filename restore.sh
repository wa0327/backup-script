#!/bin/bash
# 從 ext4 還原回本機。只補不刪（--update 且不加 --delete），
# 本機較新或本機獨有的檔案一律保留，不會造成資料遺失。

usage() {
    cat <<'USAGE'
用法：restore [--chrome] [--vscode] [--personal] [--etc] [--all]

不加參數時只還原程式碼與設定檔。會直接改變環境或需 root 的項目
（.bash_aliases、Tilix、登入狀態、個人資料、/etc）僅列出提示。
.bashrc 與 .profile 一律只提示不還原，即使加 --all 也一樣，
因其幾乎必定含該機專屬內容，須逐段比對後自行複製。

  --chrome    Chrome 登入狀態（cookie、密碼）與 gnome-keyring
  --vscode    VS Code 登入狀態與 gnome-keyring
  --personal  個人資料（Documents、Downloads、Pictures、Videos…）
  --etc       /etc/{fstab,default/grub,locale.conf,sudoers.d/jack}
              需 root
  --all       以上全部，另含 .bash_aliases 與 Tilix

登入狀態與 /etc 為整組覆寫，不保留原檔；個人資料則只補不刪、
本機較新者不覆蓋。--chrome／--vscode 執行前須先完全關閉對應程式，
還原後須登出桌面重新登入才會生效。
USAGE
}

do_chrome=0
do_vscode=0
do_personal=0
do_etc=0
do_all=0
for a in "$@"; do
    case "$a" in
        --chrome)   do_chrome=1 ;;
        --vscode)   do_vscode=1 ;;
        --personal) do_personal=1 ;;
        --etc)      do_etc=1 ;;
        --all)      do_all=1; do_chrome=1; do_vscode=1; do_personal=1; do_etc=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "未知參數：$a" >&2; usage >&2; exit 1 ;;
    esac
done

RSYNC_MODE=restore
source "$(dirname "$0")/common.sh" || exit 1

C="$CONTAINER_HOME"              # container 家目錄（solo 時即本機家目錄）
CB="$CONTAINER_BACKUP"

# ── container 的大目錄 ──────────────────────────────────────────────
sync_dir "$CB/miniconda3/envs" "$C/miniconda3/envs" isaaclab

# Omniverse 快取（約 17G），還原後可省去 Isaac Sim 首次啟動的重新編譯
sync_dir "$CB/.cache" "$C/.cache" ov

# 飛控原始碼
sync_files "$CB" "$C" ardupilot PX4-Autopilot

# ROS 2 workspace（build/install/log 需自行重新編譯）
for w in "${ros_workspaces[@]}"; do
    sync_dir "$CB" "$C" "$w" "${ros_ws_excludes[@]}"
done

# ── 兩處的 repos ────────────────────────────────────────────────────
# 排除 isaaclab-uav/.claude/memory：該路徑在 host 主機上是 mount bind 掛載點，
# 直接寫入會落在容器 rootfs 的空掛載點而非真正的資料位置。
# memory 由下方 projects 一併還原至 bind 來源端。
sync_dir "$CB" "$C" repos "isaaclab-uav/.claude/memory"
if [ "$is_solo" = 0 ]; then
    sync_dir "$HOST_BACKUP" "$HOST_HOME" repos
fi

# ── host 的 Claude 專案紀錄 ─────────────────────────────────────────
# 路徑在 host 與 solo 上皆為 /home/jack/.claude/projects。
# memory 亦在其中，還原至 bind 來源端後，容器內即可透過 bind 看到。
sync_dir "$HOST_BACKUP/.claude" "$HOST_HOME/.claude" projects

# ── 兩處的個人資料（須 --personal）──────────────────────────────────
restore_personal "$do_personal"

# ── host 系統設定（須 --etc，需 root）───────────────────────────────
restore_etc "$do_etc"

# ── 家目錄設定檔（清單與 solo 裁決表見 common.sh）─────────────────────
sync_home_files to_home "$do_all"

# Tilix 設定預設僅提示 dconf load 指令，--all 時直接套用
restore_dconf /com/gexperts/Tilix/ "$HOST_BACKUP/tilix.dconf" "$do_all"

# 登入狀態預設不還原（會清掉本機 keyring／損毀執行中的資料庫），
# 須以 --chrome／--vscode／--all 明確指定
restore_session_state "$do_chrome" "$do_vscode"

report 還原
