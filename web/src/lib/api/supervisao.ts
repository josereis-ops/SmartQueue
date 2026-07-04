import type { SupabaseClient } from "@supabase/supabase-js";
import type { PresencaStatus, RpcBaseResponse } from "@/lib/types/fila";
import type {
  DadosSupervisaoResponse,
  DrillDownTipo,
  DrilldownSupervisaoResponse,
} from "@/lib/types/supervisao";

const MSG_RPC_EM_FALTA =
  "RPC em falta no Supabase remoto. Aplica as migrations pendentes: supabase db push (ficheiros 20260703260000, 20260703261000 e 20260703262000 no SQL Editor se necessário).";

function mapRpcError(error: { code?: string; message?: string } | null): {
  sucesso: false;
  mensagem: string;
} {
  if (
    error?.code === "PGRST202" ||
    error?.message?.includes("schema cache") ||
    error?.message?.includes("Could not find the function")
  ) {
    return { sucesso: false, mensagem: MSG_RPC_EM_FALTA };
  }
  return { sucesso: false, mensagem: error?.message ?? "Erro no servidor." };
}

export async function obterDadosSupervisao(
  supabase: SupabaseClient,
  equipasFiltro?: string[]
): Promise<DadosSupervisaoResponse> {
  const { data, error } = await supabase.rpc("obter_dados_supervisao", {
    p_equipas_filtro:
      equipasFiltro && equipasFiltro.length > 0 ? equipasFiltro : null,
    p_incluir_listas: false,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as DadosSupervisaoResponse;
}

export async function obterCasosSupervisaoDrilldown(
  supabase: SupabaseClient,
  params: {
    tipo: DrillDownTipo;
    offset?: number;
    limit?: number;
    equipasFiltro?: string[];
    pesquisa?: string;
    sortCol?: string;
    sortAsc?: boolean;
  }
): Promise<DrilldownSupervisaoResponse> {
  const { data, error } = await supabase.rpc("obter_casos_supervisao_drilldown", {
    p_tipo: params.tipo,
    p_offset: params.offset ?? 0,
    p_limit: params.limit ?? 100,
    p_equipas_filtro:
      params.equipasFiltro && params.equipasFiltro.length > 0
        ? params.equipasFiltro
        : null,
    p_pesquisa: params.pesquisa?.trim() || null,
    p_sort_col: params.sortCol ?? "id",
    p_sort_asc: params.sortAsc ?? true,
  });

  if (error) {
    return mapRpcError(error);
  }

  return data as DrilldownSupervisaoResponse;
}

export async function reatribuirCaso(
  supabase: SupabaseClient,
  casoId: string,
  colaboradorId: string | null,
  flash = false
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("reatribuir_caso", {
    p_caso_id: casoId,
    p_colaborador_id: colaboradorId,
    p_flash: flash,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse;
}

export async function alterarPrioridadeFlash(
  supabase: SupabaseClient,
  casoId: string,
  flash: boolean
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("alterar_prioridade_flash", {
    p_caso_id: casoId,
    p_flash: flash,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse;
}

export async function forcarEstadoOperador(
  supabase: SupabaseClient,
  utilizadorId: string,
  presenca: PresencaStatus,
  reforco = false
): Promise<RpcBaseResponse & { casos_suspensos?: number }> {
  const { data, error } = await supabase.rpc("forcar_estado_operador", {
    p_utilizador_id: utilizadorId,
    p_presenca: presenca,
    p_reforco: reforco,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse & { casos_suspensos?: number };
}

export async function adicionarObservacaoSupervisao(
  supabase: SupabaseClient,
  casoId: string,
  texto: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("adicionar_observacao_supervisao", {
    p_caso_id: casoId,
    p_texto: texto,
  });
  if (error) {
    return mapRpcError(error);
  }

  return data as RpcBaseResponse;
}

export async function alterarEstadoCasoSupervisao(
  supabase: SupabaseClient,
  casoId: string,
  status: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("alterar_estado_caso_supervisao", {
    p_caso_id: casoId,
    p_status: status,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function alterarAgendamentoSupervisao(
  supabase: SupabaseClient,
  casoId: string,
  dataAgendamento: string | null
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("alterar_agendamento_supervisao", {
    p_caso_id: casoId,
    p_data_agendamento: dataAgendamento,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function alterarEquipaCasoSupervisao(
  supabase: SupabaseClient,
  casoId: string,
  equipaId: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("alterar_equipa_caso_supervisao", {
    p_caso_id: casoId,
    p_equipa_id: equipaId,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function concluirCasoDiretoSupervisao(
  supabase: SupabaseClient,
  casoId: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("concluir_caso_direto_supervisao", {
    p_caso_id: casoId,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function enviarNudge(
  supabase: SupabaseClient,
  destinatarioId: string,
  mensagem: string,
  casoId?: string
): Promise<RpcBaseResponse & { notificacao_id?: string }> {
  const { data, error } = await supabase.rpc("enviar_nudge", {
    p_destinatario_id: destinatarioId,
    p_mensagem: mensagem,
    p_caso_id: casoId ?? null,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse & { notificacao_id?: string };
}
