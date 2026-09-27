// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "jsr:@supabase/server@^1.7.0";

interface LoginPayload {
  identifier?: unknown;
  password?: unknown;
}

function json(status: number, body: Record<string, unknown>) {
  return Response.json(body, { status });
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

console.info("login-by-identifier started");

export default {
  fetch: withSupabase({ auth: "publishable" }, async (request, ctx) => {
    if (request.method !== "POST") return json(405, { error: "method_not_allowed" });

    let body: LoginPayload;
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "invalid_request" });
    }

    const identifier = String(body.identifier || "").trim().replace(/\s+/g, " ");
    const password = String(body.password || "");
    if (!identifier || identifier.length > 128 || !password || password.length > 256) {
      return json(400, { error: "invalid_request" });
    }

    const origin = request.headers.get("origin") || "";
    const configuredOrigins = (Deno.env.get("LOGIN_ALLOWED_ORIGINS") || "")
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
    if (configuredOrigins.length && !configuredOrigins.includes(origin)) {
      return json(403, { error: "origin_not_allowed" });
    }

    const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
    const clientIp = request.headers.get("cf-connecting-ip") || forwarded || "unknown";
    const keyHash = await sha256(`${clientIp}|${identifier.toLocaleLowerCase("ru")}`);

    const { data: retryAfter, error: limitError } = await ctx.supabaseAdmin.rpc(
      "consume_login_attempt",
      { p_key_hash: keyHash },
    );
    if (limitError) return json(500, { error: "server_error" });
    if (Number(retryAfter) > 0) {
      return json(429, { error: "rate_limited", retry_after: Number(retryAfter) });
    }

    let email = identifier.includes("@") ? identifier.toLowerCase() : "";
    if (!email) {
      const { data: userId, error: resolveError } = await ctx.supabaseAdmin.rpc(
        "resolve_login_user_id",
        { p_identifier: identifier },
      );
      if (resolveError) return json(500, { error: "server_error" });
      if (userId) {
        const { data: userData } = await ctx.supabaseAdmin.auth.admin.getUserById(userId);
        email = userData.user?.email || "";
      }
    }

    if (!email) {
      await new Promise((resolve) => setTimeout(resolve, 300));
      return json(401, { error: "invalid_credentials" });
    }

    const { data, error } = await ctx.supabase.auth.signInWithPassword({ email, password });
    if (error || !data.session) {
      const code = error?.message?.includes("Email not confirmed")
        ? "email_not_confirmed"
        : "invalid_credentials";
      return json(401, { error: code });
    }

    await ctx.supabaseAdmin.rpc("clear_login_attempts", { p_key_hash: keyHash });
    return json(200, {
      access_token: data.session.access_token,
      refresh_token: data.session.refresh_token,
    });
  }),
};
