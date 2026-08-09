#!/bin/bash
# 從本機備份到 ext4。備份為本機的鏡像（帶 --delete）。

usage() {
    cat <<'USAGE'
用法：backup.sh [分類...] [--all]

不加參數時會列出分類供互動選擇。分類可複選，例如：
    backup.sh --repos --claude

  --system    系統與 shell 設定（/etc、dotfiles、SSH／GPG 金鑰、字型）
  --app       應用程式狀態（Chrome／VS Code 登入狀態、keyring、Tilix）
  --claude    Claude Code（專案紀錄與 memory、settings.json）
  --repos     程式碼與開發環境（repos、飛控、ROS workspace、conda、Omniverse 快取）
  --personal  個人資料（Documents、Downloads、Pictures、Videos…）
  --all       以上全部，不詢問

排程執行請明確指定分類或 --all：非互動環境下不會跳出選單。
USAGE
}

RSYNC_MODE=backup
source "$(dirname "$0")/common.sh" || exit 1

for a in "$@"; do
    case "$a" in
        --all)      selected=("${CATEGORIES[@]}") ;;
        -h|--help)  usage; exit 0 ;;
        --*)
            c="${a#--}"
            if printf '%s\n' "${CATEGORIES[@]}" | grep -qx "$c"; then
                want "$c" || selected+=("$c")
            else
                echo "未知分類：$a" >&2; usage >&2; exit 1
            fi ;;
        *) echo "未知參數：$a" >&2; usage >&2; exit 1 ;;
    esac
done

# 未指定分類時互動選擇。非互動環境（排程、管線）不猜測，直接要求明確指定。
if [ ${#selected[@]} -eq 0 ]; then
    if [ ! -t 0 ]; then
        echo "未指定分類，且非互動環境。請指定分類或 --all。" >&2
        usage >&2
        exit 1
    fi
    echo "選擇要備份的分類（空白分隔，a=全部，Enter 取消）："
    i=1
    for c in "${CATEGORIES[@]}"; do
        printf "  %d) %-9s %s\n" "$i" "$c" "$(category_desc "$c")"
        i=$((i + 1))
    done
    read -r -p "> " reply
    case "$reply" in
        a|A|all) selected=("${CATEGORIES[@]}") ;;
        "")      echo "已取消"; exit 0 ;;
        *)
            for n in $reply; do
                c="${CATEGORIES[$((n - 1))]}"
                if [ -z "$c" ] || ! [ "$n" -ge 1 ] 2>/dev/null; then
                    echo "無效選項：$n" >&2; exit 1
                fi
                want "$c" || selected+=("$c")
            done ;;
    esac
    [ ${#selected[@]} -eq 0 ] && { echo "未選擇任何分類"; exit 0; }
fi

echo "備份分類：${selected[*]}"
echo

C="$CONTAINER_HOME"              # container 家目錄（single 時即本機家目錄）
CB="$CONTAINER_BACKUP"

# ── repos：程式碼與開發環境 ─────────────────────────────────────────
if want repos; then
    sync_dir "$C/miniconda3/envs" "$CB/miniconda3/envs" isaaclab

    # Omniverse 快取（著色器／材質編譯結果，約 17G）。可重生，但重建耗時甚久，
    # 備份是為了省下 Isaac Sim 首次啟動的編譯時間。
    sync_dir "$C/.cache" "$CB/.cache" ov

    # 飛控原始碼（各約 4G，含 build/ 與未提交的本機修改）
    sync_files "$C" "$CB" ardupilot PX4-Autopilot

    # ROS 2 workspace：整包備份，僅排除頂層的 build/install/log
    for w in "${ros_workspaces[@]}"; do
        sync_dir "$C" "$CB" "$w" "${ros_ws_excludes[@]}"
    done

    # 整個 repos 目錄都備份，內含未提交的本機修改，git clone 取不回來。
    # 排除 isaaclab-uav/.claude/memory：該路徑是 mount bind 掛載點，容器 rootfs
    # 內僅為空掛載點，其實際資料已包含在 claude 分類的 .claude/projects 備份中。
    sync_dir "$C" "$CB" repos "isaaclab-uav/.claude/memory"
    if [ "$is_single" = 0 ]; then
        sync_dir "$HOST_HOME" "$HOST_BACKUP" repos
    fi
fi

# ── claude：專案紀錄與設定 ──────────────────────────────────────────
if want claude; then
    # 路徑在 dual 與 single 上皆為 /home/jack/.claude/projects，一律備份到 host/。
    # memory 亦在其中（bind 來源端），是 memory 唯一的備份來源。
    sync_dir "$HOST_HOME/.claude" "$HOST_BACKUP/.claude" projects
    sync_home_files to_backup "${claude_files[@]}"
fi

# ── personal：個人資料 ──────────────────────────────────────────────
if want personal; then
    sync_files "$C" "$CB" "${personal_dirs[@]}"
    if [ "$is_single" = 0 ]; then
        sync_files "$HOST_HOME" "$HOST_BACKUP" "${personal_dirs[@]}"
    fi
fi

# ── system：系統與 shell 設定 ───────────────────────────────────────
if want system; then
    # 不含 /var/lib/lxc/jammy/config：該檔是指向 repos/lxc-config/jammy 的
    # 符號連結，實檔隨 repos 分類一併備份。
    sync_files /etc "$BACKUP_ROOT/host/etc" "${etc_files[@]}"
    sync_home_files to_backup "${system_files[@]}"
fi

# ── app：應用程式狀態 ───────────────────────────────────────────────
if want app; then
    sync_vscode_user to_backup

    # Tilix 終端機設定存於 dconf，須匯出。屬桌面環境，歸 host。
    backup_dconf /com/gexperts/Tilix/ "$HOST_BACKUP/tilix.dconf"

    # Chrome／VS Code 登入狀態與 gnome-keyring（三者須齊備才有意義，見 common.sh）
    backup_session_state
fi

# 確保所有資料真正落到磁碟，避免拔碟時資料還停留在快取
sync
report 備份
