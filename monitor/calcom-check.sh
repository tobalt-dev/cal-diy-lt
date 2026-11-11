#!/usr/bin/env bash
# Daily health check for a self-hosted cal.diy during the parallel run with MS Bookings.
# Prints one PASS/FAIL line per check, writes the report to reports/YYYY-MM-DD.txt,
# records the result as a heartbeat on ops (watched by the Ops engineer agent),
# reads that heartbeat back, and exits with the number of failed checks.
# Site-specific values come from calcom-check.conf next to the invoked path (see .example).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONF="${CALCOM_CHECK_CONF:-$HERE/calcom-check.conf}"
[ -r "$CONF" ] || { echo "missing config $CONF" >&2; exit 99; }
# shellcheck source=/dev/null
. "$CONF"
for v in URL PROD_SSH OPS_SSH APP DB HB_PGC HB_JOB COMPOSE RESEND_TOKEN_FILE; do
  [ -n "${!v:-}" ] || { echo "config $CONF: $v is empty" >&2; exit 99; }
done
REPORT_DIR="$HERE/reports"; mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/$(date -u +%F).txt"
fails=0

out() { printf '%s\n' "$*" | tee -a "$REPORT"; }
check() {  # check NAME OK(0/1) DETAIL
  if [ "$2" = 0 ]; then out "PASS $1 — $3"; else out "FAIL $1 — $3"; fails=$((fails+1)); fi
}
psql_prod() { printf '%s\n' "$1" | ssh -o BatchMode=yes "$PROD_SSH" "docker exec -i $DB psql -U calcom -d calendso -tA -v ON_ERROR_STOP=1"; }

: > "$REPORT"; out "$URL daily check $(date -u +%FT%TZ)"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$URL/auth/login")
[ "$code" = 200 ]; check login $? "HTTP $code"

want=$(grep -oE '@sha256:[0-9a-f]{64}' "$COMPOSE" | head -1 | cut -c2-)
info=$(ssh -o BatchMode=yes "$PROD_SSH" "docker inspect $APP -f '{{.Config.Image}} {{.RestartCount}} {{.State.Status}}'" 2>&1)
img=${info%% *}; rest=${info#* }; restarts=${rest%% *}; state=${rest#* }
[[ -n "$want" && "$img" == *"$want" ]]; check image $? "running ${img##*@} pinned ${want:-none}"
[[ "$state" == running && "$restarts" =~ ^[0-9]+$ && "$restarts" -le 3 ]]; check container $? "state=$state restarts=$restarts"

trg=$(psql_prod "select count(*) from pg_trigger where tgname like 'tobalt%' or tgname like 'attendee_locale%'" 2>&1)
[ "$trg" = 3 ]; check triggers $? "$trg of 3 custom triggers"

from=$(date -u +%F); to=$(date -u -d '+14 days' +%F)
for et in 4 5; do
  n=$(curl -s -m 30 -G "$URL/api/trpc/slots/getSchedule" --data-urlencode batch=1 --data-urlencode \
    "input={\"0\":{\"json\":{\"eventTypeId\":$et,\"startTime\":\"${from}T00:00:00.000Z\",\"endTime\":\"${to}T23:59:59.999Z\",\"timeZone\":\"Europe/Vilnius\",\"isTeamEvent\":false,\"usernameList\":[\"tobalt\"]}}}" \
    | python3 -c "import json,sys;r=json.load(sys.stdin)[0];print(sum(len(v) for v in r['result']['data']['json']['slots'].values()))" 2>/dev/null)
  [[ "$n" =~ ^[0-9]+$ && "$n" -gt 0 ]]; check "slots-et$et" $? "${n:-error} slots in next 14 days"
done

mail=$(curl -s -m 30 -H "Authorization: Bearer $(cat "$RESEND_TOKEN_FILE")" "https://api.resend.com/emails?limit=100" | python3 -c "
import json,sys
from datetime import datetime,timedelta,timezone
cut=datetime.now(timezone.utc)-timedelta(hours=26)
rows=[e for e in json.load(sys.stdin)['data'] if datetime.fromisoformat(e['created_at'].replace(' ','T').split('.')[0]+'+00:00')>=cut]
bad=[e for e in rows if e.get('last_event') in ('bounced','failed','complained','delivery_delayed')]
print(len(rows),len(bad),';'.join(f\"{e.get('last_event')}:{(e.get('subject') or '')[:40]}\" for e in bad))" 2>&1)
read -r sent bad detail <<<"$mail"
[[ "$bad" == 0 ]]; check mail $? "26h: ${sent:-?} sent, ${bad:-?} not delivered ${detail:-}"

noteams=$(psql_prod "select count(*) from \"Booking\" b where b.status='accepted' and b.\"createdAt\">now()-interval '7 days' and not exists (select 1 from \"BookingReference\" r where r.\"bookingId\"=b.id and r.\"meetingUrl\" like 'https://teams%')" 2>&1)
[ "$noteams" = 0 ]; check teams-links $? "$noteams accepted bookings (7 d) without a Teams link"

# Only the run the timer last started counts: a later manual run must not mask a nightly miss.
# BACKUP_SINCE overrides the start time (testing against a past run).
read -r bage bdump < <(ssh -o BatchMode=yes "$PROD_SSH" "DB=$DB SINCE='${BACKUP_SINCE:-}' bash -s" 2>&1 <<'EOF'
t=${SINCE:-$(systemctl show tobalt-backup.timer -p LastTriggerUSec --value)}
age=$(( $(date +%s) - $(date -d "$t" +%s) ))
n=$(journalctl -u tobalt-backup.service --since "$t" --no-pager -o cat \
  | awk '{print} /Finished tobalt-backup|Failed with result/{exit}' | grep -cE "db-preamble: OK pg +$DB ")
echo "$age $n"
EOF
)
[[ "$bage" =~ ^[0-9]+$ && "$bage" -le 93600 && "$bdump" == 1 ]]
check backup $? "last timer run $(( ${bage:-0} / 3600 )) h ago dumped $DB: ${bdump:-?} (want 1)"

stats=$(psql_prod "select count(*) filter (where \"createdAt\">now()-interval '24 hours'), count(*) filter (where status='accepted' and \"startTime\">now()) from \"Booking\" where title not like '%TESTAS%'" 2>&1)
out "INFO bookings created 24h | upcoming accepted: ${stats//|/ | }"

out "RESULT $fails failed"
ssh -o BatchMode=yes "$OPS_SSH" "tobalt-hb $HB_JOB --source cron --interval 86400 --grace 21600 --record-exit $fails" \
  || out "WARN heartbeat write failed"

# Read the heartbeat back from the store the alerting reads, not the writer's exit code.
want_hb=$([ "$fails" = 0 ] && echo ok || echo fail)
hb=$(printf "select coalesce(last_status,''), extract(epoch from now()-last_run)::int from script_heartbeats where job='%s'\n" "$HB_JOB" \
  | ssh -o BatchMode=yes "$OPS_SSH" "docker exec -i $HB_PGC sh -c 'psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tA -F\" \" -v ON_ERROR_STOP=1'" 2>&1)
read -r hb_status hb_age <<<"$hb"
if [[ "$hb_status" == "$want_hb" && "$hb_age" =~ ^[0-9]+$ && "$hb_age" -le 300 ]]; then
  out "HEARTBEAT $HB_JOB=$hb_status ${hb_age}s ago"
else
  out "WARN heartbeat readback: got '${hb:-nothing}', want $want_hb within 300 s"; fails=$((fails+1))
fi
exit "$fails"
