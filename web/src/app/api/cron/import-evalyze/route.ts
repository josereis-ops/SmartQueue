import { executarImportEvalyze } from "@/lib/import/evalyze-run";
import { createAdminClient } from "@/lib/supabase/admin";
import { NextResponse } from "next/server";

function autorizado(request: Request): boolean {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return false;

  const auth = request.headers.get("authorization");
  return auth === `Bearer ${secret}`;
}

/** Cron Vercel 1h — réplica GAS configurarTriggerImportacaoEvalyze */
export async function GET(request: Request) {
  if (!autorizado(request)) {
    return NextResponse.json(
      { sucesso: false, mensagem: "Nao autorizado." },
      { status: 401 }
    );
  }

  const areaId = process.env.EVALYZE_AREA_ID?.trim();
  if (!areaId) {
    return NextResponse.json(
      {
        sucesso: false,
        mensagem: "EVALYZE_AREA_ID em falta (UUID da area, ex. SU Eletricidade).",
      },
      { status: 500 }
    );
  }

  try {
    const supabase = createAdminClient();
    const data = await executarImportEvalyze(supabase, "cron", areaId);

    return NextResponse.json(data, {
      status: data.sucesso ? 200 : 500,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Erro na importacao Evalyze cron.";
    return NextResponse.json(
      {
        sucesso: false,
        mensagem: msg,
        importados: 0,
        duplicados: 0,
        ignoradosCampos: 0,
      },
      { status: 500 }
    );
  }
}
