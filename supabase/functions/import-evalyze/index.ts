import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const EVALYZE_SHEET_NAME = "Lojas";
const SCOPES = "https://www.googleapis.com/auth/spreadsheets.readonly";

interface ImportEvalyzeResponse {
  sucesso: boolean;
  mensagem?: string;
  importados?: number;
  duplicados?: number;
  ignoradosCampos?: number;
  log_id?: string;
}

type AuthMode = "cron" | "user";

function base64url(input: string | Uint8Array): string {
  const bytes =
    typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function pemToPkcs8(pem: string): Uint8Array {
  const normalized = pem.replace(/\\n/g, "\n");
  const b64 = normalized
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function obterAccessToken(
  email: string,
  privateKeyPem: string
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const payload = base64url(
    JSON.stringify({
      iss: email,
      scope: SCOPES,
      aud: "https://oauth2.googleapis.com/token",
      exp: now + 3600,
      iat: now,
    })
  );

  const keyBytes = pemToPkcs8(privateKeyPem);
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );

  const signingInput = new TextEncoder().encode(`${header}.${payload}`);
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    signingInput
  );
  const jwt = `${header}.${payload}.${base64url(new Uint8Array(signature))}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!res.ok) {
    throw new Error(`Google OAuth falhou: ${await res.text()}`);
  }

  const data = (await res.json()) as { access_token?: string };
  if (!data.access_token) {
    throw new Error("Google OAuth nao devolveu access_token.");
  }
  return data.access_token;
}

async function lerLinhasEvalyze(): Promise<string[][]> {
  const sheetId =
    Deno.env.get("EVALYZE_SHEET_ID")?.trim() ??
    Deno.env.get("EVALYZE_SPREADSHEET_ID")?.trim();
  const email = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_EMAIL")?.trim();
  const rawKey = Deno.env.get("GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY");

  if (!sheetId || !email || !rawKey) {
    throw new Error(
      "Credenciais Evalyze em falta. Configura EVALYZE_SHEET_ID, GOOGLE_SERVICE_ACCOUNT_EMAIL e GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY."
    );
  }

  const token = await obterAccessToken(email, rawKey);
  const range = encodeURIComponent(`${EVALYZE_SHEET_NAME}!A2:Q`);
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${sheetId}/values/${range}`;

  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    throw new Error(`Google Sheets API: ${await res.text()}`);
  }

  const data = (await res.json()) as { values?: string[][] };
  const rows = data.values ?? [];
  return rows.length > 1 ? rows.slice(0, -1) : rows;
}

function linhasParaJson(rows: string[][]): string[][] {
  return rows.map((row) => {
    const linha = Array(17).fill("");
    for (let c = 0; c < 17; c++) {
      linha[c] =
        row[c] !== undefined && row[c] !== null ? String(row[c]) : "";
    }
    return linha;
  });
}

function jsonResponse(body: ImportEvalyzeResponse, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function resolveAuth(req: Request): AuthMode | null {
  const auth = req.headers.get("authorization") ?? "";
  const cronSecret = Deno.env.get("CRON_SECRET")?.trim();

  if (cronSecret && auth === `Bearer ${cronSecret}`) {
    return "cron";
  }

  if (auth.startsWith("Bearer ") && auth.length > 7) {
    return "user";
  }

  return null;
}

function criarClienteCron(
  supabaseUrl: string,
  serviceKey: string
): SupabaseClient {
  return createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function criarClienteUtilizador(
  supabaseUrl: string,
  anonKey: string,
  authHeader: string
): SupabaseClient {
  return createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return jsonResponse(
      { sucesso: false, mensagem: "Metodo nao permitido." },
      405
    );
  }

  const mode = resolveAuth(req);
  if (!mode) {
    return jsonResponse({ sucesso: false, mensagem: "Nao autorizado." }, 401);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
  if (!supabaseUrl) {
    return jsonResponse(
      {
        sucesso: false,
        mensagem: "SUPABASE_URL em falta.",
        importados: 0,
        duplicados: 0,
        ignoradosCampos: 0,
      },
      500
    );
  }

  const authHeader = req.headers.get("authorization") ?? "";
  let supabase: SupabaseClient;
  let rpcArgs: Record<string, unknown>;

  if (mode === "cron") {
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
    const areaId = Deno.env.get("EVALYZE_AREA_ID")?.trim();

    if (!serviceKey) {
      return jsonResponse(
        {
          sucesso: false,
          mensagem: "SUPABASE_SERVICE_ROLE_KEY em falta.",
          importados: 0,
          duplicados: 0,
          ignoradosCampos: 0,
        },
        500
      );
    }

    if (!areaId) {
      return jsonResponse(
        {
          sucesso: false,
          mensagem: "EVALYZE_AREA_ID em falta (UUID da area).",
          importados: 0,
          duplicados: 0,
          ignoradosCampos: 0,
        },
        500
      );
    }

    supabase = criarClienteCron(supabaseUrl, serviceKey);
    rpcArgs = { p_origem: "cron", p_area_id_cron: areaId };
  } else {
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim();
    if (!anonKey) {
      return jsonResponse(
        {
          sucesso: false,
          mensagem: "SUPABASE_ANON_KEY em falta.",
          importados: 0,
          duplicados: 0,
          ignoradosCampos: 0,
        },
        500
      );
    }

    supabase = criarClienteUtilizador(supabaseUrl, anonKey, authHeader);

    const {
      data: { user },
      error: userError,
    } = await supabase.auth.getUser();
    if (userError || !user) {
      return jsonResponse(
        { sucesso: false, mensagem: "Sessao invalida." },
        401
      );
    }

    const { data: permitido, error: permError } = await supabase.rpc(
      "has_permissao",
      { p_codigo: "importacao.evalyze" }
    );
    if (permError || !permitido) {
      return jsonResponse(
        {
          sucesso: false,
          mensagem: "Sem permissao importacao.evalyze.",
          importados: 0,
          duplicados: 0,
          ignoradosCampos: 0,
        },
        403
      );
    }

    rpcArgs = { p_origem: "api_sheets" };
  }

  try {
    const rawRows = await lerLinhasEvalyze();
    const linhas = linhasParaJson(rawRows);

    const { data, error } = await supabase.rpc("importar_casos_evalyze", {
      p_linhas: linhas,
      ...rpcArgs,
    });

    if (error) {
      return jsonResponse(
        {
          sucesso: false,
          mensagem: error.message,
          importados: 0,
          duplicados: 0,
          ignoradosCampos: 0,
        },
        500
      );
    }

    const result = data as ImportEvalyzeResponse;
    return jsonResponse(result, result.sucesso ? 200 : 500);
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Erro na importacao Evalyze.";
    return jsonResponse(
      {
        sucesso: false,
        mensagem: msg,
        importados: 0,
        duplicados: 0,
        ignoradosCampos: 0,
      },
      500
    );
  }
});
