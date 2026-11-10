// Seeds the "workmentor" database with test data (run with mongosh against the URI).
const app = db.getSiblingDB("workmentor");
app.dropDatabase();

const orgA = ObjectId(), orgB = ObjectId();
app.organizations.insertMany([
  { _id: orgA, name: "Acme Corp", plan: "pro", createdAt: new Date("2025-01-10") },
  { _id: orgB, name: "Globex", plan: "free", createdAt: new Date("2025-03-02") },
]);

const users = [];
for (let i = 1; i <= 250; i++) {
  users.push({
    organization: i % 2 ? orgA : orgB,
    name: `User ${i}`,
    email: `user${i}@example.test`,
    role: i <= 2 ? "admin" : "employee",
    passwordHash: "$2b$10$fakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFakeFake", // must be redacted in reports
    active: i % 10 !== 0,
    createdAt: new Date(Date.UTC(2025, 0, 1) + i * 86400000),
  });
}
app.users.insertMany(users);
app.users.createIndex({ email: 1 }, { unique: true });
app.users.createIndex({ organization: 1, active: 1 });

const attendance = [];
for (let d = 0; d < 2000; d++) {
  attendance.push({
    user: `user${(d % 250) + 1}@example.test`,
    day: new Date(Date.UTC(2025, 5, 1) + (d % 60) * 86400000),
    minutes: 300 + (d % 240),
  });
}
app.attendances.insertMany(attendance);
app.attendances.createIndex({ user: 1, day: -1 });

// Document chunks with small (8-dim) embeddings, used after the migration to
// prove mongot indexes data written by MongoDB 7.0.
const docs = [
  { title: "Leave policy",      vec: [0.9, 0.1, 0, 0, 0, 0, 0, 0.1] },
  { title: "Expense policy",    vec: [0.1, 0.9, 0.1, 0, 0, 0, 0, 0] },
  { title: "Security handbook", vec: [0, 0.1, 0.9, 0.1, 0, 0, 0, 0] },
  { title: "Remote work",       vec: [0, 0, 0.1, 0.9, 0.1, 0, 0, 0] },
];
const chunks = [];
docs.forEach((d, i) => [orgA, orgB].forEach(org => chunks.push({
  organization: org, document: ObjectId(), docVersion: `doc${i}-1`, title: d.title,
  text: `${d.title} text for ${org}`, embedding: d.vec, embeddingModel: "test-8d",
})));
app.companydocumentchunks.insertMany(chunks);

// A second database, to prove "all databases" are backed up and preserved.
const other = db.getSiblingDB("workmentor_audit");
other.dropDatabase();
other.events.insertMany(Array.from({ length: 100 }, (_, i) => ({ seq: i, type: "login", at: new Date() })));

print("Seeded:");
for (const c of app.getCollectionNames().sort()) print(`  workmentor.${c}: ${app.getCollection(c).countDocuments()}`);
print(`  workmentor_audit.events: ${other.events.countDocuments()}`);
