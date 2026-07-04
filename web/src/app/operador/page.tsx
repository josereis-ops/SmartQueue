import { OperadorDashboard } from "@/components/operador/operador-dashboard";
import { getPerfilUtilizador } from "@/lib/auth/perfil";
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";

export default async function OperadorPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/");
  }

  const perfil = await getPerfilUtilizador(supabase);

  if (!perfil.sucesso || !perfil.utilizador) {
    redirect("/sem-acesso");
  }

  return <OperadorDashboard perfil={perfil.utilizador} />;
}
