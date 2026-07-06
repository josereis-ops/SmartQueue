"use client";

import { useCallback, useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  adicionarObservacaoSupervisao,
  alterarAgendamentoSupervisao,
  alterarEquipaCasoSupervisao,
  alterarEstadoCasoSupervisao,
  alterarPrioridadeFlash,
  concluirCasoDiretoSupervisao,
  obterCasosSupervisaoDrilldown,
  reatribuirCaso,
} from "@/lib/api/supervisao";
import type {
  AgenteSupervisao,
  CasoSupervisao,
  DrillDownTipo,
  EquipaMaster,
} from "@/lib/types/supervisao";
import { ConfirmModal } from "@/components/ui/confirm-modal";

interface CasoDrilldownModalProps {
  aberto: boolean;
  titulo: string;
  tipo: DrillDownTipo | null;
  equipasFiltro: string[];
  agentes: AgenteSupervisao[];
  equipas: EquipaMaster[];
  supabase: SupabaseClient;
  onFechar: () => void;
  onActualizado: () => void;
}

const ESTADOS_OPCOES: { value: string; label: string }[] = [
  { value: "livre", label: "Livre" },
  { value: "pendente", label: "Pendente" },
  { value: "por_tratar", label: "Por tratar" },
  { value: "agendado", label: "Agendado" },
  { value: "suspenso", label: "Suspenso" },
  { value: "outro", label: "Outro" },
];

const PAGE_SIZE = 100;

interface PendingAction {
  titulo: string;
  descricao: string;
  executar: () => Promise<void>;
}

type RpcRes = { sucesso: boolean; mensagem?: string };

type SortCol =
  | "id"
  | "criacao"
  | "rqs"
  | "skill"
  | "estado"
  | "agendIso"
  | "resp"
  | "prioridade"
  | "obs";

function sortColRpc(col: SortCol): string {
  if (col === "agendIso") return "agendiso";
  return col;
}

export function CasoDrilldownModal({
  aberto,
  titulo,
  tipo,
  equipasFiltro,
  agentes,
  equipas,
  supabase,
  onFechar,
  onActualizado,
}: CasoDrilldownModalProps) {
  const [pesquisa, setPesquisa] = useState("");
  const [pesquisaDebounced, setPesquisaDebounced] = useState("");
  const [aProcessar, setAProcessar] = useState<string | null>(null);
  const [mensagem, setMensagem] = useState("");
  const [notaCaso, setNotaCaso] = useState<CasoSupervisao | null>(null);
  const [textoNota, setTextoNota] = useState("");
  const [aGravarNota, setAGravarNota] = useState(false);
  const [confirmacao, setConfirmacao] = useState<PendingAction | null>(null);
  const [sortCol, setSortCol] = useState<SortCol>("id");
  const [sortAsc, setSortAsc] = useState(true);
  const [pagina, setPagina] = useState(0);
  const [casos, setCasos] = useState<CasoSupervisao[]>([]);
  const [total, setTotal] = useState(0);
  const [aCarregar, setACarregar] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  useEffect(() => {
    if (!aberto) return;
    setPesquisa("");
    setPesquisaDebounced("");
    setPagina(0);
    setSortCol("id");
    setSortAsc(true);
    setMensagem("");
  }, [aberto, tipo]);

  useEffect(() => {
    if (!aberto) return;
    const t = setTimeout(() => setPesquisaDebounced(pesquisa), 300);
    return () => clearTimeout(t);
  }, [pesquisa, aberto]);

  useEffect(() => {
    setPagina(0);
  }, [pesquisaDebounced, sortCol, sortAsc, tipo, equipasFiltro]);

  const carregarPagina = useCallback(async () => {
    if (!aberto || !tipo) return;
    setACarregar(true);
    setMensagem("");
    const res = await obterCasosSupervisaoDrilldown(supabase, {
      tipo,
      offset: pagina * PAGE_SIZE,
      limit: PAGE_SIZE,
      equipasFiltro: equipasFiltro.length > 0 ? equipasFiltro : undefined,
      pesquisa: pesquisaDebounced || undefined,
      sortCol: sortColRpc(sortCol),
      sortAsc,
    });
    setACarregar(false);
    if (res.sucesso) {
      setCasos(res.casos ?? []);
      setTotal(res.total ?? 0);
      return;
    }
    setCasos([]);
    setTotal(0);
    setMensagem(res.mensagem ?? "Erro ao carregar casos.");
  }, [
    aberto,
    tipo,
    supabase,
    pagina,
    equipasFiltro,
    pesquisaDebounced,
    sortCol,
    sortAsc,
  ]);

  useEffect(() => {
    void carregarPagina();
  }, [carregarPagina, refreshKey]);

  const operadores = agentes.filter(
    (a) => a.perfilSlug === "colaborador" || (!a.perfilSlug && !a.isSuper)
  );

  const totalPaginas = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const paginaActual = Math.min(pagina, totalPaginas - 1);
  const inicio = paginaActual * PAGE_SIZE;

  const toggleSort = (col: SortCol) => {
    if (sortCol === col) {
      setSortAsc((v) => !v);
    } else {
      setSortCol(col);
      setSortAsc(true);
    }
  };

  const thSort = (col: SortCol, extra = "") =>
    `cursor-pointer select-none hover:text-white ${sortCol === col ? "text-brand" : ""} ${extra}`.trim();

  const sortIcon = (col: SortCol) =>
    sortCol === col ? (sortAsc ? " ▲" : " ▼") : "";

  if (!aberto || !tipo) return null;

  const pedirConfirmacao = (acc: PendingAction) => setConfirmacao(acc);

  const actualizar = () => {
    onActualizado();
    setRefreshKey((k) => k + 1);
  };

  const runAction = async (casoId: string, fn: () => Promise<RpcRes>) => {
    setAProcessar(casoId);
    setMensagem("");
    const res = await fn();
    setAProcessar(null);
    if (res.sucesso) {
      actualizar();
      return;
    }
    setMensagem(res.mensagem ?? "Erro na operação.");
  };

  const gravarNota = async () => {
    if (!notaCaso || !textoNota.trim()) return;
    setAGravarNota(true);
    const res = await adicionarObservacaoSupervisao(
      supabase,
      notaCaso.caso_id,
      textoNota.trim()
    );
    setAGravarNota(false);
    if (res.sucesso) {
      setNotaCaso(null);
      setTextoNota("");
      actualizar();
      return;
    }
    setMensagem(res.mensagem ?? "Erro ao gravar nota.");
  };

  return (
    <>
      <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/70 p-2 backdrop-blur-sm sm:items-center sm:p-4">
        <div className="flex max-h-[92vh] w-full max-w-[98vw] flex-col rounded-xl border border-white/10 bg-card shadow-card xl:max-w-7xl">
          <header className="flex shrink-0 items-center justify-between border-b border-white/10 px-4 py-3">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-widest text-brand">
                Drill-down · controlo total
              </p>
              <h2 className="text-base font-bold text-white">{titulo}</h2>
              <p className="text-[10px] text-muted">
                {aCarregar ? "A carregar…" : `${total} casos`}
                {total > PAGE_SIZE &&
                  ` · pág. ${paginaActual + 1}/${totalPaginas} (${inicio + 1}–${Math.min(inicio + PAGE_SIZE, total)})`}
              </p>
            </div>
            <button
              type="button"
              onClick={onFechar}
              className="rounded-lg px-3 py-1.5 text-xs text-muted hover:bg-white/5 hover:text-white"
            >
              Fechar
            </button>
          </header>

          <div className="shrink-0 border-b border-white/10 px-4 py-2">
            <input
              type="search"
              value={pesquisa}
              onChange={(e) => setPesquisa(e.target.value)}
              placeholder="Pesquisa global: ID, observações, loja…"
              className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-xs text-white outline-none focus:border-brand/50"
            />
            {mensagem && (
              <p className="mt-1.5 text-[10px] text-red-300">{mensagem}</p>
            )}
          </div>

          <div className="min-h-0 flex-1 overflow-auto px-2 py-2 sm:px-4">
            <table className="w-full min-w-[1100px] text-left text-[11px]">
              <thead className="sticky top-0 z-10 bg-card">
                <tr className="border-b border-white/10 text-[10px] font-bold uppercase tracking-wide text-muted">
                  <th className={`p-1.5 ${thSort("id")}`} onClick={() => toggleSort("id")}>
                    ID{sortIcon("id")}
                  </th>
                  <th className={`p-1.5 ${thSort("criacao")}`} onClick={() => toggleSort("criacao")}>
                    Criação{sortIcon("criacao")}
                  </th>
                  <th className={`p-1.5 ${thSort("rqs")}`} onClick={() => toggleSort("rqs")}>
                    RQS{sortIcon("rqs")}
                  </th>
                  <th className={`p-1.5 ${thSort("skill")}`} onClick={() => toggleSort("skill")}>
                    Skill{sortIcon("skill")}
                  </th>
                  <th className={`p-1.5 ${thSort("estado")}`} onClick={() => toggleSort("estado")}>
                    Estado{sortIcon("estado")}
                  </th>
                  <th className={`p-1.5 ${thSort("agendIso")}`} onClick={() => toggleSort("agendIso")}>
                    Agendamento{sortIcon("agendIso")}
                  </th>
                  <th className={`p-1.5 ${thSort("resp")}`} onClick={() => toggleSort("resp")}>
                    Responsável{sortIcon("resp")}
                  </th>
                  <th className={`p-1.5 ${thSort("prioridade")}`} onClick={() => toggleSort("prioridade")}>
                    Prioridade{sortIcon("prioridade")}
                  </th>
                  <th className={`p-1.5 ${thSort("obs")}`} onClick={() => toggleSort("obs")}>
                    Observações{sortIcon("obs")}
                  </th>
                  <th className="p-1.5 text-center">Nota</th>
                  <th className="p-1.5 text-center">Acção</th>
                </tr>
              </thead>
              <tbody>
                {casos.map((c) => {
                  const busy = aProcessar === c.caso_id;
                  return (
                    <tr
                      key={c.caso_id}
                      className={`border-b border-white/5 ${
                        c.prioridade_flash ? "bg-orange-500/5" : ""
                      } ${busy || aCarregar ? "opacity-50" : ""}`}
                    >
                      <td className="p-1.5 font-semibold text-brand">
                        {c.id}
                        {c.intercalar ? " ✔" : ""}
                      </td>
                      <td className="p-1.5 text-muted">{c.criacao}</td>
                      <td className="p-1.5 text-warning">{c.rqs}</td>
                      <td className="p-1.5">
                        <select
                          defaultValue={c.equipa_id}
                          disabled={busy}
                          onChange={(e) => {
                            const eqId = e.target.value;
                            if (!eqId || eqId === c.equipa_id) return;
                            pedirConfirmacao({
                              titulo: "Alterar skill?",
                              descricao: `Confirmas alterar a skill do caso ${c.id}? O caso será limpo e devolvido à fila.`,
                              executar: async () => {
                                await runAction(c.caso_id, () =>
                                  alterarEquipaCasoSupervisao(supabase, c.caso_id, eqId)
                                );
                              },
                            });
                          }}
                          className="w-full min-w-[5rem] rounded border border-white/10 bg-input px-1 py-0.5 text-[10px] text-white"
                        >
                          <option value="">— Sem skill —</option>
                          {equipas.map((eq) => (
                            <option key={eq.id} value={eq.id}>
                              {eq.nome}
                            </option>
                          ))}
                        </select>
                      </td>
                      <td className="p-1.5">
                        <select
                          defaultValue={c.status}
                          disabled={busy}
                          onChange={(e) => {
                            const st = e.target.value;
                            if (st === c.status) return;
                            pedirConfirmacao({
                              titulo: "Alterar estado?",
                              descricao: `Confirmas forçar o estado do caso ${c.id}?`,
                              executar: async () => {
                                await runAction(c.caso_id, () =>
                                  alterarEstadoCasoSupervisao(supabase, c.caso_id, st)
                                );
                              },
                            });
                          }}
                          className="w-full min-w-[5.5rem] rounded border border-white/10 bg-input px-1 py-0.5 text-[10px] text-white"
                        >
                          {ESTADOS_OPCOES.map((o) => (
                            <option key={o.value} value={o.value}>
                              {o.label}
                            </option>
                          ))}
                          {c.status === "em_tratamento" && (
                            <option value="em_tratamento">Em Tratamento</option>
                          )}
                        </select>
                      </td>
                      <td className="p-1.5">
                        <input
                          type="datetime-local"
                          defaultValue={c.agendIso}
                          disabled={busy}
                          onChange={(e) => {
                            const val = e.target.value;
                            pedirConfirmacao({
                              titulo: val ? "Alterar agendamento?" : "Remover agendamento?",
                              descricao: `Confirmas ${val ? "alterar" : "remover"} o agendamento do caso ${c.id}?`,
                              executar: async () => {
                                await runAction(c.caso_id, () =>
                                  alterarAgendamentoSupervisao(
                                    supabase,
                                    c.caso_id,
                                    val ? new Date(val).toISOString() : null
                                  )
                                );
                              },
                            });
                          }}
                          className="w-full min-w-[8rem] rounded border border-white/10 bg-input px-1 py-0.5 text-[10px] text-white"
                        />
                      </td>
                      <td className="p-1.5">
                        <select
                          defaultValue={c.colaborador_id ?? "LIVRE"}
                          disabled={busy}
                          onChange={(e) => {
                            const val = e.target.value;
                            const colId = val === "LIVRE" ? null : val;
                            pedirConfirmacao({
                              titulo: "Reatribuir caso?",
                              descricao: `Confirmas reatribuir o caso ${c.id}?`,
                              executar: async () => {
                                await runAction(c.caso_id, () =>
                                  reatribuirCaso(
                                    supabase,
                                    c.caso_id,
                                    colId,
                                    c.prioridade_flash
                                  )
                                );
                              },
                            });
                          }}
                          className="w-full min-w-[5.5rem] rounded border border-white/10 bg-input px-1 py-0.5 text-[10px] text-white"
                        >
                          <option value="LIVRE">— Livre —</option>
                          {operadores.map((op) => (
                            <option key={op.id} value={op.id}>
                              {op.nome}
                            </option>
                          ))}
                        </select>
                      </td>
                      <td className="p-1.5">
                        <select
                          defaultValue={c.prioridade_flash ? "SIM" : ""}
                          disabled={busy}
                          onChange={(e) => {
                            const flash = e.target.value === "SIM";
                            if (flash === c.prioridade_flash) return;
                            pedirConfirmacao({
                              titulo: flash ? "Activar Flash?" : "Remover Flash?",
                              descricao: `Confirmas alterar a prioridade do caso ${c.id}?`,
                              executar: async () => {
                                await runAction(c.caso_id, () =>
                                  alterarPrioridadeFlash(supabase, c.caso_id, flash)
                                );
                              },
                            });
                          }}
                          className="w-full rounded border border-white/10 bg-input px-1 py-0.5 text-[10px] text-white"
                        >
                          <option value="">Normal</option>
                          <option value="SIM">🔥 Flash</option>
                        </select>
                      </td>
                      <td
                        className="max-w-[120px] truncate p-1.5 text-muted"
                        title={c.obsCompleta}
                      >
                        {c.obsTruncada || "—"}
                      </td>
                      <td className="p-1.5 text-center">
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => {
                            setNotaCaso(c);
                            setTextoNota("");
                          }}
                          className="rounded bg-brand/20 px-2 py-0.5 text-[10px] font-semibold text-brand hover:bg-brand/30 disabled:opacity-50"
                          title="Observação para o colaborador (histórico cumulativo)"
                        >
                          Nota
                        </button>
                      </td>
                      <td className="p-1.5 text-center">
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() =>
                            pedirConfirmacao({
                              titulo: "Concluir directamente?",
                              descricao: `Fechar o caso ${c.id} directamente? Ficará Concluído e sairá da fila.`,
                              executar: async () => {
                                await runAction(c.caso_id, () =>
                                  concluirCasoDiretoSupervisao(supabase, c.caso_id)
                                );
                              },
                            })
                          }
                          className="rounded bg-emerald-600/80 px-2 py-0.5 text-[10px] font-bold text-white hover:bg-emerald-500 disabled:opacity-50"
                        >
                          Concluir
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
            {!aCarregar && casos.length === 0 && (
              <p className="py-8 text-center text-xs text-muted">
                Nenhum caso nesta lista.
              </p>
            )}
          </div>

          {total > PAGE_SIZE && (
            <footer className="flex shrink-0 items-center justify-between border-t border-white/10 px-4 py-2">
              <p className="text-[10px] text-muted">
                A mostrar {inicio + 1}–{Math.min(inicio + PAGE_SIZE, total)} de {total}
              </p>
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  disabled={paginaActual <= 0 || aCarregar}
                  onClick={() => setPagina((p) => Math.max(0, p - 1))}
                  className="rounded-lg border border-white/10 px-3 py-1 text-[10px] font-semibold text-muted transition hover:text-white disabled:opacity-40"
                >
                  ← Anterior
                </button>
                <span className="text-[10px] tabular-nums text-white">
                  {paginaActual + 1} / {totalPaginas}
                </span>
                <button
                  type="button"
                  disabled={paginaActual >= totalPaginas - 1 || aCarregar}
                  onClick={() => setPagina((p) => Math.min(totalPaginas - 1, p + 1))}
                  className="rounded-lg border border-white/10 px-3 py-1 text-[10px] font-semibold text-muted transition hover:text-white disabled:opacity-40"
                >
                  Seguinte →
                </button>
              </div>
            </footer>
          )}
        </div>
      </div>

      {notaCaso && (
        <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/80 p-4">
          <div className="w-full max-w-md rounded-xl border border-brand/30 bg-card p-5 shadow-card">
            <p className="text-[10px] font-bold uppercase tracking-widest text-brand">
              Observação — Sala de Controlo
            </p>
            <p className="mt-1 text-xs text-muted">
              Caso <strong className="text-white">{notaCaso.id}</strong> · registada no
              histórico cumulativo
            </p>
            <textarea
              value={textoNota}
              onChange={(e) => setTextoNota(e.target.value)}
              rows={5}
              placeholder="Observação para o colaborador…"
              className="mt-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
            />
            <div className="mt-4 flex gap-2">
              <button
                type="button"
                onClick={() => setNotaCaso(null)}
                disabled={aGravarNota}
                className="flex-1 rounded-lg border border-white/15 py-2 text-xs font-semibold text-muted hover:bg-white/5"
              >
                Cancelar
              </button>
              <button
                type="button"
                onClick={() => void gravarNota()}
                disabled={aGravarNota || !textoNota.trim()}
                className="flex-1 rounded-lg bg-brand py-2 text-xs font-bold text-white disabled:opacity-50"
              >
                {aGravarNota ? "A gravar…" : "Gravar"}
              </button>
            </div>
          </div>
        </div>
      )}

      <ConfirmModal
        aberto={!!confirmacao}
        titulo={confirmacao?.titulo ?? ""}
        descricao={confirmacao?.descricao ?? ""}
        confirmarLabel="Confirmar"
        cancelarLabel="Cancelar"
        variante="warning"
        aCarregar={!!aProcessar}
        onConfirmar={() => {
          if (!confirmacao) return;
          void confirmacao.executar().then(() => setConfirmacao(null));
        }}
        onCancelar={() => setConfirmacao(null)}
      />
    </>
  );
}
