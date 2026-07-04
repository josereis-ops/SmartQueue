"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { formatarTmt } from "@/components/operador/tmt-timer";
import { forcarEstadoOperador } from "@/lib/api/supervisao";
import { createClient } from "@/lib/supabase/client";
import type { PresencaStatus } from "@/lib/types/fila";
import {
  classeBordaPresenca,
  classeSelectPresenca,
  parsePresencaStatus,
  presencaMantemCasoAtivo,
  PRESENCA_EMOJI,
  PRESENCA_LABELS,
  TODOS_ESTADOS_PRESENCA,
} from "@/lib/types/fila";
import type { AgenteSupervisao } from "@/lib/types/supervisao";

function LiveTmt({ inicioMs }: { inicioMs: number | null }) {
  const [seg, setSeg] = useState(0);
  useEffect(() => {
    if (!inicioMs) {
      setSeg(0);
      return;
    }
    const tick = () =>
      setSeg(Math.max(0, Math.floor((Date.now() - inicioMs) / 1000)));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [inicioMs]);
  if (!inicioMs) return null;
  const cor =
    seg >= 1800 ? "text-red-400" : seg >= 1200 ? "text-amber-400" : "text-emerald-400";
  return (
    <span className={`font-mono text-[10px] font-bold tabular-nums ${cor}`}>
      {formatarTmt(seg)}
    </span>
  );
}

function LiveEstadoTimer({ inicioMs }: { inicioMs: number | null }) {
  const [seg, setSeg] = useState(0);
  useEffect(() => {
    if (!inicioMs) {
      setSeg(0);
      return;
    }
    const tick = () =>
      setSeg(Math.max(0, Math.floor((Date.now() - inicioMs) / 1000)));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [inicioMs]);
  if (!inicioMs) return <span className="font-mono text-[10px] text-muted">00:00</span>;
  return (
    <span className="font-mono text-[10px] font-bold tabular-nums text-white">
      {formatarTmt(seg)}
    </span>
  );
}

interface TeamGridProps {
  agentes: AgenteSupervisao[];
  filtroNome: string;
  filtroEquipa: string;
  filtroLoja: string;
  estadosActivos: PresencaStatus[];
  onNudge: (agente: AgenteSupervisao) => void;
  onEstadoAlterado: () => void;
}

export function TeamGrid({
  agentes,
  filtroNome,
  filtroEquipa,
  filtroLoja,
  estadosActivos,
  onNudge,
  onEstadoAlterado,
}: TeamGridProps) {
  const supabase = createClient();
  const [aAlterar, setAAlterar] = useState<string | null>(null);
  const [erro, setErro] = useState("");
  const contextoSelect = useRef<
    Record<string, { valorInicial: PresencaStatus; mudou: boolean }>
  >({});

  const filtrados = useMemo(() => {
    return agentes.filter((a) => {
      const presenca = parsePresencaStatus(a.presenca);
      if (!estadosActivos.includes(presenca)) return false;
      if (filtroNome.trim()) {
        const q = filtroNome.toLowerCase();
        if (
          !a.nome.toLowerCase().includes(q) &&
          !a.email.toLowerCase().includes(q)
        ) {
          return false;
        }
      }
      if (filtroEquipa.trim()) {
        const q = filtroEquipa.toLowerCase();
        if (!(a.equipaOp || "").toLowerCase().includes(q)) return false;
      }
      if (filtroLoja.trim()) {
        const q = filtroLoja.toLowerCase();
        if (!(a.loja || "").toLowerCase().includes(q)) return false;
      }
      return true;
    });
  }, [agentes, filtroNome, filtroEquipa, filtroLoja, estadosActivos]);

  const lojas = useMemo(() => {
    const map: Record<
      string,
      { tratadas: number; concluidas: number; tempo: number; ativos: number }
    > = {};
    filtrados
      .filter((a) => !a.isSuper && a.loja)
      .forEach((a) => {
        if (!map[a.loja]) {
          map[a.loja] = { tratadas: 0, concluidas: 0, tempo: 0, ativos: 0 };
        }
        map[a.loja].tratadas += a.tratadas;
        map[a.loja].concluidas += a.concluidas;
        map[a.loja].tempo += a.tmtSegundos * a.tratadas;
        if (parsePresencaStatus(a.presenca) === "disponivel") {
          map[a.loja].ativos += 1;
        }
      });
    return Object.entries(map).sort(([a], [b]) => a.localeCompare(b));
  }, [filtrados]);

  const operadores = filtrados.filter((a) => !a.isSuper);
  const supervisores = filtrados.filter((a) => a.isSuper);

  const alterarEstado = async (
    agente: AgenteSupervisao,
    nova: PresencaStatus,
    reforco = false
  ) => {
    setAAlterar(agente.id);
    setErro("");
    const res = await forcarEstadoOperador(supabase, agente.id, nova, reforco);
    setAAlterar(null);
    if (res.sucesso) {
      onEstadoAlterado();
      return;
    }
    setErro(res.mensagem ?? "Erro ao alterar estado.");
  };

  const renderMiniCard = (agente: AgenteSupervisao) => {
    const presenca = parsePresencaStatus(agente.presenca);
    const hasCaso =
      Boolean(agente.casoAtivoId) && presencaMantemCasoAtivo(presenca);
    const busy = aAlterar === agente.id;

    return (
      <article
        key={agente.id}
        className={`flex flex-col rounded-lg border border-white/5 border-l-[3px] bg-black/25 p-2 ${classeBordaPresenca(presenca)} ${
          agente.isSuper ? "ring-1 ring-warning/20" : ""
        }`}
      >
        <div className="flex items-start justify-between gap-1">
          <div className="min-w-0 flex-1">
            <p className="truncate text-[11px] font-semibold text-white">
              {agente.isSuper && <span className="mr-0.5">👑</span>}
              {agente.nome}
            </p>
            <p className="truncate text-[9px] text-muted">
              {agente.loja || "—"} · {agente.equipaOp || "—"}
            </p>
          </div>
          <button
            type="button"
            onClick={() => onNudge(agente)}
            className="shrink-0 text-xs opacity-70 hover:opacity-100"
            title="Enviar toque"
          >
            🔔
          </button>
        </div>

        <label className="mt-1.5 block text-[9px] font-bold uppercase tracking-wide text-muted">
          Estado
        </label>
        <select
          value={presenca}
          disabled={busy}
          data-has-caso={hasCaso ? "1" : "0"}
          onFocus={() => {
            contextoSelect.current[agente.id] = {
              valorInicial: presenca,
              mudou: false,
            };
          }}
          onChange={(e) => {
            const nova = e.target.value as PresencaStatus;
            if (contextoSelect.current[agente.id]) {
              contextoSelect.current[agente.id].mudou = true;
            }
            void alterarEstado(agente, nova, false);
          }}
          onBlur={(e) => {
            const ctx = contextoSelect.current[agente.id];
            delete contextoSelect.current[agente.id];
            if (!ctx || ctx.mudou) return;
            if (e.currentTarget.getAttribute("data-has-caso") !== "1") return;
            const estadoActual = ctx.valorInicial;
            if (
              window.confirm(
                `Reforçar "${PRESENCA_LABELS[estadoActual]}"?\n\nPode desbloquear o caso activo.`
              )
            ) {
              void alterarEstado(agente, estadoActual, true);
            }
          }}
          className={`relative z-10 mt-0.5 w-full min-h-[30px] cursor-pointer appearance-auto rounded-lg border px-2 py-1.5 text-[10px] font-semibold outline-none transition focus:ring-2 focus:ring-brand/30 disabled:opacity-50 ${classeSelectPresenca(presenca)}`}
        >
          {TODOS_ESTADOS_PRESENCA.map((k) => (
            <option key={k} value={k} className="bg-[#0f1941] text-white">
              {PRESENCA_EMOJI[k] ? `${PRESENCA_EMOJI[k]} ` : ""}
              {PRESENCA_LABELS[k]}
            </option>
          ))}
        </select>

        <div className="mt-1 flex items-center justify-between">
          <LiveEstadoTimer inicioMs={agente.horaMudanca} />
          {hasCaso && (
            <div className="flex items-center gap-1 rounded bg-brand/10 px-1.5 py-0.5">
              <span className="font-mono text-[9px] font-bold text-brand">
                {agente.casoAtivoId}
              </span>
              <LiveTmt inicioMs={agente.casoAtivoTs} />
            </div>
          )}
        </div>

        <div className="mt-1.5 flex justify-between border-t border-white/5 pt-1 text-[9px] text-muted">
          <span>
            <strong className="text-white">{agente.tratadas}</strong> hoje
          </span>
          <span>
            <strong className="text-emerald-400">{agente.concluidas}</strong> conc
          </span>
          <span>
            TMT <strong className="text-brand">{agente.tmtFormatado}</strong>
          </span>
        </div>
      </article>
    );
  };

  if (filtrados.length === 0) {
    return (
      <p className="py-6 text-center text-xs text-muted">
        Nenhum colaborador corresponde aos filtros.
      </p>
    );
  }

  return (
    <div className="space-y-4">
      {erro && (
        <p className="rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-1.5 text-[10px] text-red-200">
          {erro}
        </p>
      )}

      {supervisores.length > 0 && (
        <section>
          <h3 className="mb-2 text-[10px] font-bold uppercase tracking-wider text-warning">
            👑 Supervisão
          </h3>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
            {supervisores.map(renderMiniCard)}
          </div>
        </section>
      )}

      {lojas.length > 0 && (
        <section>
          <h3 className="mb-2 text-[10px] font-bold uppercase tracking-wider text-purple-400">
            🏬 Pontos de atendimento
          </h3>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5">
            {lojas.map(([nome, d]) => {
              const tmt =
                d.tratadas > 0
                  ? formatarTmt(Math.floor(d.tempo / d.tratadas))
                  : "-:-";
              return (
                <div
                  key={nome}
                  className="rounded-lg border border-l-[3px] border-white/5 border-l-purple-500 bg-black/25 p-2"
                >
                  <p className="truncate text-[11px] font-semibold text-purple-300">
                    {nome}
                  </p>
                  <p className="text-[9px] text-muted">Activos: {d.ativos}</p>
                  <div className="mt-1 flex justify-between text-[9px]">
                    <span>
                      <strong className="text-white">{d.tratadas}</strong> hoje
                    </span>
                    <span>
                      <strong className="text-emerald-400">{d.concluidas}</strong> conc
                    </span>
                    <span>
                      TMT <strong className="text-brand">{tmt}</strong>
                    </span>
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      )}

      <section>
        <h3 className="mb-2 text-[10px] font-bold uppercase tracking-wider text-white">
          👨‍💻 Operação
        </h3>
        <div className="grid grid-cols-2 gap-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6">
          {operadores.map(renderMiniCard)}
        </div>
      </section>
    </div>
  );
}
