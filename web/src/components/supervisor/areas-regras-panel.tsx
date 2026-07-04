"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  actualizarArea,
  criarArea,
  desactivarArea,
  listarAreas,
  obterAcessoAdminAreas,
  obterRegrasFilaArea,
  salvarRegrasFilaArea,
} from "@/lib/api/gestor";
import type {
  AreaItem,
  DesempateCampo,
  MotorOrdenacaoConfig,
  PermissoesAdminAreas,
  RegrasFilaConfig,
  TierAplicavel,
  TierLivreComRqs,
} from "@/lib/types/regras-fila";
import {
  defaultRegrasFilaConfig,
  DESEMPATE_CAMPOS,
  parseRegrasFilaConfig,
  TIERS_DISPONIVEIS,
  TIMEZONES_COMUNS,
} from "@/lib/types/regras-fila";

interface AreasRegrasPanelProps {
  supabase: SupabaseClient;
  areaIdUtilizador?: string;
}

function slugify(texto: string): string {
  return texto
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function Toggle({
  label,
  descricao,
  checked,
  onChange,
  disabled,
}: {
  label: string;
  descricao?: string;
  checked: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <label className="flex cursor-pointer items-start gap-3 rounded-lg border border-white/10 bg-black/20 p-3">
      <input
        type="checkbox"
        checked={checked}
        disabled={disabled}
        onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 accent-brand"
      />
      <span>
        <span className="block text-xs font-semibold text-white">{label}</span>
        {descricao && (
          <span className="mt-0.5 block text-[10px] text-muted">{descricao}</span>
        )}
      </span>
    </label>
  );
}

export function AreasRegrasPanel({
  supabase,
  areaIdUtilizador,
}: AreasRegrasPanelProps) {
  const [permissoes, setPermissoes] = useState<PermissoesAdminAreas | null>(
    null
  );
  const [areas, setAreas] = useState<AreaItem[]>([]);
  const [areaSel, setAreaSel] = useState<string>("");
  const [regras, setRegras] = useState<RegrasFilaConfig>(
    defaultRegrasFilaConfig()
  );
  const [jsonAvancado, setJsonAvancado] = useState("");
  const [mostrarJson, setMostrarJson] = useState(false);

  const [formNome, setFormNome] = useState("");
  const [formSlug, setFormSlug] = useState("");
  const [formTimezone, setFormTimezone] = useState("Europe/Lisbon");
  const [formAtivo, setFormAtivo] = useState(true);

  const [modalNova, setModalNova] = useState(false);
  const [novaNome, setNovaNome] = useState("");
  const [novaSlug, setNovaSlug] = useState("");
  const [novaTimezone, setNovaTimezone] = useState("Europe/Lisbon");
  const [novaFiltroLoja, setNovaFiltroLoja] = useState(false);

  const [vista, setVista] = useState<"lista" | "detalhe">("lista");
  const [aCarregar, setACarregar] = useState(true);
  const [aCarregarDetalhe, setACarregarDetalhe] = useState(false);
  const [aGravarArea, setAGravarArea] = useState(false);
  const [aGravarRegras, setAGravarRegras] = useState(false);
  const [erro, setErro] = useState("");
  const [msg, setMsg] = useState("");

  const areaActual = useMemo(
    () => areas.find((a) => a.id === areaSel) ?? null,
    [areas, areaSel]
  );

  const podeEditarArea = !!permissoes?.gerir_areas;
  const podeEditarRegras = !!permissoes?.gerir_regras;

  const areasOrdenadas = useMemo(
    () =>
      [...areas].sort((a, b) => {
        if (a.ativo !== b.ativo) return a.ativo ? -1 : 1;
        return a.nome.localeCompare(b.nome, "pt");
      }),
    [areas]
  );

  const carregarAreas = useCallback(async () => {
    const res = await listarAreas(supabase);
    if (!res.sucesso) {
      setErro(res.mensagem ?? "Erro ao listar áreas.");
      return false;
    }
    const lista = res.areas ?? [];
    setAreas(lista);
    return true;
  }, [supabase]);

  const carregarRegras = useCallback(
    async (areaId: string) => {
      setACarregarDetalhe(true);
      const res = await obterRegrasFilaArea(supabase, areaId);
      setACarregarDetalhe(false);
      if (!res.sucesso) {
        setMsg(res.mensagem ?? "Erro ao carregar regras.");
        return false;
      }
      const parsed = parseRegrasFilaConfig(res.config);
      setRegras(parsed);
      setJsonAvancado(JSON.stringify(parsed, null, 2));
      return true;
    },
    [supabase]
  );

  const abrirDetalhe = useCallback(
    async (areaId: string) => {
      setAreaSel(areaId);
      setVista("detalhe");
      setMsg("");
      setMostrarJson(false);
      await carregarRegras(areaId);
    },
    [carregarRegras]
  );

  const fecharDetalhe = () => {
    setVista("lista");
    setMsg("");
    setMostrarJson(false);
  };

  const init = useCallback(async () => {
    setACarregar(true);
    setErro("");
    const acc = await obterAcessoAdminAreas(supabase);
    if (!acc.sucesso) {
      setACarregar(false);
      setErro(acc.mensagem ?? "Sem permissão para Admin Multi-Área.");
      return;
    }
    setPermissoes(acc.permissoes ?? null);

    const ok = await carregarAreas();
    setACarregar(false);
    if (!ok) return;
  }, [supabase, carregarAreas]);

  useEffect(() => {
    void init();
  }, [init]);

  useEffect(() => {
    if (!areaActual) return;
    setFormNome(areaActual.nome);
    setFormSlug(areaActual.slug);
    setFormTimezone(areaActual.timezone);
    setFormAtivo(areaActual.ativo);
  }, [areaActual]);

  const actualizarMotor = (
    patch: Omit<
      Partial<RegrasFilaConfig["motor"]>,
      "ordenacao" | "filtros_elegibilidade" | "libertar_14h"
    > & {
      filtros?: Partial<RegrasFilaConfig["motor"]["filtros_elegibilidade"]>;
      ponto?: Partial<
        RegrasFilaConfig["motor"]["filtros_elegibilidade"]["ponto_atendimento"]
      >;
      skill?: Partial<
        RegrasFilaConfig["motor"]["filtros_elegibilidade"]["skill"]
      >;
      libertar?: Partial<RegrasFilaConfig["motor"]["libertar_14h"]>;
      ordenacao?: Partial<MotorOrdenacaoConfig>;
    }
  ) => {
    setRegras((prev) => {
      const next: RegrasFilaConfig = {
        ...prev,
        motor: {
          ...prev.motor,
          ...patch,
          versao: 3,
          filtros_elegibilidade: {
            skill: {
              ...prev.motor.filtros_elegibilidade.skill,
              ...patch.skill,
            },
            ponto_atendimento: {
              ...prev.motor.filtros_elegibilidade.ponto_atendimento,
              ...patch.ponto,
            },
          },
          ordenacao: {
            ...prev.motor.ordenacao,
            ...patch.ordenacao,
          },
          libertar_14h: {
            ...prev.motor.libertar_14h,
            ...patch.libertar,
          },
        },
      };
      setJsonAvancado(JSON.stringify(next, null, 2));
      return next;
    });
  };

  const actualizarDesempate = (idx: number, campo: DesempateCampo) => {
    const actuais = [...regras.motor.ordenacao.desempate];
    const prevIdx = actuais.indexOf(campo);
    if (prevIdx >= 0) actuais[prevIdx] = actuais[idx];
    actuais[idx] = campo;
    actualizarMotor({ ordenacao: { desempate: actuais } });
  };

  const toggleTier = (tier: TierAplicavel) => {
    const actuais =
      regras.motor.filtros_elegibilidade.ponto_atendimento.aplicar_tiers;
    const next = actuais.includes(tier)
      ? actuais.filter((t) => t !== tier)
      : [...actuais, tier];
    actualizarMotor({
      ponto: { aplicar_tiers: next },
    });
  };

  const gravarArea = async () => {
    if (!podeEditarArea || !areaSel) return;
    setAGravarArea(true);
    setMsg("");
    const res = await actualizarArea(supabase, {
      id: areaSel,
      nome: formNome,
      slug: formSlug,
      timezone: formTimezone,
      ativo: formAtivo,
    });
    setAGravarArea(false);
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) void carregarAreas();
  };

  const criarNovaArea = async () => {
    if (!podeEditarArea) return;
    setAGravarArea(true);
    setMsg("");
    const res = await criarArea(supabase, {
      nome: novaNome,
      slug: novaSlug || slugify(novaNome),
      timezone: novaTimezone,
      filtroLojaAtivo: novaFiltroLoja,
    });
    setAGravarArea(false);
    if (!res.sucesso) {
      setMsg(res.mensagem ?? "Erro ao criar área.");
      return;
    }
    setMsg(`✅ ${res.mensagem}`);
    setModalNova(false);
    setNovaNome("");
    setNovaSlug("");
    setNovaFiltroLoja(false);
    await carregarAreas();
    if (res.id) void abrirDetalhe(res.id);
  };

  const desactivarAreaItem = async (area: AreaItem) => {
    if (!podeEditarArea) return;
    if (
      !confirm(
        `Desactivar a área «${area.nome}»? Utilizadores existentes mantêm-se.`
      )
    ) {
      return;
    }
    const res = await desactivarArea(supabase, area.id);
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) {
      if (vista === "detalhe" && areaSel === area.id) fecharDetalhe();
      void carregarAreas();
    }
  };

  const gravarRegras = async () => {
    if (!podeEditarRegras || !areaSel) return;
    let config = regras;
    if (mostrarJson) {
      try {
        config = parseRegrasFilaConfig(JSON.parse(jsonAvancado));
      } catch {
        setMsg("JSON inválido — corrige a sintaxe.");
        return;
      }
    }
    setAGravarRegras(true);
    setMsg("");
    const res = await salvarRegrasFilaArea(supabase, areaSel, config);
    setAGravarRegras(false);
    setMsg(res.sucesso ? `✅ ${res.mensagem}` : (res.mensagem ?? "Erro."));
    if (res.sucesso) {
      setRegras(config);
      setJsonAvancado(JSON.stringify(config, null, 2));
    }
  };

  const addNudge = () => {
    setRegras((prev) => {
      const next = { ...prev, nudge_mensagens: [...prev.nudge_mensagens, ""] };
      setJsonAvancado(JSON.stringify(next, null, 2));
      return next;
    });
  };

  const updateNudge = (idx: number, valor: string) => {
    setRegras((prev) => {
      const msgs = [...prev.nudge_mensagens];
      msgs[idx] = valor;
      const next = { ...prev, nudge_mensagens: msgs };
      setJsonAvancado(JSON.stringify(next, null, 2));
      return next;
    });
  };

  const removeNudge = (idx: number) => {
    setRegras((prev) => {
      const next = {
        ...prev,
        nudge_mensagens: prev.nudge_mensagens.filter((_, i) => i !== idx),
      };
      setJsonAvancado(JSON.stringify(next, null, 2));
      return next;
    });
  };

  if (aCarregar) {
    return (
      <p className="py-12 text-center text-sm text-muted">
        A carregar Admin Multi-Área…
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
    <>
      <div className="space-y-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <h1 className="text-lg font-bold text-white">Áreas &amp; Regras</h1>
            <p className="mt-1 text-xs text-muted">
              Lista de áreas multi-tenant. Abre uma área para editar dados e
              regras de fila (
              <code className="text-brand">regras_fila.config</code>).
            </p>
          </div>
          {podeEditarArea && (
            <button
              type="button"
              onClick={() => setModalNova(true)}
              className="rounded-lg bg-brand px-4 py-2 text-xs font-bold text-white hover:bg-brand/90"
            >
              + Nova área
            </button>
          )}
        </div>

        {msg && vista === "lista" && (
          <p
            className={`rounded-lg px-3 py-2 text-sm ${
              msg.startsWith("✅")
                ? "border border-emerald-500/30 bg-emerald-500/10 text-emerald-300"
                : "border border-amber-500/30 bg-amber-500/10 text-amber-200"
            }`}
          >
            {msg}
          </p>
        )}

        <div className="overflow-hidden rounded-lg border border-white/10 bg-black/20">
          <div className="border-b border-white/10 px-4 py-2">
            <p className="text-[9px] font-bold uppercase tracking-widest text-brand">
              Áreas ({areasOrdenadas.length})
            </p>
          </div>
          {areasOrdenadas.length === 0 ? (
            <p className="px-4 py-8 text-center text-sm text-muted">
              Nenhuma área disponível.
            </p>
          ) : (
            <div className="max-h-[520px] overflow-auto">
              <table className="w-full text-left text-[11px]">
                <thead className="sticky top-0 bg-[#0a1628] text-[10px] uppercase text-muted">
                  <tr>
                    <th className="px-4 py-2">Nome</th>
                    <th className="px-4 py-2">Slug</th>
                    <th className="hidden px-4 py-2 sm:table-cell">Timezone</th>
                    <th className="px-4 py-2">Estado</th>
                    <th className="px-4 py-2 text-right">Acções</th>
                  </tr>
                </thead>
                <tbody>
                  {areasOrdenadas.map((area) => {
                    const minha =
                      !!areaIdUtilizador && area.id === areaIdUtilizador;
                    return (
                      <tr
                        key={area.id}
                        className="border-t border-white/5 hover:bg-white/[0.02]"
                      >
                        <td className="px-4 py-3">
                          <span className="font-semibold text-white">
                            {area.nome}
                          </span>
                          {minha && (
                            <span className="ml-2 text-[9px] text-brand">
                              (a tua)
                            </span>
                          )}
                        </td>
                        <td className="px-4 py-3 font-mono text-muted">
                          {area.slug}
                        </td>
                        <td className="hidden px-4 py-3 text-muted sm:table-cell">
                          {area.timezone}
                        </td>
                        <td className="px-4 py-3">
                          <span
                            className={`inline-flex rounded-full px-2 py-0.5 text-[9px] font-bold uppercase ${
                              area.ativo
                                ? "bg-emerald-500/20 text-emerald-300"
                                : "bg-white/10 text-muted"
                            }`}
                          >
                            {area.ativo ? "Activa" : "Inactiva"}
                          </span>
                        </td>
                        <td className="px-4 py-3 text-right">
                          {(podeEditarRegras || podeEditarArea) && (
                            <button
                              type="button"
                              onClick={() => void abrirDetalhe(area.id)}
                              className="mr-3 font-semibold text-brand hover:underline"
                            >
                              Configurar
                            </button>
                          )}
                          {podeEditarArea && area.ativo && (
                            <button
                              type="button"
                              onClick={() => void desactivarAreaItem(area)}
                              className="text-red-400 hover:underline"
                            >
                              Desactivar
                            </button>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>

      {vista === "detalhe" && areaActual && (
        <div className="fixed inset-0 z-50 flex justify-end bg-black/70 backdrop-blur-sm">
          <div className="flex h-full w-full max-w-3xl flex-col border-l border-white/10 bg-[#0b1529] shadow-2xl">
            <header className="flex shrink-0 items-start justify-between gap-3 border-b border-white/10 px-5 py-4">
              <div>
                <button
                  type="button"
                  onClick={fecharDetalhe}
                  className="mb-2 text-xs font-semibold text-muted hover:text-white"
                >
                  ← Voltar à lista
                </button>
                <h2 className="text-base font-bold text-white">
                  {areaActual.nome}
                </h2>
                <p className="mt-0.5 font-mono text-[10px] text-muted">
                  {areaActual.slug} · {areaActual.timezone}
                </p>
              </div>
              <span
                className={`shrink-0 rounded-full px-2 py-1 text-[9px] font-bold uppercase ${
                  areaActual.ativo
                    ? "bg-emerald-500/20 text-emerald-300"
                    : "bg-white/10 text-muted"
                }`}
              >
                {areaActual.ativo ? "Activa" : "Inactiva"}
              </span>
            </header>

            {msg && (
              <p
                className={`mx-5 mt-3 shrink-0 rounded-lg px-3 py-2 text-xs ${
                  msg.startsWith("✅")
                    ? "border border-emerald-500/30 bg-emerald-500/10 text-emerald-300"
                    : "border border-amber-500/30 bg-amber-500/10 text-amber-200"
                }`}
              >
                {msg}
              </p>
            )}

            <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
              {aCarregarDetalhe ? (
                <p className="py-12 text-center text-sm text-muted">
                  A carregar configuração…
                </p>
              ) : (
                <div className="space-y-6">
                  {podeEditarArea && (
                    <section className="space-y-3 rounded-lg border border-white/10 bg-black/20 p-4">
                      <p className="text-[9px] font-bold uppercase tracking-widest text-brand">
                        Dados da área
                      </p>
                      <div className="grid gap-3 sm:grid-cols-2">
                        <div>
                          <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                            Nome
                          </label>
                          <input
                            value={formNome}
                            onChange={(e) => setFormNome(e.target.value)}
                            className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
                          />
                        </div>
                        <div>
                          <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                            Slug
                          </label>
                          <input
                            value={formSlug}
                            onChange={(e) => setFormSlug(e.target.value)}
                            className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
                          />
                        </div>
                        <div>
                          <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                            Timezone
                          </label>
                          <select
                            value={formTimezone}
                            onChange={(e) => setFormTimezone(e.target.value)}
                            className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
                          >
                            {TIMEZONES_COMUNS.map((tz) => (
                              <option key={tz} value={tz}>
                                {tz}
                              </option>
                            ))}
                          </select>
                        </div>
                        <div className="flex items-end">
                          <Toggle
                            label="Área activa"
                            checked={formAtivo}
                            onChange={setFormAtivo}
                          />
                        </div>
                      </div>
                      <div className="flex flex-wrap gap-2">
                        <button
                          type="button"
                          disabled={aGravarArea}
                          onClick={() => void gravarArea()}
                          className="rounded-lg bg-emerald-600 px-4 py-2 text-xs font-bold text-white hover:bg-emerald-500 disabled:opacity-50"
                        >
                          Guardar dados
                        </button>
                        {areaActual.ativo && (
                          <button
                            type="button"
                            onClick={() => void desactivarAreaItem(areaActual)}
                            className="rounded-lg border border-red-500/30 px-4 py-2 text-xs font-semibold text-red-300 hover:bg-red-500/10"
                          >
                            Desactivar área
                          </button>
                        )}
                      </div>
                    </section>
                  )}

                  {podeEditarRegras && (
                    <>
                      <section className="space-y-4 rounded-lg border border-white/10 bg-black/20 p-4">
                        <p className="text-[9px] font-bold uppercase tracking-widest text-brand">
                          Elegibilidade
                        </p>
                        <div className="grid gap-3 sm:grid-cols-2">
                          <Toggle
                            label="Validar skills do operador"
                            descricao="Caso só elegível se a skill do caso estiver nas skills M:N do operador."
                            checked={
                              regras.motor.filtros_elegibilidade.skill.ativo
                            }
                            onChange={(v) =>
                              actualizarMotor({ skill: { ativo: v } })
                            }
                          />
                          <Toggle
                            label="Restringir fila à loja do operador"
                            descricao="ON: operador só recebe casos do seu ponto. OFF: fila centralizada (ex. E-Redes). Não depende do nº de lojas."
                            checked={
                              regras.motor.filtros_elegibilidade
                                .ponto_atendimento.ativo
                            }
                            onChange={(v) =>
                              actualizarMotor({ ponto: { ativo: v } })
                            }
                          />
                          <Toggle
                            label="Prioridades automáticas"
                            descricao="Tiers GAS: flash, RQS, agendamento, em tratamento, etc."
                            checked={regras.motor.tiers_completos}
                            onChange={(v) =>
                              actualizarMotor({ tiers_completos: v })
                            }
                          />
                          <Toggle
                            label="Libertar casos RQS às 14h"
                            descricao="Dono offline → caso libertado após a hora configurada."
                            checked={regras.motor.libertar_14h.ativo}
                            onChange={(v) =>
                              actualizarMotor({ libertar: { ativo: v } })
                            }
                          />
                        </div>

                        <div className="grid gap-2 sm:grid-cols-2">
                          <details className="rounded-lg border border-emerald-500/20 bg-emerald-500/5 p-3">
                            <summary className="cursor-pointer text-xs font-semibold text-emerald-300">
                              Exemplo: SU Eletricidade
                            </summary>
                            <ul className="mt-2 list-inside list-disc space-y-1 text-[11px] text-muted">
                              <li>Restringir fila à loja: ON</li>
                              <li>Validar skills: ON</li>
                              <li>Prioridade RQS: ON</li>
                              <li>Libertar 14h: ON</li>
                            </ul>
                          </details>
                          <details className="rounded-lg border border-sky-500/20 bg-sky-500/5 p-3">
                            <summary className="cursor-pointer text-xs font-semibold text-sky-300">
                              Exemplo: E-Redes
                            </summary>
                            <ul className="mt-2 list-inside list-disc space-y-1 text-[11px] text-muted">
                              <li>Restringir fila à loja: OFF</li>
                              <li>Validar skills: ON</li>
                              <li>RQS: conforme negócio</li>
                            </ul>
                          </details>
                        </div>

                        {regras.motor.filtros_elegibilidade.ponto_atendimento
                          .ativo && (
                          <div className="space-y-3 rounded-lg border border-white/5 bg-black/10 p-3">
                            <p className="text-[10px] font-bold uppercase text-muted">
                              Em que situações a loja conta
                            </p>
                            <div className="flex flex-wrap gap-2">
                              {TIERS_DISPONIVEIS.map((t) => {
                                const activo =
                                  regras.motor.filtros_elegibilidade.ponto_atendimento.aplicar_tiers.includes(
                                    t.id
                                  );
                                return (
                                  <button
                                    key={t.id}
                                    type="button"
                                    title={t.descricao}
                                    onClick={() => toggleTier(t.id)}
                                    className={`rounded-full px-3 py-1 text-[10px] font-semibold transition ${
                                      activo
                                        ? "bg-brand text-white"
                                        : "bg-input text-muted hover:text-white"
                                    }`}
                                  >
                                    {t.label}
                                  </button>
                                );
                              })}
                            </div>
                          </div>
                        )}

                        {regras.motor.libertar_14h.ativo && (
                          <div className="grid gap-3 sm:grid-cols-2">
                            <div>
                              <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                                Hora libertar 14h
                              </label>
                              <input
                                type="time"
                                value={regras.motor.libertar_14h.hora}
                                onChange={(e) =>
                                  actualizarMotor({
                                    libertar: { hora: e.target.value },
                                  })
                                }
                                className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
                              />
                            </div>
                            <div>
                              <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                                Timezone libertar 14h
                              </label>
                              <select
                                value={regras.motor.libertar_14h.timezone}
                                onChange={(e) =>
                                  actualizarMotor({
                                    libertar: { timezone: e.target.value },
                                  })
                                }
                                className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
                              >
                                {TIMEZONES_COMUNS.map((tz) => (
                                  <option key={tz} value={tz}>
                                    {tz}
                                  </option>
                                ))}
                              </select>
                            </div>
                          </div>
                        )}
                      </section>

                      <section className="space-y-4 rounded-lg border border-white/10 bg-black/20 p-4">
                        <p className="text-[9px] font-bold uppercase tracking-widest text-brand">
                          Ordenação e prioridade
                        </p>
                        <div className="grid gap-3 sm:grid-cols-2">
                          <Toggle
                            label="Usar prioridade RQS"
                            descricao="OFF: fila por antiguidade, sem tier 3."
                            checked={regras.motor.ordenacao.usar_rqs}
                            onChange={(v) =>
                              actualizarMotor({ ordenacao: { usar_rqs: v } })
                            }
                          />
                          <Toggle
                            label="Usar prioridade flash"
                            descricao="OFF: ignora tier -1 flash."
                            checked={regras.motor.ordenacao.usar_flash}
                            onChange={(v) =>
                              actualizarMotor({ ordenacao: { usar_flash: v } })
                            }
                          />
                        </div>
                        <div className="grid gap-3 sm:grid-cols-2">
                          <div>
                            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                              Tier 3 — livre com RQS hoje
                            </label>
                            <select
                              value={regras.motor.ordenacao.tier_livre_com_rqs}
                              onChange={(e) =>
                                actualizarMotor({
                                  ordenacao: {
                                    tier_livre_com_rqs: e.target
                                      .value as TierLivreComRqs,
                                  },
                                })
                              }
                              disabled={!regras.motor.ordenacao.usar_rqs}
                              className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50 disabled:opacity-50"
                            >
                              <option value="rqs_primeiro">
                                Desempate GAS
                              </option>
                              <option value="antiguidade">
                                Só antiguidade
                              </option>
                            </select>
                          </div>
                          <div>
                            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
                              Tier 4 — livre sem RQS hoje
                            </label>
                            <select
                              value={regras.motor.ordenacao.tier_livre_sem_rqs}
                              disabled
                              className="w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none opacity-70"
                            >
                              <option value="antiguidade">
                                Antiguidade (GAS)
                              </option>
                            </select>
                          </div>
                        </div>
                        <div>
                          <p className="mb-2 text-[10px] font-bold uppercase text-muted">
                            Ordem de desempate
                          </p>
                          <div className="grid gap-2 sm:grid-cols-3">
                            {[0, 1, 2].map((idx) => (
                              <div key={idx}>
                                <label className="mb-1 block text-[9px] text-muted">
                                  {idx + 1}º critério
                                </label>
                                <select
                                  value={
                                    regras.motor.ordenacao.desempate[idx] ??
                                    "criado_em"
                                  }
                                  onChange={(e) =>
                                    actualizarDesempate(
                                      idx,
                                      e.target.value as DesempateCampo
                                    )
                                  }
                                  disabled={!regras.motor.ordenacao.usar_rqs}
                                  className="w-full rounded-lg border border-white/10 bg-input px-2 py-2 text-xs text-white outline-none focus:border-brand/50 disabled:opacity-50"
                                >
                                  {DESEMPATE_CAMPOS.map((c) => (
                                    <option key={c.id} value={c.id}>
                                      {c.label}
                                    </option>
                                  ))}
                                </select>
                              </div>
                            ))}
                          </div>
                        </div>
                      </section>

                      <section className="space-y-3 rounded-lg border border-white/10 bg-black/20 p-4">
                        <div className="flex items-center justify-between">
                          <p className="text-[9px] font-bold uppercase tracking-widest text-brand">
                            Mensagens nudge
                          </p>
                          <button
                            type="button"
                            onClick={addNudge}
                            className="text-[10px] font-semibold text-brand hover:underline"
                          >
                            + Adicionar
                          </button>
                        </div>
                        <div className="space-y-2">
                          {regras.nudge_mensagens.length === 0 && (
                            <p className="text-xs text-muted">
                              Nenhuma mensagem configurada.
                            </p>
                          )}
                          {regras.nudge_mensagens.map((m, i) => (
                            <div key={i} className="flex gap-2">
                              <input
                                value={m}
                                onChange={(e) => updateNudge(i, e.target.value)}
                                placeholder="Texto do nudge…"
                                className="flex-1 rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
                              />
                              <button
                                type="button"
                                onClick={() => removeNudge(i)}
                                className="shrink-0 rounded-lg px-2 text-muted hover:text-red-300"
                                aria-label="Remover"
                              >
                                ✕
                              </button>
                            </div>
                          ))}
                        </div>
                      </section>

                      <details
                        open={mostrarJson}
                        onToggle={(e) =>
                          setMostrarJson(e.currentTarget.open)
                        }
                        className="rounded-lg border border-white/5 bg-black/10"
                      >
                        <summary className="cursor-pointer px-3 py-2 text-xs font-semibold text-muted hover:text-white">
                          Ver JSON avançado
                        </summary>
                        <textarea
                          value={jsonAvancado}
                          onChange={(e) => setJsonAvancado(e.target.value)}
                          rows={10}
                          spellCheck={false}
                          className="w-full border-t border-white/5 bg-black/30 p-3 font-mono text-[11px] text-emerald-100 outline-none"
                        />
                      </details>
                    </>
                  )}
                </div>
              )}
            </div>

            {podeEditarRegras && !aCarregarDetalhe && (
              <footer className="shrink-0 border-t border-white/10 px-5 py-4">
                <button
                  type="button"
                  disabled={aGravarRegras}
                  onClick={() => void gravarRegras()}
                  className="w-full rounded-lg bg-brand px-6 py-2.5 text-xs font-bold text-white hover:bg-brand/90 disabled:opacity-50 sm:w-auto"
                >
                  {aGravarRegras ? "A guardar…" : "Guardar regras de fila"}
                </button>
              </footer>
            )}
          </div>
        </div>
      )}

      {modalNova && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 p-4 backdrop-blur-sm">
          <div className="w-full max-w-md rounded-xl border border-white/10 bg-[#0f1941] p-6 shadow-xl">
            <h3 className="mb-4 border-b border-white/10 pb-2 text-base font-bold text-emerald-400">
              Nova área
            </h3>
            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
              Nome
            </label>
            <input
              value={novaNome}
              onChange={(e) => {
                setNovaNome(e.target.value);
                if (!novaSlug) setNovaSlug(slugify(e.target.value));
              }}
              placeholder="E-Redes"
              className="mb-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
            />
            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
              Slug
            </label>
            <input
              value={novaSlug}
              onChange={(e) => setNovaSlug(slugify(e.target.value))}
              placeholder="e-redes"
              className="mb-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none focus:border-brand/50"
            />
            <label className="mb-1 block text-[10px] font-bold uppercase text-muted">
              Timezone
            </label>
            <select
              value={novaTimezone}
              onChange={(e) => setNovaTimezone(e.target.value)}
              className="mb-3 w-full rounded-lg border border-white/10 bg-input px-3 py-2 text-sm text-white outline-none"
            >
              {TIMEZONES_COMUNS.map((tz) => (
                <option key={tz} value={tz}>
                  {tz}
                </option>
              ))}
            </select>
            <Toggle
              label="Restringir fila à loja do operador"
              descricao="ON = template SU Eletricidade (várias lojas, operador local). OFF = E-Redes / fila centralizada por skill."
              checked={novaFiltroLoja}
              onChange={setNovaFiltroLoja}
            />
            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setModalNova(false)}
                className="rounded-lg px-4 py-2 text-xs text-muted hover:text-white"
              >
                Cancelar
              </button>
              <button
                type="button"
                disabled={aGravarArea || !novaNome.trim()}
                onClick={() => void criarNovaArea()}
                className="rounded-lg bg-brand px-4 py-2 text-xs font-bold text-white hover:bg-brand/90 disabled:opacity-50"
              >
                Criar área
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
