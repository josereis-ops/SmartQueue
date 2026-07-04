"use client";



import Image from "next/image";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";

import { createClient } from "@/lib/supabase/client";

import {

  atribuirTarefa,
  ativarAtendimentoLojaFlash,
  atualizarPresenca,
  marcarIntercalarCaso,
  obterPresencaActual,
  recuperarCasoEmTratamento,
} from "@/lib/api/fila";

import type { UtilizadorPerfil } from "@/lib/types/perfil";

import type {
  PresencaStatus,
  TarefaAtribuida,
} from "@/lib/types/fila";

import {
  classeBordaPresenca,
  classeSelectPresenca,
  ESTADOS_SIDEBAR_OPERADOR,
  parsePresencaStatus,
  PRESENCA_EMOJI,
  PRESENCA_LABELS,
  presencaMantemCasoAtivo,
  TODOS_ESTADOS_PRESENCA,
} from "@/lib/types/fila";

import { rqsExpiradaOuHoje, temIntercalarMarcada } from "@/lib/utils/rqs";

import { SignOutButton } from "@/components/sign-out-button";
import { ConfirmModal } from "@/components/ui/confirm-modal";

import { TaskActionPanel } from "@/components/operador/task-action-panel";
import {
  OperadorManualPanel,
  type EcraManual,
} from "@/components/operador/operador-manual-panel";

import { TmtTimer } from "@/components/operador/tmt-timer";



interface OperadorDashboardProps {

  perfil: UtilizadorPerfil;

}



interface NudgeAtivo {

  id: string;

  mensagem: string;

  remetenteNome: string;

}



function formatarData(iso: string | null): string {

  if (!iso) return "-";

  return new Date(iso).toLocaleString("pt-PT", {

    day: "2-digit",

    month: "2-digit",

    year: "numeric",

    hour: "2-digit",

    minute: "2-digit",

  });

}



export function OperadorDashboard({ perfil }: OperadorDashboardProps) {

  const supabase = createClient();

  const presencaInicial = parsePresencaStatus(perfil.presenca);

  const presencaRef = useRef<PresencaStatus>(presencaInicial);

  const [presenca, setPresenca] = useState<PresencaStatus>(presencaInicial);

  const [tarefa, setTarefa] = useState<TarefaAtribuida | null>(null);

  const [inicioTratamento, setInicioTratamento] = useState<string | null>(null);

  const [mensagem, setMensagem] = useState("");

  const [tipoMensagem, setTipoMensagem] = useState<"info" | "erro">("info");

  const [aCarregar, setACarregar] = useState(false);

  const [marcandoIntercalar, setMarcandoIntercalar] = useState(false);
  const [modalIntercalar, setModalIntercalar] = useState(false);
  const [flashEmCurso, setFlashEmCurso] = useState(false);
  const [ecraManual, setEcraManual] = useState<EcraManual>("principal");
  const [nudge, setNudge] = useState<NudgeAtivo | null>(null);

  const pedirEmCurso = useRef(false);

  const tarefaRef = useRef<TarefaAtribuida | null>(null);

  const acoesRef = useRef<HTMLElement>(null);



  tarefaRef.current = tarefa;



  const alertaRqsAtivo = tarefa ? rqsExpiradaOuHoje(tarefa.dataRqsIso) : false;

  const intercalarMarcado = tarefa ? temIntercalarMarcada(tarefa.intercalar) : false;



  const aplicarTarefa = useCallback(

    (nova: TarefaAtribuida, inicio: string | null = null) => {

      setTarefa(nova);

      setInicioTratamento(inicio ?? new Date().toISOString());

      setMensagem("");

      setACarregar(false);

      requestAnimationFrame(() => {

        acoesRef.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });

      });

    },

    []

  );



  const mostrarErro = (texto: string) => {

    setTipoMensagem("erro");

    setMensagem(texto);

  };



  const mostrarInfo = (texto: string) => {

    setTipoMensagem("info");

    setMensagem(texto);

  };



  const executarAtribuicao = useCallback(

    async (silencioso = false) => {

      if (pedirEmCurso.current) return;

      if (presencaRef.current !== "disponivel") return;

      if (tarefaRef.current) return;



      pedirEmCurso.current = true;

      if (!silencioso) setACarregar(true);



      const res = await atribuirTarefa(supabase, perfil.ponto_atendimento ?? perfil.equipa);



      pedirEmCurso.current = false;

      if (!silencioso) setACarregar(false);



      if (res.sucesso && res.tarefa) {

        aplicarTarefa(res.tarefa);

        return;

      }



      if (res.codigo_erro === "SQ_SEM_ELEGIVEIS") {
        if (!silencioso) {
          const skills = res.diag?.skills_operador;
          const loja = res.diag?.filtro_loja_ativo;
          const extra =
            skills !== undefined || loja !== undefined
              ? ` (${[
                  skills !== undefined ? `${skills} skill(s)` : null,
                  loja !== undefined ? `filtro loja ${loja ? "ON" : "OFF"}` : null,
                ]
                  .filter(Boolean)
                  .join(", ")})`
              : "";
          mostrarInfo(`Sem tarefas disponíveis para o teu perfil.${extra}`);
        }
        return;
      }



      if (!silencioso || res.codigo_erro === "SQ_SEM_PERMISSAO") {

        mostrarErro(res.mensagem ?? "Não foi possível atribuir tarefa.");

      }

    },

    [supabase, perfil.ponto_atendimento, perfil.equipa, aplicarTarefa]

  );



  const mudarEcraManual = (ecra: EcraManual) => {
    setEcraManual(ecra);
    setMensagem("");
  };

  const confirmarIntercalar = async () => {

    if (!tarefa || marcandoIntercalar) return;

    setMarcandoIntercalar(true);

    const res = await marcarIntercalarCaso(supabase, tarefa.id);

    setMarcandoIntercalar(false);

    setModalIntercalar(false);



    if (res.sucesso) {

      const iso = res.intercalar_em ?? new Date().toISOString();

      setTarefa({ ...tarefa, intercalar: iso });

      mostrarInfo("Intercalar marcada com sucesso.");

      return;

    }



    mostrarErro(res.mensagem ?? "Erro ao marcar intercalar.");

    if (res.ejetar) {

      setTarefa(null);

      setInicioTratamento(null);

    }

  };



  const aplicarPresenca = useCallback((nova: PresencaStatus) => {
    presencaRef.current = nova;
    setPresenca(nova);
  }, []);

  const activarClienteNaLoja = async () => {
    if (flashEmCurso) return;

    setFlashEmCurso(true);
    setACarregar(true);
    mostrarInfo("A suspender o caso por Cliente na Loja…");

    const res = await ativarAtendimentoLojaFlash(supabase);

    setFlashEmCurso(false);
    setACarregar(false);

    if (res.sucesso) {
      aplicarPresenca("atendimento_loja");
      setTarefa(null);
      setInicioTratamento(null);
      mostrarInfo(
        res.mensagem ?? "Atendimento Loja ativado. Caso suspenso com sucesso."
      );
      return;
    }

    mostrarErro(res.mensagem ?? "Falha ao ativar Cliente na Loja.");
  };

  const mudarPresenca = async (nova: PresencaStatus) => {
    if (nova === presencaRef.current) return;

    const res = await atualizarPresenca(supabase, perfil.id, nova);
    if (!res.sucesso) {
      mostrarErro(res.mensagem ?? "Erro ao actualizar presença.");
      return;
    }

    aplicarPresenca(nova);
    setMensagem("");

    if (nova === "trabalho_manual") {
      setEcraManual("trabalho");
    } else if (nova === "pausa") {
      setEcraManual("trabalho");
    } else if (nova === "disponivel") {
      setEcraManual("principal");
    }

    if (!presencaMantemCasoAtivo(nova) && (tarefaRef.current || (res.casos_suspensos ?? 0) > 0)) {
      setTarefa(null);
      setInicioTratamento(null);
    }

    if (nova === "disponivel") {
      await executarAtribuicao(false);
    }
  };



  const aposFecharCaso = () => {

    setTarefa(null);

    setInicioTratamento(null);

    if (presencaRef.current === "disponivel") {

      void executarAtribuicao(true);

    }

  };



  const fecharNudge = async (id: string) => {

    await supabase.from("notificacoes").update({ lida: true }).eq("id", id);

    setNudge(null);

  };



  useEffect(() => {
    void (async () => {
      const presencaDb = await obterPresencaActual(supabase, perfil.id);
      const efectiva = presencaDb ?? ((perfil.presenca as PresencaStatus) || "offline");
      aplicarPresenca(efectiva);

      if (efectiva === "pausa" || efectiva === "trabalho_manual") {
        setEcraManual("trabalho");
      }

      if (!presencaMantemCasoAtivo(efectiva)) {
        setTarefa(null);
        setInicioTratamento(null);
        return;
      }

      if (tarefaRef.current) return;

      const recuperado = await recuperarCasoEmTratamento(
        supabase,
        perfil.id,
        perfil.equipa
      );
      if (recuperado) {
        aplicarTarefa(recuperado.tarefa, recuperado.inicioTratamento);
      } else if (efectiva === "disponivel") {
        void executarAtribuicao(true);
      }
    })();
  }, [supabase, perfil.id, perfil.equipa, perfil.presenca, aplicarPresenca, aplicarTarefa, executarAtribuicao]);



  useEffect(() => {

    if (presenca !== "disponivel" || tarefa) return;

    const inicial = setTimeout(() => void executarAtribuicao(true), 1800);

    const id = setInterval(() => void executarAtribuicao(true), 35000);

    return () => {

      clearTimeout(inicial);

      clearInterval(id);

    };

  }, [presenca, tarefa, executarAtribuicao]);



  useEffect(() => {

    const canal = supabase

      .channel(`nudges-${perfil.id}`)

      .on(

        "postgres_changes",

        {

          event: "INSERT",

          schema: "public",

          table: "notificacoes",

          filter: `destinatario_id=eq.${perfil.id}`,

        },

        async (payload) => {

          const row = payload.new as {

            id: string;

            mensagem: string;

            remetente_id: string;

          };



          const { data: rem } = await supabase

            .from("utilizadores")

            .select("nome, email")

            .eq("id", row.remetente_id)

            .single();



          setNudge({

            id: row.id,

            mensagem: row.mensagem,

            remetenteNome:

              rem?.nome ?? rem?.email?.split("@")[0] ?? "Supervisão",

          });

        }

      )

      .subscribe();



    return () => {

      supabase.removeChannel(canal);

    };

  }, [supabase, perfil.id]);



  return (

    <div className="min-h-screen bg-navy">

      <header className="border-b border-white/10 bg-card/80 backdrop-blur-md">

        <div className="mx-auto flex max-w-5xl flex-wrap items-center justify-between gap-4 px-4 py-4 sm:px-6">

          <div className="flex items-center gap-4">

            <Image

              src="/randstad-logo.svg"

              alt="Randstad"

              width={140}

              height={32}

              priority

              className="h-8 w-auto"

            />

            <div className="hidden h-8 w-px bg-white/10 sm:block" />

            <div>

              <p className="text-[10px] font-bold uppercase tracking-widest text-brand">

                Smart Queue

              </p>

              <p className="text-sm font-semibold text-white">

                {perfil.nome.split(" ")[0]}
                {perfil.ponto_atendimento && (
                  <span className="ml-2 font-normal text-muted">
                    · {perfil.ponto_atendimento}
                  </span>
                )}
                <span className="ml-2 font-normal text-muted">
                  · {perfil.skills ?? perfil.equipa}
                </span>

              </p>

            </div>

          </div>



          <div className="flex items-center gap-3">

            {perfil.is_supervisao && (

              <Link

                href="/supervisor"

                className="hidden rounded-xl border border-brand/30 px-3 py-2 text-xs font-semibold text-brand transition hover:bg-brand/10 sm:inline-block"

              >

                Sala de Controlo

              </Link>

            )}

            <select
              value={presenca}
              onChange={(e) => void mudarPresenca(e.target.value as PresencaStatus)}
              className={`rounded-xl border px-4 py-2.5 text-sm font-semibold outline-none transition ${classeSelectPresenca(presenca)}`}
            >
              {TODOS_ESTADOS_PRESENCA.map((k) => (
                <option key={k} value={k} className="bg-card text-white">
                  {PRESENCA_EMOJI[k] ? `${PRESENCA_EMOJI[k]} ` : ""}
                  {PRESENCA_LABELS[k]}
                </option>
              ))}
            </select>

            <SignOutButton />

          </div>

        </div>

      </header>



      <div className="mx-auto flex max-w-6xl flex-col gap-4 px-4 py-6 sm:flex-row sm:px-6">
        <aside className="sticky top-4 flex shrink-0 flex-col gap-2 self-start rounded-xl border border-white/10 bg-black/20 p-4 sm:w-60">
          <p className="border-b border-white/10 pb-2 text-[10px] font-bold uppercase tracking-widest text-muted">
            ⚡ Alterar estado
          </p>
          <div className="flex flex-col gap-1">
            {ESTADOS_SIDEBAR_OPERADOR.map((est) => {
              const activo = presenca === est;
              return (
                <button
                  key={est}
                  type="button"
                  onClick={() => void mudarPresenca(est)}
                  className={`flex items-center gap-2 rounded-lg border border-white/5 border-l-4 bg-black/25 px-3 py-2 text-left text-xs font-semibold transition hover:bg-white/10 hover:text-white ${classeBordaPresenca(est)} ${
                    activo
                      ? "bg-brand/15 text-brand ring-1 ring-brand/30"
                      : "text-muted"
                  }`}
                >
                  {PRESENCA_EMOJI[est] && (
                    <span aria-hidden>{PRESENCA_EMOJI[est]}</span>
                  )}
                  {PRESENCA_LABELS[est]}
                </button>
              );
            })}
          </div>
          <p className="mt-2 border-t border-white/10 pt-2 text-[10px] font-bold uppercase tracking-widest text-muted">
            Ferramentas
          </p>
          <div className="flex flex-col gap-1">
            <button
              type="button"
              onClick={() => mudarEcraManual("principal")}
              className={`rounded-lg px-3 py-2 text-left text-xs font-semibold transition hover:bg-white/10 hover:text-white ${
                ecraManual === "principal"
                  ? "bg-brand/15 text-brand ring-1 ring-brand/30"
                  : "text-muted"
              }`}
            >
              🏠 Principal
            </button>
            <button
              type="button"
              onClick={() => {
                if (presenca !== "trabalho_manual") void mudarPresenca("trabalho_manual");
                else mudarEcraManual("trabalho");
              }}
              className={`rounded-lg px-3 py-2 text-left text-xs font-semibold transition hover:bg-white/10 hover:text-white ${
                ecraManual === "trabalho"
                  ? "bg-brand/15 text-brand ring-1 ring-brand/30"
                  : "text-muted"
              }`}
            >
              ⏳ Trabalho manual
            </button>
            <button
              type="button"
              onClick={() => mudarEcraManual("criar")}
              className={`rounded-lg px-3 py-2 text-left text-xs font-semibold transition hover:bg-white/10 hover:text-white ${
                ecraManual === "criar"
                  ? "bg-purple-500/15 text-purple-300 ring-1 ring-purple-500/30"
                  : "text-muted"
              }`}
            >
              ➕ Criar caso
            </button>
          </div>
          <p className="mt-2 border-t border-white/10 pt-2 text-[10px] text-muted">
            Offline e outros estados no selector do topo.
          </p>
        </aside>

        <main className="min-w-0 flex-1 space-y-5">

        {mensagem && (

          <p

            className={`rounded-xl px-4 py-3 text-sm ${

              tipoMensagem === "erro"

                ? "border border-red-500/30 bg-red-500/10 text-red-200"

                : "border border-emerald-500/30 bg-emerald-500/10 text-emerald-200"

            }`}

          >

            {mensagem}

          </p>

        )}



        {ecraManual !== "principal" ? (
          <OperadorManualPanel
            ecra={ecraManual}
            supabase={supabase}
            userId={perfil.id}
            equipaId={perfil.equipa_id}
            equipaFallback={perfil.equipa}
            aCarregar={aCarregar}
            temCasoActivo={!!tarefa}
            onEcra={mudarEcraManual}
            onTarefa={(nova) => aplicarTarefa(nova)}
            onErro={mostrarErro}
            onLoading={setACarregar}
          />
        ) : tarefa ? (

          <article className="glass-card overflow-hidden rounded-2xl border border-white/10 shadow-card">

            <div className="border-b border-white/10 bg-gradient-to-r from-brand/15 via-brand/5 to-transparent px-6 py-5">

              <div className="flex flex-wrap items-start justify-between gap-4">

                <TmtTimer inicioIso={inicioTratamento} />

                <div className="text-right">

                  {tarefa.prioridade_flash && (

                    <span className="mb-2 inline-block rounded-lg bg-red-500/20 px-3 py-1 text-xs font-bold uppercase tracking-wider text-red-300">

                      Flash

                    </span>

                  )}

                  <p className="text-[10px] font-bold uppercase tracking-widest text-muted">

                    Caso

                  </p>

                  <p className="text-2xl font-bold text-brand">{tarefa.idUnico}</p>

                </div>

              </div>

            </div>



            <div className="space-y-5 p-6">

              {alertaRqsAtivo && !intercalarMarcado && (

                <div className="rounded-xl border border-warning/40 bg-gradient-to-br from-warning/15 to-amber-500/5 p-5">

                  <div className="flex items-start gap-3">

                    <span className="text-2xl" aria-hidden>

                      ⚠️

                    </span>

                    <div className="flex-1 text-left">

                      <p className="text-sm font-bold text-warning">

                        RQS expirada ou para hoje

                      </p>

                      <p className="mt-1 text-xs leading-relaxed text-gray-light/90">

                        Se vais intercalar este caso noutro fluxo, confirma abaixo

                        para registar e desbloquear o agendamento.

                      </p>

                      <button

                        type="button"

                        onClick={() => setModalIntercalar(true)}

                        disabled={marcandoIntercalar}

                        className="mt-4 rounded-xl bg-warning px-6 py-2.5 text-sm font-bold text-navy shadow-sm transition hover:bg-amber-400 disabled:opacity-50"

                      >

                        Marcar como intercalar

                      </button>

                    </div>

                  </div>

                </div>

              )}



              {intercalarMarcado && (

                <p className="rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-4 py-2 text-center text-xs font-semibold text-emerald-300">

                  ✔ Intercalar marcada

                </p>

              )}



              <div className="grid gap-3 rounded-xl bg-input/60 p-4 text-sm sm:grid-cols-3">

                <div>

                  <p className="text-[10px] font-bold uppercase tracking-wider text-muted">

                    Equipa

                  </p>

                  <p className="mt-1 font-semibold text-white">

                    {tarefa.loja || perfil.equipa}

                  </p>

                </div>

                <div>

                  <p className="text-[10px] font-bold uppercase tracking-wider text-muted">

                    Canal

                  </p>

                  <p className="mt-1 font-semibold text-white">

                    {tarefa.canal ?? "-"}

                  </p>

                </div>

                <div>

                  <p className="text-[10px] font-bold uppercase tracking-wider text-muted">

                    PN

                  </p>

                  <p className="mt-1 font-semibold text-orange-400">{tarefa.pn}</p>

                </div>

                <div className="sm:col-span-2">

                  <p className="text-[10px] font-bold uppercase tracking-wider text-muted">

                    RQS

                  </p>

                  <p className="mt-1 font-semibold text-white">

                    {formatarData(tarefa.dataRqsIso)}

                  </p>

                </div>

                <div>

                  <p className="text-[10px] font-bold uppercase tracking-wider text-muted">

                    Agendamento

                  </p>

                  <p className="mt-1 font-semibold text-white">

                    {formatarData(tarefa.dataDespertadorIso)}

                  </p>

                </div>

              </div>



              {tarefa.observacoes && (

                <div className="rounded-xl border-l-4 border-brand bg-brand/5 p-4">

                  <p className="text-[10px] font-bold uppercase tracking-wider text-brand">

                    Observações

                  </p>

                  <p className="mt-2 whitespace-pre-wrap text-sm text-gray-light">

                    {tarefa.observacoes}

                  </p>

                </div>

              )}



              <section

                ref={acoesRef}

                className="rounded-xl border border-white/10 bg-black/20 p-4"

              >

                <p className="mb-3 text-[10px] font-bold uppercase tracking-widest text-brand">
                  Alterar estado do caso
                </p>

                <button
                  type="button"
                  onClick={() => void activarClienteNaLoja()}
                  disabled={aCarregar || flashEmCurso}
                  className="mb-4 w-full rounded-xl bg-gradient-to-r from-orange-500 to-orange-400 px-6 py-3 text-sm font-bold uppercase tracking-wide text-white shadow-sm transition hover:from-orange-400 hover:to-orange-300 disabled:opacity-50"
                >
                  🏃 CLIENTE NA LOJA (PAUSA FLASH)
                </button>

                <TaskActionPanel

                  tarefa={tarefa}

                  aCarregar={aCarregar}

                  alertaRqsAtivo={alertaRqsAtivo}

                  intercalarMarcado={intercalarMarcado}

                  onLoading={setACarregar}

                  onSucesso={aposFecharCaso}

                  onErro={mostrarErro}

                />

              </section>

            </div>

          </article>

        ) : (

          <section className="glass-card rounded-2xl border border-white/10 p-10 text-center shadow-card">

            <p className="text-xs font-bold uppercase tracking-widest text-muted">

              {perfil.area}

            </p>

            {presenca === "disponivel" ? (
              <>
                <p className="mt-4 text-muted">
                  {aCarregar
                    ? "A procurar tarefa na fila…"
                    : "Disponível — atribuição automática activa"}
                </p>
                <button
                  type="button"
                  onClick={() => void executarAtribuicao(false)}
                  disabled={aCarregar}
                  className="mt-8 rounded-xl bg-brand px-10 py-4 text-sm font-bold uppercase tracking-wide text-white shadow-brand transition hover:bg-brand-hover disabled:opacity-50"
                >
                  Pedir tarefa agora
                </button>
              </>
            ) : presenca === "pausa" ? (
              <p className="mt-4 text-muted">
                Em pausa — muda para Disponível para receber tarefas.
              </p>
            ) : presenca === "offline" ? (
              <p className="mt-4 text-muted">
                Offline — selecciona{" "}
                <strong className="text-white">Disponível</strong> para entrar na
                fila.
              </p>
            ) : (
              <p className="mt-4 text-muted">
                {PRESENCA_EMOJI[presenca] && (
                  <span className="mr-1">{PRESENCA_EMOJI[presenca]}</span>
                )}
                <strong className="text-white">{PRESENCA_LABELS[presenca]}</strong>
                {" — "}
                {presenca === "trabalho_manual"
                  ? "usa a ferramenta Trabalho manual na barra lateral."
                  : "não recebes tarefas automáticas. Muda para Disponível para voltar à fila."}
              </p>
            )}

          </section>

        )}

        </main>
      </div>



      <ConfirmModal
        aberto={modalIntercalar}
        titulo="Marcar como intercalar?"
        descricao="Confirmas que este caso será tratado em fluxo intercalado? Esta acção fica registada no servidor e permite agendar para além do limite da RQS de hoje."
        confirmarLabel="Sim, marcar intercalar"
        cancelarLabel="Ainda não"
        variante="warning"
        aCarregar={marcandoIntercalar}
        onConfirmar={() => void confirmarIntercalar()}
        onCancelar={() => setModalIntercalar(false)}
      />

      {nudge && (

        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm">

          <div className="w-full max-w-md rounded-2xl border border-brand/40 bg-card p-6 shadow-card">

            <p className="text-[10px] font-bold uppercase tracking-widest text-brand">

              Toque da supervisão

            </p>

            <p className="mt-1 text-sm text-muted">De: {nudge.remetenteNome}</p>

            <p className="mt-4 text-base text-white">{nudge.mensagem}</p>

            <button

              type="button"

              onClick={() => fecharNudge(nudge.id)}

              className="mt-6 w-full rounded-xl bg-brand py-3 text-sm font-bold text-white"

            >

              OK, percebi

            </button>

          </div>

        </div>

      )}

    </div>

  );

}


