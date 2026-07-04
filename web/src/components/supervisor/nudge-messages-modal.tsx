"use client";

import { useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  obterNudgeMensagens,
  salvarNudgeMensagens,
} from "@/lib/api/gestor";

interface NudgeMessagesModalProps {
  aberto: boolean;
  supabase: SupabaseClient;
  onFechar: () => void;
  onActualizado: (mensagens: string[]) => void;
}

export function NudgeMessagesModal({
  aberto,
  supabase,
  onFechar,
  onActualizado,
}: NudgeMessagesModalProps) {
  const [mensagens, setMensagens] = useState<string[]>([]);
  const [aGravar, setAGravar] = useState(false);
  const [msg, setMsg] = useState("");

  useEffect(() => {
    if (!aberto) return;
    void (async () => {
      const res = await obterNudgeMensagens(supabase);
      if (res.sucesso && res.mensagens) {
        setMensagens(res.mensagens.length > 0 ? [...res.mensagens] : [""]);
      }
    })();
  }, [aberto, supabase]);

  if (!aberto) return null;

  const gravar = async () => {
    const limpas = mensagens.map((m) => m.trim()).filter(Boolean);
    setAGravar(true);
    const res = await salvarNudgeMensagens(supabase, limpas);
    setAGravar(false);
    if (res.sucesso) {
      setMsg("Guardado.");
      onActualizado(limpas);
      setTimeout(onFechar, 800);
      return;
    }
    setMsg(res.mensagem ?? "Erro.");
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm">
      <div className="w-full max-w-lg rounded-2xl border border-white/15 bg-card p-6 shadow-card">
        <h2 className="text-lg font-bold text-white">Gerir mensagens predefinidas</h2>
        <p className="mt-1 text-xs text-muted">
          Aparecem no dropdown do modal de toque.
        </p>

        <div className="mt-4 space-y-2">
          {mensagens.map((m, idx) => (
            <div key={idx} className="flex gap-2">
              <input
                value={m}
                onChange={(e) => {
                  const next = [...mensagens];
                  next[idx] = e.target.value;
                  setMensagens(next);
                }}
                className="flex-1 rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
              />
              <button
                type="button"
                onClick={() =>
                  setMensagens((prev) => prev.filter((_, i) => i !== idx))
                }
                className="rounded-lg px-2 text-red-400 hover:bg-red-500/10"
              >
                ✕
              </button>
            </div>
          ))}
          <button
            type="button"
            onClick={() => setMensagens((prev) => [...prev, ""])}
            className="text-xs font-semibold text-brand hover:underline"
          >
            + Adicionar mensagem
          </button>
        </div>

        {msg && <p className="mt-3 text-sm text-emerald-300">{msg}</p>}

        <div className="mt-5 flex gap-3">
          <button
            type="button"
            onClick={onFechar}
            className="flex-1 rounded-xl border border-white/15 py-2.5 text-sm text-muted hover:bg-white/5"
          >
            Cancelar
          </button>
          <button
            type="button"
            disabled={aGravar}
            onClick={() => void gravar()}
            className="flex-1 rounded-xl bg-brand py-2.5 text-sm font-bold text-white disabled:opacity-50"
          >
            {aGravar ? "A guardar…" : "Guardar"}
          </button>
        </div>
      </div>
    </div>
  );
}
