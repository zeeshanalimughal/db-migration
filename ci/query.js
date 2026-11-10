// Prints version, replica set state and a query on the users collection.
const app = db.getSiblingDB("workmentor");
print(`MongoDB version:     ${db.version()}`);
print(`FCV:                 ${db.adminCommand({ getParameter: 1, featureCompatibilityVersion: 1 }).featureCompatibilityVersion.version}`);
const st = rs.status();
print(`Replica set:         ${st.set} -> ${st.members.map(m => m.name + " " + m.stateStr).join(", ")}`);
print(`users (total):       ${app.users.countDocuments()}`);
print(`users (active admin):${app.users.countDocuments({ role: "admin", active: true })}`);
print("First 3 users (email, role, org):");
app.users.find({}, { _id: 0, email: 1, role: 1, organization: 1 }).sort({ email: 1 }).limit(3).forEach(u => printjson(u));
