"use client";

interface ConfirmModalProps {
  aberto: boolean;
  titulo: string;
  descricao: string;
  confirmarLabel?: string;
  cancelarLabel?: string;
  aCarregar?: boolean;
  variante?: "default" | "warning";
  onConfirmar: () => void;
  onCancelar: () => void;
}

export function ConfirmModal({
  aberto,
  titulo,
  descricao,
  confirmarLabel = "Confirmar",
  cancelarLabel = "Cancelar",
  aCarregar = false,
  variante = "default",
  onConfirmar,
  onCancelar,
}: ConfirmModalProps) {
  if (!aberto) return null;

  const btnConfirm =
    variante === "warning"
      ? "bg-warning text-navy hover:bg-amber-400"
      : "bg-brand text-white hover:bg-brand-hover";

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-modal-title"
    >
      <div className="w-full max-w-md rounded-2xl border border-white/10 bg-card p-6 shadow-card">
        <p
          id="confirm-modal-title"
          className="text-lg font-bold text-white"
        >
          {titulo}
        </p>
        <p className="mt-3 text-sm leading-relaxed text-muted">{descricao}</p>
        <div className="mt-6 flex gap-3">
          <button
            type="button"
            onClick={onCancelar}
            disabled={aCarregar}
            className="flex-1 rounded-xl border border-white/15 py-3 text-sm font-semibold text-muted transition hover:bg-white/5 disabled:opacity-50"
          >
            {cancelarLabel}
          </button>
          <button
            type="button"
            onClick={onConfirmar}
            disabled={aCarregar}
            className={`flex-1 rounded-xl py-3 text-sm font-bold transition disabled:opacity-50 ${btnConfirm}`}
          >
            {aCarregar ? "A processar…" : confirmarLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
