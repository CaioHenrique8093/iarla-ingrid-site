// Edge Function "qz-sign" · Iarla Ingrid
// Assina os pedidos de impressão do QZ Tray com a chave privada da loja,
// para a comanda sair direto na impressora, sem a janela "Allow/Permitir".
//
// Só responde para quem está logado no painel e está na tabela "admins".
// A chave privada fica no secret QZ_PRIVATE_KEY (Supabase > Edge Functions > Secrets).
// Nunca coloque a chave privada no código nem no GitHub.

import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

let keyPromise: Promise<CryptoKey> | null = null;

function importKey(): Promise<CryptoKey> {
  const pem = Deno.env.get("QZ_PRIVATE_KEY") ?? "";
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\\n/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-512" }, false, ["sign"]);
}

function toBase64(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

const text = (body: string, status = 200) =>
  new Response(body, { status, headers: { ...cors, "Content-Type": "text/plain" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return text("method not allowed", 405);

  try {
    // 1) quem está pedindo? precisa estar logado e ser admin da loja
    const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
    if (!jwt) return text("unauthorized", 401);
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false },
    });
    const { data: userData, error: userErr } = await sb.auth.getUser(jwt);
    if (userErr || !userData?.user) return text("unauthorized", 401);
    const { data: adm } = await sb.from("admins").select("user_id").eq("user_id", userData.user.id).maybeSingle();
    if (!adm) return text("forbidden", 403);

    // 2) o que assinar
    const body = await req.json().catch(() => ({}));
    const toSign = typeof body?.request === "string" ? body.request : "";
    if (!toSign || toSign.length > 20000) return text("bad request", 400);

    // 3) assina com SHA-512 (o painel usa setSignatureAlgorithm("SHA512"))
    keyPromise = keyPromise ?? importKey();
    const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", await keyPromise, new TextEncoder().encode(toSign));
    return text(toBase64(sig));
  } catch (e) {
    console.error("qz-sign", e);
    keyPromise = null;
    return text("error", 500);
  }
});
