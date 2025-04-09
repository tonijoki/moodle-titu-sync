#!/bin/bash

# === LOAD CONFIG ===
CONF_FILE="titu.conf"
if [[ -f "$CONF_FILE" ]]; then
    source "$CONF_FILE"
else
    echo "Error: Configuration file not found at $CONF_FILE"
    exit 1
fi

# Check if LOG_DIR is set after sourcing
if [[ -z ${LOG_DIR+x} ]]; then
    echo "Error: LOG_DIR variable not set. Please check your config file."
    exit 1
fi

# === SETUP ===
PATH=/usr/local/sbin:/sbin:/bin:/usr/sbin:/usr/bin:/root/bin
set -euo pipefail
mkdir -p "$LOG_DIR"

SCRIPT_LOG="$LOG_DIR/titu-script.log"
MAIN_LOG="$LOG_DIR/titu.log"
exec &> "$SCRIPT_LOG"

# === LOG FUNCTION ===
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S%:z') - $1" >> "$MAIN_LOG"
}

# === MODE HANDLING ===
TEST_MODE=0
MOCK_API=0

case "${1:-}" in
  test) TEST_MODE=1 ;;
  --mock-api) MOCK_API=1 ;;
esac

# === DB CREDENTIALS ===
DBNAME=$(grep '$CFG->dbname' "$CONFIG_FILE" | awk -F"'" '{print $2}')
DBUSER=$(grep '$CFG->dbuser' "$CONFIG_FILE" | awk -F"'" '{print $2}')
DBPASS=$(grep '$CFG->dbpass' "$CONFIG_FILE" | awk -F"'" '{print $2}')

# === GET LAST RUN TIME ===
if [[ -f "$LAST_RUN_FILE" ]]; then
  LAST_RUN_TIMESTAMP=$(cat "$LAST_RUN_FILE")
  LAST_RUN_EPOCH=$(date -d "$LAST_RUN_TIMESTAMP" '+%s')
else
  LAST_RUN_EPOCH=0
fi

# === FETCH COMPLETION DATA ===
COMPLETION_LIST=()
for COURSE_ID in "${COURSE_IDS[@]}"; do
    RESULTS=$(psql -U "$DBUSER" -d "$DBNAME" -t -A -F"|" -c "
      SELECT json_build_object(
          'username', mdl_user.username,
          'courseId', mdl_course.id::int,
          'completiontime', TO_CHAR(TO_TIMESTAMP(mdl_course_completions.timecompleted), 'YYYY-MM-DD HH24:MI:SS')
      )
      FROM mdl_user
      JOIN mdl_course_completions ON mdl_user.id = mdl_course_completions.userid
      JOIN mdl_course ON mdl_course_completions.course = mdl_course.id
      WHERE mdl_course_completions.course = $COURSE_ID
      AND mdl_course_completions.timecompleted > $LAST_RUN_EPOCH;
    ") || continue

    if [[ -n "$RESULTS" ]]; then
        log "$RESULTS"
        while IFS="|" read -r json_line; do
            if [[ -n "$json_line" ]]; then
                COMPLETION_LIST+=("$json_line")
            fi
        done <<< "$RESULTS"
    fi
done

# === CHECK IF DATA TO SEND ===
if [[ ${#COMPLETION_LIST[@]} -eq 0 ]]; then
  log "No new completions found."
  exit 0
fi

# === BUILD JSON PAYLOAD (no jq) ===
JSON_OUTPUT="["
for line in "${COMPLETION_LIST[@]}"; do
    JSON_OUTPUT+="$line,"
done
JSON_OUTPUT="${JSON_OUTPUT%,}]"

# === SEND TO API ===
TEMP_FILE=$(mktemp)
echo "$JSON_OUTPUT" > "$TEMP_FILE"

if [[ "$TEST_MODE" -eq 1 ]]; then
  log "TEST MODE: Would send the following data:"
  cat "$TEMP_FILE" >> "$MAIN_LOG"
else
  if [[ "$MOCK_API" -eq 1 ]]; then
    log "MOCK API MODE: Simulating successful API call."
    HTTP_STATUS=200
    RESPONSE_BODY='{"message":"success (mocked)"}'
  else
    API_RESPONSE=$(curl -sS -w "\nHTTP_STATUS:%{http_code}\n" -X POST -d @"$TEMP_FILE" \
      -H "apikey: $API_KEY" \
      -H "Content-Type: application/json" \
      "$API_URL" 2>&1)

    CURL_EXIT_CODE=$?
    HTTP_STATUS=$(echo "$API_RESPONSE" | grep -oP 'HTTP_STATUS:\K[0-9]+')
    RESPONSE_BODY=$(echo "$API_RESPONSE" | grep -v "HTTP_STATUS:")

    if [[ $CURL_EXIT_CODE -ne 0 ]]; then
        log "Curl error (exit code $CURL_EXIT_CODE): $API_RESPONSE"
        HTTP_STATUS="000"
        RESPONSE_BODY="Curl error (exit code $CURL_EXIT_CODE): $API_RESPONSE"
    fi
  fi

  if [[ "$HTTP_STATUS" -ge 200 && "$HTTP_STATUS" -lt 300 ]]; then
    log "API call successful (HTTP $HTTP_STATUS) - Response: $RESPONSE_BODY"
    current_timestamp=$(date '+%Y-%m-%d %H:%M:%S%:z')
    current_timestamp=${current_timestamp:0:-3}
    echo "$current_timestamp" > "$LAST_RUN_FILE"
    log "Updated last run timestamp to current time: $current_timestamp"
  else
    log "API call failed (HTTP $HTTP_STATUS): $RESPONSE_BODY"
  fi
fi

rm "$TEMP_FILE"
