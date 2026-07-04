"use client";

import type { FilaSupervisao, DrillDownTipo } from "@/lib/types/supervisao";

interface KpiCardsProps {
  fila: FilaSupervisao;
  onDrillDown: (tipo: DrillDownTipo, titulo: string) => void;
}

interface KpiItem {
  tipo: DrillDownTipo;
  titulo: string;
  valor: number | string;
  label: string;
  sub?: string;
  cor: string;
  clicavel?: boolean;
}

export function KpiCards({ fila, onDrillDown }: KpiCardsProps) {
  const grupos: { titulo: string; cor: string; items: KpiItem[] }[] = [
    {
      titulo: "SLA & Prazos",
      cor: "border-warning",
      items: [
        {
          tipo: "atrasados",
          titulo: "Fora do SLA",
          valor: fila.atrasadosLivres,
          label: "Fora SLA (livres)",
          sub: `Act: ${fila.atrasadosTrabalho}`,
          cor: "text-warning",
          clicavel: true,
        },
        {
          tipo: "ultrapassadas",
          titulo: "RQS atrasadas",
          valor: fila.rqsUltrapassadasLivres,
          label: "RQS atr. (livres)",
          sub: `Act: ${fila.rqsUltrapassadasTrabalho}`,
          cor: "text-red-400",
          clicavel: true,
        },
        {
          tipo: "hoje",
          titulo: "RQS para hoje",
          valor: fila.rqsHojeLivres,
          label: "RQS hoje (livres)",
          sub: `Act: ${fila.rqsHojeTrabalho}`,
          cor: "text-amber-300",
          clicavel: true,
        },
      ],
    },
    {
      titulo: "Fila",
      cor: "border-success",
      items: [
        {
          tipo: "livres",
          titulo: "Casos livres",
          valor: fila.livres,
          label: "Livres",
          sub: `Trat: ${fila.tratadasDia} · Conc: ${fila.concluidasDia}`,
          cor: "text-emerald-400",
          clicavel: true,
        },
        {
          tipo: "carteira",
          titulo: "Carteira activa",
          valor: fila.carteira,
          label: "Na grelha",
          cor: "text-brand",
          clicavel: true,
        },
      ],
    },
    {
      titulo: "Operação",
      cor: "border-brand",
      items: [
        {
          tipo: "outro",
          titulo: "Estado Outro",
          valor: fila.outro,
          label: "Outro",
          cor: "text-purple-400",
          clicavel: true,
        },
        {
          tipo: "carteira",
          titulo: "Em tratamento",
          valor: fila.emTratamento,
          label: "Em trat.",
          cor: "text-sky-300",
          clicavel: false,
        },
        {
          tipo: "carteira",
          titulo: "TMT global",
          valor: fila.tmtGlobal,
          label: "TMT dia",
          cor: "text-white",
          clicavel: false,
        },
      ],
    },
  ];

  return (
    <div className="flex flex-wrap gap-3">
      {grupos.map((grupo) => (
        <section
          key={grupo.titulo}
          className={`min-w-[220px] flex-1 rounded-lg border border-white/10 border-t-2 ${grupo.cor} bg-black/20 p-3`}
        >
          <h3 className="mb-2 border-b border-white/5 pb-1.5 text-[9px] font-bold uppercase tracking-widest text-muted">
            {grupo.titulo}
          </h3>
          <div className="grid grid-cols-3 gap-2">
            {grupo.items.map((item) => (
              <button
                key={`${grupo.titulo}-${item.label}`}
                type="button"
                disabled={!item.clicavel}
                onClick={() =>
                  item.clicavel && onDrillDown(item.tipo, item.titulo)
                }
                className={`rounded-md bg-black/30 px-1.5 py-2 text-center transition ${
                  item.clicavel
                    ? "cursor-pointer hover:bg-black/50 hover:ring-1 hover:ring-brand/20"
                    : "cursor-default"
                }`}
              >
                <p className={`text-xl font-bold tabular-nums leading-none ${item.cor}`}>
                  {item.valor}
                </p>
                <p className="mt-1 text-[9px] font-semibold leading-tight text-white/90">
                  {item.label}
                </p>
                {item.sub && (
                  <p className="mt-0.5 text-[8px] leading-tight text-muted">{item.sub}</p>
                )}
              </button>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
