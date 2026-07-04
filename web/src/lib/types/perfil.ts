export interface UtilizadorPerfil {
  id: string;
  email: string;
  nome: string;
  perfil: string;
  perfil_slug: string;
  area_id: string;
  area: string;
  equipa_id: string;
  equipa: string;
  skills?: string;
  ponto_atendimento_id?: string | null;
  ponto_atendimento?: string | null;
  presenca: string;
  is_supervisao: boolean;
}

export interface PerfilUtilizadorResponse {
  sucesso: boolean;
  mensagem?: string;
  email_tentativa?: string | null;
  utilizador?: UtilizadorPerfil;
}
