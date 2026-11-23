// دالة الخادم لصور نظام الإيواء (مخزن impound الخاص)
// - upload: تعطي روابط رفع مؤقتة لصور جديدة
// - view:   تعطي روابط عرض مؤقتة (ساعة) للصور
// كل طلب يتحقق أولاً من جلسة المستخدم وصلاحيته عبر imp_session.
// النشر: Supabase → Edge Functions → Deploy a new function → Via Editor
//        الاسم impound-files، والصق هذا الملف، وأوقف خيار "Verify JWT".
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const BUCKET = "impound";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: { token?: string; action?: string; count?: number; paths?: string[] };
  try { body = await req.json(); } catch { return json({ error: "bad json" }, 400); }

  const { data: me, error: authErr } = await admin.rpc("imp_session", { p_token: body.token ?? "" });
  if (authErr || !me) return json({ error: authErr?.message || "SESSION_EXPIRED" }, 401);

  if (body.action === "upload") {
    const n = Math.min(Math.max(Number(body.count) || 1, 1), 30);
    const d = new Date();
    const prefix = `v/${d.getUTCFullYear()}/${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
    const out = [];
    for (let i = 0; i < n; i++) {
      const path = `${prefix}/${crypto.randomUUID()}.jpg`;
      const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(path);
      if (error) return json({ error: error.message }, 500);
      out.push({ path, url: data.signedUrl });
    }
    return json({ uploads: out });
  }

  if (body.action === "view") {
    const paths = (body.paths ?? []).filter((p) => typeof p === "string" && p.startsWith("v/")).slice(0, 100);
    if (!paths.length) return json({ urls: {} });
    const { data, error } = await admin.storage.from(BUCKET).createSignedUrls(paths, 3600);
    if (error) return json({ error: error.message }, 500);
    const urls: Record<string, string> = {};
    for (const r of data ?? []) if (r.signedUrl && r.path) urls[r.path] = r.signedUrl;
    return json({ urls });
  }

  return json({ error: "unknown action" }, 400);
});
