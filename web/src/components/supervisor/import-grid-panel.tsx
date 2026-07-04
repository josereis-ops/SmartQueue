"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { SupabaseClient } from "@supabase/supabase-js";
import {
  importarCasosLote,
  obterDadosGestaoEquipa,
  obterDadosGestorSkills,
  obterIdsImportacao,
} from "@/lib/api/gestor";
import {
  celulaEditavel,
  COL_LOJA,
  COL_RESPONSAVEL,
  COL_SKILL,
  errosObrigatorios,
  ESTADOS_IMPORT,
  formatarValorCelula,
  intervaloCelulas,
  NUM_COLS,
  parseExcelRobust,
  PRIORIDADES_IMPORT,
  seleccionParaClipboard,
  tipoCelula,
  type CelulaSel,
} from "@/lib/import/grid-helpers";
import { normalizarIdImportacao } from "@/lib/import/normalizacao";
import { COLUNAS_IMPORT, type LinhaImportacao } from "@/lib/types/gestor";

interface ImportGridPanelProps {
  supabase: SupabaseClient;
  onVoltar?: () => void;
}

const LINHAS_INICIAIS = 20;
const MAX_UNDO = 20;

function linhaVazia(): LinhaImportacao {
  return Array(NUM_COLS).fill("");
}

export function ImportGridPanel({ supabase, onVoltar }: ImportGridPanelProps) {
  const [grid, setGrid] = useState<LinhaImportacao[]>(() =>
    Array.from({ length: LINHAS_INICIAIS }, linhaVazia)
  );
  const [idsNegra, setIdsNegra] = useState<Set<string>>(new Set());
  const [emailLoja, setEmailLoja] = useState<Record<string, string>>({});
  const [emailsResp, setEmailsResp] = useState<string[]>([]);
  const [skills, setSkills] = useState<string[]>([]);
  const [msg, setMsg] = useState("");
  const [aProcessar, setAProcessar] = useState(false);
  const [rowStatus, setRowStatus] = useState<
    Record<number, "dup" | "invalid" | "ok" | "">
  >({});
  const [seleccionadas, setSeleccionadas] = useState<CelulaSel[]>([]);
  const [highlightCol, setHighlightCol] = useState<number | null>(null);
  const [highlightRow, setHighlightRow] = useState<number | null>(null);
  const [modalFalhas, setModalFalhas] = useState<
    { linha: number; id: string; erros: string[] }[] | null
  >(null);

  const undoStack = useRef<string[]>([]);
  const anchorRef = useRef<CelulaSel | null>(null);
  const isDragging = useRef(false);
  const gridRef = useRef<HTMLDivElement>(null);

  const pushUndo = useCallback((state: LinhaImportacao[]) => {
    undoStack.current.push(JSON.stringify(state));
    if (undoStack.current.length > MAX_UNDO) undoStack.current.shift();
  }, []);

  const carregarIds = useCallback(async () => {
    const res = await obterIdsImportacao(supabase);
    if (res.sucesso && res.ids) {
      setIdsNegra(new Set(res.ids.map(normalizarIdImportacao)));
    }
  }, [supabase]);

  useEffect(() => {
    void carregarIds();
    void obterDadosGestorSkills(supabase).then((res) => {
      if (res.sucesso && res.users && res.skills) {
        setEmailsResp(res.users.map((u) => u.email).sort());
        setSkills(res.skills.map((s) => s.nome).sort());
      }
    });
    void obterDadosGestaoEquipa(supabase).then((res) => {
      if (res.sucesso && res.utilizadores) {
        const map: Record<string, string> = {};
        res.utilizadores.forEach((u) => {
          if (u.email && u.ponto_nome) {
            map[u.email.toLowerCase()] = u.ponto_nome;
          }
        });
        setEmailLoja(map);
      }
    });
  }, [supabase, carregarIds]);

  const validarLocal = useCallback(
    (rows: LinhaImportacao[]) => {
      const vistos = new Set<string>();
      const status: Record<number, "dup" | "invalid" | "ok" | ""> = {};

      rows.forEach((row, idx) => {
        const id = normalizarIdImportacao(row[1] ?? "");
        const contacto = normalizarIdImportacao(row[16] ?? "");
        if (!id) {
          status[idx] = "";
          return;
        }

        const erros = errosObrigatorios(row);
        const dup =
          idsNegra.has(id) ||
          (contacto !== "" && idsNegra.has(contacto)) ||
          vistos.has(id) ||
          (contacto !== "" && vistos.has(contacto));

        if (dup) status[idx] = "dup";
        else if (erros.length > 0) status[idx] = "invalid";
        else status[idx] = "ok";

        vistos.add(id);
        if (contacto) vistos.add(contacto);
      });

      setRowStatus(status);
    },
    [idsNegra]
  );

  useEffect(() => {
    validarLocal(grid);
  }, [grid, validarLocal]);

  const stats = {
    novos: Object.values(rowStatus).filter((s) => s === "ok").length,
    duplicados: Object.values(rowStatus).filter((s) => s === "dup").length,
    invalidos: Object.values(rowStatus).filter((s) => s === "invalid").length,
  };

  const autoPreencherLoja = useCallback(
    (rowIdx: number, email: string) => {
      const loja = emailLoja[email.toLowerCase().trim()];
      if (!loja) return;
      setGrid((prev) => {
        const next = prev.map((r) => [...r]);
        if (!next[rowIdx]) next[rowIdx] = linhaVazia();
        next[rowIdx][COL_LOJA] = loja;
        return next;
      });
    },
    [emailLoja]
  );

  const actualizarCelula = (row: number, col: number, val: string) => {
    setGrid((prev) => {
      pushUndo(prev);
      const next = prev.map((r) => [...r]);
      if (!next[row]) next[row] = linhaVazia();
      next[row][col] = formatarValorCelula(col, val);
      return next;
    });
    if (col === COL_RESPONSAVEL && val.trim()) {
      autoPreencherLoja(row, val);
    }
  };

  const apagarLinha = (rowIdx: number) => {
    setGrid((prev) => {
      pushUndo(prev);
      return prev.filter((_, i) => i !== rowIdx);
    });
    setSeleccionadas([]);
  };

  const limparSeleccionadas = () => {
    if (seleccionadas.length === 0) return;
    setGrid((prev) => {
      pushUndo(prev);
      const next = prev.map((r) => [...r]);
      seleccionadas.forEach(({ row, col }) => {
        if (next[row] && celulaEditavel(col)) next[row][col] = "";
      });
      return next;
    });
    setSeleccionadas([]);
  };

  const iniciarSelecao = (row: number, col: number, shift: boolean) => {
    setHighlightCol(null);
    setHighlightRow(null);
    isDragging.current = true;

    if (shift && anchorRef.current) {
      setSeleccionadas(intervaloCelulas(anchorRef.current, { row, col }));
      return;
    }

    anchorRef.current = { row, col };
    setSeleccionadas([{ row, col }]);
  };

  const expandirSelecao = (row: number, col: number) => {
    if (!isDragging.current || !anchorRef.current) return;
    setSeleccionadas(intervaloCelulas(anchorRef.current, { row, col }));
  };

  useEffect(() => {
    const up = () => {
      isDragging.current = false;
    };
    window.addEventListener("mouseup", up);
    return () => window.removeEventListener("mouseup", up);
  }, []);

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "z") {
      e.preventDefault();
      if (undoStack.current.length === 0) return;
      const last = JSON.parse(undoStack.current.pop()!) as LinhaImportacao[];
      setGrid(last);
      setSeleccionadas([]);
      return;
    }
    if (e.key === "Delete" || e.key === "Backspace") {
      const target = e.target as HTMLElement;
      if (target.tagName === "INPUT" || target.tagName === "SELECT") {
        e.preventDefault();
        limparSeleccionadas();
      }
    }
    if (e.key === "Escape") {
      setSeleccionadas([]);
      setHighlightCol(null);
      setHighlightRow(null);
    }
  };

  const colarNaGrelha = useCallback(
    (text: string, start?: CelulaSel) => {
      const rows = parseExcelRobust(text).filter((l) => l.some((c) => c.trim()));
      if (rows.length === 0) return;

      pushUndo(grid);
      const startR = start?.row ?? 0;
      const startC = start?.col ?? 0;
      const selSet =
        seleccionadas.length > 1
          ? [...seleccionadas].sort((a, b) => a.row - b.row || a.col - b.col)
          : null;

      setGrid((prev) => {
        const next = [...prev];
        const totalNecessario = startR + rows.length;
        while (next.length < totalNecessario) {
          next.push(linhaVazia());
        }

        if (selSet && selSet.length > 1) {
          const byRow: Record<number, CelulaSel[]> = {};
          selSet.forEach((c) => {
            if (!byRow[c.row]) byRow[c.row] = [];
            byRow[c.row].push(c);
          });
          const rowKeys = Object.keys(byRow)
            .map(Number)
            .sort((a, b) => a - b);

          rowKeys.forEach((r, rIdx) => {
            const sourceRow = rows[rIdx % rows.length];
            const cells = byRow[r].sort((a, b) => a.col - b.col);
            let srcCol = 0;
            cells.forEach((cell) => {
              if (!celulaEditavel(cell.col)) return;
              const val = sourceRow[srcCol % sourceRow.length] ?? "";
              if (!next[cell.row]) next[cell.row] = linhaVazia();
              next[cell.row][cell.col] = formatarValorCelula(cell.col, val.trim());
              srcCol++;
            });
          });
        } else {
          rows.forEach((rowData, rIdx) => {
            let gridCol = startC;
            rowData.forEach((val) => {
              while (gridCol < NUM_COLS && !celulaEditavel(gridCol)) gridCol++;
              if (gridCol >= NUM_COLS) return;
              if (!next[startR + rIdx]) next[startR + rIdx] = linhaVazia();
              next[startR + rIdx][gridCol] = formatarValorCelula(
                gridCol,
                val.trim()
              );
              gridCol++;
            });
          });
        }

        next.forEach((row, idx) => {
          const email = row[COL_RESPONSAVEL]?.trim();
          if (email && emailLoja[email.toLowerCase()]) {
            next[idx][COL_LOJA] = emailLoja[email.toLowerCase()];
          }
        });

        return next;
      });

      setSeleccionadas([]);
      setMsg(`Colados ${rows.length} linha(s) do Excel.`);
    },
    [grid, pushUndo, seleccionadas, emailLoja]
  );

  const handlePaste = (e: React.ClipboardEvent) => {
    const text = e.clipboardData.getData("text/plain");
    if (!text.includes("\t") && !text.includes("\n")) return;
    e.preventDefault();
    const start =
      seleccionadas.length > 0
        ? seleccionadas[0]
        : anchorRef.current ?? { row: 0, col: 0 };
    colarNaGrelha(text, start);
  };

  const handleCopy = (e: React.ClipboardEvent) => {
    if (seleccionadas.length === 0) return;
    e.preventDefault();
    const text = seleccionParaClipboard(grid, seleccionadas);
    e.clipboardData.setData("text/plain", text);
  };

  const adicionarLinhas = (n: number) => {
    setGrid((prev) => [...prev, ...Array.from({ length: n }, linhaVazia)]);
  };

  const processar = async () => {
    const rowsToSend: LinhaImportacao[] = [];
    let dupCount = 0;
    let invalidCount = 0;

    grid.forEach((row, idx) => {
      const id = normalizarIdImportacao(row[1] ?? "");
      if (!id) return;
      const st = rowStatus[idx];
      if (st === "dup") {
        dupCount += 1;
        return;
      }
      if (st === "invalid") {
        invalidCount += 1;
        return;
      }
      if (st === "ok") rowsToSend.push(row);
    });

    if (invalidCount > 0) {
      setMsg(
        `Importação bloqueada: ${invalidCount} linha(s) inválidas (laranja). Corrige antes de continuar.`
      );
      return;
    }

    if (rowsToSend.length === 0) {
      setMsg("Nenhuma linha nova para importar (duplicados ou vazios).");
      return;
    }

    const ok = window.confirm(
      `Validação concluída.\n\nNovos: ${rowsToSend.length}\nDuplicados ignorados: ${dupCount}\n\nConfirmar gravação?`
    );
    if (!ok) return;

    setAProcessar(true);
    setMsg("A gravar no Supabase…");

    const res = await importarCasosLote(supabase, rowsToSend);
    setAProcessar(false);

    if (res.sucesso) {
      setMsg(`✅ ${res.mensagem}`);
      setGrid(Array.from({ length: LINHAS_INICIAIS }, linhaVazia));
      setRowStatus({});
      setSeleccionadas([]);
      undoStack.current = [];
      setModalFalhas(null);
      void carregarIds();
      return;
    }

    if (res.falhas && res.falhas.length > 0) setModalFalhas(res.falhas);
    setMsg(res.mensagem ?? "Erro na importação.");
  };

  const celulaSeleccionada = (row: number, col: number) =>
    seleccionadas.some((s) => s.row === row && s.col === col);

  const renderInput = (rowIdx: number, colIdx: number, val: string) => {
    const tipo = tipoCelula(colIdx);
    const baseClass =
      "w-full min-w-[72px] border-none bg-transparent px-1.5 py-1 text-white outline-none focus:bg-brand/10";

    if (tipo === "loja") {
      return (
        <input
          readOnly
          value={val}
          placeholder="Auto"
          className={`${baseClass} text-muted italic`}
        />
      );
    }

    if (tipo === "estado") {
      return (
        <select
          value={val}
          onChange={(e) => actualizarCelula(rowIdx, colIdx, e.target.value)}
          onFocus={() => setSeleccionadas([])}
          className={`${baseClass} appearance-auto`}
        >
          {ESTADOS_IMPORT.map((o) => (
            <option key={o || "vazio"} value={o} className="bg-navy">
              {o || "—"}
            </option>
          ))}
        </select>
      );
    }

    if (tipo === "prioridade") {
      return (
        <select
          value={val}
          onChange={(e) => actualizarCelula(rowIdx, colIdx, e.target.value)}
          className={`${baseClass} appearance-auto`}
        >
          {PRIORIDADES_IMPORT.map((o) => (
            <option key={o || "vazio"} value={o} className="bg-navy">
              {o ? "SIM (Flash)" : "—"}
            </option>
          ))}
        </select>
      );
    }

    const inputType =
      tipo === "date" ? "date" : tipo === "datetime" ? "datetime-local" : "text";

    return (
      <input
        type={inputType}
        value={val}
        list={
          colIdx === COL_RESPONSAVEL
            ? "datalist-responsavel"
            : colIdx === COL_SKILL
              ? "datalist-skill"
              : undefined
        }
        onChange={(e) => actualizarCelula(rowIdx, colIdx, e.target.value)}
        className={baseClass}
      />
    );
  };

  return (
    <div
      className="space-y-4"
      onPaste={handlePaste}
      onCopy={handleCopy}
      onKeyDown={handleKeyDown}
      tabIndex={0}
      ref={gridRef}
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-lg font-bold text-white">
            📥 Importação Inteligente (Grelha Excel)
          </h1>
          <p className="text-xs text-muted">
            Ctrl+V · arrastar para seleccionar · Shift+clique intervalo · Copy
            (Excel tab) · Delete · Ctrl+Z
          </p>
        </div>
        {onVoltar && (
          <button
            type="button"
            onClick={onVoltar}
            className="rounded-lg bg-white/10 px-4 py-2 text-xs font-semibold text-white hover:bg-white/15"
          >
            ⬅ Voltar
          </button>
        )}
      </div>

      <div className="flex flex-wrap items-center gap-3 rounded-lg bg-white/5 p-3 text-[11px]">
        <span className="text-emerald-300">
          💡 Selecciona células e Ctrl+V do Excel.
        </span>
        <button
          type="button"
          onClick={() => adicionarLinhas(10)}
          className="rounded-lg bg-brand/20 px-2 py-1 font-bold text-brand"
        >
          +10 linhas
        </button>
        <button
          type="button"
          onClick={limparSeleccionadas}
          disabled={seleccionadas.length === 0}
          className="rounded-lg bg-white/10 px-2 py-1 font-bold text-white disabled:opacity-40"
        >
          Limpar selecção
        </button>
        <span className="ml-auto flex flex-wrap gap-3 font-semibold">
          <span className="text-emerald-300">Novos: {stats.novos}</span>
          <span className="text-red-300">Duplicados: {stats.duplicados}</span>
          <span className="text-amber-300">Inválidos: {stats.invalidos}</span>
        </span>
      </div>

      <datalist id="datalist-responsavel">
        {emailsResp.map((e) => (
          <option key={e} value={e} />
        ))}
      </datalist>
      <datalist id="datalist-skill">
        {skills.map((s) => (
          <option key={s} value={s} />
        ))}
      </datalist>

      <div className="max-h-[520px] overflow-auto rounded-lg border border-white/10 bg-black/20 outline-none focus-within:border-brand/30">
        <table className="min-w-[2600px] select-none text-[10px]">
          <thead className="sticky top-0 z-10 bg-navy/95">
            <tr>
              <th className="w-8 border border-white/10 px-1 py-1 text-center text-muted">
                Del
              </th>
              <th className="w-8 border border-white/10 px-1 py-1 text-center text-muted">
                #
              </th>
              {COLUNAS_IMPORT.map((col, cIdx) => (
                <th
                  key={col}
                  onClick={() => {
                    setHighlightRow(null);
                    setHighlightCol(highlightCol === cIdx ? null : cIdx);
                    setSeleccionadas([]);
                  }}
                  className={`cursor-pointer border border-white/10 px-2 py-1 text-left font-semibold transition hover:bg-white/10 ${
                    highlightCol === cIdx
                      ? "bg-amber-500/15 text-amber-200"
                      : cIdx === COL_LOJA
                        ? "bg-brand/10 text-brand"
                        : cIdx === 16
                          ? "bg-amber-500/10 text-amber-200"
                          : "text-muted"
                  }`}
                >
                  {col}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {grid.map((row, rIdx) => {
              const st = rowStatus[rIdx];
              const bg =
                st === "dup"
                  ? "bg-red-500/30"
                  : st === "invalid"
                    ? "bg-amber-500/15"
                    : st === "ok"
                      ? "bg-emerald-500/5"
                      : highlightRow === rIdx
                        ? "bg-amber-500/10"
                        : "";
              return (
                <tr key={rIdx} className={bg}>
                  <td className="border border-white/10 p-0 text-center">
                    <button
                      type="button"
                      onClick={() => apagarLinha(rIdx)}
                      className="px-1 py-1 text-red-400 hover:text-red-300"
                      title="Apagar linha"
                    >
                      ❌
                    </button>
                  </td>
                  <td
                    className={`cursor-pointer border border-white/10 px-1 py-0 text-center text-muted ${
                      highlightRow === rIdx ? "bg-amber-500/15" : ""
                    }`}
                    onClick={() => {
                      setHighlightCol(null);
                      setHighlightRow(highlightRow === rIdx ? null : rIdx);
                      setSeleccionadas([]);
                    }}
                  >
                    {rIdx + 1}
                  </td>
                  {COLUNAS_IMPORT.map((_, cIdx) => (
                    <td
                      key={cIdx}
                      onMouseDown={(e) => {
                        if ((e.target as HTMLElement).closest("select")) return;
                        e.preventDefault();
                        iniciarSelecao(rIdx, cIdx, e.shiftKey);
                      }}
                      onMouseEnter={() => expandirSelecao(rIdx, cIdx)}
                      className={`border border-white/10 p-0 ${
                        highlightCol === cIdx ? "bg-amber-500/10" : ""
                      } ${
                        celulaSeleccionada(rIdx, cIdx)
                          ? "bg-brand/30 ring-2 ring-inset ring-brand/60"
                          : ""
                      }`}
                    >
                      {renderInput(rIdx, cIdx, row[cIdx] ?? "")}
                    </td>
                  ))}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3">
        <p
          className={`text-sm font-semibold ${
            msg.startsWith("✅") ? "text-emerald-300" : "text-white"
          }`}
        >
          {msg}
        </p>
        <button
          type="button"
          disabled={aProcessar || stats.invalidos > 0}
          onClick={() => void processar()}
          className="rounded-xl bg-emerald-600 px-6 py-2.5 text-sm font-bold text-white hover:bg-emerald-500 disabled:opacity-50"
        >
          {aProcessar ? "A importar…" : "🚀 Confirmar e importar"}
        </button>
      </div>

      {modalFalhas && modalFalhas.length > 0 && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <div className="max-h-[80vh] w-full max-w-lg overflow-auto rounded-xl border border-red-500/30 bg-card p-5 shadow-xl">
            <h2 className="text-base font-bold text-red-200">
              Importação bloqueada — detalhe das falhas
            </h2>
            <ul className="mt-3 space-y-2 text-xs text-white">
              {modalFalhas.map((f) => (
                <li
                  key={`${f.linha}-${f.id}`}
                  className="rounded-lg border border-white/10 bg-black/30 p-2"
                >
                  <strong>
                    Linha {f.linha} · ID {f.id}
                  </strong>
                  <p className="mt-1 text-muted">{f.erros.join(", ")}</p>
                </li>
              ))}
            </ul>
            <button
              type="button"
              onClick={() => setModalFalhas(null)}
              className="mt-4 w-full rounded-lg bg-white/10 py-2 text-sm font-semibold text-white"
            >
              Fechar
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
