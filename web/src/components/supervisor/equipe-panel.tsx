"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  eliminarUtilizador,
  gerirPontoAtendimento,
  gerirSkill,
  guardarUtilizador,
  obterDadosGestaoEquipa,
} from "@/lib/api/gestor";
import type {
  PontoAtendimentoItem,
  PerfilItem,
  PermissoesGestaoEquipa,
  SkillItem,
  TabGestaoEquipa,
  UtilizadorEquipa,
} from "@/lib/types/gestor";

interface EquipePanelProps {
  supabase: SupabaseClient;
  onAbrirAdminRegras?: () => void;
}

const TABS: { id: TabGestaoEquipa; label: string; icon: string }[] = [
  { id: "utilizadores", label: "Utilizadores", icon: "👥" },
  { id: "pontos", label: "Pontos", icon: "🏬" },
  { id: "skills", label: "Skills", icon: "🎯" },
  { id: "perfis", label: "Perfis", icon: "🏷️" },
  { id: "regras", label: "Regras de Fila", icon: "⚙️" },
];

const PERFIS_DEFAULT = "a0000000-0000-4000-8000-000000000001";

export function EquipePanel({ supabase, onAbrirAdminRegras }: EquipePanelProps) {
  const [tab, setTab] = useState<TabGestaoEquipa>("utilizadores");
  const [utilizadores, setUtilizadores] = useState<UtilizadorEquipa[]>([]);
  const [pontos, setPontos] = useState<PontoAtendimentoItem[]>([]);
  const [skills, setSkills] = useState<SkillItem[]>([]);
  const [perfis, setPerfis] = useState<PerfilItem[]>([]);
  const [permissoes, setPermissoes] = useState<PermissoesGestaoEquipa | null>(
    null
  );
  const [aCarregar, setACarregar] = useState(true);
  const [erro, setErro] = useState("");
  const [msg, setMsg] = useState("");
  const [pesquisa, setPesquisa] = useState("");

  const [modalUser, setModalUser] = useState(false);
  const [emailOriginal, setEmailOriginal] = useState("");
  const [formEmail, setFormEmail] = useState("");
  const [formNome, setFormNome] = useState("");
  const [formPonto, setFormPonto] = useState("");
  const [formEquipa, setFormEquipa] = useState("");
  const [formPerfil, setFormPerfil] = useState(PERFIS_DEFAULT);
  const [formSupervisor, setFormSupervisor] = useState("");
  const [formExibirCard, setFormExibirCard] = useState(true);
  const [formResponsavelEquipa, setFormResponsavelEquipa] = useState(false);
  const [aGravar, setAGravar] = useState(false);

  const [listaNome, setListaNome] = useState("");
  const [listaCodigo, setListaCodigo] = useState("");
  const [editListaId, setEditListaId] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    setACarregar(true);
    setErro("");
    const res = await obterDadosGestaoEquipa(supabase);
    setACarregar(false);
    if (!res.sucesso) {
      setErro(res.mensagem ?? "Erro ao carregar.");
      return;
    }
    setUtilizadores(res.utilizadores ?? []);
    setPontos(res.pontos ?? []);
    setSkills(res.skills ?? []);
    setPerfis(res.perfis ?? []);
    setPermissoes(res.permissoes ?? null);
  }, [supabase]);

  useEffect(() => {
    void carregar();
  }, [carregar]);

  const pontosActivos = useMemo(
    () => pontos.filter((p) => p.ativo),
    [pontos]
  );
  const skillsActivas = useMemo(
    () => skills.filter((s) => s.ativo !== false),
    [skills]
  );

  const supervisoresEquipa = useMemo(
    () => utilizadores.filter((u) => u.e_responsavel_equipa),
    [utilizadores]
  );

  const perfilSlugActual = useMemo(
    () => perfis.find((p) => p.id === formPerfil)?.slug ?? "colaborador",
    [perfis, formPerfil]
  );

  const filtrar = (texto: string) => {
    const q = pesquisa.toLowerCase();
    return texto.toLowerCase().includes(q);
  };

  const usersFiltrados = useMemo(
    () =>
      utilizadores.filter(
        (u) =>
          filtrar(u.nome) ||
          filtrar(u.email) ||
          filtrar(u.ponto_nome ?? "") ||
          filtrar(u.equipa_nome) ||
          filtrar(u.perfil_nome)
      ),
    [utilizadores, pesquisa]
  );

  const defaultsPorPerfil = (slug: string) => {
    if (slug === "colaborador") {
      return { exibirCard: true, responsavel: false };
    }
    if (slug === "supervisor") {
      return { exibirCard: true, responsavel: true };
    }
    return { exibirCard: false, responsavel: false };
  };

  const abrirModalUtilizador = (user?: UtilizadorEquipa) => {
    if (user) {
      setEmailOriginal(user.email);
      setFormEmail(user.email);
      setFormNome(user.nome);
      setFormPonto(user.ponto_atendimento_id ?? "");
      setFormEquipa(user.equipa_id);
      setFormPerfil(user.perfil_id ?? PERFIS_DEFAULT);
      setFormSupervisor(user.supervisor_id ?? "");
      setFormExibirCard(user.exibir_card_sala);
      setFormResponsavelEquipa(user.e_responsavel_equipa);
    } else {
      const defs = defaultsPorPerfil("colaborador");
      setEmailOriginal("");
      setFormEmail("");
      setFormNome("");
      setFormPonto(pontosActivos[0]?.id ?? "");
      setFormEquipa(skillsActivas[0]?.id ?? "");
      setFormPerfil(PERFIS_DEFAULT);
      setFormSupervisor("");
      setFormExibirCard(defs.exibirCard);
      setFormResponsavelEquipa(defs.responsavel);
    }
    setModalUser(true);
    setMsg("");
  };

  const gravarUtilizador = async () => {
    if (!permissoes?.gerir_utilizadores) return;
    setAGravar(true);
    setMsg("");
    const res = await guardarUtilizador(supabase, {
      emailOriginal: emailOriginal,
      email: formEmail.trim(),
      nome: formNome.trim(),
      pontoId: formPonto || null,
      equipaId: formEquipa,
      perfilId: formPerfil || null,
      supervisorId:
        perfilSlugActual === "colaborador" ? formSupervisor || null : null,
      exibirCardSala: formExibirCard,
      eResponsavelEquipa:
        perfilSlugActual === "colaborador" ? false : formResponsavelEquipa,
    });
    setAGravar(false);
    if (res.sucesso) {
      setModalUser(false);
      setMsg(`✅ ${res.mensagem}`);
      void carregar();
      return;
    }
    setMsg(res.mensagem ?? "Erro ao guardar.");
  };

  const removerUtilizador = async (email: string) => {
    if (!confirm(`Eliminar utilizador ${email}?`)) return;
    const res = await eliminarUtilizador(supabase, email);
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) void carregar();
  };

  const gravarLista = async (tipo: "pontos" | "skills") => {
    if (!permissoes?.gerir_equipas) return;
    const fn = tipo === "pontos" ? gerirPontoAtendimento : gerirSkill;
    const acao = editListaId ? "editar" : "adicionar";
    setAGravar(true);
    const res = await fn(supabase, acao, {
      id: editListaId ?? undefined,
      nome: listaNome.trim(),
      codigo: listaCodigo.trim(),
    });
    setAGravar(false);
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) {
      setListaNome("");
      setListaCodigo("");
      setEditListaId(null);
      void carregar();
    }
  };

  const toggleListaActivo = async (
    tipo: "pontos" | "skills",
    id: string,
    activo: boolean
  ) => {
    const fn = tipo === "pontos" ? gerirPontoAtendimento : gerirSkill;
    const res = await fn(supabase, activo ? "desactivar" : "activar", { id });
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) void carregar();
  };

  if (aCarregar) {
    return (
      <p className="py-12 text-center text-sm text-muted">
        A carregar gestao de equipa…
      </p>
    );
  }

  if (erro) {
    return (
      <p className="rounded-lg border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-200">
        {erro}
      </p>
    );
  }

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-bold text-white">
            👥 Gestão de Equipa & Estrutura
          </h1>
          <p className="text-xs text-muted">
            CRUD utilizadores, pontos, skills master e regras de fila por área.
            Skills M:N em massa → Gestor de Skills.
          </p>
        </div>
        {permissoes?.gerir_utilizadores && tab === "utilizadores" && (
          <button
            type="button"
            onClick={() => abrirModalUtilizador()}
            className="rounded-lg bg-emerald-600 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-500"
          >
            ➕ Criar Utilizador
          </button>
        )}
      </div>

      <div className="flex flex-wrap gap-1 border-b border-white/10 pb-1">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            onClick={() => {
              setTab(t.id);
              setMsg("");
              setPesquisa("");
            }}
            className={`rounded-t-lg px-3 py-2 text-xs font-semibold transition ${
              tab === t.id
                ? "border-b-2 border-brand bg-brand/10 text-brand"
                : "text-muted hover:text-white"
            }`}
          >
            {t.icon} {t.label}
          </button>
        ))}
      </div>

      {tab !== "regras" && (
        <input
          type="search"
          placeholder="🔍 Pesquisar na lista actual…"
          value={pesquisa}
          onChange={(e) => setPesquisa(e.target.value)}
          className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-xs text-white outline-none focus:border-brand/50"
        />
      )}

      {tab === "utilizadores" && (
        <div className="max-h-[450px] overflow-auto rounded-lg border border-white/10 bg-black/20">
          <table className="w-full text-left text-[11px]">
            <thead className="sticky top-0 bg-[#0a1628] text-[10px] uppercase text-muted">
              <tr>
                <th className="px-3 py-2">Email</th>
                <th className="px-3 py-2">Nome</th>
                <th className="px-3 py-2">Ponto</th>
                <th className="px-3 py-2">Skill prim.</th>
                <th className="px-3 py-2">Resp. equipa</th>
                <th className="px-3 py-2">Perfil</th>
                {permissoes?.gerir_utilizadores && (
                  <th className="px-3 py-2 text-center">Acções</th>
                )}
              </tr>
            </thead>
            <tbody>
              {usersFiltrados.map((u) => (
                <tr
                  key={u.id}
                  className="border-t border-white/5 hover:bg-white/[0.02]"
                >
                  <td className="px-3 py-2 text-white">{u.email}</td>
                  <td className="px-3 py-2">{u.nome}</td>
                  <td className="px-3 py-2 text-muted">
                    {u.ponto_nome ?? "—"}
                  </td>
                  <td className="px-3 py-2">{u.equipa_nome}</td>
                  <td className="px-3 py-2 text-muted">
                    {u.supervisor_nome ?? "—"}
                  </td>
                  <td className="px-3 py-2">{u.perfil_nome}</td>
                  {permissoes?.gerir_utilizadores && (
                    <td className="px-3 py-2 text-center">
                      <button
                        type="button"
                        onClick={() => abrirModalUtilizador(u)}
                        className="mr-2 text-brand hover:underline"
                      >
                        Editar
                      </button>
                      <button
                        type="button"
                        onClick={() => void removerUtilizador(u.email)}
                        className="text-red-400 hover:underline"
                      >
                        Eliminar
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {tab === "pontos" && (
        <ListaCrud
          items={pontos.filter(
            (p) => filtrar(p.nome) || filtrar(p.codigo)
          )}
          podeGerir={!!permissoes?.gerir_equipas}
          listaNome={listaNome}
          listaCodigo={listaCodigo}
          editId={editListaId}
          aGravar={aGravar}
          onNome={setListaNome}
          onCodigo={setListaCodigo}
          onEdit={(item) => {
            setEditListaId(item.id);
            setListaNome(item.nome);
            setListaCodigo(item.codigo);
          }}
          onCancel={() => {
            setEditListaId(null);
            setListaNome("");
            setListaCodigo("");
          }}
          onGravar={() => void gravarLista("pontos")}
          onToggle={(id, activo) => void toggleListaActivo("pontos", id, activo)}
        />
      )}

      {tab === "skills" && (
        <ListaCrud
          items={skills.filter(
            (s) => filtrar(s.nome) || filtrar(s.codigo)
          )}
          podeGerir={!!permissoes?.gerir_equipas}
          listaNome={listaNome}
          listaCodigo={listaCodigo}
          editId={editListaId}
          aGravar={aGravar}
          onNome={setListaNome}
          onCodigo={setListaCodigo}
          onEdit={(item) => {
            setEditListaId(item.id);
            setListaNome(item.nome);
            setListaCodigo(item.codigo);
          }}
          onCancel={() => {
            setEditListaId(null);
            setListaNome("");
            setListaCodigo("");
          }}
          onGravar={() => void gravarLista("skills")}
          onToggle={(id, activo) => void toggleListaActivo("skills", id, activo)}
          labelSkill
        />
      )}

      {tab === "perfis" && (
        <div className="space-y-3">
          <p className="text-xs text-muted">
            Perfis de sistema — atribuição via formulário de utilizador.
            {permissoes?.gerir_perfis
              ? " Gestão de permissões: perfil Developer."
              : " Apenas Developer gere permissões do sistema."}
          </p>
          <div className="max-h-[400px] overflow-auto rounded-lg border border-white/10 bg-black/20">
            <table className="w-full text-left text-[11px]">
              <thead className="sticky top-0 bg-[#0a1628] text-[10px] uppercase text-muted">
                <tr>
                  <th className="px-3 py-2">Perfil</th>
                  <th className="px-3 py-2">Slug</th>
                  <th className="px-3 py-2 text-right">Utilizadores</th>
                </tr>
              </thead>
              <tbody>
                {perfis
                  .filter((p) => filtrar(p.nome) || filtrar(p.slug))
                  .map((p) => (
                    <tr
                      key={p.id}
                      className="border-t border-white/5"
                    >
                      <td className="px-3 py-2 text-white">{p.nome}</td>
                      <td className="px-3 py-2 text-muted">{p.slug}</td>
                      <td className="px-3 py-2 text-right">{p.utilizadores}</td>
                    </tr>
                  ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === "regras" && (
        <div className="space-y-3">
          {permissoes?.gerir_regras ? (
            <>
              <p className="text-xs text-muted">
                As regras de fila por área passaram para o painel{" "}
                <strong className="text-white">Áreas &amp; Regras</strong> —
                formulário tipado em vez de JSON cru. O motor MS-11 continua a
                ler <code className="text-brand">regras_fila.config</code> na BD.
              </p>
              {onAbrirAdminRegras ? (
                <button
                  type="button"
                  onClick={onAbrirAdminRegras}
                  className="rounded-lg bg-brand px-6 py-2 text-xs font-bold text-white hover:bg-brand/90"
                >
                  Abrir Admin Áreas &amp; Regras
                </button>
              ) : (
                <p className="text-sm text-amber-200">
                  Aplica a migration MS-15 (supabase db push) para activar o
                  painel Admin Multi-Área.
                </p>
              )}
            </>
          ) : (
            <p className="text-sm text-amber-200">
              Sem permissão admin.regras_fila para editar configuração.
            </p>
          )}
        </div>
      )}

      {msg && (
        <p
          className={`text-center text-sm ${
            msg.startsWith("✅") ? "text-emerald-300" : "text-amber-200"
          }`}
        >
          {msg}
        </p>
      )}

      {modalUser && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4 backdrop-blur-sm">
          <div className="w-full max-w-md rounded-xl border border-white/10 bg-[#0f1941] p-6 shadow-xl">
            <h3 className="mb-4 border-b border-white/10 pb-2 text-base font-bold text-emerald-400">
              {emailOriginal ? "Editar utilizador" : "Novo utilizador"}
            </h3>
            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
              E-mail (chave de acesso)
            </label>
            <input
              type="email"
              value={formEmail}
              onChange={(e) => setFormEmail(e.target.value)}
              className="mb-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
            />
            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
              Nome completo
            </label>
            <input
              type="text"
              value={formNome}
              onChange={(e) => setFormNome(e.target.value)}
              className="mb-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
            />
            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
              Ponto de atendimento
            </label>
            <select
              value={formPonto}
              onChange={(e) => setFormPonto(e.target.value)}
              className="mb-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
            >
              <option value="">— Nenhum —</option>
              {pontosActivos.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.nome}
                </option>
              ))}
            </select>
            <div className="mb-3 grid grid-cols-2 gap-3">
              <div>
                <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                  Skill primária
                </label>
                <select
                  value={formEquipa}
                  onChange={(e) => setFormEquipa(e.target.value)}
                  className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
                >
                  {skillsActivas.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.nome}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                  Perfil / cargo
                </label>
                <select
                  value={formPerfil}
                  onChange={(e) => {
                    const id = e.target.value;
                    setFormPerfil(id);
                    const slug =
                      perfis.find((p) => p.id === id)?.slug ?? "colaborador";
                    const defs = defaultsPorPerfil(slug);
                    setFormExibirCard(defs.exibirCard);
                    setFormResponsavelEquipa(defs.responsavel);
                    if (slug === "colaborador") {
                      setFormSupervisor("");
                    }
                  }}
                  className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
                >
                  {perfis.map((p) => (
                    <option key={p.id} value={p.id}>
                      {p.nome}
                    </option>
                  ))}
                </select>
              </div>
            </div>
            <div className="mb-3 space-y-2 rounded-lg border border-white/10 bg-black/20 p-3">
              <label className="flex cursor-pointer items-start gap-2 text-xs text-white">
                <input
                  type="checkbox"
                  checked={formExibirCard}
                  onChange={(e) => {
                    const checked = e.target.checked;
                    setFormExibirCard(checked);
                    if (!checked) setFormResponsavelEquipa(false);
                  }}
                  className="mt-0.5"
                />
                <span>
                  <strong>Aparecer na Sala de Controlo</strong>
                  <span className="mt-0.5 block text-[10px] text-muted">
                    Card visível na grelha operacional (útil para developer que
                    também opera).
                  </span>
                </span>
              </label>
              {perfilSlugActual !== "colaborador" && formExibirCard && (
                <label className="flex cursor-pointer items-start gap-2 text-xs text-white">
                  <input
                    type="checkbox"
                    checked={formResponsavelEquipa}
                    onChange={(e) => setFormResponsavelEquipa(e.target.checked)}
                    className="mt-0.5"
                  />
                  <span>
                    <strong>Responsável de equipa (secção 👑)</strong>
                    <span className="mt-0.5 block text-[10px] text-muted">
                      Aparece na secção Supervisão e pode ser atribuído a
                      colaboradores.
                    </span>
                  </span>
                </label>
              )}
            </div>
            {perfilSlugActual === "colaborador" && (
              <>
                <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                  Responsável de equipa (supervisor)
                </label>
                <select
                  value={formSupervisor}
                  onChange={(e) => setFormSupervisor(e.target.value)}
                  className="mb-1 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
                >
                  <option value="">— Nenhum (fallback skill) —</option>
                  {supervisoresEquipa.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.nome}
                      {s.perfil_slug !== "supervisor"
                        ? ` (${s.perfil_nome})`
                        : ""}
                    </option>
                  ))}
                </select>
                {supervisoresEquipa.length === 0 && (
                  <p className="mb-3 text-[10px] text-amber-200">
                    Nenhum responsável disponível. Edita um utilizador (ex.: tu)
                    e marca «Responsável de equipa (secção 👑)».
                  </p>
                )}
              </>
            )}
            <p className="mb-3 text-[10px] text-muted">
              OAuth: o email tem de existir aqui antes do 1.º login Google.
            </p>
            <div className="flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setModalUser(false)}
                className="rounded-lg border border-white/10 px-4 py-2 text-xs font-semibold text-muted hover:text-white"
              >
                Cancelar
              </button>
              <button
                type="button"
                disabled={aGravar}
                onClick={() => void gravarUtilizador()}
                className="rounded-lg bg-emerald-600 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-500 disabled:opacity-50"
              >
                Gravar
              </button>
            </div>
            {msg && !msg.startsWith("✅") && (
              <p className="mt-3 text-center text-xs text-amber-200">{msg}</p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

interface ListaCrudProps {
  items: (PontoAtendimentoItem | SkillItem)[];
  podeGerir: boolean;
  listaNome: string;
  listaCodigo: string;
  editId: string | null;
  aGravar: boolean;
  labelSkill?: boolean;
  onNome: (v: string) => void;
  onCodigo: (v: string) => void;
  onEdit: (item: PontoAtendimentoItem | SkillItem) => void;
  onCancel: () => void;
  onGravar: () => void;
  onToggle: (id: string, activo: boolean) => void;
}

function ListaCrud({
  items,
  podeGerir,
  listaNome,
  listaCodigo,
  editId,
  aGravar,
  labelSkill,
  onNome,
  onCodigo,
  onEdit,
  onCancel,
  onGravar,
  onToggle,
}: ListaCrudProps) {
  return (
    <div className="space-y-3">
      {podeGerir && (
        <div className="flex flex-wrap items-end gap-2 rounded-lg border border-white/10 bg-black/20 p-3">
          <div className="min-w-[140px] flex-1">
            <label className="mb-1 block text-[10px] font-bold text-muted">
              Nome
            </label>
            <input
              value={listaNome}
              onChange={(e) => onNome(e.target.value)}
              className="w-full rounded-lg border border-white/10 bg-input px-2 py-1.5 text-xs text-white outline-none"
            />
          </div>
          <div className="min-w-[100px] flex-1">
            <label className="mb-1 block text-[10px] font-bold text-muted">
              Código
            </label>
            <input
              value={listaCodigo}
              onChange={(e) => onCodigo(e.target.value)}
              className="w-full rounded-lg border border-white/10 bg-input px-2 py-1.5 text-xs text-white outline-none"
            />
          </div>
          <button
            type="button"
            disabled={aGravar}
            onClick={onGravar}
            className="rounded-lg bg-brand px-4 py-2 text-xs font-bold text-white disabled:opacity-50"
          >
            {editId ? "Actualizar" : "Adicionar"}
          </button>
          {editId && (
            <button
              type="button"
              onClick={onCancel}
              className="rounded-lg border border-white/10 px-3 py-2 text-xs text-muted"
            >
              Cancelar
            </button>
          )}
        </div>
      )}
      <div className="max-h-[350px] overflow-auto rounded-lg border border-white/10 bg-black/20">
        <table className="w-full text-left text-[11px]">
          <thead className="sticky top-0 bg-[#0a1628] text-[10px] uppercase text-muted">
            <tr>
              <th className="px-3 py-2">Nome</th>
              <th className="px-3 py-2">Código</th>
              <th className="px-3 py-2">Estado</th>
              {podeGerir && <th className="px-3 py-2 text-center">Acções</th>}
            </tr>
          </thead>
          <tbody>
            {items.map((item) => (
              <tr key={item.id} className="border-t border-white/5">
                <td className="px-3 py-2 text-white">{item.nome}</td>
                <td className="px-3 py-2 text-muted">{item.codigo}</td>
                <td className="px-3 py-2">
                  <span
                    className={
                      item.ativo !== false
                        ? "text-emerald-400"
                        : "text-red-400 line-through"
                    }
                  >
                    {item.ativo !== false ? "Activo" : "Inactivo"}
                  </span>
                </td>
                {podeGerir && (
                  <td className="px-3 py-2 text-center">
                    <button
                      type="button"
                      onClick={() => onEdit(item)}
                      className="mr-2 text-brand hover:underline"
                    >
                      Editar
                    </button>
                    <button
                      type="button"
                      onClick={() =>
                        onToggle(item.id, item.ativo !== false)
                      }
                      className="text-amber-300 hover:underline"
                    >
                      {item.ativo !== false ? "Desactivar" : "Activar"}
                    </button>
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {labelSkill && (
        <p className="text-[10px] text-muted">
          Atribuição M:N operador↔skills continua no Gestor de Skills.
        </p>
      )}
    </div>
  );
}
