# Servidor MCP de GitHub — Setup para el equipo

Este repo trae configurado un servidor MCP de GitHub que le da a tu asistente (Copilot, Claude Code) acceso a repos, issues, pull requests y **GitHub Projects** (para ver el estado de los tableros de la organización).

Corre localmente vía Docker, autenticado con tu propio Personal Access Token (PAT) — no se comparte ningún token en el repo.

## Requisitos

- [Docker](https://docs.docker.com/get-docker/) instalado y corriendo.
- Un Personal Access Token de GitHub con acceso a esta organización.

## 1. Generar tu Personal Access Token

1. Andá a GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens**.
2. Creá uno con acceso a los repos/organización que corresponda.
3. En permisos, habilitá al menos:
   - **Contents**: Read
   - **Issues**: Read and write
   - **Pull requests**: Read and write
   - **Projects**: Read and write

## 2. Exportar el token como variable de entorno

**Ubuntu / macOS (bash):**
```bash
echo 'export GITHUB_PERSONAL_ACCESS_TOKEN=tu_token_aqui' >> ~/.bashrc
source ~/.bashrc
```

**macOS (zsh):**
```bash
echo 'export GITHUB_PERSONAL_ACCESS_TOKEN=tu_token_aqui' >> ~/.zshrc
source ~/.zshrc
```

**Windows (PowerShell):**
```powershell
[System.Environment]::SetEnvironmentVariable("GITHUB_PERSONAL_ACCESS_TOKEN", "tu_token_aqui", "User")
```

> Reiniciá tu editor/IDE por completo después de este paso (no alcanza con recargar la ventana).

## 3. Activar el servidor según tu editor

| Editor | Qué hacer |
|---|---|
| **VS Code (GitHub Copilot)** | Ya está en `.vscode/mcp.json`. Abrí el archivo y hacé clic en "Start" arriba del bloque `github`, o `Ctrl+Shift+P` → `MCP: List Servers`. |
| **Claude Code** (CLI o extensión VS Code) | Ya está en `.mcp.json` en la raíz. Corré `/mcp` en el chat para confirmar que dice "Connected". |
| **Antigravity** | No se lee automáticamente del repo. Copiá el contenido de `antigravity-mcp-config.reference.json` en: panel Agent → `...` → **MCP Servers** → **Manage MCP Servers** → **View raw config**. |

## Troubleshooting

- **"Connected" nunca aparece / error de auth**: confirmá que `echo $GITHUB_PERSONAL_ACCESS_TOKEN` te devuelve el token en una terminal nueva. Si no aparece, el editor no heredó la variable — reinicialo por completo.
- **Docker no encuentra la imagen**: la primera vez tarda unos segundos en descargar `ghcr.io/github/github-mcp-server`. Necesitás conexión a internet la primera vez que se ejecuta.
- **No ves herramientas de Projects**: confirmá que tu PAT tiene el permiso "Projects" habilitado (paso 1).