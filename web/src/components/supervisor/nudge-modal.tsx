"use client";

import { useEffect, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import { enviarNudge } from "@/lib/api/supervisao";
import { obterNudgeMensagens } from "@/lib/api/gestor";
import type { AgenteSupervisao } from "@/lib/types/supervisao";
import { NudgeMessagesModal } from "@/components/supervisor/nudge-messages-modal";

const FALLBACK_MENSAGENS = [
  "Preciso da tua ajuda num caso.",
  "Por favor, atende a chamada activa.",
  "Vem à sala de controlo, p.f.",
];

interface NudgeModalProps {
  aberto: boolean;
  agente: AgenteSupervisao | null;
  supabase: SupabaseClient;
  onFechar: () => void;
}

export function NudgeModal({
  aberto,
  agente,
  supabase,
  onFechar,
}: NudgeModalProps) {
  const [mensagem, setMensagem] = useState("");
  const [aEnviar, setAEnviar] = useState(false);
  const [predef, setPredef] = useState<string[]>(FALLBACK_MENSAGENS);
  const [gerirAberto, setGerirAberto] = useState(false);
  const [feedback, setFeedback] = useState<{
    tipo: "ok" | "erro";
    texto: string;
  } | null>(null);

  useEffect(() => {
    if (!aberto) return;
    void (async () => {
      const res = await obterNudgeMensagens(supabase);
      if (res.sucesso && res.mensagens && res.mensagens.length > 0) {
        setPredef(res.mensagens);
      }
    })();
  }, [aberto, supabase]);

  if (!aberto || !agente) return null;

  const enviar = async () => {
    if (!mensagem.trim()) return;
    setAEnviar(true);
    setFeedback(null);
    const res = await enviarNudge(
      supabase,
      agente.id,
      mensagem.trim(),
      agente.casoAtivoCasoId ?? undefined
    );
    setAEnviar(false);
    if (res.sucesso) {
      setFeedback({ tipo: "ok", texto: "Toque enviado com sucesso." });
      setMensagem("");
      setTimeout(onFechar, 1200);
      return;
    }
    setFeedback({ tipo: "erro", texto: res.mensagem ?? "Erro ao enviar." });
  };

  return (
    <>
      <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm">
        <div className="w-full max-w-md rounded-2xl border border-brand/30 bg-card p-6 shadow-card">
          <p className="text-[10px] font-bold uppercase tracking-widest text-brand">
            Toque da supervisão
          </p>
          <h2 className="mt-1 text-lg font-bold text-white">{agente.nome}</h2>
          <p className="text-xs text-muted">{agente.loja}</p>

          {agente.casoAtivoId && (
            <p className="mt-3 rounded-lg bg-brand/10 px-3 py-2 text-xs text-brand">
              Caso activo: {agente.casoAtivoId}
            </p>
          )}

          <label className="mt-4 block">
            <span className="text-xs font-semibold text-muted">
              Mensagem rápida
            </span>
            <select
              value=""
              onChange={(e) => {
                if (e.target.value) setMensagem(e.target.value);
              }}
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
            >
              <option value="">— Escolher mensagem predefinida —</option>
              {predef.map((m) => (
                <option key={m} value={m}>
                  {m}
                </option>
              ))}
            </select>
          </label>

          <button
            type="button"
            onClick={() => setGerirAberto(true)}
            className="mt-2 text-[11px] font-semibold text-brand hover:underline"
          >
            Gerir mensagens…
          </button>

          <label className="mt-3 block">
            <span className="text-xs font-semibold text-muted">
              Mensagem personalizada
            </span>
            <textarea
              value={mensagem}
              onChange={(e) => setMensagem(e.target.value)}
              rows={4}
              placeholder="Ex.: Por favor confirma o estado do caso…"
              className="mt-1 w-full rounded-xl border border-white/10 bg-input px-4 py-3 text-sm text-white outline-none focus:border-brand/50"
            />
          </label>

          {feedback && (
            <p
              className={`mt-3 text-sm ${
                feedback.tipo === "ok" ? "text-emerald-300" : "text-red-300"
              }`}
            >
              {feedback.texto}
            </p>
          )}

          <div className="mt-5 flex gap-3">
            <button
              type="button"
              onClick={onFechar}
              disabled={aEnviar}
              className="flex-1 rounded-xl border border-white/15 py-3 text-sm font-semibold text-muted hover:bg-white/5 disabled:opacity-50"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={() => void enviar()}
              disabled={aEnviar || !mensagem.trim()}
              className="flex-1 rounded-xl bg-brand py-3 text-sm font-bold text-white hover:bg-brand-hover disabled:opacity-50"
            >
              {aEnviar ? "A enviar…" : "Enviar toque"}
            </button>
          </div>
        </div>
      </div>

      <NudgeMessagesModal
        aberto={gerirAberto}
        supabase={supabase}
        onFechar={() => setGerirAberto(false)}
        onActualizado={setPredef}
      />
    </>
  );
}
