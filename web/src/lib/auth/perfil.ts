import type { SupabaseClient } from "@supabase/supabase-js";
import type { PerfilUtilizadorResponse } from "@/lib/types/perfil";

/** Réplica GAS getPerfilUtilizador() via RPC Supabase. */
export async function getPerfilUtilizador(
  supabase: SupabaseClient
): Promise<PerfilUtilizadorResponse> {
  const { data, error } = await supabase.rpc("get_perfil_utilizador");

  if (error) {
    return {
      sucesso: false,
      mensagem: error.message,
      email_tentativa: null,
    };
  }

  return (data ?? {
    sucesso: false,
    mensagem: "Resposta inválida do servidor.",
  }) as PerfilUtilizadorResponse;
}
