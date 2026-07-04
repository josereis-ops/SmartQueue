import { createSign } from "crypto";

const EVALYZE_SHEET_NAME = "Lojas";
const SCOPES = "https://www.googleapis.com/auth/spreadsheets.readonly";

function base64url(input: Buffer | string): string {
  const buf = typeof input === "string" ? Buffer.from(input) : input;
  return buf
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function obterAccessToken(
  email: string,
  privateKey: string
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

  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${payload}`);
  signer.end();
  const signature = base64url(signer.sign(privateKey));

  const jwt = `${header}.${payload}.${signature}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });

  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`Google OAuth falhou: ${txt}`);
  }

  const data = (await res.json()) as { access_token?: string };
  if (!data.access_token) {
    throw new Error("Google OAuth nao devolveu access_token.");
  }
  return data.access_token;
}

/** Le aba Lojas (A:Q, linha 2+) — replica GAS _abrirSpreadsheetEvalyze_ + getRange. */
export async function lerLinhasEvalyze(): Promise<string[][]> {
  const sheetId = process.env.EVALYZE_SHEET_ID?.trim();
  const email = process.env.GOOGLE_SERVICE_ACCOUNT_EMAIL?.trim();
  const rawKey = process.env.GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY;

  if (!sheetId || !email || !rawKey) {
    throw new Error(
      "Credenciais Evalyze em falta. Configura EVALYZE_SHEET_ID, GOOGLE_SERVICE_ACCOUNT_EMAIL e GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY."
    );
  }

  const privateKey = rawKey.replace(/\\n/g, "\n");
  const token = await obterAccessToken(email, privateKey);

  const range = encodeURIComponent(`${EVALYZE_SHEET_NAME}!A2:Q`);
  const url = `https://sheets.googleapis.com/v4/spreadsheets/${sheetId}/values/${range}`;

  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${token}` },
  });

  if (!res.ok) {
    const txt = await res.text();
    throw new Error(`Google Sheets API: ${txt}`);
  }

  const data = (await res.json()) as { values?: string[][] };
  const rows = data.values ?? [];

  // GAS exclui ultima linha de dados (lastRow - 1)
  if (rows.length > 1) {
    return rows.slice(0, -1);
  }

  return rows;
}

export function linhasParaJson(rows: string[][]): string[][] {
  return rows.map((row) => {
    const linha = Array(17).fill("");
    for (let c = 0; c < 17; c++) {
      linha[c] = row[c] !== undefined && row[c] !== null ? String(row[c]) : "";
    }
    return linha;
  });
}
