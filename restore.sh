#!/bin/bash
# 從 ext4 還原回本機。分類與 backup.sh 相同。
#
# 一般檔案只補不刪（--update 且不加 --delete），本機較新或本機獨有者一律保留。
# 登入狀態與 /etc 例外，為整組覆寫 —— 它們必須是一致的一套，混合新舊會壞掉。

usage() {
    cat <<'USAGE'
用法：restore.sh [分類...] [--all]

不加參數時會列出分類供互動選擇。分類可複選，例如：
    restore.sh --repos --claude

  --system    系統與 shell 設定（/etc、dotfiles、SSH／GPG 金鑰、字型）
              /etc 需 root，且 fstab／grub 變更需重開機
  --app       應用程式狀態（Chrome／VS Code 登入狀態、keyring、Tilix）
              執行前須先完全關閉 Chrome 與 VS Code；
              keyring 更換後須登出桌面重新登入才會生效
  --claude    Claude Code（專案紀錄與 memory、settings.json）
  --repos     程式碼與開發環境（repos、飛控、ROS workspace、conda、Omniverse 快取）
  --personal  個人資料（Documents、Downloads、Pictures、Videos…）
  --all       以上全部，不詢問

.bashrc 與 .profile 一律只提示不還原，即使 --all 也一樣：
兩者幾乎必定含該機專屬內容，須逐段比對後自行複製。
USAGE
}

RSYNC_MODE=restore
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

# 未指定分類時互動選擇。非互動環境不猜測，直接要求明確指定。
if [ ${#selected[@]} -eq 0 ]; then
    if [ ! -t 0 ]; then
        echo "未指定分類，且非互動環境。請指定分類或 --all。" >&2
        usage >&2
        exit 1
    fi
    echo "選擇要還原的分類（空白分隔，a=全部，Enter 取消）："
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

echo "還原分類：${selected[*]}"
echo

C="$CONTAINER_HOME"              # container 家目錄（single 時即本機家目錄）
CB="$CONTAINER_BACKUP"

# ── repos：程式碼與開發環境 ─────────────────────────────────────────
if want repos; then
    sync_dir "$CB/miniconda3/envs" "$C/miniconda3/envs" isaaclab

    # Omniverse 快取（約 17G），還原後可省去 Isaac Sim 首次啟動的重新編譯
    sync_dir "$CB/.cache" "$C/.cache" ov

    sync_files "$CB" "$C" ardupilot PX4-Autopilot

    # ROS 2 workspace（build/install/log 需自行重新編譯）
    for w in "${ros_workspaces[@]}"; do
        sync_dir "$CB" "$C" "$w" "${ros_ws_excludes[@]}"
    done

    # 排除 isaaclab-uav/.claude/memory：該路徑在 dual 主機上是 mount bind 掛載點，
    # 直接寫入會落在容器 rootfs 的空掛載點而非真正的資料位置。
    # memory 由 claude 分類的 projects 一併還原至 bind 來源端。
    sync_dir "$CB" "$C" repos "isaaclab-uav/.claude/memory"
    if [ "$is_single" = 0 ]; then
        sync_dir "$HOST_BACKUP" "$HOST_HOME" repos
    fi
fi

# ── claude：專案紀錄與設定 ──────────────────────────────────────────
if want claude; then
    # 路徑在 dual 與 single 上皆為 /home/jack/.claude/projects。
    # memory 亦在其中，還原至 bind 來源端後，容器內即可透過 bind 看到。
    sync_dir "$HOST_BACKUP/.claude" "$HOST_HOME/.claude" projects
    sync_home_files to_home "${claude_files[@]}"
fi

# ── personal：個人資料 ──────────────────────────────────────────────
if want personal; then
    restore_personal
fi

# ── system：系統與 shell 設定 ───────────────────────────────────────
if want system; then
    sync_home_files to_home "${system_files[@]}"
    restore_etc
fi

# ── app：應用程式狀態 ───────────────────────────────────────────────
if want app; then
    sync_vscode_user to_home
    restore_dconf /com/gexperts/Tilix/ "$HOST_BACKUP/tilix.dconf"
    restore_session_state
fi

report 還原
