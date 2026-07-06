import type { RpcBaseResponse } from "@/lib/types/fila";

export interface SkillItem {
  id: string;
  nome: string;
  codigo: string;
  ativo?: boolean;
}

export interface GestorUser {
  email: string;
  nome: string;
  skills: string[];
}

export interface DadosGestorSkillsResponse extends RpcBaseResponse {
  users?: GestorUser[];
  skills?: SkillItem[];
}

export interface ObjetivoLoja {
  loja: string;
  objetivo: number;
}

export interface ObjetivosEdicaoResponse extends RpcBaseResponse {
  dados?: ObjetivoLoja[];
}

export interface IdsImportacaoResponse extends RpcBaseResponse {
  ids?: string[];
}

export interface ImportarCasosResponse extends RpcBaseResponse {
  inseridos?: number;
  falhas?: { linha: number; id: string; erros: string[] }[];
}

export interface NudgeMensagensResponse extends RpcBaseResponse {
  mensagens?: string[];
}

/** 17 colunas GAS: Loja, ID, Canal, Email, PN, Criação, RQS, Intercalar, Obs, Estado, Responsável, Hora Início, Agendamento, Distribuição, Skill, Prioridade, Contacto Aux */
export type LinhaImportacao = string[];

export const COLUNAS_IMPORT = [
  "Loja",
  "ID CASO",
  "Canal",
  "Email",
  "PN",
  "Criação",
  "RQS",
  "Intercalar",
  "Observações",
  "Estado",
  "Responsável",
  "Hora Início",
  "Agendamento",
  "Distribuição",
  "Skill",
  "Prioridade",
  "Contacto Aux.",
] as const;

export interface PontoAtendimentoItem {
  id: string;
  nome: string;
  codigo: string;
  ativo: boolean;
}

export interface PerfilItem {
  id: string;
  nome: string;
  slug: string;
  is_system: boolean;
  utilizadores: number;
}

export interface UtilizadorEquipa {
  id: string;
  email: string;
  nome: string;
  ponto_atendimento_id: string | null;
  ponto_nome: string | null;
  equipa_id: string;
  equipa_nome: string;
  perfil_id: string | null;
  perfil_nome: string;
  perfil_slug: string;
  role: string;
  tem_auth: boolean;
  supervisor_id: string | null;
  supervisor_nome: string | null;
}

export interface PermissoesGestaoEquipa {
  gerir_utilizadores: boolean;
  gerir_equipas: boolean;
  gerir_regras: boolean;
  gerir_perfis: boolean;
}

export interface DadosGestaoEquipaResponse extends RpcBaseResponse {
  utilizadores?: UtilizadorEquipa[];
  pontos?: PontoAtendimentoItem[];
  skills?: SkillItem[];
  perfis?: PerfilItem[];
  regras_fila?: Record<string, unknown>;
  permissoes?: PermissoesGestaoEquipa;
}

export interface RegrasFilaResponse extends RpcBaseResponse {
  config?: Record<string, unknown>;
}

export type TabGestaoEquipa =
  | "utilizadores"
  | "pontos"
  | "skills"
  | "perfis"
  | "regras";

export type PainelSupervisor =
  | "controlo"
  | "equipa"
  | "skills"
  | "objetivos"
  | "import"
  | "areas";

export interface ImportEvalyzeResponse extends RpcBaseResponse {
  importados?: number;
  duplicados?: number;
  ignoradosCampos?: number;
  log_id?: string;
}

export interface UltimaImportEvalyze {
  id: string;
  executado_em: string;
  origem: string;
  sucesso: boolean;
  importados: number;
  duplicados: number;
  ignoradosCampos: number;
  mensagem: string | null;
  duracao_ms: number | null;
}

export interface StatusImportEvalyzeResponse extends RpcBaseResponse {
  ultima?: UltimaImportEvalyze | null;
}
