/**
 * SKYLINK Pay Relay — Cloudflare Worker
 * ------------------------------------------------------------
 * Sits between the captive portal and Abliner so that:
 *   1. Deposit requests are signed server-side (x-abliner-timestamp / x-abliner-signature).
 *   2. The Abliner API key and whsec_ signing secret never reach customers.
 *   3. The price is decided here, not in the browser.
 *   4. Automatically syncs paid users to MikroTik Hotspot via /mikrotik/sync!
 *
 * Endpoints:
 *   POST /pay             { "package": "2h", "phone": "07XXXXXXXX" }
 *   GET  /status?ref=...  Check payment status
 *   GET  /mikrotik/sync   MikroTik router fetches RouterOS script to add paid users
 *   GET  /sync            Alias for /mikrotik/sync
 *   GET  /health          Healthcheck
 */

const ABLINER = "https://abliner.net/api/v1";

const PACKAGES = {
  "4h":  { amount: 500,   uptime: "04:00:00" },
  "1d":  { amount: 1000,  uptime: "1d 00:00:00" },
  "24h": { amount: 1000,  uptime: "1d 00:00:00" },
  "3d":  { amount: 2500,  uptime: "3d 00:00:00" },
  "7d":  { amount: 6000,  uptime: "7d 00:00:00" },
  "30d": { amount: 20000, uptime: "30d 00:00:00" },
  // Backward compatibility for old test payments
  "2h":  { amount: 500,   uptime: "04:00:00" },
  "5h":  { amount: 1000,  uptime: "1d 00:00:00" },
  "12h": { amount: 1500,  uptime: "12:00:00" }
};

const AMOUNT_TO_UPTIME = {
  500:   "04:00:00",
  1000:  "1d 00:00:00",
  1500:  "12:00:00",
  2500:  "3d 00:00:00",
  6000:  "7d 00:00:00",
  20000: "30d 00:00:00"
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400"
};

function json(obj, status) {
  const s = status || 200;
  return new Response(JSON.stringify(obj), {
    status: s,
    headers: Object.assign({}, CORS, {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store"
    })
  });
}

async function hmacHex(secret, message) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  const bytes = new Uint8Array(sig);
  let hex = "";
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, "0");
  }
  return hex;
}

function normalizePhone(raw) {
  const c = String(raw || "").replace(/[\s\-+]/g, "");
  if (/^255[67]\d{8}$/.test(c)) return c;
  if (/^0[67]\d{8}$/.test(c)) return "255" + c.slice(1);
  if (/^[67]\d{8}$/.test(c)) return "255" + c;
  return null;
}

async function handlePay(request, env) {
  let input;
  try {
    input = await request.json();
  } catch (e) {
    return json({ ok: false, code: "invalid_json", message: "Ombi si sahihi." }, 400);
  }

  const pkgKey = String(input.package || "");
  const pkg = PACKAGES[pkgKey];
  if (!pkg) {
    return json({ ok: false, code: "invalid_package", message: "Kifurushi hakijulikani." }, 422);
  }

  const phone = normalizePhone(input.phone);
  if (!phone) {
    return json({ ok: false, code: "invalid_phone", message: "Namba ya simu si sahihi." }, 422);
  }

  const shortPhone = phone.startsWith("255") ? phone.slice(3) : (phone.startsWith("0") ? phone.slice(1) : phone);
  const suffix = Math.random().toString(36).substring(2, 6).toUpperCase();
  const reference = "S" + shortPhone + "_" + suffix;
  const amount = pkg.amount;
  const body = JSON.stringify({ amount: amount, method: "mobile", currency: "TZS", phone: phone, reference: reference });
  const ts = Math.floor(Date.now() / 1000).toString();
  const signature = await hmacHex(env.ABLINER_WEBHOOK_SECRET, ts + "." + body);

  const res = await fetch(ABLINER + "/deposits", {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + env.ABLINER_API_KEY,
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Idempotency-Key": reference,
      "x-abliner-timestamp": ts,
      "x-abliner-signature": signature
    },
    body: body
  });

  const raw = await res.text();
  let data = {};
  try { data = JSON.parse(raw); } catch (e) {}

  if (!res.ok) {
    return json({
      ok: false,
      code: data.code || "abliner_error",
      message: data.message || ("Abliner error (" + res.status + ")"),
      retryable: Boolean(data.retryable)
    }, res.status);
  }

  const d = data.data || data;
  return json({
    ok: true,
    reference: reference,
    id: d.id || null,
    status: (d.status || "processing").toLowerCase(),
    amount: amount,
    phone: phone,
    uptime: pkg.uptime
  });
}

async function handleWithdraw(request, env) {
  let input;
  try {
    input = await request.json();
  } catch (e) {
    return json({ ok: false, code: "invalid_json", message: "Ombi si sahihi." }, 400);
  }

  const amount = Number(input.amount);
  if (!amount || isNaN(amount) || amount < 1000) {
    return json({ ok: false, code: "invalid_amount", message: "Kiasi cha kutoa lazima kiwe kuanzia TZS 1,000." }, 422);
  }

  const phone = normalizePhone(input.phone);
  if (!phone) {
    return json({ ok: false, code: "invalid_phone", message: "Namba ya simu ya kupokelea si sahihi." }, 422);
  }

  // ISOLATED SKYLINK FUNDS: Calculate balance collected from this Hotspot ONLY
  const resTx = await fetch(ABLINER + "/transactions?limit=100", {
    headers: {
      "Authorization": "Bearer " + env.ABLINER_API_KEY,
      "Accept": "application/json"
    }
  });

  if (!resTx.ok) {
    return json({ ok: false, code: "abliner_unavailable", message: "Imeshindikana kuthibitisha salio la Abliner." }, 502);
  }

  const dataTx = await resTx.json();
  const list = Array.isArray(dataTx && dataTx.data) ? dataTx.data : [];

  let hotspotGross = 0;
  let hotspotWithdrawn = 0;

  for (let i = 0; i < list.length; i++) {
    const t = list[i];
    const status = String(t.status || "").toLowerCase();
    const isSuccess = status === "completed" || status === "success" || status === "successful";
    const ref = String(t.customer_reference || t.reference || "");

    if (ref.startsWith("SKYLINK_WITHDRAW_") || (ref.startsWith("W") && ref.includes("_"))) {
      if (isSuccess || status === "processing" || status === "pending") {
        hotspotWithdrawn += Number(t.amount) || 0;
      }
    } else if (ref.startsWith("SKYLINK_") || (ref.startsWith("S") && ref.includes("_"))) {
      if (isSuccess) {
        hotspotGross += Number(t.amount) || 0;
      }
    }
  }

  const availableBalance = Math.max(0, hotspotGross - hotspotWithdrawn);

  if (amount > availableBalance) {
    return json({
      ok: false,
      code: "insufficient_skylink_balance",
      message: `Huwezi kutoa kiasi hiki (TZS ${amount.toLocaleString()}). Salio lililokusanywa kupitia mfumo huu wa Skylink pekee ni TZS ${availableBalance.toLocaleString()}.`,
      available_balance: availableBalance,
      gross_collected: hotspotGross,
      total_withdrawn: hotspotWithdrawn
    }, 400);
  }

  // Security: Check Admin Password (default PIN: 1961)
  const adminPassword = String(input.admin_password || input.password || "").trim();
  const expectedPassword = env.ADMIN_PASSWORD || "1961";
  if (adminPassword !== expectedPassword) {
    return json({ ok: false, code: "unauthorized", message: "Nenosiri au Jina la Admin si sahihi." }, 401);
  }

  // Execute Withdrawal via Abliner Payout API (Max 15-char reference for mobile money operators)
  const shortPhone = phone.startsWith("255") ? phone.slice(3) : (phone.startsWith("0") ? phone.slice(1) : phone);
  const suffix = Math.random().toString(36).substring(2, 6).padEnd(4, "0").toUpperCase();
  const reference = "W" + shortPhone + "_" + suffix;
  const body = JSON.stringify({
    amount: amount,
    currency: "TZS",
    method: "mobile",
    recipient: phone,
    phone: phone,
    reference: reference
  });

  const res = await fetch(ABLINER + "/withdrawals", {
    method: "POST",
    headers: {
      "Authorization": "Bearer " + env.ABLINER_API_KEY,
      "Content-Type": "application/json",
      "Accept": "application/json",
      "Idempotency-Key": reference
    },
    body: body
  });

  const raw = await res.text();
  let data = {};
  try { data = JSON.parse(raw); } catch (e) {}

  if (!res.ok) {
    return json({
      ok: false,
      code: data.code || "withdrawal_failed",
      message: data.message || ("Abliner error (" + res.status + ")"),
      retryable: Boolean(data.retryable)
    }, res.status);
  }

  const d = data.data || data;
  return json({
    ok: true,
    reference: reference,
    id: d.id || null,
    status: (d.status || "processing").toLowerCase(),
    amount: amount,
    phone: phone,
    remaining_balance: availableBalance - amount,
    message: `Ombi la kutoa TZS ${amount.toLocaleString()} kwenda ${phone} limetumwa kikamilifu.`
  });
}

async function handleStatus(url, env) {
  const ref = url.searchParams.get("ref") || "";
  if (!ref.startsWith("SKYLINK_") && !ref.startsWith("S") && !ref.startsWith("W")) {
    return json({ ok: false, code: "invalid_reference" }, 400);
  }

  const res = await fetch(ABLINER + "/transactions?limit=100", {
    headers: {
      "Authorization": "Bearer " + env.ABLINER_API_KEY,
      "Accept": "application/json"
    }
  });
  if (!res.ok) {
    return json({ ok: false, code: "abliner_unavailable" }, 502);
  }

  const data = await res.json();
  const list = Array.isArray(data && data.data) ? data.data : [];
  const tx = list.find(function(t) {
    return t.customer_reference === ref || (t.reference && t.reference === ref);
  });

  const status = tx ? String(tx.status || "processing").toLowerCase() : "processing";
  return json({ ok: true, reference: ref, status: status });
}

async function handleMikrotikSync(env) {
  const res = await fetch(ABLINER + "/transactions?limit=100", {
    headers: {
      "Authorization": "Bearer " + env.ABLINER_API_KEY,
      "Accept": "application/json"
    }
  });
  if (!res.ok) {
    return new Response("# Error fetching Abliner transactions\n", {
      status: 200,
      headers: { "Content-Type": "text/plain; charset=utf-8" }
    });
  }

  const data = await res.json();
  const list = Array.isArray(data && data.data) ? data.data : [];
  const scriptParts = [];
  const seenPhones = new Set();

  for (let i = 0; i < list.length; i++) {
    const t = list[i];
    const status = String(t.status || "").toLowerCase();
    if (status !== "completed" && status !== "successful" && status !== "success") {
      continue;
    }

    const ref = String(t.customer_reference || t.reference || "");
    // ONLY process captive portal references
    if (!ref.startsWith("SKYLINK_") && !ref.startsWith("S")) {
      continue;
    }

    let phone = "";
    let uptime = AMOUNT_TO_UPTIME[Number(t.amount)] || "04:00:00";

    if (ref.startsWith("S") && ref.includes("_")) {
      const parts = ref.split("_");
      const shortP = parts[0].substring(1);
      if (/^[67]\d{8}$/.test(shortP)) {
        phone = "255" + shortP;
      }
    } else if (ref.startsWith("SKYLINK_")) {
      const parts = ref.split("_");
      if (parts.length >= 4 && parts[0] === "SKYLINK") {
        phone = parts[1];
        const pkgKey = parts[2];
        if (PACKAGES[pkgKey]) {
          uptime = PACKAGES[pkgKey].uptime;
        }
      } else {
        phone = normalizePhone(t.customer_phone || t.phone || t.account_number);
      }
    }

    if (!phone) {
      phone = normalizePhone(t.customer_phone || t.phone || t.account_number);
    }

    if (!phone) {
      continue;
    }

    // Deduplicate: ONLY keep the most recent payment for each phone!
    if (seenPhones.has(phone)) {
      continue;
    }
    seenPhones.add(phone);

    const safeRef = ref.replace(/[^a-zA-Z0-9_-]/g, "");

    const block = 
      ":do {\n" +
      '  :local uId [/ip hotspot user find name="' + phone + '"]\n' +
      '  :if ([:len $uId] = 0) do={\n' +
      '    /ip hotspot user add name="' + phone + '" password="' + phone + '" limit-uptime=' + uptime + ' comment="' + safeRef + '" profile="default"\n' +
      '    :log info "[SKYLINK] Added user ' + phone + ' limit-uptime=' + uptime + '"\n' +
      "  } else={\n" +
      '    :local c ""\n' +
      '    :do { :set c [/ip hotspot user get $uId comment] } on-error={}\n' +
      '    :if ([:typeof [:find $c "' + safeRef + '"]] = "nil") do={\n' +
      '      /ip hotspot user set $uId limit-uptime=' + uptime + ' comment="' + safeRef + '"\n' +
      '      /ip hotspot user reset-counters $uId\n' +
      '      /ip hotspot active remove [find user="' + phone + '"]\n' +
      '      :do { /system scheduler remove [find name="' + phone + '"] } on-error={}\n' +
      '      :log info "[SKYLINK] Renewed user ' + phone + ' limit-uptime=' + uptime + '"\n' +
      "    }\n" +
      "  }\n" +
      "} on-error={}";

    scriptParts.push(block);
  }

  const body = scriptParts.length > 0 ? scriptParts.join("\n") + "\n" : "# No pending paid users\n";
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Cache-Control": "no-cache, no-store"
    }
  });
}

async function handleTransactions(env) {
  const res = await fetch(ABLINER + "/transactions?limit=100", {
    headers: {
      "Authorization": "Bearer " + env.ABLINER_API_KEY,
      "Accept": "application/json"
    }
  });
  if (!res.ok) {
    return json({ ok: false, error: "failed_to_fetch_transactions" }, 502);
  }
  const data = await res.json();
  return json(data, 200);
}

let latestTelemetry = null;

async function handleTelemetryPost(request, env) {
  try {
    const raw = await request.text();
    let data;
    try {
      data = JSON.parse(raw);
    } catch (_) {
      return json({ ok: false, error: "invalid_json" }, 400);
    }

    const payload = {
      received_at: Date.now(),
      data: data
    };

    latestTelemetry = payload;

    try {
      const cache = caches.default;
      const key = new Request("https://skylink-internal.cache/telemetry");
      await cache.put(key, new Response(JSON.stringify(payload), {
        headers: { "Content-Type": "application/json", "Cache-Control": "public, max-age=180" }
      }));
    } catch (_) {}

    return json({ ok: true, message: "telemetry_received", timestamp: payload.received_at });
  } catch (err) {
    return json({ ok: false, error: err.message }, 500);
  }
}

async function handleTelemetryGet(env) {
  let item = latestTelemetry;

  if (!item) {
    try {
      const cache = caches.default;
      const key = new Request("https://skylink-internal.cache/telemetry");
      const hit = await cache.match(key);
      if (hit) {
        item = await hit.json();
      }
    } catch (_) {}
  }

  if (item && item.received_at) {
    const ageSec = Math.round((Date.now() - item.received_at) / 1000);
    const isLive = ageSec <= 120;
    return json({
      ok: true,
      live: isLive,
      age_seconds: ageSec,
      telemetry: item.data
    });
  }

  return json({
    ok: true,
    live: false,
    message: "Awaiting router heartbeat (push_telemetry script)"
  });
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS });
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    try {
      if (!env.ABLINER_API_KEY || !env.ABLINER_WEBHOOK_SECRET) {
        return json({ ok: false, code: "relay_not_configured", message: "Relay haijawekewa siri za Abliner." }, 500);
      }
      if (path === "/pay" && request.method === "POST") {
        return await handlePay(request, env);
      }
      if (path === "/withdraw" && request.method === "POST") {
        return await handleWithdraw(request, env);
      }
      if (path === "/status" && request.method === "GET") {
        return await handleStatus(url, env);
      }
      if ((path === "/mikrotik/sync" || path === "/sync") && request.method === "GET") {
        return await handleMikrotikSync(env);
      }
      if (path === "/transactions" && request.method === "GET") {
        return await handleTransactions(env);
      }
      if (path === "/telemetry") {
        if (request.method === "POST") return await handleTelemetryPost(request, env);
        if (request.method === "GET") return await handleTelemetryGet(env);
      }
      if (path === "/health") {
        return json({ ok: true, service: "skylink-pay-relay", auto_sync: true });
      }
      return json({ ok: false, code: "not_found" }, 404);
    } catch (err) {
      return json({ ok: false, code: "relay_error", message: String(err && err.message || err) }, 500);
    }
  }
};
