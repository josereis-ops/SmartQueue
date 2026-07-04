import type { SupabaseClient } from "@supabase/supabase-js";
import { lerLinhasEvalyze, linhasParaJson } from "@/lib/google/evalyze-sheets";
import type { ImportEvalyzeResponse } from "@/lib/types/gestor";

export type OrigemImportEvalyze = "api_sheets" | "cron";

export async function executarImportEvalyze(
  supabase: SupabaseClient,
  origem: OrigemImportEvalyze,
  areaIdCron?: string
): Promise<ImportEvalyzeResponse> {
  const rawRows = await lerLinhasEvalyze();
  const linhas = linhasParaJson(rawRows);

  const { data, error } = await supabase.rpc("importar_casos_evalyze", {
    p_linhas: linhas,
    p_origem: origem,
    ...(areaIdCron ? { p_area_id_cron: areaIdCron } : {}),
  });

  if (error) {
    return {
      sucesso: false,
      mensagem: error.message,
      importados: 0,
      duplicados: 0,
      ignoradosCampos: 0,
    };
  }

  return data as ImportEvalyzeResponse;
}
