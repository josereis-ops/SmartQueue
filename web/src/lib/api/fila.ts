import type { SupabaseClient } from "@supabase/supabase-js";
import type {
  AtribuirTarefaResponse,
  MeusPendentesResponse,
  PresencaStatus,
  RpcBaseResponse,
  TarefaAtribuida,
} from "@/lib/types/fila";

export function normalizarTarefa(
  raw: unknown,
  equipaFallback = ""
): TarefaAtribuida | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const id = String(r.id ?? "");
  const idUnico = String(r.idUnico ?? r.id_externo ?? "");
  if (!id || !idUnico) return null;

  return {
    id,
    idUnico,
    loja: String(r.loja ?? equipaFallback),
    canal: (r.canal as string | null) ?? null,
    pn: String(r.pn ?? "-"),
    observacoes: String(r.observacoes ?? r.notas ?? ""),
    dataRqsIso: (r.dataRqsIso ?? r.data_rqs ?? null) as string | null,
    dataDespertadorIso: (r.dataDespertadorIso ??
      r.data_agendamento ??
      r.data_rqs ??
      null) as string | null,
    intercalar: (r.intercalar ?? r.intercalar_em ?? null) as string | null,
    prioridade_flash: Boolean(r.prioridade_flash),
  };
}

export async function obterPresencaActual(
  supabase: SupabaseClient,
  userId: string
): Promise<PresencaStatus | null> {
  const { data, error } = await supabase
    .from("utilizadores")
    .select("presenca")
    .eq("id", userId)
    .maybeSingle();

  if (error || !data?.presenca) return null;
  return data.presenca as PresencaStatus;
}

export async function recuperarCasoEmTratamento(
  supabase: SupabaseClient,
  userId: string,
  equipaFallback: string
): Promise<{ tarefa: TarefaAtribuida; inicioTratamento: string | null } | null> {
  const { data, error } = await supabase
    .from("casos")
    .select(
      "id, id_externo, canal, pn, notas, data_rqs, data_agendamento, intercalar_em, prioridade_flash, inicio_tratamento, equipas(nome)"
    )
    .eq("status", "em_tratamento")
    .eq("colaborador_id", userId)
    .order("inicio_tratamento", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (error || !data) return null;

  const equipaRaw = data.equipas as { nome: string } | { nome: string }[] | null;
  const equipaNome = Array.isArray(equipaRaw)
    ? equipaRaw[0]?.nome
    : equipaRaw?.nome;
  const tarefa = normalizarTarefa(
    {
      ...data,
      idUnico: data.id_externo,
      loja: equipaNome ?? equipaFallback,
      observacoes: data.notas,
      dataRqsIso: data.data_rqs,
      dataDespertadorIso: data.data_agendamento ?? data.data_rqs,
      intercalar: data.intercalar_em,
    },
    equipaFallback
  );

  if (!tarefa) return null;

  return {
    tarefa,
    inicioTratamento: data.inicio_tratamento as string | null,
  };
}

export async function atribuirTarefa(
  supabase: SupabaseClient,
  equipaFallback = ""
): Promise<AtribuirTarefaResponse> {
  const { data, error } = await supabase.rpc("atribuir_tarefa", {
    p_equipa_id: null,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return mapAtribuirResponse(data, equipaFallback);
}

function mapAtribuirResponse(
  data: unknown,
  equipaFallback: string
): AtribuirTarefaResponse {
  const res = data as AtribuirTarefaResponse;
  if (!res?.sucesso) return res;
  const tarefa = normalizarTarefa(res.tarefa, equipaFallback);
  if (!tarefa) {
    return {
      sucesso: false,
      mensagem: "Resposta inválida do servidor (tarefa incompleta).",
    };
  }
  return { ...res, tarefa };
}

export async function atribuirTarefaEspecifica(
  supabase: SupabaseClient,
  idExterno: string,
  equipaFallback = ""
): Promise<AtribuirTarefaResponse> {
  const { data, error } = await supabase.rpc("atribuir_tarefa_especifica", {
    p_id_externo: idExterno,
  });

  if (error) {
    const rpcIndisponivel =
      error.code === "PGRST202" ||
      error.message.includes("atribuir_tarefa_especifica") ||
      error.message.includes("schema cache");
    return {
      sucesso: false,
      mensagem: rpcIndisponivel
        ? "RPC atribuir_tarefa_especifica em falta. Aplica a migration 20260703262000 (supabase db push)."
        : error.message,
    };
  }

  return mapAtribuirResponse(data, equipaFallback);
}

export async function criarCasoManual(
  supabase: SupabaseClient,
  params: {
    idExterno: string;
    canal: string;
    dataCriacao: string;
    dataRqs: string;
    equipaId: string;
  }
): Promise<AtribuirTarefaResponse> {
  const { data, error } = await supabase.rpc("criar_caso_manual", {
    p_id_externo: params.idExterno,
    p_canal: params.canal,
    p_data_criacao: params.dataCriacao,
    p_data_rqs: params.dataRqs,
    p_equipa_id: params.equipaId,
  });

  if (error) {
    const rpcIndisponivel =
      error.code === "PGRST202" ||
      error.message.includes("criar_caso_manual") ||
      error.message.includes("schema cache");
    return {
      sucesso: false,
      mensagem: rpcIndisponivel
        ? "RPC criar_caso_manual em falta. Aplica a migration 20260703430000 (supabase db push)."
        : error.message,
    };
  }

  return mapAtribuirResponse(data, "");
}

export async function obterMeusPendentes(
  supabase: SupabaseClient
): Promise<MeusPendentesResponse> {
  const { data, error } = await supabase.rpc("obter_meus_pendentes");

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as MeusPendentesResponse;
}

export async function concluirCaso(
  supabase: SupabaseClient,
  casoId: string,
  observacoes?: string,
  status: "concluido" | "cancelado" = "concluido"
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("concluir_caso", {
    p_caso_id: casoId,
    p_observacoes: observacoes ?? null,
    p_status: status,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse;
}

export async function agendarCaso(
  supabase: SupabaseClient,
  casoId: string,
  status: "agendado" | "pendente" | "suspenso" | "outro",
  dataAgendamento: string,
  observacoes?: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("agendar_caso", {
    p_caso_id: casoId,
    p_status: status,
    p_data_agendamento: dataAgendamento,
    p_observacoes: observacoes ?? null,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse;
}

export async function marcarOutro(
  supabase: SupabaseClient,
  casoId: string,
  observacoes?: string,
  dataAgendamento?: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("marcar_outro", {
    p_caso_id: casoId,
    p_observacoes: observacoes ?? null,
    p_data_agendamento: dataAgendamento ?? null,
  });

  if (error) {
    return { sucesso: false, mensagem: error.message };
  }

  return data as RpcBaseResponse;
}

export async function atualizarPresenca(
  supabase: SupabaseClient,
  _userId: string,
  presenca: PresencaStatus
): Promise<{ sucesso: boolean; mensagem?: string; casos_suspensos?: number }> {
  const { data, error } = await supabase.rpc("atualizar_presenca", {
    p_presenca: presenca,
  });

  if (!error && data) {
    return data as { sucesso: boolean; mensagem?: string; casos_suspensos?: number };
  }

  const rpcIndisponivel =
    error?.code === "PGRST202" ||
    (error?.message?.includes("atualizar_presenca") ?? false);

  if (rpcIndisponivel) {
    const { error: updErr } = await supabase
      .from("utilizadores")
      .update({ presenca, ultimo_ping: new Date().toISOString() })
      .eq("id", _userId);

    if (updErr) {
      return { sucesso: false, mensagem: updErr.message };
    }
    return { sucesso: true };
  }

  return { sucesso: false, mensagem: error?.message ?? "Erro ao actualizar presença." };
}

export async function ativarAtendimentoLojaFlash(
  supabase: SupabaseClient
): Promise<{ sucesso: boolean; mensagem?: string; casos_suspensos?: number }> {
  const { data, error } = await supabase.rpc("ativar_atendimento_loja_flash");

  if (!error && data) {
    return data as { sucesso: boolean; mensagem?: string; casos_suspensos?: number };
  }

  return {
    sucesso: false,
    mensagem: error?.message ?? "Erro ao activar Atendimento Loja.",
  };
}

export async function marcarIntercalarCaso(
  supabase: SupabaseClient,
  casoId: string
): Promise<RpcBaseResponse & { intercalar_em?: string }> {
  const { data, error } = await supabase.rpc("marcar_intercalar", {
    p_caso_id: casoId,
  });

  if (!error && data) {
    return data as RpcBaseResponse & { intercalar_em?: string };
  }

  // Fallback se a migration ainda não estiver aplicada no Supabase remoto
  const rpcIndisponivel =
    error?.code === "PGRST202" ||
    (error?.message?.includes("marcar_intercalar") ?? false);

  if (rpcIndisponivel) {
    const agora = new Date().toISOString();
    const { error: updErr } = await supabase
      .from("casos")
      .update({ intercalar_em: agora })
      .eq("id", casoId)
      .eq("status", "em_tratamento");

    if (updErr) {
      return { sucesso: false, mensagem: updErr.message };
    }
    return {
      sucesso: true,
      mensagem: "Intercalar marcada com sucesso.",
      intercalar_em: agora,
    };
  }

  return { sucesso: false, mensagem: error?.message ?? "Erro ao marcar intercalar." };
}
