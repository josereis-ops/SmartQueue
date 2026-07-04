/** Helpers grelha importação — paridade GAS Dashboard.html */

export const COL_LOJA = 0;
export const COL_ID = 1;
export const COL_RESPONSAVEL = 10;
export const COL_SKILL = 14;
export const NUM_COLS = 17;

export const COLS_DATA = new Set([5, 6, 7, 12, 13]);
export const COL_ESTADO = 9;
export const COL_PRIORIDADE = 15;

export const ESTADOS_IMPORT = [
  "",
  "Pendente",
  "Por tratar",
  "Agendado",
  "Outro",
  "Suspenso",
] as const;

export const PRIORIDADES_IMPORT = ["", "SIM"] as const;

export function parseExcelRobust(text: string): string[][] {
  const result: string[][] = [];
  let row: string[] = [];
  let col = "";
  let inQuotes = false;

  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') {
      inQuotes = !inQuotes;
    } else if (char === "\t" && !inQuotes) {
      row.push(col);
      col = "";
    } else if ((char === "\n" || char === "\r") && !inQuotes) {
      if (char === "\r" && text[i + 1] === "\n") i++;
      row.push(col);
      result.push(row);
      row = [];
      col = "";
    } else {
      col += char;
    }
  }
  if (col !== "" || row.length > 0) {
    row.push(col);
    result.push(row);
  }
  return result;
}

/** Converte valor colado para formato ISO date ou datetime-local */
export function formatarValorData(tipo: "date" | "datetime-local", val: string): string {
  if (!val?.trim()) return "";

  const trimmed = val.trim();
  const datePart = trimmed.split(" ")[0].split(/[/\-.]/);

  if (datePart.length === 3) {
    const iso =
      datePart[2].length === 4
        ? `${datePart[2]}-${datePart[1].padStart(2, "0")}-${datePart[0].padStart(2, "0")}`
        : `${datePart[0]}-${datePart[1].padStart(2, "0")}-${datePart[2].padStart(2, "0")}`;

    if (tipo === "datetime-local") {
      const h = trimmed.includes(":") ? trimmed.split(" ")[1]?.slice(0, 5) : "09:00";
      return `${iso}T${h ?? "09:00"}`;
    }
    return iso;
  }

  return trimmed;
}

export function tipoCelula(col: number): "loja" | "date" | "datetime" | "estado" | "prioridade" | "text" {
  if (col === COL_LOJA) return "loja";
  if (col === COL_ESTADO) return "estado";
  if (col === COL_PRIORIDADE) return "prioridade";
  if (col === 12) return "datetime";
  if (COLS_DATA.has(col)) return "date";
  return "text";
}

export function celulaEditavel(col: number): boolean {
  return col !== COL_LOJA;
}

export function formatarValorCelula(col: number, val: string): string {
  const t = tipoCelula(col);
  if (t === "date") return formatarValorData("date", val);
  if (t === "datetime") return formatarValorData("datetime-local", val);
  return val.trim();
}

export function dataValida(s: string): boolean {
  if (!s.trim()) return false;
  const t = new Date(s.trim());
  return !Number.isNaN(t.getTime());
}

export function errosObrigatorios(row: string[]): string[] {
  const erros: string[] = [];
  if (!row[1]?.trim()) erros.push("ID caso");
  if (!row[2]?.trim()) erros.push("Canal de entrada");
  if (!row[14]?.trim()) erros.push("Skill");
  if (!dataValida(row[5] ?? "")) erros.push("Data criação");
  if (!dataValida(row[6] ?? "")) erros.push("Data RQS");
  return erros;
}

export interface CelulaSel {
  row: number;
  col: number;
}

export function intervaloCelulas(a: CelulaSel, b: CelulaSel): CelulaSel[] {
  const r0 = Math.min(a.row, b.row);
  const r1 = Math.max(a.row, b.row);
  const c0 = Math.min(a.col, b.col);
  const c1 = Math.max(a.col, b.col);
  const cells: CelulaSel[] = [];
  for (let r = r0; r <= r1; r++) {
    for (let c = c0; c <= c1; c++) {
      cells.push({ row: r, col: c });
    }
  }
  return cells;
}

export function seleccionParaClipboard(
  grid: string[][],
  seleccionadas: CelulaSel[]
): string {
  if (seleccionadas.length === 0) return "";

  const mapa: Record<number, Record<number, string>> = {};
  let minR = Infinity;
  let maxR = -Infinity;
  let minC = Infinity;
  let maxC = -Infinity;

  seleccionadas.forEach(({ row, col }) => {
    if (!mapa[row]) mapa[row] = {};
    mapa[row][col] = grid[row]?.[col] ?? "";
    minR = Math.min(minR, row);
    maxR = Math.max(maxR, row);
    minC = Math.min(minC, col);
    maxC = Math.max(maxC, col);
  });

  const linhas: string[] = [];
  for (let r = minR; r <= maxR; r++) {
    const cols: string[] = [];
    for (let c = minC; c <= maxC; c++) {
      cols.push(mapa[r]?.[c] ?? "");
    }
    linhas.push(cols.join("\t"));
  }
  return linhas.join("\n");
}
