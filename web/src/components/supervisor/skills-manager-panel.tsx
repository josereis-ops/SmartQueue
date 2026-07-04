"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  atualizarSkillsEmMassa,
  obterDadosGestorSkills,
} from "@/lib/api/gestor";
import type { GestorUser, SkillItem } from "@/lib/types/gestor";

interface SkillsManagerPanelProps {
  supabase: SupabaseClient;
}

export function SkillsManagerPanel({ supabase }: SkillsManagerPanelProps) {
  const [users, setUsers] = useState<GestorUser[]>([]);
  const [skills, setSkills] = useState<SkillItem[]>([]);
  const [aCarregar, setACarregar] = useState(true);
  const [erro, setErro] = useState("");
  const [msg, setMsg] = useState("");
  const [aGravar, setAGravar] = useState(false);
  const [selUsers, setSelUsers] = useState<Set<string>>(new Set());
  const [selSkills, setSelSkills] = useState<Set<string>>(new Set());
  const [filtroUsers, setFiltroUsers] = useState("");
  const [filtroSkills, setFiltroSkills] = useState("");

  const carregar = useCallback(async () => {
    setACarregar(true);
    const res = await obterDadosGestorSkills(supabase);
    setACarregar(false);
    if (res.sucesso) {
      setUsers(res.users ?? []);
      setSkills(res.skills ?? []);
      setErro("");
      return;
    }
    setErro(res.mensagem ?? "Erro ao carregar.");
  }, [supabase]);

  useEffect(() => {
    void carregar();
  }, [carregar]);

  const userItems = useMemo(
    () =>
      users.filter(
        (u) =>
          u.nome.toLowerCase().includes(filtroUsers.toLowerCase()) ||
          u.email.toLowerCase().includes(filtroUsers.toLowerCase())
      ),
    [users, filtroUsers]
  );

  const skillItems = useMemo(
    () =>
      skills.filter((s) =>
        s.nome.toLowerCase().includes(filtroSkills.toLowerCase())
      ),
    [skills, filtroSkills]
  );

  const toggleUser = (email: string) => {
    setSelUsers((prev) => {
      const next = new Set(prev);
      if (next.has(email)) next.delete(email);
      else next.add(email);
      return next;
    });
  };

  const toggleSkill = (nome: string) => {
    setSelSkills((prev) => {
      const next = new Set(prev);
      if (next.has(nome)) next.delete(nome);
      else next.add(nome);
      return next;
    });
  };

  const aplicar = async (acao: "adicionar" | "remover") => {
    if (selUsers.size === 0 || selSkills.size === 0) {
      setMsg("Seleciona pelo menos um operador e uma skill.");
      return;
    }
    setAGravar(true);
    setMsg("");
    const res = await atualizarSkillsEmMassa(
      supabase,
      Array.from(selUsers),
      Array.from(selSkills),
      acao
    );
    setAGravar(false);
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) void carregar();
  };

  if (aCarregar) {
    return (
      <p className="py-12 text-center text-sm text-muted">A carregar skills…</p>
    );
  }

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-lg font-bold text-white">⚙️ Gestor de Skills</h1>
        <p className="text-xs text-muted">
          Atribuição multi-skill por operador (réplica GAS Config_Skills + col M).
        </p>
      </div>

      {erro && (
        <p className="rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-200">
          {erro}
        </p>
      )}

      <div className="flex flex-col gap-3 lg:h-[420px] lg:flex-row">
        <div className="flex flex-1 flex-col rounded-lg border border-white/10 bg-black/20 p-3">
          <h3 className="mb-2 border-b border-white/5 pb-2 text-xs font-bold text-brand">
            1. Seleciona os Operadores
          </h3>
          <input
            type="search"
            placeholder="Pesquisar colaborador…"
            value={filtroUsers}
            onChange={(e) => setFiltroUsers(e.target.value)}
            className="mb-2 rounded-lg border border-white/10 bg-input px-2 py-1.5 text-[11px] text-white outline-none focus:border-brand/50"
          />
          <div className="flex-1 space-y-1 overflow-y-auto pr-1">
            {userItems.map((u) => (
              <label
                key={u.email}
                className="flex cursor-pointer items-start gap-2 rounded px-1 py-0.5 text-[11px] hover:bg-white/5"
              >
                <input
                  type="checkbox"
                  checked={selUsers.has(u.email)}
                  onChange={() => toggleUser(u.email)}
                  className="mt-0.5 accent-brand"
                />
                <span>
                  <span className="text-white">{u.nome}</span>
                  <span className="block text-[10px] text-muted">
                    {u.skills.join(", ") || "sem skills"}
                  </span>
                </span>
              </label>
            ))}
          </div>
        </div>

        <div className="flex flex-1 flex-col rounded-lg border border-white/10 bg-black/20 p-3">
          <h3 className="mb-2 border-b border-white/5 pb-2 text-xs font-bold text-brand">
            2. Seleciona as Skills
          </h3>
          <input
            type="search"
            placeholder="Pesquisar skill…"
            value={filtroSkills}
            onChange={(e) => setFiltroSkills(e.target.value)}
            className="mb-2 rounded-lg border border-white/10 bg-input px-2 py-1.5 text-[11px] text-white outline-none focus:border-brand/50"
          />
          <div className="flex-1 space-y-1 overflow-y-auto pr-1">
            {skillItems.map((s) => (
              <label
                key={s.id}
                className="flex cursor-pointer items-center gap-2 rounded px-1 py-0.5 text-[11px] hover:bg-white/5"
              >
                <input
                  type="checkbox"
                  checked={selSkills.has(s.nome)}
                  onChange={() => toggleSkill(s.nome)}
                  className="accent-brand"
                />
                <span className="text-white">{s.nome}</span>
              </label>
            ))}
          </div>
        </div>
      </div>

      <div className="flex flex-wrap justify-center gap-3">
        <button
          type="button"
          disabled={aGravar}
          onClick={() => void aplicar("adicionar")}
          className="rounded-xl bg-emerald-600 px-6 py-2.5 text-xs font-bold text-white hover:bg-emerald-500 disabled:opacity-50"
        >
          ➕ Adicionar
        </button>
        <button
          type="button"
          disabled={aGravar}
          onClick={() => void aplicar("remover")}
          className="rounded-xl bg-red-600/80 px-6 py-2.5 text-xs font-bold text-white hover:bg-red-600 disabled:opacity-50"
        >
          ➖ Remover
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
