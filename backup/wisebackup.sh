#!/usr/bin/env bash
set -Eeuo pipefail

### === CONFIG ===
AWS_NAMESPACE="WiseBackup"
AWS_DEFAULT_REGION="us-east-1"
export AWS_DEFAULT_REGION
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:690063008832:newcombe-storage-alerts"
HOSTNAME="$(hostname -s)"

# Fill in the real UUIDs
SRC1_UUID="f923f153-e624-487a-9f54-baec24cec4ab"   # /media/casey/wcstore2
DST1_UUID="21f4e317-6f64-4bb8-85fc-c37573280654"   # /media/casey/Newcombe01
SRC2_UUID="5c719d20-7fd5-4e30-a20a-479b698109e8"   # /media/casey/WC Storage 1
DST2_UUID="9da343f0-3965-49eb-b8a4-8ae166a004bd"   # /media/casey/WC Storage 2

SRC1="/media/casey/wcstore2";        DST1="/media/casey/Newcombe01"
SRC2="/media/casey/WC Storage 1";   DST2="/media/casey/WC Storage 2"

S3_PHOTO_BUCKET="s3://wisecapture-archive"
S3_FAMILY_BUCKET="s3://wisefamily-archive"

STATE_DIR="/home/casey/.local/share/wisebackup"
LOG="/home/casey/automater.log"
SENTINEL=".mirror_sentinel"

EXCLUDES_COMMON=( --exclude 'lost+found' --exclude '.Trash-1000/*' --exclude '.DS_Store' --exclude '._.DS_Store' --exclude '.AppleDouble/' --exclude '._*' )

### === ALERTING ===
_sns_alert() {
  aws sns publish --region us-east-1 --topic-arn "$SNS_TOPIC_ARN" \
    --message "$1" --subject "$2" 2>/dev/null || true
}

trap '_sns_alert "wisebackup failed on Newcombe at $(date). Check $LOG for details." "WiseCapture Backup FAILED"' ERR

### === HELPERS ===
ts() { date +'%Y-%m-%d %H:%M:%S'; }

ensure_state_dir() {
  mkdir -p "$STATE_DIR"
}

srcdst_dim() {
  local job="$1"
  echo "[{Name=Host,Value=$HOSTNAME},{Name=Job,Value=$job}]"
}

emit_cw() {
  local ns="$1" mname="$2" val="$3" unit="$4" dims="$5"
  aws cloudwatch put-metric-data --namespace "$ns" --metric-data "MetricName=$mname,Value=$val,Unit=$unit,Dimensions=$dims" >/dev/null
}

check_mount () {
  local path=$1 uuid=$2
  mountpoint -q "$path" || { echo "ERR not a mountpoint: $path"; exit 1; }
  local src devuuid

  devuuid="$(findmnt -no UUID "$path")"
  [[ -n "$devuuid" ]] || { echo "ERR cannot read UUID at $path"; exit 1; }
  [[ "$devuuid" == "$uuid" ]] || { echo "ERR UUID mismatch at $path ($devuuid != $uuid)"; exit 1; }
  [[ -f "$path/$SENTINEL" ]] || { echo "ERR missing sentinel at $path"; exit 1; }
  # basic sanity: expect more than 5 entries to reduce "empty source" risk
  [[ $(find "$path" -mindepth 1 -maxdepth 1 | wc -l) -gt 5 ]] || { echo "ERR suspiciously few entries at $path"; exit 1; }
}

run_rsync_with_metrics () {
  local label="$1" src="$2" dst="$3"
  local stats="/tmp/rsync_${label}_$$_stats.txt"
  local start end dur dims
  start=$(date +%s)
  rsync -a --delete --ignore-errors --delete-after --human-readable --stats "${EXCLUDES_COMMON[@]}" "$src/" "$dst/" | tee "$stats" >/dev/null
  end=$(date +%s); dur=$((end-start))

  # Parse rsync stats
  local bytes files
  bytes="$(awk -F': ' '/Total transferred file size:/ {print $2}' "$stats" | tr -cd '0-9')"
  files="$(awk -F': ' '/Number of regular files transferred:/ {print $2}' "$stats" | tr -cd '0-9')"
  : "${bytes:=0}" ; : "${files:=0}"

  dims="$(srcdst_dim "$label")"
  emit_cw "$AWS_NAMESPACE" "BackupDurationSeconds" "$dur" "Seconds" "$dims"
  emit_cw "$AWS_NAMESPACE" "BytesTransferred" "$bytes" "Bytes" "$dims"
  emit_cw "$AWS_NAMESPACE" "FilesTransferred" "$files" "Count" "$dims"

  rm -f "$stats"
  echo "$(ts) $label rsync done in ${dur}s, files=${files}, bytes=${bytes}" >> "$LOG"
}

# Estimate changed bytes for S3 by "files newer than last run" (good proxy)
estimate_changed_bytes_since () {
  local path="$1" last_epoch="$2"
  # find exits non-zero on unreadable dirs (e.g. lost+found); || true prevents ERR trap
  { find "$path" -type f -newermt "@$last_epoch" -printf '%s\n' 2>/dev/null || true; } \
    | awk '{s+=$1} END{print s+0}'
}

s3_sync_with_metrics () {
  local label="$1" path="$2" bucket="$3"
  local out="/tmp/s3sync_${label}_$$_out.txt"
  local err="/tmp/s3sync_${label}_$$_err.txt"
  local stamp="$STATE_DIR/${label}.last_run"
  local last_epoch=0

  [[ -f "$stamp" ]] && last_epoch="$(cat "$stamp" || echo 0)"

  local start end dur dims s3_exit=0
  start=$(date +%s)
  aws s3 sync "$path/" "$bucket" --force-glacier-transfer "${EXCLUDES_COMMON[@]}" \
    2>"$err" | tee "$out" >/dev/null || s3_exit=$?
  end=$(date +%s); dur=$((end-start))

  # aws s3 sync exits non-zero when it encounters unreadable filesystem dirs (e.g., lost+found).
  # Tolerate that specific case; re-raise if there are actual S3/auth errors in stderr.
  if [[ $s3_exit -ne 0 ]]; then
    local real_errors
    real_errors=$(grep -v 'File/Directory is not readable\|Skipping file' "$err" | grep -c '.' || true)
    if [[ $real_errors -gt 0 ]]; then
      cat "$err" >&2
      rm -f "$out" "$err"
      exit $s3_exit
    fi
  fi

  local uploads est_bytes
  # aws s3 sync uses \r for progress updates; normalize to \n before counting upload lines
  uploads=$(tr '\r' '\n' < "$out" | grep -c '^upload:' || true)
  est_bytes="$(estimate_changed_bytes_since "$path" "$last_epoch")"

  dims="$(srcdst_dim "$label")"
  emit_cw "$AWS_NAMESPACE" "S3SyncDurationSeconds" "$dur" "Seconds" "$dims"
  emit_cw "$AWS_NAMESPACE" "S3FilesUploaded" "$uploads" "Count" "$dims"
  emit_cw "$AWS_NAMESPACE" "EstimatedUploadBytes" "$est_bytes" "Bytes" "$dims"

  date +%s > "$stamp"
  rm -f "$out" "$err"
  echo "$(ts) $label s3 sync done in ${dur}s, uploads=${uploads}, est_bytes=${est_bytes}" >> "$LOG"
}

### === MAIN ===
ensure_state_dir

# Guard both mirrors
check_mount "$SRC1" "$SRC1_UUID"
check_mount "$DST1" "$DST1_UUID"
check_mount "$SRC2" "$SRC2_UUID"
check_mount "$DST2" "$DST2_UUID"

# Local mirrors (identical trees; --delete)
run_rsync_with_metrics "PersonalMirror" "$SRC1" "$DST1"
run_rsync_with_metrics "WCPhotoMirror"  "$SRC2" "$DST2"

# Cloud backups
s3_sync_with_metrics "WCPhotoS3"  "$SRC2" "$S3_PHOTO_BUCKET"
s3_sync_with_metrics "FamilyS3"   "$SRC1/Backup" "$S3_FAMILY_BUCKET"

emit_cw "$AWS_NAMESPACE" "BackupSuccess" 1 "Count" "[{Name=Host,Value=$HOSTNAME}]"
echo "$(ts) wisebackup completed" >> "$LOG"

if [ "$(date +%u)" = "7" ]; then
  _sns_alert "Weekly check-in: WiseCapture backup completed successfully on $(date)." "WiseCapture Backup OK — Weekly Summary"
fi
