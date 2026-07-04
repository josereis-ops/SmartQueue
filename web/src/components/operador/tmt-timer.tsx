"use client";

import { useEffect, useState } from "react";

export function formatarTmt(segundos: number): string {
  const s = Math.max(0, segundos);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60)
    .toString()
    .padStart(2, "0");
  const sec = (s % 60).toString().padStart(2, "0");
  if (h > 0) return `${h}:${m}:${sec}`;
  return `${m}:${sec}`;
}

function classeTmt(segundos: number): string {
  if (segundos >= 1800) return "text-red-400";
  if (segundos >= 1200) return "text-amber-400";
  return "text-emerald-400";
}

interface TmtTimerProps {
  inicioIso: string | null;
}

export function TmtTimer({ inicioIso }: TmtTimerProps) {
  const [segundos, setSegundos] = useState(0);

  useEffect(() => {
    if (!inicioIso) {
      setSegundos(0);
      return;
    }

    const inicio = new Date(inicioIso).getTime();
    const tick = () =>
      setSegundos(Math.floor((Date.now() - inicio) / 1000));

    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [inicioIso]);

  return (
    <div className="text-center sm:text-left">
      <p className="text-[10px] font-bold uppercase tracking-[0.25em] text-muted">
        TMT
      </p>
      <p
        className={`font-mono text-4xl font-bold tabular-nums tracking-wider sm:text-5xl ${classeTmt(segundos)}`}
        aria-live="polite"
        aria-label={`Tempo médio de tratamento: ${formatarTmt(segundos)}`}
      >
        {inicioIso ? formatarTmt(segundos) : "--:--"}
      </p>
    </div>
  );
}
