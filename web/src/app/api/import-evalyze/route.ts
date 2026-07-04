import { executarImportEvalyze } from "@/lib/import/evalyze-run";
import { createClient } from "@/lib/supabase/server";
import { NextResponse } from "next/server";

export async function POST() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return NextResponse.json(
      { sucesso: false, mensagem: "Sessao invalida." },
      { status: 401 }
    );
  }

  try {
    const data = await executarImportEvalyze(supabase, "api_sheets");
    return NextResponse.json(data, { status: data.sucesso ? 200 : 500 });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Erro na importacao Evalyze.";
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
