"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { agendarCaso, concluirCaso, marcarOutro } from "@/lib/api/fila";
import type { TarefaAtribuida } from "@/lib/types/fila";

export type AcaoCasoUi =
  | "concluido"
  | "cancelado"
  | "pendente"
  | "agendado"
  | "outro";

const ACAO_LABELS: Record<AcaoCasoUi, string> = {
  concluido: "Concluir",
  cancelado: "Cancelar caso",
  pendente: "Pendente",
  agendado: "Agendar",
  outro: "Outro",
};

interface TaskActionPanelProps {
  tarefa: TarefaAtribuida;
  aCarregar: boolean;
  alertaRqsAtivo?: boolean;
  intercalarMarcado?: boolean;
  onLoading: (v: boolean) => void;
  onSucesso: () => void;
  onErro: (msg: string) => void;
}

function precisaData(acao: AcaoCasoUi): boolean {
  return acao === "pendente" || acao === "agendado" || acao === "outro";
}

function datetimeLocalParaIso(valor: string): string {
  return new Date(valor).toISOString();
}

export function TaskActionPanel({
  tarefa,
  aCarregar,
  alertaRqsAtivo = false,
  intercalarMarcado = false,
  onLoading,
  onSucesso,
  onErro,
}: TaskActionPanelProps) {
  const supabase = createClient();
  const [acaoAberta, setAcaoAberta] = useState<AcaoCasoUi | null>(null);
  const [justificacao, setJustificacao] = useState("");
  const [dataAgendamento, setDataAgendamento] = useState("");

  const abrirAcao = (acao: AcaoCasoUi) => {
    setAcaoAberta(acao);
    setJustificacao("");
    setDataAgendamento("");
  };

  const tentarAbrirAcao = (acao: AcaoCasoUi) => {
    if (
      acao !== "concluido" &&
      acao !== "cancelado" &&
      alertaRqsAtivo &&
      !intercalarMarcado
    ) {
      const avancar = window.confirm(
        "⚠️ ATENÇÃO: A RQS não foi enviada/marcada e a data é para hoje ou já expirou!\n\nQueres avançar e alterar o estado mesmo assim?"
      );
      if (!avancar) return;
    }
    abrirAcao(acao);
  };

  const fecharPainel = () => {
    setAcaoAberta(null);
    setJustificacao("");
    setDataAgendamento("");
  };

  const submeter = async () => {
    if (!acaoAberta) return;

    if (acaoAberta !== "concluido" && !justificacao.trim()) {
      onErro("A justificação é obrigatória.");
      return;
    }

    let dataIso: string | undefined;
    if (precisaData(acaoAberta)) {
      if (!dataAgendamento) {
        onErro("A data/hora é obrigatória para este estado.");
        return;
      }
      const d = new Date(dataAgendamento);
      if (Number.isNaN(d.getTime())) {
        onErro("Data/hora inválida.");
        return;
      }
      if (d.getTime() < Date.now()) {
        onErro("A data/hora não pode estar no passado.");
        return;
      }
      const max = new Date();
      max.setDate(max.getDate() + 7);
      if (d > max) {
        onErro("Não podes agendar com mais de 7 dias de antecedência.");
        return;
      }
      dataIso = datetimeLocalParaIso(dataAgendamento);
    }

    onLoading(true);
    let res;

    if (acaoAberta === "concluido") {
      res = await concluirCaso(
        supabase,
        tarefa.id,
        justificacao || undefined,
        "concluido"
      );
    } else if (acaoAberta === "cancelado") {
      res = await concluirCaso(
        supabase,
        tarefa.id,
        justificacao,
        "cancelado"
      );
    } else if (acaoAberta === "outro") {
      res = await marcarOutro(
        supabase,
        tarefa.id,
        justificacao,
        dataIso
      );
    } else {
      res = await agendarCaso(
        supabase,
        tarefa.id,
        acaoAberta,
        dataIso!,
        justificacao
      );
    }

    onLoading(false);

    if (res.sucesso) {
      fecharPainel();
      onSucesso();
      return;
    }

    onErro(res.mensagem ?? "Erro ao processar ação.");
    if (res.ejetar) {
      fecharPainel();
      onSucesso();
    }
  };

  const minDatetime = () => {
    const n = new Date();
    n.setMinutes(n.getMinutes() - n.getTimezoneOffset());
    return n.toISOString().slice(0, 16);
  };

  const maxDatetime = () => {
    const n = new Date();
    n.setDate(n.getDate() + 7);
    n.setMinutes(n.getMinutes() - n.getTimezoneOffset());
    return n.toISOString().slice(0, 16);
  };

  if (acaoAberta) {
    return (
      <div className="mt-6 rounded-lg border border-white/10 bg-black/20 p-4">
        <p className="text-sm font-semibold text-emerald-400">
          Ação: {ACAO_LABELS[acaoAberta]}
        </p>

        {acaoAberta === "concluido" && (
          <p className="mt-2 rounded bg-amber-500/10 px-3 py-2 text-xs text-amber-200">
            Tens a certeza? Caso resolvido não pode ser desfeito.
          </p>
        )}

        <label className="mt-4 block text-xs text-muted">
          {acaoAberta === "concluido"
            ? "Justificação (facultativo)"
            : "Justificação (obrigatório)"}
        </label>
        <textarea
          value={justificacao}
          onChange={(e) => setJustificacao(e.target.value)}
          className="mt-1 w-full rounded-lg border border-white/10 bg-black/30 px-3 py-2 text-sm text-white outline-none focus:border-brand"
          rows={3}
          placeholder="Motivo detalhado…"
        />

        {precisaData(acaoAberta) && (
          <>
            <label className="mt-3 block text-xs text-muted">
              Data/hora (deadline / agendamento)
            </label>
            <input
              type="datetime-local"
              value={dataAgendamento}
              min={minDatetime()}
              max={maxDatetime()}
              onChange={(e) => setDataAgendamento(e.target.value)}
              className="mt-1 w-full rounded-lg border border-white/10 bg-black/30 px-3 py-2 text-sm text-white outline-none focus:border-brand"
            />
          </>
        )}

        <div className="mt-4 grid grid-cols-2 gap-3">
          <button
            type="button"
            onClick={fecharPainel}
            disabled={aCarregar}
            className="rounded-lg border border-white/20 py-2 text-sm text-muted"
          >
            Voltar
          </button>
          <button
            type="button"
            onClick={submeter}
            disabled={aCarregar}
            className="rounded-lg bg-emerald-600 py-2 text-sm font-semibold text-white disabled:opacity-50"
          >
            {aCarregar ? "A processar…" : "Confirmar"}
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <button
        type="button"
        onClick={() => tentarAbrirAcao("concluido")}
        className="rounded-lg bg-emerald-600 py-3.5 text-sm font-bold uppercase tracking-wide text-white shadow-md hover:bg-emerald-500"
      >
        ✔ Concluir
      </button>
      <div className="grid gap-2 sm:grid-cols-2">
        <button
          type="button"
          onClick={() => tentarAbrirAcao("pendente")}
          className="rounded-lg bg-amber-500 py-3.5 text-sm font-bold uppercase tracking-wide text-slate-900 shadow-md hover:bg-amber-400"
        >
          ⏳ Pendente
        </button>
        <button
          type="button"
          onClick={() => tentarAbrirAcao("agendado")}
          className="rounded-lg bg-brand py-3.5 text-sm font-bold uppercase tracking-wide text-white shadow-brand hover:bg-brand-hover"
        >
          📅 Agendar
        </button>
        <button
          type="button"
          onClick={() => tentarAbrirAcao("outro")}
          className="rounded-lg bg-violet-600 py-3.5 text-sm font-bold uppercase tracking-wide text-white shadow-md hover:bg-violet-500 sm:col-span-2"
        >
          ❓ Outro
        </button>
      </div>
      <button
        type="button"
        onClick={() => tentarAbrirAcao("cancelado")}
        className="rounded-lg border-2 border-red-500/50 py-3.5 text-sm font-bold uppercase tracking-wide text-red-300 hover:bg-red-500/10"
      >
        ❌ Cancelar caso
      </button>
    </div>
  );
}
