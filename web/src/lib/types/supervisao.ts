import type { RpcBaseResponse } from "@/lib/types/fila";

export interface EquipaMaster {
  id: string;
  nome: string;
  codigo: string;
}

export interface CasoSupervisao {
  id: string;
  caso_id: string;
  skill: string;
  equipa_id: string;
  equipa: string;
  criacao: string;
  rqs: string;
  agendIso: string;
  estado: string;
  status: string;
  resp: string;
  resp_email: string;
  colaborador_id: string | null;
  obsCompleta: string;
  obsTruncada: string;
  intercalar: string;
  prioridade: string;
  prioridade_flash: boolean;
  inicio_tratamento: string | null;
}

export interface FilaSupervisao {
  livres: number;
  emTratamento: number;
  suspensos: number;
  carteira: number;
  outro: number;
  atrasadosLivres: number;
  atrasadosTrabalho: number;
  rqsUltrapassadasLivres: number;
  rqsUltrapassadasTrabalho: number;
  rqsHojeLivres: number;
  rqsHojeTrabalho: number;
  tratadasDia: number;
  concluidasDia: number;
  tmtGlobal: string;
  listaAtrasados: CasoSupervisao[];
  listaRqsUltrapassadas: CasoSupervisao[];
  listaRqsHoje: CasoSupervisao[];
  listaLivres: CasoSupervisao[];
  listaTodos: CasoSupervisao[];
  listaOutro: CasoSupervisao[];
}

export interface AgenteSupervisao {
  id: string;
  email: string;
  nome: string;
  loja: string;
  equipaOp: string;
  estado: string;
  presenca: string;
  horaMudanca: number;
  tratadas: number;
  concluidas: number;
  tmtFormatado: string;
  tmtSegundos: number;
  isSuper: boolean;
  perfilSlug?: string;
  supervisorId?: string | null;
  casoAtivoId: string | null;
  casoAtivoCasoId: string | null;
  casoAtivoTs: number | null;
}

export interface DadosSupervisaoResponse extends RpcBaseResponse {
  equipa?: AgenteSupervisao[];
  fila?: FilaSupervisao;
  equipasMaster?: EquipaMaster[];
}

export type DrillDownTipo =
  | "atrasados"
  | "ultrapassadas"
  | "hoje"
  | "livres"
  | "carteira"
  | "outro";

export interface DrilldownSupervisaoResponse extends RpcBaseResponse {
  total?: number;
  offset?: number;
  limit?: number;
  casos?: CasoSupervisao[];
}
