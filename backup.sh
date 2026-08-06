#!/bin/bash
# 從本機備份到 ext4。備份為本機的鏡像（帶 --delete）。

RSYNC_MODE=backup
source "$(dirname "$0")/common.sh" || exit 1

C="$CONTAINER_HOME"              # container 家目錄（solo 時即本機家目錄）
CB="$CONTAINER_BACKUP"

# ── container 的大目錄 ──────────────────────────────────────────────
sync_dir "$C/miniconda3/envs" "$CB/miniconda3/envs" isaaclab

# Omniverse 快取（著色器／材質編譯結果，約 17G）。可重生，但重建耗時甚久，
# 備份是為了省下 Isaac Sim 首次啟動的編譯時間。
sync_dir "$C/.cache" "$CB/.cache" ov

# 飛控原始碼（各約 4G，含 build/ 與未提交的本機修改）
sync_files "$C" "$CB" ardupilot PX4-Autopilot

# ── 兩處的 repos ────────────────────────────────────────────────────
# 整個 repos 目錄都備份，內含未提交的本機修改，git clone 取不回來。
# 排除 isaaclab-uav/.claude/memory：該路徑是 mount bind 掛載點，容器 rootfs
# 內僅為空掛載點，其實際資料已包含在下方 host 的 .claude/projects 備份中。
sync_dir "$C" "$CB" repos "isaaclab-uav/.claude/memory"
if [ "$is_solo" = 0 ]; then
    sync_dir "$HOST_HOME" "$HOST_BACKUP" repos
fi

# ── host 的 Claude 專案紀錄 ─────────────────────────────────────────
# 路徑在 host 與 solo 上皆為 /home/jack/.claude/projects，一律備份到 host/。
# memory 亦在其中（bind 來源端），是 memory 唯一的備份來源。
sync_dir "$HOST_HOME/.claude" "$HOST_BACKUP/.claude" projects

# ── 兩處的個人資料 ──────────────────────────────────────────────────
sync_files "$C" "$CB" "${personal_dirs[@]}"
if [ "$is_solo" = 0 ]; then
    sync_files "$HOST_HOME" "$HOST_BACKUP" "${personal_dirs[@]}"
fi

# ── host 系統設定 ───────────────────────────────────────────────────
# 不含 /var/lib/lxc/jammy/config：該檔是指向 repos/lxc-config/jammy 的
# 符號連結，實檔已隨上方 host repos 一併備份。
sync_files /etc "$BACKUP_ROOT/host/etc" "${etc_files[@]}"

# ── 家目錄設定檔（清單與 solo 裁決表見 common.sh）─────────────────────
sync_home_files to_backup

# Tilix 終端機設定存於 dconf，須匯出。屬桌面環境，歸 host。
backup_dconf /com/gexperts/Tilix/ "$HOST_BACKUP/tilix.dconf"

# Chrome／VS Code 登入狀態與 gnome-keyring（三者須齊備才有意義，見 common.sh）
backup_session_state

# 確保所有資料真正落到磁碟，避免拔碟時資料還停留在快取
sync
report 備份
