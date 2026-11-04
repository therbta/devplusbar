// Dev+ Bar webhook relay (optional). A Cloudflare Worker that receives Vercel and Heroku
// webhooks and tells the app "something happened" so it polls at once instead of waiting.
// It stores only a timestamp, never payloads or tokens.
//
// Bindings: KV namespace RELAY; secrets VERCEL_SECRET, HEROKU_SECRET, READ_TOKEN.
// App setting: https://<worker>/<READ_TOKEN>   (the app appends /events?since=…)

async function hmac(algorithm, secret, body) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: algorithm }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, body));
}
const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
const b64 = (bytes) => btoa(String.fromCharCode(...bytes));

function safeEqual(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

async function bump(env) {
  const now = Date.now() / 1000;
  await env.RELAY.put("latest", String(now));
  return new Response("ok");
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const body = await request.arrayBuffer();

    if (request.method === "POST" && url.pathname === "/hook/vercel") {
      const signature = request.headers.get("x-vercel-signature");
      if (!safeEqual(signature, hex(await hmac("SHA-1", env.VERCEL_SECRET, body)))) {
        return new Response("bad signature", { status: 401 });
      }
      return bump(env);
    }

    if (request.method === "POST" && url.pathname === "/hook/heroku") {
      const signature = request.headers.get("Heroku-Webhook-Hmac-SHA256");
      if (!safeEqual(signature, b64(await hmac("SHA-256", env.HEROKU_SECRET, body)))) {
        return new Response("bad signature", { status: 401 });
      }
      return bump(env);
    }

    if (request.method === "GET" && url.pathname === `/${env.READ_TOKEN}/events`) {
      const since = Number(url.searchParams.get("since") || 0);
      const latest = Number((await env.RELAY.get("latest")) || 0);
      return Response.json({ count: latest > since ? 1 : 0, latest });
    }

    return new Response("not found", { status: 404 });
  },
};
