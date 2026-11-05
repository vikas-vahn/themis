// Surepass DigiLocker: the one verification plutus-api's test mode still sends
// to the real provider. atlas-rn verifies Aadhaar this way: the backend asks
// Surepass for a consent URL, the app opens it in a WebView, the user approves
// on DigiLocker's site, and the WebView is redirected to a URL containing
// `redirect=true`. The app then asks the backend for the status, and the
// backend polls Surepass and downloads the Aadhaar record.
//
// Here the consent page is ours. It approves automatically after a moment
// (append ?auto=0 to the consent URL to require a tap on "Allow"), which keeps
// the mobile flow free of WebView interaction.
//
// The Aadhaar holder's name defaults to the mobile suite's first identity.
// Change it for a run with:  POST /_control/digilocker {"name": "..."}

module.exports = (route, ctx) => {
  const clients = new Map();
  const settings = { name: "Mobile Fleet One" };
  let counter = 0;

  const envelope = (data) => ({
    body: { data, status_code: 200, success: true, message: "Success", message_code: "success" },
  });

  route("POST", "/_control/digilocker", ({ body }) => {
    if (body && typeof body.name === "string") settings.name = body.name;
    return { body: settings };
  });

  route("POST", "/surepass/api/v1/digilocker/initialize", () => {
    counter += 1;
    const clientId = `digilocker_e2e_${Date.now()}_${counter}`;
    clients.set(clientId, { status: "client_initiated" });
    return envelope({
      client_id: clientId,
      token: `e2e-token-${counter}`,
      url: `${ctx.publicUrl}/digilocker/consent/${clientId}`,
      expiry_seconds: 600,
    });
  });

  route("GET", "/digilocker/consent/:clientId", ({ params, query }) => {
    if (!clients.has(params.clientId)) return { status: 404, body: "Unknown DigiLocker session" };
    const allow = `${ctx.publicUrl}/digilocker/consent/${params.clientId}/allow`;
    const auto = query.get("auto") !== "0";
    return {
      body: `<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
${auto ? `<meta http-equiv="refresh" content="1;url=${allow}">` : ""}
<title>DigiLocker (E2E stand-in)</title></head>
<body style="font-family:sans-serif;padding:24px">
<h2>DigiLocker (E2E stand-in)</h2>
<p>Share Aadhaar of <b>${settings.name}</b> with VAHN?</p>
<p><a id="allow" href="${allow}" style="font-size:20px">Allow</a></p>
</body></html>`,
    };
  });

  route("GET", "/digilocker/consent/:clientId/allow", ({ params }) => {
    const client = clients.get(params.clientId);
    if (!client) return { status: 404, body: "Unknown DigiLocker session" };
    // "completed" = consent given, record not downloaded yet.
    client.status = "completed";
    return {
      status: 302,
      headers: { Location: `${ctx.publicUrl}/digilocker/done?redirect=true` },
      body: "",
    };
  });

  route("GET", "/digilocker/done", () => ({
    body: `<!doctype html><html><body style="font-family:sans-serif;padding:24px"><h2>Aadhaar shared</h2></body></html>`,
  }));

  route("GET", "/surepass/api/v1/digilocker/status/:clientId", ({ params }) => {
    const client = clients.get(params.clientId);
    if (!client) return { status: 404, body: { success: false, status_code: 404, message: "client not found" } };
    return envelope({ client_id: params.clientId, status: client.status, completed: client.status !== "client_initiated" });
  });

  route("GET", "/surepass/api/v1/digilocker/download-aadhaar/:clientId", ({ params }) => {
    const client = clients.get(params.clientId);
    if (!client || client.status === "client_initiated") {
      return { status: 422, body: { success: false, status_code: 422, message: "consent not given" } };
    }
    client.status = "downloaded";
    return envelope({
      client_id: params.clientId,
      digilocker_metadata: { name: settings.name, gender: "M", dob: "1985-01-01" },
      aadhaar_xml_data: {
        full_name: settings.name,
        care_of: "S/O E2E Senior",
        dob: "1985-01-01",
        yob: "1985",
        zip: "560001",
        profile_image: "",
        gender: "M",
        masked_aadhaar: `XXXXXXXX${String(1000 + (counter % 9000))}`,
        full_address: "No 1, 1st Main, MG Road, Bengaluru, Karnataka 560001",
        father_name: "E2E Senior",
        address: {
          country: "India",
          dist: "Bengaluru",
          state: "Karnataka",
          po: "MG Road",
          house: "No 1",
          loc: "",
          vtc: "Bengaluru",
          subdist: "",
          street: "1st Main",
          landmark: "",
        },
      },
      xml_url: "",
    });
  });
};
