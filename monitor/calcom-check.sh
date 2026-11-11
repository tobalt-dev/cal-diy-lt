#!/usr/bin/env bash
# Daily health check for meet.tobalt.lt (cal.diy) during the parallel run with MS Bookings.
# Prints one PASS/FAIL line per check, writes the report to reports/YYYY-MM-DD.txt,
# records the result as heartbeat "calcom-meet-daily" on ops (watched by the Ops engineer agent),
# and exits with the number of failed checks.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORT_DIR="$HERE/reports"; mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/$(date -u +%F).txt"
URL=https://meet.tobalt.lt
APP=calcom-nda1reojlymij7p59okos4ax
DB=database-nda1reojlymij7p59okos4ax
COMPOSE="$HERE/../deploy/compose.yml"
RESEND_TOKEN_FILE=/root/.cal-diy-resend-token
fails=0

out() { printf '%s\n' "$*" | tee -a "$REPORT"; }
check() {  # check NAME OK(0/1) DETAIL
  if [ "$2" = 0 ]; then out "PASS $1 — $3"; else out "FAIL $1 — $3"; fails=$((fails+1)); fi
}
psql_prod() { printf '%s\n' "$1" | ssh -o BatchMode=yes prod "docker exec -i $DB psql -U calcom -d calendso -tA -v ON_ERROR_STOP=1"; }

: > "$REPORT"; out "meet.tobalt.lt daily check $(date -u +%FT%TZ)"

code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$URL/auth/login")
[ "$code" = 200 ]; check login $? "HTTP $code"

want=$(grep -oE 'cal-diy-lt@sha256:[0-9a-f]{64}' "$COMPOSE" | cut -d@ -f2)
info=$(ssh -o BatchMode=yes prod "docker inspect $APP -f '{{.Config.Image}} {{.RestartCount}} {{.State.Status}}'" 2>&1)
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

dump=$(ssh -o BatchMode=yes prod "journalctl -u tobalt-backup.service --since '-26 hours' --no-pager | grep -c 'db-preamble: OK pg    $DB'" 2>&1)
[[ "$dump" =~ ^[0-9]+$ && "$dump" -ge 1 ]]; check backup $? "nightly dump lines for $DB in 26 h: $dump"

stats=$(psql_prod "select count(*) filter (where \"createdAt\">now()-interval '24 hours'), count(*) filter (where status='accepted' and \"startTime\">now()) from \"Booking\" where title not like '%TESTAS%'" 2>&1)
out "INFO bookings created 24h | upcoming accepted: ${stats//|/ | }"

out "RESULT $fails failed"
ssh -o BatchMode=yes ops "tobalt-hb calcom-meet-daily --source cron --interval 86400 --grace 21600 --record-exit $fails" \
  || out "WARN heartbeat write failed"
exit "$fails"
