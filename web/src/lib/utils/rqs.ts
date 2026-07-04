/** RQS expirada ou para hoje (réplica GAS alertaRqsAtivo) */
export function rqsExpiradaOuHoje(dataRqsIso: string | null): boolean {
  if (!dataRqsIso) return false;
  const dRqs = new Date(dataRqsIso);
  if (Number.isNaN(dRqs.getTime())) return false;

  const limite = new Date();
  limite.setHours(23, 59, 59, 999);
  return dRqs <= limite;
}

export function temIntercalarMarcada(valor: string | null | undefined): boolean {
  return Boolean(valor && valor.toString().trim() !== "");
}
