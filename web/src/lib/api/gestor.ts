import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcBaseResponse } from "@/lib/types/fila";
import type {
  DadosGestaoEquipaResponse,
  DadosGestorSkillsResponse,
  IdsImportacaoResponse,
  ImportarCasosResponse,
  ImportEvalyzeResponse,
  LinhaImportacao,
  NudgeMensagensResponse,
  ObjetivoLoja,
  ObjetivosEdicaoResponse,
  RegrasFilaResponse,
  StatusImportEvalyzeResponse,
} from "@/lib/types/gestor";
import type {
  AcessoAdminAreasResponse,
  ListarAreasResponse,
  RegrasFilaAreaResponse,
  RegrasFilaConfig,
} from "@/lib/types/regras-fila";

const MSG_RPC_EM_FALTA =
  "RPC em falta. Aplica as migrations pendentes: supabase db push.";

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

export async function obterDadosGestorSkills(
  supabase: SupabaseClient
): Promise<DadosGestorSkillsResponse> {
  const { data, error } = await supabase.rpc("obter_dados_gestor_skills");
  if (error) return mapRpcError(error);
  return data as DadosGestorSkillsResponse;
}

export async function atualizarSkillsEmMassa(
  supabase: SupabaseClient,
  emails: string[],
  skills: string[],
  acao: "adicionar" | "remover"
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("atualizar_skills_em_massa", {
    p_emails: emails,
    p_skills: skills,
    p_acao: acao,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function obterObjetivosEdicao(
  supabase: SupabaseClient,
  mes: string
): Promise<ObjetivosEdicaoResponse> {
  const { data, error } = await supabase.rpc("obter_objetivos_edicao", {
    p_mes: mes,
  });
  if (error) return mapRpcError(error);
  return data as ObjetivosEdicaoResponse;
}

export async function salvarObjetivosMassa(
  supabase: SupabaseClient,
  mes: string,
  objetivos: ObjetivoLoja[]
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("salvar_objetivos_massa", {
    p_mes: mes,
    p_objetivos: objetivos,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function obterIdsImportacao(
  supabase: SupabaseClient
): Promise<IdsImportacaoResponse> {
  const { data, error } = await supabase.rpc("obter_ids_importacao");
  if (error) return mapRpcError(error);
  return data as IdsImportacaoResponse;
}

export async function importarCasosLote(
  supabase: SupabaseClient,
  linhas: LinhaImportacao[]
): Promise<ImportarCasosResponse> {
  const { data, error } = await supabase.rpc("importar_casos_lote", {
    p_linhas: linhas,
  });
  if (error) return mapRpcError(error);
  return data as ImportarCasosResponse;
}

export async function importarCasosEvalyze(
  supabase: SupabaseClient,
  linhas: LinhaImportacao[],
  origem = "manual"
): Promise<ImportEvalyzeResponse> {
  const { data, error } = await supabase.rpc("importar_casos_evalyze", {
    p_linhas: linhas,
    p_origem: origem,
  });
  if (error) return mapRpcError(error);
  return data as ImportEvalyzeResponse;
}

export async function obterStatusImportEvalyze(
  supabase: SupabaseClient
): Promise<StatusImportEvalyzeResponse> {
  const { data, error } = await supabase.rpc("obter_status_import_evalyze");
  if (error) return mapRpcError(error);
  return data as StatusImportEvalyzeResponse;
}

export async function obterNudgeMensagens(
  supabase: SupabaseClient
): Promise<NudgeMensagensResponse> {
  const { data, error } = await supabase.rpc("obter_nudge_mensagens");
  if (error) return mapRpcError(error);
  return data as NudgeMensagensResponse;
}

export async function salvarNudgeMensagens(
  supabase: SupabaseClient,
  mensagens: string[]
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("salvar_nudge_mensagens", {
    p_mensagens: mensagens,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function obterDadosGestaoEquipa(
  supabase: SupabaseClient
): Promise<DadosGestaoEquipaResponse> {
  const { data, error } = await supabase.rpc("obter_dados_gestao_equipa");
  if (error) return mapRpcError(error);
  return data as DadosGestaoEquipaResponse;
}

export async function guardarUtilizador(
  supabase: SupabaseClient,
  dados: {
    emailOriginal: string;
    email: string;
    nome: string;
    pontoId: string | null;
    equipaId: string;
    perfilId: string | null;
    supervisorId?: string | null;
    exibirCardSala?: boolean;
    eResponsavelEquipa?: boolean;
  }
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("guardar_utilizador", {
    p_email_original: dados.emailOriginal || "",
    p_email: dados.email,
    p_nome: dados.nome,
    p_ponto_id: dados.pontoId || null,
    p_equipa_id: dados.equipaId,
    p_perfil_id: dados.perfilId || null,
    p_supervisor_id: dados.supervisorId || null,
    p_exibir_card_sala: dados.exibirCardSala ?? null,
    p_e_responsavel_equipa: dados.eResponsavelEquipa ?? null,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function eliminarUtilizador(
  supabase: SupabaseClient,
  email: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("eliminar_utilizador", {
    p_email: email,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function gerirPontoAtendimento(
  supabase: SupabaseClient,
  acao: "adicionar" | "editar" | "desactivar" | "activar",
  opts: { id?: string; nome?: string; codigo?: string }
): Promise<RpcBaseResponse & { id?: string }> {
  const { data, error } = await supabase.rpc("gerir_ponto_atendimento", {
    p_acao: acao,
    p_id: opts.id ?? null,
    p_nome: opts.nome ?? null,
    p_codigo: opts.codigo ?? null,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse & { id?: string };
}

export async function gerirSkill(
  supabase: SupabaseClient,
  acao: "adicionar" | "editar" | "desactivar" | "activar",
  opts: { id?: string; nome?: string; codigo?: string }
): Promise<RpcBaseResponse & { id?: string }> {
  const { data, error } = await supabase.rpc("gerir_skill", {
    p_acao: acao,
    p_id: opts.id ?? null,
    p_nome: opts.nome ?? null,
    p_codigo: opts.codigo ?? null,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse & { id?: string };
}

export async function obterRegrasFila(
  supabase: SupabaseClient
): Promise<RegrasFilaResponse> {
  const { data, error } = await supabase.rpc("obter_regras_fila");
  if (error) return mapRpcError(error);
  return data as RegrasFilaResponse;
}

export async function salvarRegrasFila(
  supabase: SupabaseClient,
  config: Record<string, unknown>
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("salvar_regras_fila", {
    p_config: config,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function obterAcessoAdminAreas(
  supabase: SupabaseClient
): Promise<AcessoAdminAreasResponse> {
  const { data, error } = await supabase.rpc("obter_acesso_admin_areas");
  if (error) return mapRpcError(error);
  return data as AcessoAdminAreasResponse;
}

export async function listarAreas(
  supabase: SupabaseClient
): Promise<ListarAreasResponse> {
  const { data, error } = await supabase.rpc("listar_areas");
  if (error) return mapRpcError(error);
  return data as ListarAreasResponse;
}

export async function criarArea(
  supabase: SupabaseClient,
  dados: {
    nome: string;
    slug: string;
    timezone: string;
    filtroLojaAtivo: boolean;
  }
): Promise<RpcBaseResponse & { id?: string; slug?: string }> {
  const { data, error } = await supabase.rpc("criar_area", {
    p_nome: dados.nome,
    p_slug: dados.slug,
    p_timezone: dados.timezone,
    p_filtro_loja_ativo: dados.filtroLojaAtivo,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse & { id?: string; slug?: string };
}

export async function actualizarArea(
  supabase: SupabaseClient,
  dados: {
    id: string;
    nome?: string;
    slug?: string;
    timezone?: string;
    ativo?: boolean;
  }
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("actualizar_area", {
    p_id: dados.id,
    p_nome: dados.nome ?? null,
    p_slug: dados.slug ?? null,
    p_timezone: dados.timezone ?? null,
    p_ativo: dados.ativo ?? null,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function desactivarArea(
  supabase: SupabaseClient,
  id: string
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("desactivar_area", { p_id: id });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}

export async function obterRegrasFilaArea(
  supabase: SupabaseClient,
  areaId: string
): Promise<RegrasFilaAreaResponse> {
  const { data, error } = await supabase.rpc("obter_regras_fila_area", {
    p_area_id: areaId,
  });
  if (error) return mapRpcError(error);
  return data as RegrasFilaAreaResponse;
}

export async function salvarRegrasFilaArea(
  supabase: SupabaseClient,
  areaId: string,
  config: RegrasFilaConfig
): Promise<RpcBaseResponse> {
  const { data, error } = await supabase.rpc("salvar_regras_fila_area", {
    p_area_id: areaId,
    p_config: config,
  });
  if (error) return mapRpcError(error);
  return data as RpcBaseResponse;
}
