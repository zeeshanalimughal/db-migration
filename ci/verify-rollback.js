// Post-rollback assertions: the server must be the original version with the original data.
const fail = (m) => { print("ASSERTION FAILED: " + m); quit(1); };
const expectVersion = process.env.EXPECT_VERSION;
const app = db.getSiblingDB("workmentor");

if (db.version() !== expectVersion) fail(`version ${db.version()} != ${expectVersion}`);
const fcv = db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version;
if (fcv !== "7.0") fail(`FCV ${fcv} != 7.0`);
const st = rs.status();
if (st.set !== "rs0" || st.myState !== 1) fail("replica set not PRIMARY");
print(`OK version ${db.version()}, FCV ${fcv}, replica set ${st.set} PRIMARY (same URI, same user/password)`);

const expected = { organizations: 2, users: 250, attendances: 2000, companydocumentchunks: 8 };
for (const [c, n] of Object.entries(expected)) {
  const got = app.getCollection(c).countDocuments();
  if (got !== n) fail(`${c}: ${got} != ${n}`);
}
if (db.getSiblingDB("workmentor_audit").events.countDocuments() !== 100) fail("workmentor_audit.events count");
const idx = app.users.getIndexes().find(i => i.name === "email_1");
if (!idx || !idx.unique) fail("unique email index missing");
print("OK data and indexes identical to before the migration");

// The search user only existed after the migration; the snapshot predates it.
if (db.getSiblingDB("admin").getUser("mongotUser")) fail("mongotUser exists: data is not the pre-migration snapshot");
print("OK users are exactly the pre-migration users");

// The app can still write.
app.rollback_write_check.insertOne({ at: new Date() });
app.rollback_write_check.drop();
print("OK writes work");
