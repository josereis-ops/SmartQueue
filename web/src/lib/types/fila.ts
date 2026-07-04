export interface TarefaAtribuida {
  id: string;
  idUnico: string;
  loja: string;
  canal: string | null;
  pn: string;
  observacoes: string;
  dataRqsIso: string | null;
  dataDespertadorIso: string | null;
  intercalar: string | null;
  prioridade_flash: boolean;
}

export interface AtribuirTarefaDiag {
  skills_operador?: number;
  filtro_loja_ativo?: boolean;
}

export interface AtribuirTarefaResponse {
  sucesso: boolean;
  mensagem?: string;
  codigo_erro?: string;
  recuperacao?: boolean;
  tarefa?: TarefaAtribuida;
  diag?: AtribuirTarefaDiag;
}

export interface PendenteItem {
  id: string;
  estado: string;
  rqs: string;
  agendamento: string;
  obsCompleta: string;
  obsTruncada: string;
  hasIntercalar: boolean;
  isRqsAtrasada: boolean;
}

export interface MeusPendentesResponse {
  sucesso: boolean;
  mensagem?: string;
  codigo_erro?: string;
  dados?: PendenteItem[];
}

export interface RpcBaseResponse {
  sucesso: boolean;
  mensagem?: string;
  codigo_erro?: string;
  ejetar?: boolean;
}

export type PresencaStatus =
  | "disponivel"
  | "atendimento_loja"
  | "pausa"
  | "refeicao"
  | "reuniao"
  | "trabalho_manual"
  | "atendimento_cc"
  | "formacao"
  | "trabalhos_spv"
  | "offline";

export const TODOS_ESTADOS_PRESENCA: PresencaStatus[] = [
  "disponivel",
  "atendimento_loja",
  "pausa",
  "refeicao",
  "reuniao",
  "trabalho_manual",
  "atendimento_cc",
  "formacao",
  "trabalhos_spv",
  "offline",
];

export const PRESENCA_LABELS: Record<PresencaStatus, string> = {
  disponivel: "Disponível",
  atendimento_loja: "Atendimento Loja",
  pausa: "Pausa",
  refeicao: "Refeição",
  reuniao: "Reunião",
  trabalho_manual: "Trabalho manual",
  atendimento_cc: "Atendimento cc",
  formacao: "Formação",
  trabalhos_spv: "Trabalhos SPV",
  offline: "Offline",
};

export const PRESENCA_EMOJI: Partial<Record<PresencaStatus, string>> = {
  disponivel: "🟢",
  atendimento_loja: "🏬",
  pausa: "🟡",
  refeicao: "🟠",
  reuniao: "🔵",
  trabalho_manual: "🔵",
  atendimento_cc: "🟣",
  formacao: "🟣",
  trabalhos_spv: "⚪",
  offline: "⚫",
};

export function presencaRecebeTarefa(p: PresencaStatus): boolean {
  return p === "disponivel";
}

export function presencaMantemCasoAtivo(p: PresencaStatus): boolean {
  return p === "disponivel" || p === "trabalho_manual";
}

export function classeBordaPresenca(p: PresencaStatus): string {
  switch (p) {
    case "disponivel":
      return "border-l-emerald-500";
    case "pausa":
      return "border-l-amber-500";
    case "refeicao":
      return "border-l-orange-500";
    case "reuniao":
    case "trabalho_manual":
      return "border-l-blue-500";
    case "atendimento_cc":
    case "formacao":
      return "border-l-purple-500";
    case "atendimento_loja":
      return "border-l-cyan-500";
    case "trabalhos_spv":
      return "border-l-white/40";
    case "offline":
      return "border-l-white/20 opacity-80";
    default:
      return "border-l-white/20";
  }
}

export function classeSelectPresenca(p: PresencaStatus): string {
  switch (p) {
    case "disponivel":
      return "border-emerald-500/40 bg-emerald-500/10 text-emerald-300";
    case "pausa":
      return "border-amber-500/40 bg-amber-500/10 text-amber-300";
    case "refeicao":
      return "border-orange-500/40 bg-orange-500/10 text-orange-300";
    case "offline":
      return "border-white/15 bg-input text-muted";
    default:
      return "border-brand/30 bg-brand/10 text-brand";
  }
}

export function parsePresencaStatus(raw: string | null | undefined): PresencaStatus {
  if (raw && TODOS_ESTADOS_PRESENCA.includes(raw as PresencaStatus)) {
    return raw as PresencaStatus;
  }
  return "offline";
}

/** Botões rápidos sidebar operador (GAS — sem Offline, fica no select topo) */
export const ESTADOS_SIDEBAR_OPERADOR: PresencaStatus[] = [
  "disponivel",
  "atendimento_loja",
  "pausa",
  "refeicao",
  "formacao",
  "atendimento_cc",
  "reuniao",
  "trabalho_manual",
  "trabalhos_spv",
];
