"use client";

import { useCallback, useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  executarImportEvalyze,
  obterStatusImportEvalyze,
} from "@/lib/api/gestor";
import type { ImportEvalyzeResponse, StatusImportEvalyzeResponse } from "@/lib/types/gestor";
import { ConfirmModal } from "@/components/ui/confirm-modal";

interface EvalyzeImportPanelProps {
  supabase: SupabaseClient;
}

function formatarData(iso: string | null | undefined): string {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("pt-PT", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function EvalyzeImportPanel({ supabase }: EvalyzeImportPanelProps) {
  const [status, setStatus] = useState<StatusImportEvalyzeResponse | null>(null);
  const [resultado, setResultado] = useState<ImportEvalyzeResponse | null>(null);
  const [aProcessar, setAProcessar] = useState(false);
  const [confirmar, setConfirmar] = useState(false);
  const [erro, setErro] = useState("");

  const carregarStatus = useCallback(async () => {
    const res = await obterStatusImportEvalyze(supabase);
    if (res.sucesso) {
      setStatus(res);
      setErro("");
    } else {
      setErro(res.mensagem ?? "Erro ao carregar status.");
    }
  }, [supabase]);

  useEffect(() => {
    void carregarStatus();
  }, [carregarStatus]);

  const executar = async () => {
    setConfirmar(false);
    setAProcessar(true);
    setResultado(null);

    try {
      const data = await executarImportEvalyze(supabase);
      setResultado(data);
      if (!data.sucesso) {
        setErro(data.mensagem ?? "Erro na importacao.");
      } else {
        setErro("");
      }
      void carregarStatus();
    } catch {
      setErro("Falha de rede ao contactar o servidor.");
    } finally {
      setAProcessar(false);
    }
  };

  const ultima = status?.ultima;

  return (
    <div className="space-y-4 rounded-lg border border-brand/20 bg-brand/5 p-4">
      <div>
        <span className="inline-block rounded-full bg-brand/20 px-3 py-1 text-[10px] font-bold uppercase tracking-wider text-brand">
          Smart Queue · Importacao Automatica
        </span>
        <h2 className="mt-2 text-base font-bold text-white">
          Relatorio Evalyze (aba Lojas)
        </h2>
        <p className="mt-1 text-xs text-muted">
          Carrega casos novos do Relatorio Smart Queue para a fila. Duplicados
          ignorados (ID + Contacto Aux). Linhas incompletas sao saltadas.
          Em producao, o pg_cron no Supabase executa automaticamente de hora a hora.
        </p>
      </div>

      <ul className="list-inside list-disc space-y-1 text-[11px] text-muted">
        <li>Duplicados ignorados (ID caso + Contacto Aux)</li>
        <li>Linhas incompletas saltadas — restantes casos seguem</li>
        <li>Data de Distribuicao preenchida com o dia de hoje</li>
      </ul>

      {ultima && (
        <div className="rounded-lg border border-white/10 bg-black/20 p-3 text-[11px]">
          <p className="mb-2 font-bold uppercase tracking-wider text-muted">
            Ultima execucao
          </p>
          <p className="text-white">
            {formatarData(ultima.executado_em)} · {ultima.origem}
          </p>
          <div className="mt-2 grid grid-cols-3 gap-2">
            <div className="rounded-lg bg-emerald-500/10 p-2 text-center">
              <div className="text-lg font-bold text-emerald-300">
                {ultima.importados}
              </div>
              <div className="text-[9px] uppercase text-muted">Importados</div>
            </div>
            <div className="rounded-lg bg-amber-500/10 p-2 text-center">
              <div className="text-lg font-bold text-amber-300">
                {ultima.duplicados}
              </div>
              <div className="text-[9px] uppercase text-muted">Duplicados</div>
            </div>
            <div className="rounded-lg bg-red-500/10 p-2 text-center">
              <div className="text-lg font-bold text-red-300">
                {ultima.ignoradosCampos}
              </div>
              <div className="text-[9px] uppercase text-muted">Ignorados</div>
            </div>
          </div>
        </div>
      )}

      {erro && (
        <p className="rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-200">
          {erro}
        </p>
      )}

      {resultado && (
        <div
          className={`rounded-lg border px-3 py-2 text-sm ${
            resultado.sucesso
              ? "border-emerald-500/30 bg-emerald-500/10 text-emerald-200"
              : "border-amber-500/30 bg-amber-500/10 text-amber-200"
          }`}
        >
          {resultado.sucesso ? "✅" : "⚠️"} {resultado.mensagem}
          {(resultado.importados != null ||
            resultado.duplicados != null ||
            resultado.ignoradosCampos != null) && (
            <div className="mt-2 grid grid-cols-3 gap-2 text-center text-[10px]">
              <span>{resultado.importados ?? 0} importados</span>
              <span>{resultado.duplicados ?? 0} duplicados</span>
              <span>{resultado.ignoradosCampos ?? 0} ignorados</span>
            </div>
          )}
        </div>
      )}

      <button
        type="button"
        disabled={aProcessar}
        onClick={() => setConfirmar(true)}
        className="w-full rounded-xl bg-brand px-4 py-3 text-sm font-bold text-white transition hover:bg-brand-hover disabled:opacity-50 sm:w-auto"
      >
        {aProcessar ? "⏳ A importar…" : "⚡ Importar agora"}
      </button>

      <ConfirmModal
        aberto={confirmar}
        titulo="Smart Queue · Importacao Automatica"
        descricao="Carregar casos novos do Relatorio Smart Queue (aba Lojas) para a fila de Distribuicao?"
        confirmarLabel="⚡ Importar agora"
        aCarregar={aProcessar}
        onConfirmar={() => void executar()}
        onCancelar={() => setConfirmar(false)}
      />
    </div>
  );
}
