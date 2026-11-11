#!/usr/bin/env bash
# =============================================================================
# migrate-mongodb.sh
#
# In-place upgrade of a single-node MongoDB replica set on Ubuntu 22.04
# from 7.0.x  ->  8.0.x  ->  8.3.x, then installs mongot (MongoDB Search in
# Community) so $vectorSearch works.
#
# Run it ON THE DATABASE HOST, as root (sudo). The only input is the MongoDB
# connection URI of a user with the `root` role, e.g.
#   mongodb://admin:<pass>@127.0.0.1:27017/workmentor?authSource=admin&replicaSet=rs0
#
# Ways to pass it (in order of preference, the first two keep the password out
# of shell history and `ps`):
#   sudo ./migrate-mongodb.sh                 # prompts for the URI (hidden input)
#   sudo -E ./migrate-mongodb.sh              # reads $MONGO_URI from the environment
#   sudo ./migrate-mongodb.sh '<uri>'         # positional argument (least safe)
#
# What it does, in order (each step is verified before the next one starts):
#   1. Pre-flight checks: root, Ubuntu jammy, apt-installed mongod under systemd,
#      URI points at THIS host's mongod, single-member replica set, healthy
#      PRIMARY, FCV matches binary version, enough disk for a backup, free ports.
#   2. Prints a "before" report (version, replica set, FCV, users, counts).
#   3. Full logical backup of every database (mongodump --oplog, gzip archive),
#      verified with a mongorestore --dryRun, plus copies of mongod.conf, the
#      keyfile, the apt sources and the current mongod binaries.
#   4. 7.0 -> 8.0 binaries (clean shutdown, apt install, restart, verify),
#      then setFeatureCompatibilityVersion 8.0.
#   5. 8.0 -> 8.3 binaries, then setFeatureCompatibilityVersion 8.3.
#   6. Installs mongot as a systemd service, creates its searchCoordinator
#      user, adds the search setParameters to mongod.conf, restarts mongod.
#   7. Prints an "after" report and compares collection counts.
#
# The script is resumable: re-running it detects the current binary/FCV state
# and continues from where it stopped. On a server that is already fully
# migrated it only verifies and prints the report.
#
# If a binary upgrade fails BEFORE the FCV is raised, the previous binaries
# are put back automatically and mongod is restarted on them. Once the FCV is
# raised there is no in-place downgrade: recovery is a restore of the backup
# (the restore command is printed at the end of the backup step).
#
# Optional environment overrides (defaults are what was tested):
#   TARGET_VERSION=8.3.4       INTERMEDIATE_VERSION=8.0.34
#   MONGOT_VERSION=1.78.0      INSTALL_MONGOT=1
#   BACKUP_ROOT=/var/backups/mongodb-migration
#   APP_DB=<db from URI, else workmentor>   USERS_COLLECTION=users
#   MONGOD_SERVICE=mongod      ASSUME_YES=0 (1 = no confirmation prompt)
#   STRICT_COUNTS=0 (1 = fail if any collection count changed)
#   VERIFY_RESTORE=auto (restore the backup into a temporary mongod and compare
#                        counts when disk allows; always = required; never = skip)
#   MONGOT_GRPC_PORT=27028 MONGOT_HEALTH_PORT=27029 MONGOT_METRICS_PORT=9946
#   MONGOT_MEMORY_MAX=     (e.g. 2G: memory cap for the mongot service)
#   CHECK_ONLY=0           (1 = run every pre-flight check and the before
#                           report, change nothing in MongoDB, exit)
#
# Recommended on production: run once with CHECK_ONLY=1, fix anything it
# reports, take a disk snapshot, stop the app writers, then run for real.
# =============================================================================

set -Eeuo pipefail
umask 077

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
TARGET_VERSION="${TARGET_VERSION:-8.3.4}"
INTERMEDIATE_VERSION="${INTERMEDIATE_VERSION:-8.0.34}"
MONGOT_VERSION="${MONGOT_VERSION:-1.78.0}"
INSTALL_MONGOT="${INSTALL_MONGOT:-1}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/mongodb-migration}"
USERS_COLLECTION="${USERS_COLLECTION:-users}"
MONGOD_SERVICE="${MONGOD_SERVICE:-mongod}"
ASSUME_YES="${ASSUME_YES:-0}"
STRICT_COUNTS="${STRICT_COUNTS:-0}"
MONGOT_GRPC_PORT="${MONGOT_GRPC_PORT:-27028}"
# Not mongot's documented 8080: on hosts with Varnish, nginx usually listens on 8080.
MONGOT_HEALTH_PORT="${MONGOT_HEALTH_PORT:-27029}"
MONGOT_MEMORY_MAX="${MONGOT_MEMORY_MAX:-}"  # e.g. 2G: systemd MemoryMax for mongot (the JVM sizes its heap from it)
CHECK_ONLY="${CHECK_ONLY:-0}"              # 1 = pre-flight checks + before report only, then exit
MONGOT_METRICS_PORT="${MONGOT_METRICS_PORT:-9946}"
START_TIMEOUT="${START_TIMEOUT:-900}"   # seconds to wait for mongod to become PRIMARY
VERIFY_RESTORE="${VERIFY_RESTORE:-auto}" # auto | always | never  (full restore test of the backup)

TARGET_SERIES="${TARGET_VERSION%.*}"            # 8.3
INTERMEDIATE_SERIES="${INTERMEDIATE_VERSION%.*}" # 8.0
APT_KEY_SERIES="8.0"   # repo.mongodb.org signs the 8.0, 8.2 and 8.3 repos with the 8.0 key
APT_KEYRING="/usr/share/keyrings/mongodb-server-${APT_KEY_SERIES}.gpg"
APT_KEY_FINGERPRINT="4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05"

MONGOT_HOME="/opt/mongot"
MONGOT_ETC="/etc/mongot"
MONGOT_DATA="/var/lib/mongot"
MONGOT_USER_DB="mongotUser"

TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${BACKUP_ROOT}/${TS}"
LOG_FILE=""
TMP_DIR=""
CURRENT_STEP="startup"

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_0=$'\e[0m'; else C_B=; C_G=; C_Y=; C_R=; C_0=; fi
log()   { printf '%s [%s] %s\n' "$(date -u +%H:%M:%S)" "INFO" "$*"; }
ok()    { printf '%s [%s] %s%s%s\n' "$(date -u +%H:%M:%S)" " OK " "$C_G" "$*" "$C_0"; }
warn()  { printf '%s [%s] %s%s%s\n' "$(date -u +%H:%M:%S)" "WARN" "$C_Y" "$*" "$C_0" >&2; }
die()   { printf '%s [%s] %s%s%s\n' "$(date -u +%H:%M:%S)" "FAIL" "$C_R" "$*" "$C_0" >&2; exit 1; }
step()  { CURRENT_STEP="$*"; printf '\n%s==== %s ====%s\n' "$C_B" "$*" "$C_0"; }

on_error() {
  local rc=$? line=${1:-?}
  printf '\n%s[FAIL] step "%s" failed (exit %s, line %s).%s\n' "$C_R" "$CURRENT_STEP" "$rc" "$line" "$C_0" >&2
  [[ -n "$LOG_FILE" ]] && printf 'Full log: %s\n' "$LOG_FILE" >&2
  [[ -d "$RUN_DIR/dump" ]] && printf 'Backup: %s\n' "$RUN_DIR" >&2
  printf 'The script is resumable: fix the cause and run it again.\n' >&2
}
trap 'on_error $LINENO' ERR
cleanup() {
  stop_restore_mongod 2>/dev/null || true
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  return 0
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# Input: the URI (never echoed, never passed on a command line)
# ----------------------------------------------------------------------------
MIG_URI="${1:-${MONGO_URI:-}}"
if [[ -z "$MIG_URI" ]]; then
  if [[ -t 0 ]]; then
    read -r -s -p "MongoDB connection URI (root user): " MIG_URI; echo
  fi
fi
[[ -n "$MIG_URI" ]] || die "No MongoDB URI given (argument, \$MONGO_URI or prompt)."
[[ "$MIG_URI" =~ ^mongodb(\+srv)?:// ]] || die "The URI must start with mongodb:// or mongodb+srv://"
# Not exported: only mongosh (via js_uri) and the 0600 tools config ever see it.
export -n MONGO_URI 2>/dev/null || true
unset MONGO_URI

# ----------------------------------------------------------------------------
# Root, OS and lock
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0  (use sudo -E if you pass \$MONGO_URI)."
# `sudo -E` keeps the caller's HOME; mongosh/gpg would then leave root-owned
# files in that user's home directory. Use root's own home.
HOME="$(getent passwd root | cut -d: -f6)"; export HOME
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_CODENAME:-}" == "jammy" ]] \
  || die "This script supports Ubuntu 22.04 (jammy) only; found ${PRETTY_NAME:-unknown}."

mkdir -p "$BACKUP_ROOT"; chmod 700 "$BACKUP_ROOT"
exec 9>"$BACKUP_ROOT/.migration.lock"
flock -n 9 || die "Another migration run holds $BACKUP_ROOT/.migration.lock"

mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
LOG_FILE="$RUN_DIR/migration.log"
exec > >(tee -a "$LOG_FILE") 2>&1
TMP_DIR="$(mktemp -d)"

log "Run directory: $RUN_DIR"
log "Target: MongoDB $TARGET_VERSION (via $INTERMEDIATE_VERSION), mongot $MONGOT_VERSION"

# ----------------------------------------------------------------------------
# mongosh / tools wrappers. The URI travels in the environment only.
# ----------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# js_uri <uri> <script>: run JS against <uri>; `db` is the URI's database.
# The URI is handed to mongosh through its environment, never on the command line.
js_uri() {
  MIG_CONNECT_URI="$1" mongosh --nodb --quiet --norc --eval "
    try { db = connect(process.env.MIG_CONNECT_URI); } catch (e) { print('CONNECT_ERROR: ' + e.message); quit(3); }
    $2"
}
# js <script>: run JS against the migration URI.
js() { js_uri "$MIG_URI" "$1"; }
# js_try: like js, but never trips the ERR trap (for polling).
js_try() { js "$1" 2>/dev/null || true; }

# A mongodump/mongorestore config file holding the URI, readable by root only.
TOOLS_CFG=""

# mongodump treats a database in the URI path as --db, and --oplog only works
# on a full dump. Strip the path; when it was also the implicit auth database
# (no authSource option), carry it over as authSource so login still works.
tools_uri() {
  local uri="$1" scheme rest hosts tail db="" opts=""
  scheme="${uri%%://*}"; rest="${uri#*://}"
  hosts="${rest%%[/?]*}"; tail="${rest:${#hosts}}"
  if [[ "$tail" == /* ]]; then tail="${tail#/}"; db="${tail%%\?*}"; fi
  [[ "$tail" == *\?* ]] && opts="${tail#*\?}"
  if [[ -n "$db" && ! "$opts" =~ (^|&)authSource= ]]; then
    opts="${opts:+$opts&}authSource=$db"
  fi
  printf '%s://%s/%s\n' "$scheme" "$hosts" "${opts:+?$opts}"
}

write_tools_cfg() {
  TOOLS_CFG="$TMP_DIR/tools.yaml"
  local turi; turi="$(tools_uri "$MIG_URI")"
  # YAML single-quoted scalar: escape single quotes by doubling them.
  printf "uri: '%s'\n" "${turi//\'/\'\'}" > "$TOOLS_CFG"
  chmod 600 "$TOOLS_CFG"
}

# apt/dpkg run with the normal 022 umask (the script's 077 is only for our own files).
apt_quiet() {
  ( umask 022
    DEBIAN_FRONTEND=noninteractive apt-get -y -q \
      -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@" )
}

# ----------------------------------------------------------------------------
# Readers
# ----------------------------------------------------------------------------
server_version() { js 'print(db.version())'; }
fcv() { js 'print(db.adminCommand({getParameter:1, featureCompatibilityVersion:1}).featureCompatibilityVersion.version)'; }
series_of() { echo "${1%.*}"; }

wait_primary() {
  local deadline=$(( $(date +%s) + START_TIMEOUT )) out
  log "Waiting for mongod to accept connections and become PRIMARY (max ${START_TIMEOUT}s)..."
  while (( $(date +%s) < deadline )); do
    if ! systemctl is-active --quiet "$MONGOD_SERVICE"; then
      if systemctl is-failed --quiet "$MONGOD_SERVICE"; then
        journalctl -u "$MONGOD_SERVICE" -n 40 --no-pager || true
        return 1
      fi
    fi
    out="$(js_try 'print(db.hello().isWritablePrimary === true ? "PRIMARY" : "NOT_PRIMARY")')"
    [[ "$out" == "PRIMARY" ]] && { ok "mongod is up and PRIMARY"; return 0; }
    sleep 3
  done
  return 1
}

mongod_conf_path() {
  local p
  p="$(js 'const o=db.adminCommand({getCmdLineOpts:1}); print(o.parsed.config || "")')"
  [[ -n "$p" ]] || p="/etc/mongod.conf"
  echo "$p"
}

# ----------------------------------------------------------------------------
# Reports
# ----------------------------------------------------------------------------
REPORT_JS='
const out = {};
const hello = db.hello();
out.serverVersion = db.version();
out.fcv = db.adminCommand({getParameter:1, featureCompatibilityVersion:1}).featureCompatibilityVersion.version;
const st = db.adminCommand({replSetGetStatus:1});
out.replicaSet = { enabled: true, name: st.set, myState: st.myState,
  members: st.members.map(m => ({ name: m.name, state: m.stateStr, health: m.health })) };
out.isWritablePrimary = hello.isWritablePrimary;
const appDb = db.getSiblingDB(process.env.APP_DB);
const usersColl = process.env.USERS_COLLECTION;
const SENSITIVE = /pass|secret|token|hash|salt|otp|key|session|refresh|credential/i;
const redact = (doc) => { const r = {}; for (const k of Object.keys(doc)) r[k] = SENSITIVE.test(k) ? "<redacted>" : doc[k]; return r; };
out.appDatabase = process.env.APP_DB;
if (appDb.getCollectionNames().includes(usersColl)) {
  const c = appDb.getCollection(usersColl);
  out.usersCollection = { name: usersColl, count: c.countDocuments({}),
    sample: c.find({}).sort({_id: 1}).limit(3).toArray().map(redact) };
} else {
  out.usersCollection = { name: usersColl, note: "collection not found in " + process.env.APP_DB };
}
out.databaseUsers = db.getSiblingDB("admin").system.users.find({}, {user:1, db:1, "roles.role":1, _id:0}).toArray();
print(EJSON.stringify(out, null, 2, { relaxed: true }));
'
print_report() {
  local title="$1"
  step "$title"
  APP_DB="$APP_DB" USERS_COLLECTION="$USERS_COLLECTION" js "$REPORT_JS" | tee "$RUN_DIR/report-$(echo "$title" | tr ' A-Z' '-a-z').json"
}

# One line per collection: "<db.collection>\t<documents>\t<indexes>", sorted.
COUNTS_JS='
const res = {};
db.adminCommand({listDatabases:1, nameOnly:true}).databases.forEach(d => {
  // local/config are internal; __mdb_internal_* holds mongot metadata created by the migration itself.
  if (["local","config"].includes(d.name) || d.name.startsWith("__mdb")) return;
  const sdb = db.getSiblingDB(d.name);
  sdb.getCollectionInfos({type:"collection"}).forEach(ci => {
    if (ci.name.startsWith("system.") || ci.name.startsWith("__mdb")) return;
    const c = sdb.getCollection(ci.name);
    res[d.name + "." + ci.name] = c.countDocuments({}) + "\t" + c.getIndexes().length;
  });
});
Object.keys(res).sort().forEach(k => print(k + "\t" + res[k]));
'
snapshot_counts() { js "$COUNTS_JS" > "$1"; }

# ----------------------------------------------------------------------------
# Backup verification
# ----------------------------------------------------------------------------
STABLE=0
RESTORE_PID_FILE=""

# mongodump logs "done dumping `db.coll` (N documents)"; older tools omit the
# backticks. Output: "<ns>\t<N>" per collection.
parse_dump_log() {
  sed -nE 's/.*done dumping `?([^` ]+)`? \(([0-9]+) documents?\).*/\1\t\2/p' "$1" | sort -u
}

verify_dump_log() {
  log "Checking the dump log against the live collections ..."
  parse_dump_log "$RUN_DIR/dump/mongodump.log" > "$RUN_DIR/counts-dumped.tsv"
  [[ -s "$RUN_DIR/counts-dumped.tsv" ]] || die "Could not read any 'done dumping' line from mongodump.log"
  local bad=0 ns cnt _idx dumped
  while IFS=$'\t' read -r ns cnt _idx; do
    dumped="$(awk -F'\t' -v n="$ns" '$1==n{print $2}' "$RUN_DIR/counts-dumped.tsv")"
    if [[ -z "$dumped" ]]; then
      if [[ "$cnt" == "0" ]]; then warn "Empty collection $ns not listed by mongodump"; else warn "Missing from the dump: $ns"; bad=1; fi
    elif [[ "$STABLE" == "1" && "$dumped" != "$cnt" ]]; then
      warn "$ns: $cnt documents live, $dumped dumped"; bad=1
    fi
  done < "$RUN_DIR/counts-before.tsv"
  [[ "$bad" == "0" ]] || die "Backup verification failed: the dump does not match the live data. Nothing was changed."
  ok "Dump log lists all $(wc -l < "$RUN_DIR/counts-before.tsv") collections with matching document counts"
}

stop_restore_mongod() {
  [[ -n "$RESTORE_PID_FILE" && -s "$RESTORE_PID_FILE" ]] || return 0
  local pid i; pid="$(cat "$RESTORE_PID_FILE")"
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -KILL "$pid" 2>/dev/null || true
  rm -f "$RESTORE_PID_FILE"
  return 0
}

# Restores the whole archive into a throw-away mongod (current binary, random
# local port, no auth, small cache) and compares every collection's document
# and index counts with the live server.
restore_test() {
  local archive="$1" tdir="$RUN_DIR/restore-test" port="" p
  for p in $(seq 27090 27099); do
    ss -Hltn "sport = :$p" | grep -q . || { port="$p"; break; }
  done
  [[ -n "$port" ]] || { warn "No free port in 27090-27099 for the restore test"; return 1; }
  rm -rf "$tdir"; mkdir -p "$tdir/db"
  RESTORE_PID_FILE="$tdir/mongod.pid"
  log "Restore test: temporary mongod on 127.0.0.1:$port ..."
  "$(command -v mongod)" --dbpath "$tdir/db" --port "$port" --bind_ip 127.0.0.1 --fork \
    --logpath "$tdir/mongod.log" --pidfilepath "$RESTORE_PID_FILE" --wiredTigerCacheSizeGB 0.25 \
    --setParameter diagnosticDataCollectionEnabled=false >/dev/null 2>&1 9>&- \
    || { tail -20 "$tdir/mongod.log"; return 1; }
  local turi="mongodb://127.0.0.1:$port/?directConnection=true"
  log "Restore test: mongorestore --oplogReplay of the full archive ..."
  # Same command as a real recovery (see RESTORE.txt). --oplogReplay cannot be
  # combined with --nsInclude/--nsExclude; mongorestore skips the internal
  # config.* session/transaction collections on its own.
  if ! mongorestore --uri "$turi" --gzip --archive="$archive" --oplogReplay \
        2>"$tdir/restore.log" 9>&-; then
    tail -20 "$tdir/restore.log"; stop_restore_mongod; return 1
  fi
  grep -E 'document\(s\) (restored successfully|failed to restore)' "$tdir/restore.log" | tail -1 || true
  if grep -qE '(^|[^0-9])[1-9][0-9]* document\(s\) failed to restore' "$tdir/restore.log"; then
    warn "Some documents failed to restore"; stop_restore_mongod; return 1
  fi
  js_uri "$turi" "$COUNTS_JS" > "$RUN_DIR/counts-restored.tsv" || { stop_restore_mongod; return 1; }
  stop_restore_mongod
  rm -rf "$tdir/db"

  if [[ "$STABLE" == "1" ]]; then
    if ! diff -u "$RUN_DIR/counts-before.tsv" "$RUN_DIR/counts-restored.tsv"; then
      warn "Restored data differs from the live data (columns: namespace, documents, indexes)"; return 1
    fi
    ok "Restore test passed: all $(wc -l < "$RUN_DIR/counts-restored.tsv") collections restored with identical document and index counts"
  else
    if ! diff -u <(cut -f1,3 "$RUN_DIR/counts-before.tsv") <(cut -f1,3 "$RUN_DIR/counts-restored.tsv"); then
      warn "Restored collections/indexes differ from the live server"; return 1
    fi
    ok "Restore test passed: all collections and indexes restored (document counts moved because of live writes)"
  fi
}

# ----------------------------------------------------------------------------
# Step 1: pre-flight
# ----------------------------------------------------------------------------
step "1. Pre-flight checks"

need_cmd mongosh || die "mongosh not found. Install it first: apt-get install mongodb-mongosh"
need_cmd curl    || apt_quiet install curl
need_cmd gpg     || apt_quiet install gnupg
need_cmd flock   || die "flock missing (util-linux)"
[[ -z "$MONGOT_MEMORY_MAX" || "$MONGOT_MEMORY_MAX" =~ ^[0-9]+[KMGT]?$ ]] \
  || die "MONGOT_MEMORY_MAX must look like 2G or 1536M (got '$MONGOT_MEMORY_MAX')"
need_cmd python3 || die "python3 is required (YAML validation of mongod.conf / mongot config)"
if ! python3 -c 'import yaml' 2>/dev/null; then
  log "Installing python3-yaml (used to validate config files)"
  apt_quiet install python3-yaml >/dev/null
fi

conn="$(js 'print("CONNECTED")' 2>&1 || true)"
[[ "$conn" == *CONNECTED* ]] || die "Cannot connect/authenticate with the given URI: ${conn//"$MIG_URI"/<uri>}"
ok "Connected and authenticated"

URI_DB="$(js 'print(db.getName())')"
if [[ -n "${APP_DB:-}" ]]; then :; elif [[ "$URI_DB" != "test" && "$URI_DB" != "admin" ]]; then APP_DB="$URI_DB"; else APP_DB="workmentor"; fi
log "Application database for the report: $APP_DB"

# The user must be able to do everything below (backup all DBs, FCV, users, shutdown).
has_root="$(js 'const s=db.adminCommand({connectionStatus:1}).authInfo.authenticatedUserRoles; print(s.some(r=>r.role==="root" && r.db==="admin") ? "yes" : "no")')"
[[ "$has_root" == "yes" ]] || die "The URI's user needs the root role on admin (backup, FCV change, user creation)."
ok "User has the root role"

systemctl cat "$MONGOD_SERVICE" >/dev/null 2>&1 \
  || die "systemd unit ${MONGOD_SERVICE}.service not found (set MONGOD_SERVICE)."
systemctl is-active --quiet "$MONGOD_SERVICE" || die "${MONGOD_SERVICE} is not running."

# The URI must reach the mongod managed by this host's systemd unit, otherwise
# we would upgrade local packages while talking to a different server.
srv_pid="$(js 'print(Number(db.serverStatus().pid))')"
unit_pid="$(systemctl show -p MainPID --value "$MONGOD_SERVICE")"
[[ "$srv_pid" == "$unit_pid" ]] \
  || die "The URI connects to mongod pid $srv_pid but ${MONGOD_SERVICE}.service runs pid $unit_pid. Run the script on the DB host with a URI to the local mongod."
ok "URI points at the local ${MONGOD_SERVICE} (pid $unit_pid)"

# Status is "<want> <flag> <state>": "install ok installed" or, for packages
# pinned with apt-mark hold (common on production), "hold ok installed".
[[ "$(dpkg-query -W -f='${Status}' mongodb-org-server 2>/dev/null | awk '{print $3}')" == "installed" ]] \
  || die "mongodb-org-server is not installed via apt. Only apt installs are supported."
PKG_VER="$(dpkg-query -W -f='${Version}' mongodb-org-server)"
mapfile -t ORG_PKGS < <(dpkg-query -W -f='${Package} ${Status}\n' 'mongodb-org*' 2>/dev/null \
  | awk '$NF=="installed"{print $1}' | grep -E '^mongodb-org(-server|-mongos|-database|-tools|-database-tools-extra|-shell)?$' || true)
# Meta packages pin exact versions of their dependencies, so if any meta package
# is installed we install the whole family explicitly at the same version.
if printf '%s\n' "${ORG_PKGS[@]}" | grep -qxE 'mongodb-org|mongodb-org-database|mongodb-org-tools'; then
  mapfile -t ORG_PKGS < <(printf '%s\n' "${ORG_PKGS[@]}" mongodb-org-server mongodb-org-mongos \
    mongodb-org-database-tools-extra mongodb-org-database mongodb-org-tools | grep -vx mongodb-org-shell | sort -u)
fi
log "Installed MongoDB packages: ${ORG_PKGS[*]} (server $PKG_VER)"

CUR_VER="$(server_version)"
CUR_FCV="$(fcv)"
log "Running version: $CUR_VER   FCV: $CUR_FCV"
[[ "$CUR_VER" == "$PKG_VER" ]] || warn "Running mongod ($CUR_VER) differs from installed package ($PKG_VER)."

case "$(series_of "$CUR_VER")" in
  7.0|8.0|"$TARGET_SERIES") ;;
  *) die "Unsupported starting version $CUR_VER (expected 7.0.x, 8.0.x or ${TARGET_SERIES}.x)." ;;
esac

rs_info="$(js 'const s=db.adminCommand({replSetGetStatus:1}); print(s.members.length + " " + Number(s.myState) + " " + s.set)' 2>&1)" \
  || die "Replica set status unavailable. This script expects a replica set (got: $rs_info)."
read -r RS_MEMBERS RS_STATE RS_NAME <<<"$rs_info"
[[ "$RS_STATE" == "1" ]] || die "This node is not PRIMARY (state $RS_STATE)."
[[ "$RS_MEMBERS" == "1" ]] || die "Replica set $RS_NAME has $RS_MEMBERS members. This script only does single-node in-place upgrades; multi-member sets need a rolling upgrade."
ok "Replica set '$RS_NAME' is enabled, single member, PRIMARY"

CONF="$(mongod_conf_path)"
[[ -f "$CONF" ]] || die "mongod config $CONF not found"
log "mongod config: $CONF"
KEYFILE="$(js 'const o=db.adminCommand({getCmdLineOpts:1}).parsed; print((o.security && o.security.keyFile) || "")')"
AUTHZ="$(js 'const o=db.adminCommand({getCmdLineOpts:1}).parsed; print((o.security && o.security.authorization) || "")')"
TLS_MODE="$(js 'const o=db.adminCommand({getCmdLineOpts:1}).parsed; print((o.net && o.net.tls && o.net.tls.mode) || "disabled")')"
DBPATH="$(js 'const o=db.adminCommand({getCmdLineOpts:1}).parsed; print((o.storage && o.storage.dbPath) || "/var/lib/mongodb")')"
log "keyFile: ${KEYFILE:-<none>}  authorization: ${AUTHZ:-<default>}  tls: $TLS_MODE  dbPath: $DBPATH"
if [[ "$INSTALL_MONGOT" == "1" ]]; then
  [[ -n "$KEYFILE" ]] || die "mongot requires a replica set with keyfile access control; no keyFile configured."
  [[ "$TLS_MODE" == "disabled" ]] || die "mongod uses TLS ($TLS_MODE). This script configures mongot without TLS only; set INSTALL_MONGOT=0 and configure mongot manually."
fi

# FCV must match the binary series before we move to the next binary.
case "$(series_of "$CUR_VER")" in
  7.0) [[ "$CUR_FCV" == "7.0" ]] || die "Running 7.0 with FCV $CUR_FCV; FCV must be 7.0 before upgrading." ;;
  8.0) [[ "$CUR_FCV" == "7.0" || "$CUR_FCV" == "8.0" ]] || die "Unexpected FCV $CUR_FCV on 8.0." ;;
esac

# Disk space for the backup: uncompressed data size + 1 GiB margin (gzip usually
# shrinks it a lot, so this is conservative).
read -r DATA_BYTES INDEX_BYTES < <(js 'let t=0, i=0; db.adminCommand({listDatabases:1}).databases.forEach(d=>{ if(d.name!=="local"){ const s=db.getSiblingDB(d.name).stats(); t+=Number(s.dataSize); i+=Number(s.indexSize); } }); print(Math.ceil(t) + " " + Math.ceil(i))')
[[ "$DATA_BYTES" =~ ^[0-9]+$ && "$INDEX_BYTES" =~ ^[0-9]+$ ]] || die "Could not read database sizes"
FREE_BYTES="$(df -B1 --output=avail "$BACKUP_ROOT" | tail -1 | tr -d ' ')"
NEED_BYTES=$(( DATA_BYTES + 1073741824 ))
log "Data size: $((DATA_BYTES/1048576)) MiB; free on $(df --output=target "$BACKUP_ROOT" | tail -1): $((FREE_BYTES/1048576)) MiB"
(( FREE_BYTES > NEED_BYTES )) || die "Not enough free disk for a safe backup (need ~$((NEED_BYTES/1048576)) MiB). Set BACKUP_ROOT to a larger disk."
DB_FREE="$(df -B1 --output=avail "$DBPATH" | tail -1 | tr -d ' ')"
(( DB_FREE > 2147483648 )) || die "Less than 2 GiB free on the dbPath filesystem; upgrade/startup could fail."
ok "Disk space is sufficient"

if [[ "$INSTALL_MONGOT" == "1" ]] && ! systemctl is-active --quiet mongot 2>/dev/null; then
  for p in "$MONGOT_GRPC_PORT" "$MONGOT_HEALTH_PORT" "$MONGOT_METRICS_PORT"; do
    if ss -Hltn "sport = :$p" | grep -q .; then
      die "Port $p is already in use (needed by mongot). Set MONGOT_GRPC_PORT/MONGOT_HEALTH_PORT/MONGOT_METRICS_PORT."
    fi
  done
  ok "mongot ports $MONGOT_GRPC_PORT/$MONGOT_HEALTH_PORT/$MONGOT_METRICS_PORT are free"
fi

# Are the packages we need actually downloadable? Check before touching anything.
for v in "$INTERMEDIATE_VERSION" "$TARGET_VERSION"; do
  s="$(series_of "$v")"
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://repo.mongodb.org/apt/ubuntu/dists/jammy/mongodb-org/$s/multiverse/binary-amd64/mongodb-org-server_${v}_amd64.deb" || true)"
  [[ "$code" == "200" ]] || die "mongodb-org-server $v is not downloadable from repo.mongodb.org (HTTP $code)."
done
if [[ "$INSTALL_MONGOT" == "1" ]]; then
  code="$(curl -s -o /dev/null -r 0-0 -w '%{http_code}' "https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_x86_64.tgz" || true)"
  [[ "$code" == "200" || "$code" == "206" ]] || die "mongot $MONGOT_VERSION tarball is not downloadable (HTTP $code)."
fi
ok "All packages are reachable"

# ----------------------------------------------------------------------------
# Step 2: before report + confirmation
# ----------------------------------------------------------------------------
print_report "2. BEFORE migration"
snapshot_counts "$RUN_DIR/counts-before.tsv"
log "Collection counts saved to $RUN_DIR/counts-before.tsv ($(wc -l < "$RUN_DIR/counts-before.tsv") collections)"

if [[ "$CHECK_ONLY" == "1" ]]; then
  step "CHECK ONLY: finished"
  ok "All pre-flight checks passed. MongoDB was not changed (no backup, no upgrade)."
  log "Report and counts: $RUN_DIR"
  exit 0
fi

ALREADY_DONE=0
if [[ "$(series_of "$CUR_VER")" == "$TARGET_SERIES" && "$CUR_FCV" == "$TARGET_SERIES" ]]; then
  if [[ "$INSTALL_MONGOT" != "1" ]] || systemctl is-active --quiet mongot 2>/dev/null; then ALREADY_DONE=1; fi
fi

if [[ "$ALREADY_DONE" == "0" && "$ASSUME_YES" != "1" ]]; then
  cat <<EOF

${C_B}About to migrate MongoDB on $(hostname)${C_0}
  $CUR_VER (FCV $CUR_FCV)  ->  $INTERMEDIATE_VERSION  ->  $TARGET_VERSION (FCV $TARGET_SERIES)
  + mongot $MONGOT_VERSION (install=$INSTALL_MONGOT)

mongod will be stopped and restarted several times: the application WILL see
downtime. Stop or pause application writers first (e.g. pm2 stop) for a
consistent backup. Raising the FCV is not reversible in place.

EOF
  [[ -t 0 ]] || die "No terminal for confirmation. Re-run interactively or set ASSUME_YES=1."
  read -r -p "Type MIGRATE to continue: " answer
  [[ "$answer" == "MIGRATE" ]] || die "Aborted by user."
fi

# ----------------------------------------------------------------------------
# Step 3: backup
# ----------------------------------------------------------------------------
if [[ "$ALREADY_DONE" == "0" ]]; then
  step "3. Backup"
  if ! need_cmd mongodump || ! need_cmd mongorestore; then
    log "Installing mongodb-database-tools (mongodump/mongorestore)"
    apt_quiet install mongodb-database-tools
  fi
  write_tools_cfg
  mkdir -p "$RUN_DIR/dump" "$RUN_DIR/files"
  ARCHIVE="$RUN_DIR/dump/full-backup.archive.gz"

  log "mongodump of all databases with --oplog (point-in-time consistent) ..."
  mongodump --config="$TOOLS_CFG" --oplog --gzip --archive="$ARCHIVE" 2>"$RUN_DIR/dump/mongodump.log" \
    || { tail -20 "$RUN_DIR/dump/mongodump.log"; die "mongodump failed"; }
  [[ -s "$ARCHIVE" ]] || die "Backup archive is empty"
  sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
  ok "Archive written: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"

  # Did anything write while we were dumping? (decides exact vs. tolerant checks)
  snapshot_counts "$RUN_DIR/counts-post-dump.tsv"
  if cmp -s "$RUN_DIR/counts-before.tsv" "$RUN_DIR/counts-post-dump.tsv"; then
    STABLE=1; log "No writes during the dump: verification will require exact counts."
  else
    STABLE=0; warn "Data changed during the dump (application still writing?). Counts are compared loosely."
  fi

  verify_dump_log
  case "$VERIFY_RESTORE" in
    never) warn "Full restore test skipped (VERIFY_RESTORE=never)." ;;
    always|auto)
      RESTORE_FREE="$(df -B1 --output=avail "$RUN_DIR" | tail -1 | tr -d ' ')"
      RESTORE_NEED=$(( DATA_BYTES + INDEX_BYTES + 1073741824 ))
      if (( RESTORE_FREE > RESTORE_NEED )); then
        restore_test "$ARCHIVE" || die "Restore test failed (see the output above; logs in $RUN_DIR/restore-test). The live server was not changed."
      elif [[ "$VERIFY_RESTORE" == "always" ]]; then
        die "Not enough disk for the restore test (need ~$((RESTORE_NEED/1048576)) MiB free)."
      else
        warn "Full restore test skipped: needs ~$((RESTORE_NEED/1048576)) MiB free, have $((RESTORE_FREE/1048576)) MiB. The dump log check passed; consider a disk snapshot too."
      fi ;;
    *) die "VERIFY_RESTORE must be auto, always or never" ;;
  esac

  cp -a "$CONF" "$RUN_DIR/files/"
  [[ -n "$KEYFILE" && -f "$KEYFILE" ]] && cp -a "$KEYFILE" "$RUN_DIR/files/"
  cp -a /etc/apt/sources.list.d "$RUN_DIR/files/apt-sources.list.d" 2>/dev/null || true
  mkdir -p "$RUN_DIR/files/bin-$CUR_VER"
  cp -a "$(command -v mongod)" "$RUN_DIR/files/bin-$CUR_VER/"
  need_cmd mongos && cp -a "$(command -v mongos)" "$RUN_DIR/files/bin-$CUR_VER/" || true
  chmod -R go-rwx "$RUN_DIR"
  ok "Backup complete: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
  cat > "$RUN_DIR/RESTORE.txt" <<EOF
Backup taken $TS from MongoDB $CUR_VER (FCV $CUR_FCV), replica set $RS_NAME.
Archive: $ARCHIVE  (sha256 in $ARCHIVE.sha256)

Restore (onto a running, empty-or-disposable deployment; --drop replaces collections):
  mongorestore --uri '<root uri>' --gzip --archive='$ARCHIVE' --oplogReplay --drop

Config files, keyfile and the previous mongod binary are in: $RUN_DIR/files
EOF
  log "Restore instructions: $RUN_DIR/RESTORE.txt"
fi

# ----------------------------------------------------------------------------
# Binary upgrade with automatic rollback (only valid while FCV is unchanged)
# ----------------------------------------------------------------------------
add_apt_repo() {
  local series="$1"
  if [[ ! -s "$APT_KEYRING" ]]; then
    log "Importing MongoDB ${APT_KEY_SERIES} signing key"
    export GNUPGHOME="$TMP_DIR/gnupg"; mkdir -p -m 700 "$GNUPGHOME"
    curl -fsSL "https://pgp.mongodb.com/server-${APT_KEY_SERIES}.asc" | gpg --batch --yes --dearmor -o "$APT_KEYRING.tmp"
    gpg --batch --show-keys --with-colons "$APT_KEYRING.tmp" 2>/dev/null \
      | grep -q "$APT_KEY_FINGERPRINT" || { rm -f "$APT_KEYRING.tmp"; die "Signing key fingerprint mismatch"; }
    mv "$APT_KEYRING.tmp" "$APT_KEYRING"; chmod 644 "$APT_KEYRING"
  fi
  echo "deb [ arch=amd64,arm64 signed-by=$APT_KEYRING ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/${series} multiverse" \
    > "/etc/apt/sources.list.d/mongodb-org-${series}.list"
  chmod 644 "/etc/apt/sources.list.d/mongodb-org-${series}.list"
  apt_quiet update -o Dir::Etc::sourcelist="sources.list.d/mongodb-org-${series}.list" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" >/dev/null
}

install_mongodb_pkgs() {
  local ver="$1" args=() p
  for p in "${ORG_PKGS[@]}"; do
    [[ "$p" == "mongodb-org-shell" ]] && continue   # legacy shell does not exist in 8.x
    args+=("$p=$ver")
  done
  apt-mark unhold "${ORG_PKGS[@]}" >/dev/null 2>&1 || true
  apt_quiet install --allow-downgrades --allow-change-held-packages "${args[@]}" || return 1
  apt-mark hold "${args[@]%%=*}" >/dev/null || return 1
}

stop_mongod() {
  log "Stopping ${MONGOD_SERVICE} cleanly ..."
  # Clean shutdown through the server first (flushes, steps down), then systemd.
  js_try 'db.adminCommand({shutdown: 1, timeoutSecs: 60})' >/dev/null
  systemctl stop "$MONGOD_SERVICE" || true
  local i
  for i in $(seq 1 120); do systemctl is-active --quiet "$MONGOD_SERVICE" || break; sleep 1; done
  systemctl is-active --quiet "$MONGOD_SERVICE" && die "mongod did not stop"
  pgrep -x mongod >/dev/null && die "A mongod process is still running"
  ok "mongod stopped"
}

start_mongod() {
  systemctl reset-failed "$MONGOD_SERVICE" 2>/dev/null || true
  systemctl start "$MONGOD_SERVICE"
  wait_primary
}

rollback_binaries() {
  local prev_ver="$1" saved_dir="$2"
  warn "Rolling back mongod binaries to $prev_ver (FCV was not changed) ..."
  systemctl stop "$MONGOD_SERVICE" || true
  if apt-cache madison mongodb-org-server | awk '{print $3}' | grep -qx "$prev_ver" \
     && install_mongodb_pkgs "$prev_ver"; then
    ok "Reinstalled packages $prev_ver"
  elif [[ -x "$saved_dir/mongod" ]]; then
    warn "Package $prev_ver not available in apt; restoring the saved mongod binary."
    install -m 755 "$saved_dir/mongod" "$(command -v mongod || echo /usr/bin/mongod)"
    [[ -x "$saved_dir/mongos" ]] && install -m 755 "$saved_dir/mongos" /usr/bin/mongos
  else
    die "Rollback impossible: no saved binary. Restore from $RUN_DIR."
  fi
  start_mongod || die "mongod did not start after rollback. See journalctl -u $MONGOD_SERVICE"
  ok "Rolled back to $(server_version)"
}

upgrade_binaries() {
  local to_ver="$1" to_series; to_series="$(series_of "$1")"
  local prev_ver; prev_ver="$(dpkg-query -W -f='${Version}' mongodb-org-server)"
  local saved="$RUN_DIR/files/bin-$prev_ver"
  if [[ ! -x "$saved/mongod" ]]; then mkdir -p "$saved"; cp -a "$(command -v mongod)" "$saved/"; fi

  log "Adding apt repository mongodb-org/$to_series"
  add_apt_repo "$to_series"

  # Pre-download everything while mongod is still running, to keep downtime short.
  log "Downloading packages $to_ver ..."
  local args=() p
  for p in "${ORG_PKGS[@]}"; do [[ "$p" == "mongodb-org-shell" ]] || args+=("$p=$to_ver"); done
  apt_quiet install --download-only --allow-change-held-packages "${args[@]}" >/dev/null

  stop_mongod
  if ! install_mongodb_pkgs "$to_ver"; then
    warn "Package installation failed"
    rollback_binaries "$prev_ver" "$saved"; die "Upgrade to $to_ver failed; rolled back."
  fi
  # apt may replace the unit file; make sure systemd sees it.
  systemctl daemon-reload
  if ! start_mongod; then
    warn "mongod $to_ver failed to start"
    journalctl -u "$MONGOD_SERVICE" -n 60 --no-pager || true
    rollback_binaries "$prev_ver" "$saved"; die "Upgrade to $to_ver failed; rolled back."
  fi
  local now; now="$(server_version)"
  [[ "$now" == "$to_ver" ]] || { rollback_binaries "$prev_ver" "$saved"; die "Expected $to_ver, got $now; rolled back."; }
  ok "mongod binaries upgraded: $prev_ver -> $now"
}

set_fcv() {
  local target="$1" now
  now="$(fcv)"
  if [[ "$now" == "$target" ]]; then ok "FCV already $target"; return 0; fi
  log "Setting featureCompatibilityVersion $now -> $target ..."
  js "const r = db.adminCommand({setFeatureCompatibilityVersion: '$target', confirm: true});
      if (r.ok !== 1) { printjson(r); quit(2); }"
  now="$(fcv)"
  [[ "$now" == "$target" ]] || die "FCV is $now after setting $target"
  ok "FCV is now $target"
}

health_check() {
  local v f st
  v="$(server_version)"; f="$(fcv)"
  st="$(js 'const s=db.adminCommand({replSetGetStatus:1}); print(Number(s.myState)===1 && s.members.every(m=>Number(m.health)===1) ? "HEALTHY" : "UNHEALTHY")')"
  [[ "$st" == "HEALTHY" ]] || die "Replica set unhealthy after upgrade"
  js "const r=db.getSiblingDB('$APP_DB').runCommand({ping:1}); if(r.ok!==1) quit(2);" \
    || die "Database $APP_DB not reachable"
  ok "Health: version $v, FCV $f, replica set healthy, $APP_DB reachable"
}

# ----------------------------------------------------------------------------
# Steps 4 & 5: version upgrades (resumable state machine)
# ----------------------------------------------------------------------------
if [[ "$ALREADY_DONE" == "0" ]]; then
  CUR_VER="$(server_version)"
  if [[ "$(series_of "$CUR_VER")" == "7.0" ]]; then
    step "4. Upgrade 7.0 -> $INTERMEDIATE_VERSION"
    upgrade_binaries "$INTERMEDIATE_VERSION"
    health_check
  fi
  CUR_VER="$(server_version)"
  if [[ "$(series_of "$CUR_VER")" == "$INTERMEDIATE_SERIES" ]]; then
    step "4b. Set FCV $INTERMEDIATE_SERIES"
    set_fcv "$INTERMEDIATE_SERIES"
    health_check
    step "5. Upgrade $INTERMEDIATE_SERIES -> $TARGET_VERSION"
    upgrade_binaries "$TARGET_VERSION"
    health_check
  fi
  CUR_VER="$(server_version)"
  [[ "$(series_of "$CUR_VER")" == "$TARGET_SERIES" ]] || die "Unexpected version $CUR_VER"
  step "5b. Set FCV $TARGET_SERIES"
  set_fcv "$TARGET_SERIES"
  health_check
  rm -f /etc/apt/sources.list.d/mongodb-org-"$INTERMEDIATE_SERIES".list
fi

# ----------------------------------------------------------------------------
# Step 6: mongot (Search in Community) for $vectorSearch
# ----------------------------------------------------------------------------
ensure_mongod_search_params() {
  local conf="$1" changed=0 key val
  declare -A params=(
    [mongotHost]="localhost:$MONGOT_GRPC_PORT"
    [searchIndexManagementHostAndPort]="localhost:$MONGOT_GRPC_PORT"
    [skipAuthenticationToSearchIndexManagementServer]="false"
    [useGrpcForSearch]="true"
  )
  cp -a "$conf" "$RUN_DIR/files/$(basename "$conf").before-mongot"
  local new="$TMP_DIR/mongod.conf.new"
  cp -a "$conf" "$new"
  if ! grep -qE '^setParameter:' "$new"; then
    printf '\nsetParameter:\n' >> "$new"
  fi
  # Reuse the indentation of existing setParameter entries (YAML must be consistent).
  local indent
  indent="$(awk '/^setParameter:/{f=1;next} f&&NF&&!/^[[:space:]]*#/{ if (match($0,/^[ ]+/)) print substr($0,1,RLENGTH); exit }' "$new")"
  [[ -n "$indent" ]] || indent="  "
  for key in mongotHost searchIndexManagementHostAndPort skipAuthenticationToSearchIndexManagementServer useGrpcForSearch; do
    val="${params[$key]}"
    if grep -qE "^[[:space:]]+${key}:" "$new"; then
      grep -qE "^[[:space:]]+${key}:[[:space:]]*\"?${val}\"?[[:space:]]*$" "$new" \
        || die "mongod.conf already sets $key to a different value; fix it manually."
      continue
    fi
    # Insert right after the top-level `setParameter:` line (a trailing comment is allowed).
    awk -v line="${indent}${key}: ${val}" '{print} /^setParameter:[[:space:]]*(#.*)?$/{print line}' "$new" > "$new.tmp" && mv "$new.tmp" "$new"
    changed=1
  done
  if (( changed )); then
    # Prove the edit is safe before installing it: valid YAML, nothing outside
    # setParameter changed, existing parameters kept, new ones present.
    python3 - "$conf" "$new" <<'PY' || die "Edited mongod.conf failed validation; the original was left untouched."
import sys, yaml
old = yaml.safe_load(open(sys.argv[1])) or {}
new = yaml.safe_load(open(sys.argv[2])) or {}
sp_old = old.pop("setParameter", None) or {}
sp_new = new.pop("setParameter", None) or {}
assert old == new, "settings outside setParameter changed"
for k, v in sp_old.items():
    assert sp_new.get(k) == v, "existing setParameter %s changed" % k
assert sp_new.get("useGrpcForSearch") is True, "useGrpcForSearch"
assert sp_new.get("skipAuthenticationToSearchIndexManagementServer") is False, "skipAuthentication..."
assert sp_new.get("mongotHost") and sp_new.get("mongotHost") == sp_new.get("searchIndexManagementHostAndPort"), "hosts"
print("mongod.conf setParameter:", sp_new)
PY
    chown --reference="$conf" "$new"; chmod --reference="$conf" "$new"
    cat "$new" > "$conf"
    log "Added search setParameters to $conf"
    return 0
  fi
  return 1
}

install_mongot() {
  step "6. Install mongot $MONGOT_VERSION (vector search)"
  local host_port; host_port="$(js 'print(db.hello().me)')"
  log "mongot will sync from $host_port"

  id mongot >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$MONGOT_DATA" --shell /usr/sbin/nologin mongot

  local dest="$MONGOT_HOME/$MONGOT_VERSION"
  if [[ ! -x "$dest/mongot" ]]; then
    local tgz="$TMP_DIR/mongot.tgz" base="https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_x86_64.tgz"
    log "Downloading $base"
    curl -fsSL --retry 5 --retry-delay 5 -o "$tgz" "$base"
    mkdir -p "$TMP_DIR/mongot-x"
    tar -xzf "$tgz" -C "$TMP_DIR/mongot-x"
    # The shallowest file named "mongot" is the launcher script.
    local launcher; launcher="$(find "$TMP_DIR/mongot-x" -maxdepth 3 -type f -name mongot -printf '%d %p\n' | sort -n | head -1 | cut -d' ' -f2-)"
    [[ -n "$launcher" ]] || die "mongot launcher not found in tarball"
    mkdir -p "$MONGOT_HOME"
    rm -rf "$dest"; cp -a "$(dirname "$launcher")" "$dest"
    # Root-owned, readable/executable by the mongot user, writable by nobody else.
    chown -R root:root "$dest"; chmod -R u+rwX,go+rX,go-w "$dest"; chmod 755 "$MONGOT_HOME"
    [[ -x "$dest/mongot" ]] || chmod 755 "$dest/mongot"
    log "mongot installed in $dest: $(ls "$dest" | tr '\n' ' ')"
  fi
  ln -sfn "$dest" "$MONGOT_HOME/current"

  # Search user. Password is random, lives only in a 0400 file owned by mongot.
  mkdir -p "$MONGOT_ETC/secrets" "$MONGOT_DATA"
  chown mongot:mongot "$MONGOT_DATA"; chmod 750 "$MONGOT_DATA"
  chown root:mongot "$MONGOT_ETC"; chmod 750 "$MONGOT_ETC"
  chown mongot:mongot "$MONGOT_ETC/secrets"; chmod 700 "$MONGOT_ETC/secrets"
  local pwfile="$MONGOT_ETC/secrets/passwordFile"
  local pw; pw="$(openssl rand -hex 32)"
  local exists; exists="$(js "print(db.getSiblingDB('admin').getUser('$MONGOT_USER_DB') ? 'yes' : 'no')")"
  if [[ "$exists" == "yes" ]]; then
    MONGOT_PW="$pw" js "db.getSiblingDB('admin').updateUser('$MONGOT_USER_DB', {pwd: process.env.MONGOT_PW, roles: [{role: 'searchCoordinator', db: 'admin'}]})" >/dev/null
  else
    MONGOT_PW="$pw" js "db.getSiblingDB('admin').createUser({user: '$MONGOT_USER_DB', pwd: process.env.MONGOT_PW, roles: [{role: 'searchCoordinator', db: 'admin'}]})" >/dev/null
  fi
  rm -f "$pwfile"; printf '%s' "$pw" > "$pwfile"; unset pw
  chown mongot:mongot "$pwfile"; chmod 400 "$pwfile"
  ok "User $MONGOT_USER_DB (searchCoordinator) ready; password in $pwfile"

  # Start from the config.default.yml shipped in the tarball (so the layout is
  # exactly what this mongot version expects) and only replace our values.
  local default_cfg; default_cfg="$(find "$dest" -maxdepth 2 -name 'config.default.yml' | head -1)"
  MG_HOST="$host_port" MG_USER="$MONGOT_USER_DB" MG_PWFILE="$pwfile" MG_DATA="$MONGOT_DATA" \
  MG_GRPC="localhost:$MONGOT_GRPC_PORT" MG_METRICS="localhost:$MONGOT_METRICS_PORT" \
  MG_HEALTH="localhost:$MONGOT_HEALTH_PORT" \
  python3 - "${default_cfg:-}" "$MONGOT_ETC/mongot.yml" <<'PY' || die "Could not build the mongot config"
import os, sys, yaml
src, dst = sys.argv[1], sys.argv[2]
E = os.environ
cfg = None
if src and os.path.isfile(src):
    cfg = yaml.safe_load(open(src))
    print("mongot config based on", src)
if not isinstance(cfg, dict):
    print("mongot config: tarball default not found, using the documented layout")
    cfg = {
        "syncSource": {"replicaSet": {
            "hostAndPort": "x", "scramAuth": {"username": "x", "authSource": "admin", "passwordFile": "x"},
            "tls": {"enabled": False}}},
        "storage": {"dataPath": "x"},
        "server": {"grpc": {"address": "x", "tls": {"mode": "disabled"}}},
        "metrics": {"enabled": True, "address": "x"},
        "healthCheck": {"address": "x"},
        "logging": {"verbosity": "INFO"},
    }

def walk_set(node, key, value):
    """Set every occurrence of key below node; returns how many were set."""
    n = 0
    if isinstance(node, dict):
        for k in list(node):
            if k == key:
                node[k] = value(node[k]) if callable(value) else value
                n += 1
            else:
                n += walk_set(node[k], key, value)
    elif isinstance(node, list):
        for item in node:
            n += walk_set(item, key, value)
    return n

def need(ok, what):
    if not ok:
        sys.exit("mongot config: could not find '%s' in the default config" % what)

ss = cfg.get("syncSource")
need(isinstance(ss, dict), "syncSource")
need(walk_set(ss, "hostAndPort", lambda old: [E["MG_HOST"]] if isinstance(old, list) else E["MG_HOST"]), "hostAndPort")
need(walk_set(ss, "username", E["MG_USER"]), "username")
need(walk_set(ss, "passwordFile", E["MG_PWFILE"]), "passwordFile")
walk_set(ss, "authSource", "admin")
# mongot and mongod are on the same host: no TLS on that link.
walk_set(ss, "tls", lambda old: dict(old, enabled=False) if isinstance(old, dict) else False)

cfg.setdefault("storage", {})["dataPath"] = E["MG_DATA"]
grpc = cfg.setdefault("server", {}).setdefault("grpc", {})
grpc["address"] = E["MG_GRPC"]
if isinstance(grpc.get("tls"), dict):
    grpc["tls"]["mode"] = "disabled"
cfg.setdefault("metrics", {}).update({"enabled": True, "address": E["MG_METRICS"]})
cfg.setdefault("healthCheck", {})["address"] = E["MG_HEALTH"]
logging_cfg = cfg.get("logging")
if isinstance(logging_cfg, dict):
    logging_cfg.pop("logPath", None)   # log to stdout -> journald

with open(dst, "w") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
print(yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False))
PY
  chown root:mongot "$MONGOT_ETC/mongot.yml"; chmod 640 "$MONGOT_ETC/mongot.yml"

  cat > /etc/systemd/system/mongot.service <<EOF
[Unit]
Description=MongoDB Search (mongot) $MONGOT_VERSION
After=network-online.target ${MONGOD_SERVICE}.service
Wants=network-online.target

[Service]
User=mongot
Group=mongot
WorkingDirectory=$MONGOT_HOME/current
ExecStart=$MONGOT_HOME/current/mongot --config $MONGOT_ETC/mongot.yml
Restart=on-failure
RestartSec=5
LimitNOFILE=64000
${MONGOT_MEMORY_MAX:+MemoryMax=$MONGOT_MEMORY_MAX}
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$MONGOT_DATA

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/mongot.service
  systemctl daemon-reload
  systemctl enable mongot >/dev/null 2>&1
  systemctl restart mongot

  if ensure_mongod_search_params "$CONF"; then
    log "Restarting mongod to load the search parameters ..."
    stop_mongod
    if ! start_mongod; then
      warn "mongod did not start with the search parameters; restoring the previous mongod.conf"
      cat "$RUN_DIR/files/$(basename "$CONF").before-mongot" > "$CONF"
      start_mongod || die "mongod does not start even with the previous config. See journalctl -u $MONGOD_SERVICE"
      die "mongot integration failed; mongod is running without search."
    fi
  else
    ok "mongod.conf already has the search parameters"
  fi

  log "Waiting for mongot health check (SERVING) ..."
  local i h=""
  for i in $(seq 1 120); do
    h="$(curl -s "http://localhost:$MONGOT_HEALTH_PORT/health" || true)"
    [[ "$h" == *SERVING* ]] && break
    sleep 5
  done
  if [[ "$h" != *SERVING* ]]; then
    journalctl -u mongot -n 60 --no-pager || true
    die "mongot is not SERVING (last response: ${h:-none})"
  fi
  ok "mongot is SERVING"
}

verify_search() {
  # Read-only check that mongod can reach mongot: listSearchIndexes must succeed.
  local coll
  coll="$(js "const n=db.getSiblingDB('$APP_DB').getCollectionInfos({type:'collection'}).map(c=>c.name).filter(n=>!n.startsWith('system.')); print(n[0]||'')")"
  if [[ -z "$coll" ]]; then warn "No collection in $APP_DB to test listSearchIndexes"; return 0; fi
  js "const r=db.getSiblingDB('$APP_DB').runCommand({listSearchIndexes:'$coll'}); if(r.ok!==1){printjson(r); quit(2);} print('search indexes on $coll: ' + r.cursor.firstBatch.length)" \
    || die "listSearchIndexes failed: mongod cannot talk to mongot"
  ok "mongod <-> mongot search management works"
}

if [[ "$INSTALL_MONGOT" == "1" ]]; then
  if [[ "$ALREADY_DONE" == "1" ]]; then
    step "6. mongot already installed"
  else
    install_mongot
  fi
  verify_search
fi

# ----------------------------------------------------------------------------
# Step 7: after report and data comparison
# ----------------------------------------------------------------------------
health_check
print_report "7. AFTER migration"
snapshot_counts "$RUN_DIR/counts-after.tsv"

step "8. Data comparison (document counts per collection)"
if diff -u "$RUN_DIR/counts-before.tsv" "$RUN_DIR/counts-after.tsv" > "$RUN_DIR/counts.diff"; then
  ok "All $(wc -l < "$RUN_DIR/counts-after.tsv") collections have identical document and index counts"
else
  cat "$RUN_DIR/counts.diff"
  if [[ "$STRICT_COUNTS" == "1" ]]; then
    die "Collection counts changed during migration (STRICT_COUNTS=1)."
  fi
  warn "Counts changed. Expected only if the application kept writing during the migration."
fi

step "DONE"
printf '%-28s %s\n' "MongoDB version:" "$(server_version)"
printf '%-28s %s\n' "featureCompatibilityVersion:" "$(fcv)"
printf '%-28s %s\n' "Replica set enabled:" "yes ($RS_NAME, $(js 'print(db.adminCommand({replSetGetStatus:1}).members[0].stateStr)'))"
[[ "$INSTALL_MONGOT" == "1" ]] && printf '%-28s %s\n' "mongot:" "$(systemctl is-active mongot) ($(curl -s "http://localhost:$MONGOT_HEALTH_PORT/health"))"
printf '%-28s %s\n' "Backup / logs:" "$RUN_DIR"
ok "Migration finished successfully."
