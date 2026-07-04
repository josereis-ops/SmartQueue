"use client";

import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { obterDadosSupervisao } from "@/lib/api/supervisao";
import type { UtilizadorPerfil } from "@/lib/types/perfil";
import type { PresencaStatus } from "@/lib/types/fila";
import {
  classeSelectPresenca,
  parsePresencaStatus,
  PRESENCA_EMOJI,
  PRESENCA_LABELS,
  TODOS_ESTADOS_PRESENCA,
} from "@/lib/types/fila";
import { atualizarPresenca } from "@/lib/api/fila";
import type {
  AgenteSupervisao,
  CasoSupervisao,
  DadosSupervisaoResponse,
  DrillDownTipo,
  FilaSupervisao,
} from "@/lib/types/supervisao";
import { SignOutButton } from "@/components/sign-out-button";
import { KpiCards } from "@/components/supervisor/kpi-cards";
import { TeamGrid } from "@/components/supervisor/team-grid";
import { CasoDrilldownModal } from "@/components/supervisor/caso-drilldown-modal";
import { NudgeModal } from "@/components/supervisor/nudge-modal";
import { SupervisorSidebar } from "@/components/supervisor/supervisor-sidebar";
import { SkillsManagerPanel } from "@/components/supervisor/skills-manager-panel";
import { EquipePanel } from "@/components/supervisor/equipe-panel";
import { ObjetivosPanel } from "@/components/supervisor/objetivos-panel";
import { ImportGridPanel } from "@/components/supervisor/import-grid-panel";
import { EvalyzeImportPanel } from "@/components/supervisor/evalyze-import-panel";
import { AreasRegrasPanel } from "@/components/supervisor/areas-regras-panel";
import type { PainelSupervisor } from "@/lib/types/gestor";
import { obterAcessoAdminAreas } from "@/lib/api/gestor";

interface SupervisorDashboardProps {
  perfil: UtilizadorPerfil;
}

const PAINEL_TITULOS: Record<PainelSupervisor, string> = {
  controlo: "Sala de Controlo",
  equipa: "Gestão de Equipa",
  skills: "Gestor de Skills",
  objetivos: "Gestor Objetivos",
  import: "Importar Casos",
  areas: "Áreas & Regras",
};

/** Fallback client-side enquanto a RPC MS-15 não está aplicada. */
function perfilTemAcessoAdmin(perfil: UtilizadorPerfil): boolean {
  return perfil.perfil_slug === "developer" || perfil.perfil_slug === "admin";
}

const FILA_VAZIA: FilaSupervisao = {
  livres: 0,
  emTratamento: 0,
  suspensos: 0,
  carteira: 0,
  outro: 0,
  atrasadosLivres: 0,
  atrasadosTrabalho: 0,
  rqsUltrapassadasLivres: 0,
  rqsUltrapassadasTrabalho: 0,
  rqsHojeLivres: 0,
  rqsHojeTrabalho: 0,
  tratadasDia: 0,
  concluidasDia: 0,
  tmtGlobal: "00:00",
  listaAtrasados: [],
  listaRqsUltrapassadas: [],
  listaRqsHoje: [],
  listaLivres: [],
  listaTodos: [],
  listaOutro: [],
};

function listaDrillDown(
  fila: FilaSupervisao,
  tipo: DrillDownTipo
): CasoSupervisao[] {
  switch (tipo) {
    case "atrasados":
      return fila.listaAtrasados;
    case "ultrapassadas":
      return fila.listaRqsUltrapassadas;
    case "hoje":
      return fila.listaRqsHoje;
    case "livres":
      return fila.listaLivres;
    case "carteira":
      return fila.listaTodos;
    case "outro":
      return fila.listaOutro;
    default:
      return [];
  }
}

export function SupervisorDashboard({ perfil }: SupervisorDashboardProps) {
  const supabase = createClient();
  const presencaInicial = parsePresencaStatus(perfil.presenca);
  const presencaRef = useRef(presencaInicial);
  const [presenca, setPresenca] = useState<PresencaStatus>(presencaInicial);
  const [aAlterarPresenca, setAAlterarPresenca] = useState(false);
  const [erroPresenca, setErroPresenca] = useState("");
  const [dados, setDados] = useState<DadosSupervisaoResponse | null>(null);
  const [aCarregar, setACarregar] = useState(true);
  const [erro, setErro] = useState("");
  const [filtroEquipas, setFiltroEquipas] = useState<string[]>([]);
  const [filtroNome, setFiltroNome] = useState("");
  const [filtroEquipa, setFiltroEquipa] = useState("");
  const [filtroLoja, setFiltroLoja] = useState("");
  const [estadosActivos, setEstadosActivos] = useState<PresencaStatus[]>([
    ...TODOS_ESTADOS_PRESENCA,
  ]);
  const [drillDown, setDrillDown] = useState<{
    tipo: DrillDownTipo;
    titulo: string;
  } | null>(null);
  const [nudgeAlvo, setNudgeAlvo] = useState<AgenteSupervisao | null>(null);
  const [painel, setPainel] = useState<PainelSupervisor>("controlo");
  const [subImport, setSubImport] = useState<"evalyze" | "grelha">("evalyze");
  const [mostrarAdminAreas, setMostrarAdminAreas] = useState(() =>
    perfilTemAcessoAdmin(perfil)
  );

  useEffect(() => {
    void obterAcessoAdminAreas(supabase).then((res) => {
      if (res.sucesso) {
        setMostrarAdminAreas(true);
        return;
      }
      if (!perfilTemAcessoAdmin(perfil)) {
        setMostrarAdminAreas(false);
      }
    });
  }, [supabase, perfil]);

  const carregar = useCallback(async (silencioso = false) => {
    if (!silencioso) setACarregar(true);
    const res = await obterDadosSupervisao(
      supabase,
      filtroEquipas.length > 0 ? filtroEquipas : undefined
    );
    if (!silencioso) setACarregar(false);
    if (res.sucesso) {
      setDados(res);
      setErro("");
      return;
    }
    if (!silencioso) {
      setErro(
        res.mensagem?.includes("obter_dados_supervisao")
          ? "A RPC obter_dados_supervisao ainda não está no Supabase. Aplica as migrations pendentes: supabase db push (ou executa os ficheiros 20260703240000 e 20260703250000 no SQL Editor do dashboard)."
          : (res.mensagem ?? "Erro ao carregar Sala de Controlo.")
      );
    }
  }, [supabase, filtroEquipas]);

  useEffect(() => {
    if (painel === "controlo") void carregar();
  }, [carregar, painel]);

  useEffect(() => {
    if (painel !== "controlo") return;

    const canal = supabase
      .channel("supervisor-realtime")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "casos" },
        () => void carregar(true)
      )
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "utilizadores" },
        () => void carregar(true)
      )
      .subscribe();

    const intervalo = setInterval(() => void carregar(true), 30000);

    return () => {
      supabase.removeChannel(canal);
      clearInterval(intervalo);
    };
  }, [supabase, carregar, painel]);

  const fila = dados?.fila ?? FILA_VAZIA;
  const equipa = dados?.equipa ?? [];
  const equipasMaster = dados?.equipasMaster ?? [];

  const casosDrillDown = useMemo(
    () => (drillDown ? listaDrillDown(fila, drillDown.tipo) : []),
    [drillDown, fila]
  );

  const toggleEquipa = (id: string) => {
    setFiltroEquipas((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]
    );
  };

  const toggleEstado = (est: PresencaStatus) => {
    setEstadosActivos((prev) =>
      prev.includes(est) ? prev.filter((x) => x !== est) : [...prev, est]
    );
  };

  const mudarPresenca = async (nova: PresencaStatus) => {
    if (nova === presencaRef.current) return;
    setAAlterarPresenca(true);
    setErroPresenca("");
    const res = await atualizarPresenca(supabase, perfil.id, nova);
    setAAlterarPresenca(false);
    if (res.sucesso) {
      presencaRef.current = nova;
      setPresenca(nova);
      if (painel === "controlo") void carregar(true);
      return;
    }
    setErroPresenca(res.mensagem ?? "Erro ao alterar o teu estado.");
  };

  return (
    <div className="min-h-screen overflow-x-hidden bg-navy">
      <header className="border-b border-white/10 bg-card/80 backdrop-blur-md">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center justify-between gap-4 px-4 py-4 sm:px-6">
          <div className="flex min-w-0 items-center gap-4">
            <Image
              src="/randstad-logo.svg"
              alt="Randstad"
              width={140}
              height={32}
              priority
              className="h-8 w-auto shrink-0"
            />
            <div className="hidden h-8 w-px shrink-0 bg-white/10 sm:block" />
            <div className="min-w-0">
              <p className="text-[10px] font-bold uppercase tracking-widest text-brand">
                {PAINEL_TITULOS[painel]}
              </p>
              <p className="text-sm font-semibold text-white">
                {perfil.nome.split(" ")[0]}
                <span className="ml-2 font-normal text-muted">· {perfil.area}</span>
              </p>
            </div>
          </div>

          <div className="flex flex-wrap items-center gap-2">
            <select
              value={presenca}
              disabled={aAlterarPresenca}
              onChange={(e) => void mudarPresenca(e.target.value as PresencaStatus)}
              title="O teu estado de presença"
              className={`rounded-xl border px-3 py-2 text-xs font-semibold outline-none transition disabled:opacity-50 sm:px-4 sm:py-2.5 sm:text-sm ${classeSelectPresenca(presenca)}`}
            >
              {TODOS_ESTADOS_PRESENCA.map((k) => (
                <option key={k} value={k} className="bg-card text-white">
                  {PRESENCA_EMOJI[k] ? `${PRESENCA_EMOJI[k]} ` : ""}
                  {PRESENCA_LABELS[k]}
                </option>
              ))}
            </select>
            <Link
              href="/operador"
              className="rounded-xl border border-white/15 px-4 py-2 text-xs font-semibold text-muted transition hover:border-brand/40 hover:text-white"
            >
              Modo operador
            </Link>
            {painel === "controlo" && (
              <button
                type="button"
                onClick={() => void carregar()}
                disabled={aCarregar}
                className="rounded-xl border border-brand/30 bg-brand/10 px-4 py-2 text-xs font-bold text-brand transition hover:bg-brand/20 disabled:opacity-50"
              >
                {aCarregar ? "A actualizar…" : "Actualizar"}
              </button>
            )}
            <SignOutButton />
          </div>
        </div>
      </header>

      {erroPresenca && (
        <p className="mx-auto max-w-7xl px-4 pt-2 text-xs text-red-300 sm:px-6">
          {erroPresenca}
        </p>
      )}

      <div className="mx-auto flex max-w-7xl flex-col gap-4 px-3 py-4 sm:px-4 sm:py-5 lg:flex-row lg:items-start">
        <SupervisorSidebar
          painel={painel}
          onPainel={setPainel}
          onActualizar={() => void carregar()}
          aCarregar={aCarregar}
          mostrarAdminAreas={mostrarAdminAreas}
        />

        <main className="min-w-0 flex-1 space-y-3 overflow-x-hidden">
          {painel === "controlo" && (
            <>
              {erro && (
                <p className="rounded-xl border border-red-500/30 bg-red-500/10 px-4 py-3 text-sm text-red-200">
                  {erro}
                </p>
              )}

              {equipasMaster.length > 0 && (
                <section className="rounded-lg border border-white/10 bg-black/20 p-3">
                  <p className="mb-2 text-[9px] font-bold uppercase tracking-widest text-muted">
                    Filtrar casos por skill
                  </p>
                  <div className="flex flex-wrap gap-1.5">
                    {equipasMaster.map((eq) => {
                      const activo = filtroEquipas.includes(eq.id);
                      return (
                        <button
                          key={eq.id}
                          type="button"
                          onClick={() => toggleEquipa(eq.id)}
                          className={`rounded-full px-2.5 py-1 text-[10px] font-semibold transition ${
                            activo
                              ? "bg-brand text-white"
                              : "bg-input text-muted hover:text-white"
                          }`}
                        >
                          {eq.nome}
                        </button>
                      );
                    })}
                    {filtroEquipas.length > 0 && (
                      <button
                        type="button"
                        onClick={() => setFiltroEquipas([])}
                        className="rounded-full px-2.5 py-1 text-[10px] text-muted hover:text-white"
                      >
                        Limpar
                      </button>
                    )}
                  </div>
                </section>
              )}

              <KpiCards
                fila={fila}
                onDrillDown={(tipo, titulo) => setDrillDown({ tipo, titulo })}
              />

              <section className="rounded-lg border border-white/10 bg-black/20 p-3">
                <p className="mb-2 text-[9px] font-bold uppercase tracking-widest text-brand">
                  Filtros grelha
                </p>
                <div className="mb-2 flex flex-wrap gap-2">
                  <input
                    type="search"
                    value={filtroNome}
                    onChange={(e) => setFiltroNome(e.target.value)}
                    placeholder="Nome…"
                    className="min-w-[100px] flex-1 rounded-lg border border-white/10 bg-input px-2 py-1.5 text-[11px] text-white outline-none focus:border-brand/50"
                  />
                  <input
                    type="search"
                    value={filtroEquipa}
                    onChange={(e) => setFiltroEquipa(e.target.value)}
                    placeholder="Skill…"
                    className="min-w-[100px] flex-1 rounded-lg border border-white/10 bg-input px-2 py-1.5 text-[11px] text-white outline-none focus:border-brand/50"
                  />
                  <input
                    type="search"
                    value={filtroLoja}
                    onChange={(e) => setFiltroLoja(e.target.value)}
                    placeholder="P. atendimento…"
                    className="min-w-[100px] flex-1 rounded-lg border border-white/10 bg-input px-2 py-1.5 text-[11px] text-white outline-none focus:border-brand/50"
                  />
                </div>
                <div className="flex flex-wrap gap-1.5">
                  {TODOS_ESTADOS_PRESENCA.map((est) => {
                    const activo = estadosActivos.includes(est);
                    return (
                      <button
                        key={est}
                        type="button"
                        onClick={() => toggleEstado(est)}
                        className={`rounded-full border px-2 py-0.5 text-[10px] font-semibold transition ${
                          activo
                            ? "border-brand/40 bg-brand/15 text-brand"
                            : "border-white/10 text-muted line-through opacity-50"
                        }`}
                      >
                        {PRESENCA_EMOJI[est] ?? ""} {PRESENCA_LABELS[est]}
                      </button>
                    );
                  })}
                </div>
              </section>

              <section className="rounded-lg border border-white/10 bg-black/20 p-3">
                <h2 className="mb-3 text-[10px] font-bold uppercase tracking-widest text-white">
                  Equipa em tempo real
                </h2>
                <TeamGrid
                  agentes={equipa}
                  filtroNome={filtroNome}
                  filtroEquipa={filtroEquipa}
                  filtroLoja={filtroLoja}
                  estadosActivos={estadosActivos}
                  onNudge={setNudgeAlvo}
                  onEstadoAlterado={() => void carregar(true)}
                />
              </section>
            </>
          )}

          {painel === "equipa" && (
            <section className="rounded-lg border border-white/10 bg-black/20 p-4">
              <EquipePanel
                supabase={supabase}
                onAbrirAdminRegras={
                  mostrarAdminAreas
                    ? () => setPainel("areas")
                    : undefined
                }
              />
            </section>
          )}

          {painel === "skills" && (
            <section className="rounded-lg border border-white/10 bg-black/20 p-4">
              <SkillsManagerPanel supabase={supabase} />
            </section>
          )}

          {painel === "objetivos" && (
            <section className="rounded-lg border border-white/10 bg-black/20 p-4">
              <ObjetivosPanel supabase={supabase} />
            </section>
          )}

          {painel === "import" && (
            <section className="rounded-lg border border-white/10 bg-black/20 p-4">
              <div className="mb-4 flex flex-wrap gap-2 border-b border-white/10 pb-3">
                <button
                  type="button"
                  onClick={() => setSubImport("evalyze")}
                  className={`rounded-lg px-4 py-2 text-xs font-bold transition ${
                    subImport === "evalyze"
                      ? "bg-brand/20 text-brand"
                      : "text-muted hover:bg-white/5 hover:text-white"
                  }`}
                >
                  ⚡ Importação Evalyze
                </button>
                <button
                  type="button"
                  onClick={() => setSubImport("grelha")}
                  className={`rounded-lg px-4 py-2 text-xs font-bold transition ${
                    subImport === "grelha"
                      ? "bg-brand/20 text-brand"
                      : "text-muted hover:bg-white/5 hover:text-white"
                  }`}
                >
                  📥 Grelha Excel (manual)
                </button>
              </div>
              {subImport === "evalyze" ? (
                <EvalyzeImportPanel supabase={supabase} />
              ) : (
                <ImportGridPanel
                  supabase={supabase}
                  onVoltar={() => setSubImport("evalyze")}
                />
              )}
            </section>
          )}

          {painel === "areas" && mostrarAdminAreas && (
            <AreasRegrasPanel
              supabase={supabase}
              areaIdUtilizador={perfil.area_id}
            />
          )}
        </main>
      </div>

      <CasoDrilldownModal
        aberto={!!drillDown}
        titulo={drillDown?.titulo ?? ""}
        casos={casosDrillDown}
        agentes={equipa}
        equipas={equipasMaster}
        supabase={supabase}
        onFechar={() => setDrillDown(null)}
        onActualizado={() => void carregar()}
      />

      <NudgeModal
        aberto={!!nudgeAlvo}
        agente={nudgeAlvo}
        supabase={supabase}
        onFechar={() => setNudgeAlvo(null)}
      />
    </div>
  );
}
