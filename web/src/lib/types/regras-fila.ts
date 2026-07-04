export type TierAplicavel = "scan" | "dono_ausente" | "libertar_14h";

export type ModoPontoAtendimento = "mesmo_ponto";

export type DesempateCampo = "agendamento" | "rqs" | "criado_em";

export type TierLivreSemRqs = "antiguidade";

export type TierLivreComRqs = "rqs_primeiro" | "antiguidade";

export interface MotorOrdenacaoConfig {
  usar_rqs: boolean;
  usar_flash: boolean;
  desempate: DesempateCampo[];
  tier_livre_sem_rqs: TierLivreSemRqs;
  tier_livre_com_rqs: TierLivreComRqs;
}

export interface MotorConfig {
  versao: 3;
  filtros_elegibilidade: {
    skill: {
      ativo: boolean;
      fonte: "utilizador_equipas";
    };
    ponto_atendimento: {
      ativo: boolean;
      modo: ModoPontoAtendimento;
      aplicar_tiers: TierAplicavel[];
    };
  };
  ordenacao: MotorOrdenacaoConfig;
  tiers_completos: boolean;
  libertar_14h: {
    ativo: boolean;
    hora: string;
    timezone: string;
  };
}

export interface RegrasFilaConfig {
  motor: MotorConfig;
  nudge_mensagens: string[];
}

export interface AreaItem {
  id: string;
  nome: string;
  slug: string;
  timezone: string;
  ativo: boolean;
  criado_em?: string;
}

export interface PermissoesAdminAreas {
  gerir_areas: boolean;
  gerir_regras: boolean;
  multi_area: boolean;
}

export interface AcessoAdminAreasResponse {
  sucesso: boolean;
  mensagem?: string;
  permissoes?: PermissoesAdminAreas;
  area_id?: string;
}

export interface ListarAreasResponse {
  sucesso: boolean;
  mensagem?: string;
  areas?: AreaItem[];
}

export interface RegrasFilaAreaResponse {
  sucesso: boolean;
  mensagem?: string;
  area_id?: string;
  config?: RegrasFilaConfig;
}

export const DESEMPATE_CAMPOS: { id: DesempateCampo; label: string }[] = [
  { id: "agendamento", label: "Data agendamento / despertador" },
  { id: "rqs", label: "Urgência RQS (hoje, sem intercalar)" },
  { id: "criado_em", label: "Antiguidade (criado_em)" },
];

export const TIERS_DISPONIVEIS: { id: TierAplicavel; label: string; descricao: string }[] = [
  {
    id: "scan",
    label: "Flash / scan",
    descricao: "Casos com prioridade flash — operador só vê os da sua loja",
  },
  {
    id: "dono_ausente",
    label: "Dono ausente",
    descricao: "Casos cujo dono está offline há 3+ dias",
  },
  {
    id: "libertar_14h",
    label: "Libertar 14h",
    descricao: "Casos RQS libertados após a hora configurada",
  },
];

export const TIMEZONES_COMUNS = [
  "Europe/Lisbon",
  "Europe/London",
  "Europe/Madrid",
  "Europe/Paris",
  "Atlantic/Azores",
  "UTC",
] as const;

export function defaultMotorOrdenacao(): MotorOrdenacaoConfig {
  return {
    usar_rqs: true,
    usar_flash: true,
    desempate: ["agendamento", "rqs", "criado_em"],
    tier_livre_sem_rqs: "antiguidade",
    tier_livre_com_rqs: "rqs_primeiro",
  };
}

export function defaultRegrasFilaConfig(
  filtroLojaAtivo = false,
  timezone = "Europe/Lisbon"
): RegrasFilaConfig {
  return {
    motor: {
      versao: 3,
      filtros_elegibilidade: {
        skill: { ativo: true, fonte: "utilizador_equipas" },
        ponto_atendimento: {
          ativo: filtroLojaAtivo,
          modo: "mesmo_ponto",
          aplicar_tiers: ["scan", "dono_ausente", "libertar_14h"],
        },
      },
      ordenacao: defaultMotorOrdenacao(),
      tiers_completos: true,
      libertar_14h: { ativo: true, hora: "14:00", timezone },
    },
    nudge_mensagens: [],
  };
}

function parseDesempate(raw: unknown): DesempateCampo[] {
  const defaults = defaultMotorOrdenacao().desempate;
  if (!Array.isArray(raw)) return defaults;
  const parsed = raw.filter((t): t is DesempateCampo =>
    ["agendamento", "rqs", "criado_em"].includes(String(t))
  );
  return parsed.length > 0 ? parsed : defaults;
}

export function parseRegrasFilaConfig(raw: unknown): RegrasFilaConfig {
  const base = defaultRegrasFilaConfig();
  if (!raw || typeof raw !== "object") return base;

  const obj = raw as Record<string, unknown>;
  const motor = (obj.motor ?? {}) as Record<string, unknown>;
  const filtros = (motor.filtros_elegibilidade ?? {}) as Record<string, unknown>;
  const skill = (filtros.skill ?? {}) as Record<string, unknown>;
  const ponto = (filtros.ponto_atendimento ?? {}) as Record<string, unknown>;
  const libertar = (motor.libertar_14h ?? {}) as Record<string, unknown>;
  const ordenacao = (motor.ordenacao ?? {}) as Record<string, unknown>;

  const tiersRaw = ponto.aplicar_tiers;
  const tiers: TierAplicavel[] = Array.isArray(tiersRaw)
    ? tiersRaw.filter((t): t is TierAplicavel =>
        ["scan", "dono_ausente", "libertar_14h"].includes(String(t))
      )
    : base.motor.filtros_elegibilidade.ponto_atendimento.aplicar_tiers;

  const nudgesRaw = obj.nudge_mensagens;
  const nudges = Array.isArray(nudgesRaw)
    ? nudgesRaw.map(String).filter(Boolean)
    : [];

  const tierLivreComRqs = String(ordenacao.tier_livre_com_rqs ?? "rqs_primeiro");
  const tierLivreSemRqs = String(ordenacao.tier_livre_sem_rqs ?? "antiguidade");

  return {
    motor: {
      versao: 3,
      filtros_elegibilidade: {
        skill: {
          ativo: skill.ativo !== false,
          fonte: "utilizador_equipas",
        },
        ponto_atendimento: {
          ativo: ponto.ativo === true,
          modo: "mesmo_ponto",
          aplicar_tiers: tiers,
        },
      },
      ordenacao: {
        usar_rqs: ordenacao.usar_rqs !== false,
        usar_flash: ordenacao.usar_flash !== false,
        desempate: parseDesempate(ordenacao.desempate),
        tier_livre_sem_rqs:
          tierLivreSemRqs === "antiguidade" ? "antiguidade" : "antiguidade",
        tier_livre_com_rqs:
          tierLivreComRqs === "antiguidade" ? "antiguidade" : "rqs_primeiro",
      },
      tiers_completos: motor.tiers_completos !== false,
      libertar_14h: {
        ativo: libertar.ativo !== false,
        hora: String(libertar.hora ?? "14:00"),
        timezone: String(libertar.timezone ?? "Europe/Lisbon"),
      },
    },
    nudge_mensagens: nudges,
  };
}
