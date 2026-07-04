"use client";

import { useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  obterObjetivosEdicao,
  salvarObjetivosMassa,
} from "@/lib/api/gestor";
import type { ObjetivoLoja } from "@/lib/types/gestor";

interface ObjetivosPanelProps {
  supabase: SupabaseClient;
}

function formatMesInput(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  return `${y}-${m}`;
}

function mesParaGas(mesInput: string): string {
  const [y, m] = mesInput.split("-");
  return `${m}/${y}`;
}

export function ObjetivosPanel({ supabase }: ObjetivosPanelProps) {
  const [mesInput, setMesInput] = useState(formatMesInput(new Date()));
  const [dados, setDados] = useState<ObjetivoLoja[]>([]);
  const [aCarregar, setACarregar] = useState(false);
  const [aGravar, setAGravar] = useState(false);
  const [msg, setMsg] = useState("");
  const [carregado, setCarregado] = useState(false);

  const carregar = async () => {
    if (!mesInput) {
      setMsg("Seleciona um mês válido.");
      return;
    }
    setACarregar(true);
    setMsg("A procurar na base de dados…");
    const res = await obterObjetivosEdicao(supabase, mesParaGas(mesInput));
    setACarregar(false);
    if (res.sucesso && res.dados) {
      setDados(res.dados);
      setCarregado(true);
      setMsg("");
      return;
    }
    setMsg(res.mensagem ?? "Erro ao carregar.");
  };

  const gravar = async () => {
    if (!carregado || dados.length === 0) {
      setMsg("Carrega a tabela antes de gravar.");
      return;
    }
    setAGravar(true);
    setMsg("A gravar todos os objetivos…");
    const res = await salvarObjetivosMassa(
      supabase,
      mesParaGas(mesInput),
      dados
    );
    setAGravar(false);
    setMsg(
      res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro ao gravar.")
    );
  };

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-lg font-bold text-white">🎯 Gestor de Objetivos</h1>
        <p className="text-xs text-muted">
          Objetivos mensais por ponto de atendimento (loja/localização).
        </p>
      </div>

      <div className="flex flex-wrap items-end gap-3">
        <label className="block">
          <span className="text-[10px] font-bold uppercase text-muted">
            Mês alvo
          </span>
          <input
            type="month"
            value={mesInput}
            onChange={(e) => {
              setMesInput(e.target.value);
              setCarregado(false);
            }}
            className="mt-1 block rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
          />
        </label>
        <button
          type="button"
          onClick={() => void carregar()}
          disabled={aCarregar}
          className="rounded-xl border border-brand/30 bg-brand/10 px-4 py-2 text-xs font-bold text-brand hover:bg-brand/20 disabled:opacity-50"
        >
          {aCarregar ? "A carregar…" : "Carregar tabela"}
        </button>
      </div>

      <div className="max-h-[450px] overflow-y-auto rounded-lg border border-white/10 bg-black/15 p-2">
        {!carregado ? (
          <p className="py-8 text-center text-sm text-muted">
            Clica em Carregar para ver os objetivos do mês.
          </p>
        ) : (
          <table className="w-full text-left text-xs">
            <thead>
              <tr className="border-b border-white/10 text-muted">
                <th className="px-3 py-2 font-semibold">Ponto de atendimento</th>
                <th className="px-3 py-2 font-semibold w-32">Objetivo</th>
              </tr>
            </thead>
            <tbody>
              {dados.map((row, idx) => (
                <tr key={row.loja} className="border-b border-white/5">
                  <td className="px-3 py-2 text-white">{row.loja}</td>
                  <td className="px-3 py-2">
                    <input
                      type="number"
                      min={0}
                      value={row.objetivo}
                      onChange={(e) => {
                        const val = parseInt(e.target.value, 10) || 0;
                        setDados((prev) =>
                          prev.map((r, i) =>
                            i === idx ? { ...r, objetivo: val } : r
                          )
                        );
                      }}
                      className="w-full rounded border border-white/10 bg-input px-2 py-1 text-white outline-none focus:border-brand/50"
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <div className="text-center">
        <button
          type="button"
          onClick={() => void gravar()}
          disabled={aGravar || !carregado}
          className="rounded-xl bg-emerald-600 px-8 py-2.5 text-sm font-bold text-white hover:bg-emerald-500 disabled:opacity-50"
        >
          {aGravar ? "A gravar…" : "Gravar alterações"}
        </button>
      </div>

      {msg && (
        <p
          className={`text-center text-sm ${
            msg.startsWith("✅") ? "text-emerald-300" : "text-amber-200"
          }`}
        >
          {msg}
        </p>
      )}
    </div>
  );
}
