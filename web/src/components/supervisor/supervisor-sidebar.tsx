"use client";

import type { PainelSupervisor } from "@/lib/types/gestor";

interface SupervisorSidebarProps {
  painel: PainelSupervisor;
  onPainel: (p: PainelSupervisor) => void;
  onActualizar?: () => void;
  aCarregar?: boolean;
  mostrarAdminAreas?: boolean;
}

const NAV: { id: PainelSupervisor; label: string; icon: string }[] = [
  { id: "controlo", label: "Sala de Controlo", icon: "👁️" },
  { id: "equipa", label: "Gestão de Equipa", icon: "👥" },
  { id: "skills", label: "Gestor de Skills", icon: "⚙️" },
  { id: "objetivos", label: "Gestor Objetivos", icon: "🎯" },
  { id: "import", label: "Importar Casos", icon: "📥" },
];

const NAV_ADMIN: { id: PainelSupervisor; label: string; icon: string } = {
  id: "areas",
  label: "Áreas & Regras",
  icon: "🏢",
};

export function SupervisorSidebar({
  painel,
  onPainel,
  onActualizar,
  aCarregar,
  mostrarAdminAreas,
}: SupervisorSidebarProps) {
  const items = mostrarAdminAreas ? [...NAV, NAV_ADMIN] : NAV;

  return (
    <aside className="w-full shrink-0 lg:sticky lg:top-4 lg:w-52 lg:max-h-[calc(100vh-2rem)]">
      <div className="flex flex-col gap-1 rounded-xl border border-white/10 bg-black/20 p-3 lg:overflow-y-auto lg:p-4">
        <h2 className="mb-2 hidden border-b border-white/10 pb-2 text-sm font-bold text-white lg:block">
          Supervisão
        </h2>
        <p className="mb-1 hidden text-[9px] font-bold uppercase tracking-widest text-brand lg:block">
          Ferramentas
        </p>
        <nav className="-mx-1 flex gap-1 overflow-x-auto pb-1 lg:mx-0 lg:flex-col lg:overflow-visible lg:pb-0">
          {items.map((item) => (
            <button
              key={item.id}
              type="button"
              onClick={() => onPainel(item.id)}
              className={`shrink-0 rounded-lg px-3 py-2 text-left text-xs font-semibold transition lg:w-full ${
                painel === item.id
                  ? "bg-brand/20 text-brand"
                  : "text-muted hover:bg-white/5 hover:text-white"
              }`}
            >
              {item.icon} {item.label}
            </button>
          ))}
        </nav>
        {painel === "controlo" && onActualizar && (
          <div className="mt-2 hidden border-t border-white/10 pt-3 lg:block">
            <button
              type="button"
              onClick={onActualizar}
              disabled={aCarregar}
              className="w-full rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-3 py-2 text-xs font-bold text-emerald-300 transition hover:bg-emerald-500/20 disabled:opacity-50"
            >
              {aCarregar ? "A actualizar…" : "🔄 Actualizar"}
            </button>
          </div>
        )}
      </div>
    </aside>
  );
}
