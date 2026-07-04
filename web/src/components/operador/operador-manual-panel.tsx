"use client";

import { useCallback, useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  atribuirTarefaEspecifica,
  criarCasoManual,
  obterMeusPendentes,
} from "@/lib/api/fila";
import type { PendenteItem, TarefaAtribuida } from "@/lib/types/fila";

const CANAIS_MANUAL = [
  "ProduçãoDistribuída (EMAIL)",
  "SUED",
  "Facilitador (EMAIL)",
  "LOJAS",
  "CONTACT CENTER",
  "Documentos Digitalizados (EMAIL)",
  "EMAIL",
  "CONSUMIDOR (EMAIL)",
  "SICUR",
] as const;

export type EcraManual = "principal" | "trabalho" | "criar";

interface SkillOpcao {
  id: string;
  nome: string;
}

interface OperadorManualPanelProps {
  ecra: EcraManual;
  supabase: SupabaseClient;
  userId: string;
  equipaId: string;
  equipaFallback: string;
  aCarregar: boolean;
  temCasoActivo: boolean;
  onEcra: (ecra: EcraManual) => void;
  onTarefa: (tarefa: TarefaAtribuida) => void;
  onErro: (msg: string) => void;
  onLoading: (v: boolean) => void;
}

export function OperadorManualPanel({
  ecra,
  supabase,
  userId,
  equipaId,
  equipaFallback,
  aCarregar,
  temCasoActivo,
  onEcra,
  onTarefa,
  onErro,
  onLoading,
}: OperadorManualPanelProps) {
  const [idPuxar, setIdPuxar] = useState("");
  const [pendentes, setPendentes] = useState<PendenteItem[]>([]);
  const [aTratarPendente, setATratarPendente] = useState<string | null>(null);
  const [skills, setSkills] = useState<SkillOpcao[]>([]);

  const [novoId, setNovoId] = useState("");
  const [novoCanal, setNovoCanal] = useState("");
  const [novaCriacao, setNovaCriacao] = useState("");
  const [novaRqs, setNovaRqs] = useState("");
  const [novaSkill, setNovaSkill] = useState("");
  const [aCriar, setACriar] = useState(false);

  const carregarSkills = useCallback(async () => {
    const { data } = await supabase
      .from("utilizador_equipas")
      .select("equipa_id, equipas(id, nome)")
      .eq("utilizador_id", userId);

    const lista: SkillOpcao[] = [];
    const vistos = new Set<string>();

    for (const row of data ?? []) {
      const eqRaw = row.equipas as { id: string; nome: string } | { id: string; nome: string }[] | null;
      const eq = Array.isArray(eqRaw) ? eqRaw[0] : eqRaw;
      if (eq && !vistos.has(eq.id)) {
        vistos.add(eq.id);
        lista.push({ id: eq.id, nome: eq.nome });
      }
    }

    if (equipaId && !vistos.has(equipaId)) {
      const { data: eq } = await supabase
        .from("equipas")
        .select("id, nome")
        .eq("id", equipaId)
        .maybeSingle();
      if (eq) lista.unshift({ id: eq.id, nome: eq.nome });
    }

    lista.sort((a, b) => a.nome.localeCompare(b.nome, "pt"));
    setSkills(lista);
    if (lista.length === 1) setNovaSkill(lista[0].id);
  }, [supabase, userId, equipaId]);

  const carregarPendentes = useCallback(async () => {
    const res = await obterMeusPendentes(supabase);
    if (res.sucesso && res.dados) setPendentes(res.dados);
  }, [supabase]);

  useEffect(() => {
    if (ecra === "criar") void carregarSkills();
    if (ecra === "trabalho") void carregarPendentes();
  }, [ecra, carregarSkills, carregarPendentes]);

  const puxarPorId = async (idExterno: string) => {
    const id = idExterno.trim();
    if (!id) {
      onErro("Insere o número do caso.");
      return;
    }

    if (temCasoActivo) {
      if (
        !window.confirm(
          "Já tens um caso activo. Substituir pelo caso indicado?"
        )
      ) {
        return;
      }
    }

    onLoading(true);
    const res = await atribuirTarefaEspecifica(supabase, id, equipaFallback);
    onLoading(false);

    if (res.sucesso && res.tarefa) {
      setIdPuxar("");
      onEcra("principal");
      onTarefa(res.tarefa);
      return;
    }

    onErro(res.mensagem ?? "Não foi possível puxar o caso.");
  };

  const tratarPendente = async (idExterno: string) => {
    if (temCasoActivo) {
      if (
        !window.confirm(
          "Já tens um caso activo. Substituir pelo pendente seleccionado?"
        )
      ) {
        return;
      }
    }

    setATratarPendente(idExterno);
    onLoading(true);
    const res = await atribuirTarefaEspecifica(supabase, idExterno, equipaFallback);
    setATratarPendente(null);
    onLoading(false);

    if (res.sucesso && res.tarefa) {
      onEcra("principal");
      onTarefa(res.tarefa);
      return;
    }

    onErro(res.mensagem ?? "Não foi possível tratar o caso.");
  };

  const submeterCriar = async () => {
    if (!novoId.trim()) {
      onErro("Insere o número do caso.");
      return;
    }
    if (!novoCanal) {
      onErro("O canal é obrigatório.");
      return;
    }
    if (!novaCriacao) {
      onErro("A data de criação é obrigatória.");
      return;
    }
    if (!novaRqs) {
      onErro("A data de RQS é obrigatória.");
      return;
    }
    if (!novaSkill) {
      onErro("A skill é obrigatória.");
      return;
    }

    if (temCasoActivo) {
      if (
        !window.confirm(
          "Já tens um caso activo. Substituir pelo novo caso manual?"
        )
      ) {
        return;
      }
    }

    setACriar(true);
    onLoading(true);
    const res = await criarCasoManual(supabase, {
      idExterno: novoId.trim(),
      canal: novoCanal,
      dataCriacao: novaCriacao,
      dataRqs: novaRqs,
      equipaId: novaSkill,
    });
    setACriar(false);
    onLoading(false);

    if (res.sucesso && res.tarefa) {
      setNovoId("");
      setNovoCanal("");
      setNovaCriacao("");
      setNovaRqs("");
      onEcra("principal");
      onTarefa(res.tarefa);
      return;
    }

    onErro(res.mensagem ?? "Erro ao criar caso manual.");
  };

  if (ecra === "trabalho") {
    return (
      <section className="glass-card space-y-5 rounded-2xl border border-white/10 p-5 shadow-card">
        <div>
          <h2 className="text-sm font-bold text-brand">⏳ Trabalho manual e pendentes</h2>
          <p className="mt-1 text-xs text-muted">
            Puxa um caso específico da fila pelo ID ou trata os teus pendentes.
          </p>
        </div>

        <div>
          <p className="mb-2 text-[10px] font-bold uppercase tracking-widest text-muted">
            Puxar caso específico
          </p>
          <div className="flex flex-col gap-2 sm:flex-row">
            <input
              type="text"
              value={idPuxar}
              onChange={(e) => setIdPuxar(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void puxarPorId(idPuxar);
              }}
              placeholder="Insira o Nº do Caso"
              className="flex-1 rounded-xl border border-white/10 bg-input px-4 py-2.5 text-sm text-white outline-none focus:border-brand/50"
            />
            <button
              type="button"
              disabled={aCarregar}
              onClick={() => void puxarPorId(idPuxar)}
              className="rounded-xl bg-brand px-6 py-2.5 text-xs font-bold uppercase tracking-wide text-white transition hover:bg-brand-hover disabled:opacity-50"
            >
              Puxar caso
            </button>
          </div>
        </div>

        <div>
          <div className="mb-2 flex items-center justify-between">
            <p className="text-[10px] font-bold uppercase tracking-widest text-muted">
              Meus pendentes / agendados
            </p>
            <button
              type="button"
              onClick={() => void carregarPendentes()}
              className="text-[10px] font-semibold text-brand hover:underline"
            >
              Actualizar
            </button>
          </div>
          <div className="overflow-x-auto rounded-xl bg-input/40">
            {pendentes.length === 0 ? (
              <p className="py-6 text-center text-sm text-emerald-400">
                Não tens casos pendentes neste momento.
              </p>
            ) : (
              <table className="w-full text-left text-xs">
                <thead>
                  <tr className="border-b border-white/10 text-muted">
                    <th className="p-3">ID</th>
                    <th className="p-3">Estado</th>
                    <th className="p-3">RQS</th>
                    <th className="p-3">Agendamento</th>
                    <th className="p-3">Obs</th>
                    <th className="p-3 text-center">Acção</th>
                  </tr>
                </thead>
                <tbody>
                  {pendentes.map((c) => (
                    <tr
                      key={c.id}
                      className={`border-b border-white/5 ${
                        c.isRqsAtrasada && !c.hasIntercalar
                          ? "border-l-4 border-l-red-500 bg-red-500/10"
                          : c.hasIntercalar
                            ? "border-l-4 border-l-emerald-500 bg-emerald-500/5"
                            : ""
                      }`}
                    >
                      <td className="p-3 font-medium">
                        {c.id}
                        {c.isRqsAtrasada && !c.hasIntercalar ? " ⚠️" : ""}
                        {c.hasIntercalar ? " ✔️" : ""}
                      </td>
                      <td className="p-3">{c.estado}</td>
                      <td className="p-3">{c.rqs}</td>
                      <td className="p-3">{c.agendamento}</td>
                      <td className="max-w-[160px] truncate p-3" title={c.obsCompleta}>
                        {c.obsTruncada}
                      </td>
                      <td className="p-3 text-center">
                        <button
                          type="button"
                          onClick={() => void tratarPendente(c.id)}
                          disabled={aCarregar || aTratarPendente === c.id}
                          className="rounded-lg bg-emerald-600 px-3 py-1 text-[10px] font-bold text-white transition hover:bg-emerald-500 disabled:opacity-50"
                        >
                          {aTratarPendente === c.id ? "…" : "Tratar"}
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </div>
        </div>
      </section>
    );
  }

  if (ecra === "criar") {
    return (
      <section className="glass-card space-y-4 rounded-2xl border border-white/10 p-5 shadow-card">
        <div>
          <h2 className="text-sm font-bold text-purple-300">➕ Criar novo caso manual</h2>
          <p className="mt-1 text-xs text-muted">
            O caso fica atribuído a ti imediatamente (Em Tratamento).
          </p>
        </div>

        <div className="max-w-lg space-y-3">
          <label className="block">
            <span className="text-[10px] font-bold uppercase tracking-widest text-muted">
              Nº do caso
            </span>
            <input
              type="text"
              value={novoId}
              onChange={(e) => setNovoId(e.target.value)}
              placeholder="Ex: CAS-12345"
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-4 py-2.5 text-sm text-white outline-none focus:border-brand/50"
            />
          </label>

          <label className="block">
            <span className="text-[10px] font-bold uppercase tracking-widest text-muted">
              Canal
            </span>
            <select
              value={novoCanal}
              onChange={(e) => setNovoCanal(e.target.value)}
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-4 py-2.5 text-sm text-white outline-none focus:border-brand/50"
            >
              <option value="">— Seleccione o canal —</option>
              {CANAIS_MANUAL.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
          </label>

          <label className="block">
            <span className="text-[10px] font-bold uppercase tracking-widest text-muted">
              Data de criação
            </span>
            <input
              type="date"
              value={novaCriacao}
              onChange={(e) => setNovaCriacao(e.target.value)}
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-4 py-2.5 text-sm text-white outline-none focus:border-brand/50"
            />
          </label>

          <label className="block">
            <span className="text-[10px] font-bold uppercase tracking-widest text-muted">
              Data de RQS (limite)
            </span>
            <input
              type="date"
              value={novaRqs}
              onChange={(e) => setNovaRqs(e.target.value)}
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-4 py-2.5 text-sm text-white outline-none focus:border-brand/50"
            />
          </label>

          <label className="block">
            <span className="text-[10px] font-bold uppercase tracking-widest text-muted">
              Skill obrigatória
            </span>
            <select
              value={novaSkill}
              onChange={(e) => setNovaSkill(e.target.value)}
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-4 py-2.5 text-sm text-white outline-none focus:border-brand/50"
            >
              <option value="">
                {skills.length === 0 ? "A carregar skills…" : "— Seleccione a skill —"}
              </option>
              {skills.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.nome}
                </option>
              ))}
            </select>
          </label>

          <button
            type="button"
            disabled={aCarregar || aCriar}
            onClick={() => void submeterCriar()}
            className="mt-2 rounded-xl bg-purple-600 px-6 py-3 text-xs font-bold uppercase tracking-wide text-white transition hover:bg-purple-500 disabled:opacity-50"
          >
            {aCriar ? "A criar…" : "Criar e tratar"}
          </button>
        </div>
      </section>
    );
  }

  return null;
}
