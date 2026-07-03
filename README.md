# Smart Queue v2

POC multi-área para gestão de filas operacionais. Stack: **Next.js (Vercel)** + **Supabase** (PostgreSQL, Auth, Realtime, RPCs).

Sistema legado Google Apps Script em [`legacy/`](legacy/) — referência only, não alterar.

## Estrutura

```
SmartQueue/
├── legacy/              # Exports GAS (referência)
├── web/                 # Frontend Next.js → Vercel
├── supabase/
│   └── migrations/      # Schema + RLS + RPCs
└── scripts/             # Seeds e utilitários
```

## Pré-requisitos

- Node.js 20+
- Git, GitHub CLI (`gh`), Supabase CLI, Vercel CLI
- Conta Supabase (EU) — projecto `SmartQueue`

## Setup local

```powershell
# 1. Variáveis de ambiente (copiar para web/.env.local quando existir)
cp .env.example web/.env.local

# 2. Supabase — projecto já ligado
supabase link --project-ref gwjfwdbwydwtkxffhysb

# 3. Frontend (quando scaffold Next.js estiver criado)
cd web
npm install
npm run dev
```

## Deploy

| Serviço   | Destino                          |
|-----------|------------------------------------|
| Frontend  | Vercel (ligado ao repo GitHub)     |
| Backend   | Supabase RPCs + RLS (sem servidor) |
| Base dados| Supabase EU (`eu-central-1`)       |

## Comandos úteis

```powershell
supabase db push          # aplicar migrations
supabase db diff          # gerar migration a partir de alterações
gh repo view --web        # abrir repo no browser
```
