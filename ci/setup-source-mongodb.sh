#!/usr/bin/env bash
# Builds a production-like MongoDB 7.0 server on the CI runner:
#   apt install (same as prod), systemd unit, single-node replica set "rs0",
#   keyfile internal auth, authorization enabled, root user "admin".
# Requires: ADMIN_PW in the environment. Run as root.
set -Eeuo pipefail

SOURCE_VERSION="${SOURCE_VERSION:-7.0.42}"
FALLBACK_VERSION="${FALLBACK_VERSION:-7.0.41}"
: "${ADMIN_PW:?ADMIN_PW must be set}"

echo "::group::Remove any preinstalled MongoDB"
systemctl stop mongod 2>/dev/null || true
apt-get purge -y -q 'mongodb-org*' >/dev/null 2>&1 || true
rm -rf /var/lib/mongodb /var/log/mongodb /etc/mongod.conf
echo "::endgroup::"

echo "::group::Install MongoDB $SOURCE_VERSION from repo.mongodb.org"
apt-get update -q
apt-get install -y -q gnupg curl python3-yaml >/dev/null
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | gpg --batch --yes --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
  > /etc/apt/sources.list.d/mongodb-org-7.0.list
apt-get update -q

VER="$SOURCE_VERSION"
if ! apt-cache madison mongodb-org-server | awk '{print $3}' | grep -qx "$VER"; then
  echo "::warning::mongodb-org $VER is not published in the MongoDB apt repo (it was never released as a GA package / was withdrawn). Using $FALLBACK_VERSION, the closest published 7.0 release, as the source version."
  VER="$FALLBACK_VERSION"
fi
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  "mongodb-org=$VER" "mongodb-org-database=$VER" "mongodb-org-server=$VER" \
  "mongodb-org-mongos=$VER" "mongodb-org-tools=$VER" "mongodb-org-database-tools-extra=$VER" \
  mongodb-mongosh mongodb-database-tools
apt-mark hold mongodb-org mongodb-org-database mongodb-org-server mongodb-org-mongos mongodb-org-tools mongodb-org-database-tools-extra
echo "SOURCE_VERSION_USED=$VER" >> "${GITHUB_ENV:-/dev/null}"
echo "::endgroup::"

echo "::group::Configure replica set + keyfile + authorization"
mkdir -p /etc/mongodb
openssl rand -base64 756 > /etc/mongodb/keyfile
chown mongodb:mongodb /etc/mongodb/keyfile
chmod 400 /etc/mongodb/keyfile

# Mirrors a typical prod config. setParameter uses 4-space indentation on
# purpose, to prove the migration script keeps the file valid YAML.
cat > /etc/mongod.conf <<'EOF'
# mongod.conf (CI copy of a production-like configuration)
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
replication:
  replSetName: rs0
security:
  authorization: enabled
  keyFile: /etc/mongodb/keyfile
setParameter:
    cursorTimeoutMillis: 600000
EOF
mkdir -p /var/lib/mongodb /var/log/mongodb
chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb

systemctl daemon-reload
systemctl enable mongod
systemctl restart mongod
for i in $(seq 1 60); do mongosh --quiet --eval 'db.hello().ok' >/dev/null 2>&1 && break; sleep 1; done
echo "::endgroup::"

echo "::group::Initiate replica set and create root user (localhost exception)"
mongosh --quiet --eval 'rs.initiate({_id: "rs0", members: [{_id: 0, host: "localhost:27017"}]})'
for i in $(seq 1 60); do
  [[ "$(mongosh --quiet --eval 'db.hello().isWritablePrimary')" == "true" ]] && break; sleep 1
done
mongosh --quiet --eval '
  db.getSiblingDB("admin").createUser({user: "admin", pwd: process.env.ADMIN_PW, roles: [{role: "root", db: "admin"}]});
  print("root user created");'
echo "::endgroup::"

# Authorization really is enforced:
if mongosh --quiet --eval 'db.adminCommand({listDatabases: 1}).ok' 2>/dev/null | grep -qx 1; then
  echo "::error::Unauthenticated listDatabases succeeded - auth is not enforced"; exit 1
fi
echo "Source server ready: $(mongod --version | head -1)"
