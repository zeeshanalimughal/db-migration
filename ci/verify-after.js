// Post-migration assertions. Exits non-zero on any failure.
const fail = (m) => { print("ASSERTION FAILED: " + m); quit(1); };
const expectVersion = process.env.EXPECT_VERSION;
const app = db.getSiblingDB("workmentor");

if (db.version() !== expectVersion) fail(`version ${db.version()} != ${expectVersion}`);
const fcv = db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version;
if (fcv !== expectVersion.split(".").slice(0, 2).join(".")) fail(`FCV ${fcv}`);
const st = rs.status();
if (st.set !== "rs0" || st.myState !== 1) fail("replica set not PRIMARY");
print(`OK version ${db.version()}, FCV ${fcv}, replica set ${st.set} PRIMARY`);

const expected = { organizations: 2, users: 250, attendances: 2000, companydocumentchunks: 8 };
for (const [c, n] of Object.entries(expected)) {
  const got = app.getCollection(c).countDocuments();
  if (got !== n) fail(`${c}: ${got} != ${n}`);
}
if (db.getSiblingDB("workmentor_audit").events.countDocuments() !== 100) fail("workmentor_audit.events count");
const idx = app.users.getIndexes().find(i => i.name === "email_1");
if (!idx || !idx.unique) fail("unique email index missing");
print("OK data and indexes intact");

// Vector search through mongot on data written by 7.0.
const coll = app.companydocumentchunks;
coll.createSearchIndex({
  name: "ci_vector",
  type: "vectorSearch",
  definition: { fields: [
    { type: "vector", path: "embedding", numDimensions: 8, similarity: "cosine" },
    { type: "filter", path: "organization" },
  ] },
});
const deadline = Date.now() + 5 * 60 * 1000;
let ready = false;
while (Date.now() < deadline) {
  const ix = coll.getSearchIndexes("ci_vector")[0];
  if (ix && ix.queryable) { ready = true; break; }
  sleep(3000);
}
if (!ready) fail("vector index not queryable within 5 minutes");
print("OK vector index is queryable");

const org = coll.findOne({ title: "Security handbook" }).organization;
const res = coll.aggregate([
  { $vectorSearch: { index: "ci_vector", path: "embedding", queryVector: [0, 0.1, 0.95, 0.05, 0, 0, 0, 0],
      numCandidates: 20, limit: 3, filter: { organization: org } } },
  { $project: { _id: 0, title: 1, organization: 1, score: { $meta: "vectorSearchScore" } } },
]).toArray();
printjson(res);
if (res.length === 0) fail("no $vectorSearch results");
if (res[0].title !== "Security handbook") fail(`top hit is ${res[0].title}`);
if (!res.every(r => String(r.organization) === String(org))) fail("filter leaked another organization");
print("OK $vectorSearch works (top hit correct, org filter respected)");
coll.dropSearchIndex("ci_vector");
