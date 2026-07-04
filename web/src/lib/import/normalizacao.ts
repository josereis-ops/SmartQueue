/** Réplica GAS _normalizarIdImportacao_ — inclui notação científica Excel E+15 */
export function normalizarIdImportacao(v: string | null | undefined): string {
  if (v == null || String(v).trim() === "") return "";

  let s = String(v).replace(/\s+/g, "").toUpperCase().trim();

  if (s.includes("E+") || s.length > 10) {
    const num = Number(String(v).replace(",", ".").replace(/\s+/g, ""));
    if (!Number.isNaN(num)) {
      s = BigInt(Math.round(num)).toString();
    }
  }

  if (s === "" || s === "NULL") return "";
  return s;
}
