#!/usr/bin/env node
// Puts a fleet owner into a known state through the public API, so a UI flow
// can start from where its subject begins instead of clicking through
// everything before it. Uses only endpoints the apps themselves call.
//
//   node e2e/lib/seed.mjs onboard  --suite W --index 1      new owner, KYC done
//   node e2e/lib/seed.mjs customer --phone 7xxxxxxxxx       customer + addresses
//                                                           for an existing owner
//
// Prints one JSON object describing what it created. `--suite`/`--index` pick
// the identity from plutus-java e2e/verification-testing.yml.

const API = `${process.env.E2E_API_URL || "http://localhost:18080"}/api`;
const OTP = process.env.E2E_OTP || "667766";

const SUITES = { A: "Api", M: "Mobile", W: "Web", X: "Spare" };
const WORDS = ["One", "Two", "Three", "Four", "Five"];

function identity(suite, index) {
  const name = SUITES[suite];
  const word = WORDS[index - 1];
  if (!name || !word) throw new Error(`no fixture identity for suite=${suite} index=${index}`);
  const n = String(index).padStart(4, "0");
  return {
    name: `${name} Fleet ${word}`,
    pan: `EEEC${suite}${n}${suite}`,
    trucks: ["A", "B", "C"].map((t) => `KA51${suite}${t}${n}`),
  };
}

const randomDigits = (n) =>
  Array.from({ length: n }, () => Math.floor(Math.random() * 10)).join("");

async function call(method, path, { token, body } = {}) {
  const res = await fetch(`${API}${path}`, {
    method,
    headers: {
      "Content-Type": "application/json",
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    throw new Error(`${method} ${path}: HTTP ${res.status}, non-JSON body: ${text.slice(0, 200)}`);
  }
  // plutus wraps everything and answers 200 for 400/422, so trust the envelope.
  if (!res.ok || json.success === false) {
    throw new Error(`${method} ${path}: ${json.statusCode ?? res.status} ${json.message ?? ""}`);
  }
  return json.data;
}

async function login(phone) {
  await call("POST", "/auth/send-otp?channel=SMS", { body: { phone } });
  return call("POST", "/auth/verify-otp", { body: { phone, otp: OTP } });
}

async function onboard({ suite, index }) {
  const id = identity(suite, Number(index));
  const phone = `7${randomDigits(9)}`;
  const session = await login(phone);
  let token = session.accessToken;
  const userId = session.user.id;

  const user = await call("PUT", `/users/${userId}`, {
    token,
    body: {
      name: id.name,
      email: `e2e.${phone}@example.com`,
      role: "TORG_ADMIN",
      onboardingStatus: "BASIC_DETAILS_ADDED",
      fleetSize: 5,
      preferredLanguage: "English",
    },
  });
  const torgId = user.torgId;

  const pan = await call("POST", "/pan", { token, body: { panNumber: id.pan, isSoleProprietor: false } });
  if (pan.status !== "VERIFIED") throw new Error(`PAN ${id.pan} came back ${pan.status}`);

  const aadhaar = await call("POST", "/aadhaar/verify-otp?otp=123456", {
    token,
    body: { aadhaarNumber: `4${randomDigits(11)}`, torgId },
  });
  if (aadhaar.status !== "VERIFIED") throw new Error(`Aadhaar came back ${aadhaar.status}`);

  const done = await call("PUT", `/users/${userId}`, {
    token,
    body: { onboardingStatus: "BUSINESS_DETAILS_ADDED" },
  });
  if (done.onboardingStatus !== "ONBOARDING_COMPLETED") {
    throw new Error(`onboarding status is ${done.onboardingStatus}`);
  }

  return { phone, userId, torgId, name: id.name, pan: id.pan, trucks: id.trucks };
}

async function customer({ phone, name = "E2E Customer" }) {
  const session = await login(phone);
  const token = session.accessToken;
  const torgId = session.user.torgId;
  if (!torgId) throw new Error(`user ${phone} has no Torg yet`);

  const created = await call("POST", "/customers", { token, body: { name, torgId } });
  const saved = await call("PUT", `/customers/${created.id}`, {
    token,
    body: {
      name,
      torgId,
      pickupLocationList: [
        {
          id: "new-pickup",
          city: "Bengaluru",
          state: "Karnataka",
          latitude: 12.9716,
          longitude: 77.5946,
          address: "MG Road, Bengaluru",
          pincode: "560001",
          nickName: "BLR Yard",
        },
      ],
      destinationLocationList: [
        {
          id: "new-drop",
          city: "Chennai",
          state: "Tamil Nadu",
          latitude: 13.0827,
          longitude: 80.2707,
          address: "Anna Salai, Chennai",
          pincode: "600002",
          nickName: "MAA Depot",
        },
      ],
    },
  });

  return {
    customerId: saved.id,
    customerName: saved.name,
    pickupNickName: saved.pickupLocationList[0].nickName,
    dropNickName: saved.destinationLocationList[0].nickName,
  };
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    if (!argv[i].startsWith("--") || argv[i + 1] === undefined) {
      throw new Error(`bad argument: ${argv[i]}`);
    }
    args[argv[i].slice(2)] = argv[i + 1];
  }
  return args;
}

const commands = { onboard, customer };
const [command, ...rest] = process.argv.slice(2);

if (!commands[command]) {
  console.error("usage: seed.mjs <onboard|customer> [--key value ...]");
  process.exit(2);
}

commands[command](parseArgs(rest))
  .then((out) => console.log(JSON.stringify(out)))
  .catch((err) => {
    console.error(`[seed] ${command} failed: ${err.message}`);
    process.exit(1);
  });
